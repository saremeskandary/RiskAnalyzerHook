// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "lib/v4-periphery/src/base/hooks/BaseHook.sol";
import "./interfaces.sol";
import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title RiskAnalyzerHook
 * @notice Main hook contract for Uniswap v4 risk analysis
 * @dev Implements hook callbacks and coordinates risk management
 */
contract RiskAnalyzerHook is IUniswapV4RiskAnalyzerHook, BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // Component interfaces
    IVolatilityOracle public immutable volatilityOracle;
    ILiquidityScoring public immutable liquidityScoring;
    IPositionManager public immutable positionManager;
    IRiskRegistry public immutable riskRegistry;
    IRiskController public immutable riskController;
    IRiskAggregator public immutable riskAggregator;
    IRiskNotifier public immutable riskNotifier;

    // Risk thresholds
    uint256 public constant HIGH_RISK_THRESHOLD = 7500; // 75%
    uint256 public constant CRITICAL_RISK_THRESHOLD = 9000; // 90%

    // Mapping to track pool metrics
    mapping(PoolId => RiskMetrics) public poolMetrics;

    // Events
    event PoolRiskUpdated(PoolId indexed poolId, RiskMetrics metrics);
    event HighRiskDetected(PoolId indexed poolId, string reason);
    event ActionTriggered(PoolId indexed poolId, IRiskController.ActionType actionType);

    // Errors
    error RiskTooHigh();
    error UnauthorizedCallback();

    constructor(
        IPoolManager _poolManager,
        address _volatilityOracle,
        address _liquidityScoring,
        address _positionManager,
        address _riskRegistry,
        address _riskController,
        address _riskAggregator,
        address _riskNotifier
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        liquidityScoring = ILiquidityScoring(_liquidityScoring);
        positionManager = IPositionManager(_positionManager);
        riskRegistry = IRiskRegistry(_riskRegistry);
        riskController = IRiskController(_riskController);
        riskAggregator = IRiskAggregator(_riskAggregator);
        riskNotifier = IRiskNotifier(_riskNotifier);
    }

    /// @dev Safely converts int128 to uint256, taking absolute value
    function _absoluteInt128ToUint256(int128 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(uint128(value)) : uint256(uint128(-value));
    }

    /**
     * @notice Returns the hooks that this contract implements
     */
    function getHooksCalls() public pure virtual returns (uint16) {
        return uint16(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
    }

    /**
     * @notice Returns the hook permissions
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Get risk parameters for a pool
     */
    function getRiskParameters(PoolId poolId) external view override returns (RiskParameters memory) {
        return riskRegistry.getPoolParameters(poolId);
    }

    /**
     * @notice Update risk parameters for a pool
     */
    function updateRiskParameters(PoolId poolId, RiskParameters calldata newParams) external override {
        riskRegistry.updatePoolParameters(poolId, newParams);
    }

    /**
     * @notice Get system-wide risk metrics
     */
    function getSystemRisk()
        external
        view
        override
        returns (uint256 totalRisk, uint256 averageRisk, uint256 highRiskPoolCount)
    {
        return riskAggregator.getSystemRisk();
    }

    /**
     * @notice Hook callback before swap
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();
        RiskMetrics storage metrics = poolMetrics[poolId];

        // Update volatility with new price
        metrics.volatilityScore = volatilityOracle.calculateVolatility(
            poolId, params.sqrtPriceLimitX96 > 0 ? int256(uint256(params.sqrtPriceLimitX96)) : metrics.lastPrice
        );

        // Check if risk is too high
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(poolId);
        if (totalRisk >= CRITICAL_RISK_THRESHOLD) {
            _handleCriticalRisk(poolId, "Critical risk level detected before swap");
            revert RiskTooHigh();
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /**
     * @notice Hook callback after swap
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();
        _updatePoolMetrics(poolId, params.sqrtPriceLimitX96, uint256(delta.amount0()));

        return (IHooks.afterSwap.selector, 0);
    }

    /**
     * @notice Hook callback before modifying liquidity
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();

        // Update liquidity position risk for adding liquidity
        positionManager.updatePositionRisk(
            sender,
            poolId,
            _calculatePositionRisk(poolId, uint256(params.liquidityDelta), params.tickLower, params.tickUpper)
        );

        // Check concentration risk
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(poolId);
        if (totalRisk >= HIGH_RISK_THRESHOLD) {
            _handleHighRisk(poolId, "High concentration risk detected");
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();

        // Update liquidity position risk for removing liquidity
        positionManager.updatePositionRisk(
            sender,
            poolId,
            _calculatePositionRisk(poolId, uint256(-params.liquidityDelta), params.tickLower, params.tickUpper)
        );

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Hook callback after modifying liquidity
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();
        _updatePoolMetrics(poolId, 0, delta.amount0());

        return (IHooks.afterAddLiquidity.selector, );
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();
        _updatePoolMetrics(poolId, 0, uint256(delta.amount0()));

        return IHooks.afterRemoveLiquidity.selector;
    }
    /**
     * @notice Calculate position risk score
     */

    function _calculatePositionRisk(PoolId poolId, uint256 liquidityDelta, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256)
    {
        return riskAggregator.aggregatePoolRisk(poolId);
    }

    /**
     * @notice Update pool metrics
     */
    function _updatePoolMetrics(PoolId poolId, uint160 sqrtPriceX96, int128 amount) internal {
        RiskMetrics storage metrics = poolMetrics[poolId];

        // Update metrics
        metrics.lastPrice = sqrtPriceX96 > 0 ? int256(uint256(sqrtPriceX96)) : metrics.lastPrice;
        metrics.lastUpdateBlock = block.number;
        metrics.updateCounter++;

        // If liquidityScoring expects uint256, convert here
        uint256 absAmount = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));

        // Calculate new metrics
        metrics.volatilityScore = volatilityOracle.calculateVolatility(poolId, metrics.lastPrice);
        metrics.liquidityScore = liquidityScoring.calculateStabilityScore(poolId, absAmount);

        // Rest of the function...
    }

    /**
     * @notice Handle high risk situation
     */
    function _handleHighRisk(PoolId poolId, string memory reason) internal {
        emit HighRiskDetected(poolId, reason);

        // Notify relevant parties
        riskNotifier.notifyUser(msg.sender, 3, string(abi.encodePacked("High risk alert: ", reason)));

        // Execute risk control action
        riskController.executeAction(poolId, IRiskController.ActionType.WARNING);
        emit ActionTriggered(poolId, IRiskController.ActionType.WARNING);
    }

    /**
     * @notice Handle critical risk situation
     */
    function _handleCriticalRisk(PoolId poolId, string memory reason) internal {
        emit HighRiskDetected(poolId, reason);

        // Notify relevant parties
        riskNotifier.notifyUser(msg.sender, 4, string(abi.encodePacked("CRITICAL risk alert: ", reason)));

        // Execute emergency action
        riskController.executeAction(poolId, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(poolId, IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Get risk metrics for a pool
     */
    function getRiskMetrics(PoolId poolId) external view override returns (RiskMetrics memory) {
        return poolMetrics[poolId];
    }

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(PoolId poolId) external override onlyOwner {
        riskController.executeAction(poolId, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(poolId, IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Resume pool operations
     */
    function resumeOperations(PoolId poolId) external override onlyOwner {
        riskController.resetControls(poolId);
        riskRegistry.activatePool(poolId);
        poolMetrics[poolId].isHighRisk = false;
    }

    /**
     * @notice Get position risk data
     */
    function getPositionRisk(address user, PoolId poolId) external view returns (PositionRisk memory) {
        return riskAggregator.aggregateUserRisk(user);
    }

    /**
     * @notice Initialize hooks for a new pool
     */
    function initializePoolHooks(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        if (poolMetrics[poolId].lastUpdateBlock > 0) revert InvalidPool();

        // Initialize all components for the pool
        RiskParameters memory params = RiskParameters({
            volatilityThreshold: 1000, // 10%
            liquidityThreshold: 1000000, // Base liquidity requirement
            concentrationThreshold: 7500, // 75%
            cooldownPeriod: 1 hours,
            circuitBreakerEnabled: true
        });

        riskRegistry.registerPool(poolId, params);

        poolMetrics[poolId] = RiskMetrics({
            volatilityScore: 0,
            liquidityScore: 0,
            concentrationRisk: 0,
            lastPrice: 0,
            lastUpdateBlock: block.number,
            updateCounter: 0,
            isHighRisk: false
        });
    }
}
