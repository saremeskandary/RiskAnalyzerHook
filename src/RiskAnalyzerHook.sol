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
import "../lib/RiskMath.sol";
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
    uint256 public constant VOLATILITY_WEIGHT = 9000; // 90%
    uint256 public constant LIQUIDITY_WEIGHT = 9000; // 90%
    uint256 public constant POSITION_WEIGHT = 9000; // 90%

    // Mapping to track pool metrics
    mapping(PoolId => RiskMetrics) public poolMetrics;

    // Events
    event PoolRiskUpdated(PoolId indexed poolId, RiskMetrics metrics);
    event HighRiskDetected(PoolId indexed poolId, string reason);
    event ActionTriggered(PoolId indexed poolId, IRiskController.ActionType actionType);

    // Errors
    error RiskTooHigh();
    error UnauthorizedCallback();
    error InvalidAddress();

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

    function calculatePoolRisk(PoolId poolId) external view returns (uint256 totalRiskScore) {
        // Calculate risk without updating cache
        uint256 volatilityScore = riskRegistry.calculateVolatilityScore(volatilityOracle.getVolatilityData(poolId));
        uint256 liquidityScore = riskRegistry.calculateLiquidityScore(poolId);
        uint256 positionScore = riskRegistry.calculatePositionScore(poolId);

        uint256[] memory scores = new uint256[](3);
        uint256[] memory weights = new uint256[](3);
        scores[0] = volatilityScore;
        scores[1] = liquidityScore;
        scores[2] = positionScore;
        weights[0] = VOLATILITY_WEIGHT;
        weights[1] = LIQUIDITY_WEIGHT;
        weights[2] = POSITION_WEIGHT;

        return RiskMath.calculateWeightedRisk(scores, weights);
    }

    function calculateUserRisk(address user) external view returns (uint256 totalRiskScore) {
        if (user == address(0)) revert InvalidAddress();

        // Get all pools
        PoolId[] memory pools = riskRegistry.getAllPools();
        uint256 totalPositions;
        uint256 totalRisk;

        // Calculate risk for each position without caching
        for (uint256 i = 0; i < pools.length; i++) {
            IPositionManager.PositionData memory position = positionManager.getPositionData(user, pools[i]);
            if (position.size > 0) {
                uint256 poolRisk = this.calculatePoolRisk(pools[i]);
                totalRisk += (poolRisk * position.size);
                totalPositions += position.size;
            }
        }

        return totalPositions > 0 ? totalRisk / totalPositions : 0;
    }

    /**
     * @notice Update risk parameters for a pool
     */
    function updateRiskParameters(PoolKey calldata key, RiskParameters calldata newParams) external {
        // Convert from IUniswapV4RiskAnalyzerHook.RiskParameters to IRiskRegistry.RiskParameters
        IRiskRegistry.RiskParameters memory registryParams = IRiskRegistry.RiskParameters({
            volatilityThreshold: newParams.maxVolatility,
            liquidityThreshold: newParams.minLiquidity,
            concentrationThreshold: newParams.maxConcentration,
            isActive: newParams.circuitBreakerEnabled
        });

        riskRegistry.updatePoolParameters(key, registryParams);
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
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(key.toId());
        if (totalRisk >= CRITICAL_RISK_THRESHOLD) {
            _handleCriticalRisk(key, "Critical risk level detected before swap");
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
        int128 a = delta.amount0();
        _updatePoolMetrics(key, params.sqrtPriceLimitX96, a);

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
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(key.toId());
        if (totalRisk >= HIGH_RISK_THRESHOLD) {
            _handleHighRisk(key, "High concentration risk detected");
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
            key.toId(),
            _calculatePositionRisk(key.toId(), uint256(-params.liquidityDelta), params.tickLower, params.tickUpper)
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
        _updatePoolMetrics(key, 0, delta.amount0());

        return (
            IHooks.afterAddLiquidity.selector,
            BalanceDelta.wrap(0) // Return zero balance delta if no changes needed
        );
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        PoolId poolId = key.toId();
        _updatePoolMetrics(key, 0, delta.amount0());

        return (IHooks.afterRemoveLiquidity.selector, delta);
    }
    /**
     * @notice Calculate position risk score
     */

    function _calculatePositionRisk(PoolId poolId, uint256 liquidityDelta, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256)
    {
        // Removed 'view' modifier
        return riskAggregator.aggregatePoolRisk(poolId);
    }

    /**
     * @notice Update pool metrics
     */
    function _updatePoolMetrics(PoolKey calldata key, uint160 sqrtPriceX96, int128 amount) internal {
        RiskMetrics storage metrics = poolMetrics[key.toId()];

        // Update metrics
        metrics.lastPrice = sqrtPriceX96 > 0 ? int256(uint256(sqrtPriceX96)) : metrics.lastPrice;
        metrics.lastUpdateBlock = block.number;
        // Remove updateCounter increment since it's not part of the struct

        // If liquidityScoring expects uint256, convert here
        uint256 absAmount = amount >= 0 ? uint256(uint128(amount)) : uint256(uint128(-amount));

        // Calculate new metrics
        metrics.volatilityScore = volatilityOracle.calculateVolatility(key.toId(), metrics.lastPrice);
        metrics.liquidityScore = liquidityScoring.calculateStabilityScore(key.toId(), absAmount);

        // Update concentration risk if needed
        metrics.concentrationRisk = 0; // Set appropriate concentration risk calculation

        // Update high risk status if needed
        metrics.isHighRisk = metrics.volatilityScore > HIGH_RISK_THRESHOLD
            || metrics.liquidityScore > HIGH_RISK_THRESHOLD || metrics.concentrationRisk > HIGH_RISK_THRESHOLD;
    }
    /**
     * @notice Handle high risk situation
     */

    function _handleHighRisk(PoolKey calldata key, string memory reason) internal {
        emit HighRiskDetected(key.toId(), reason);

        // Notify relevant parties
        riskNotifier.notifyUser(msg.sender, 3, string(abi.encodePacked("High risk alert: ", reason)));

        // Execute risk control action
        riskController.executeAction(key, IRiskController.ActionType.WARNING);
        emit ActionTriggered(key.toId(), IRiskController.ActionType.WARNING);
    }

    /**
     * @notice Handle critical risk situation
     */
    function _handleCriticalRisk(PoolKey calldata key, string memory reason) internal {
        emit HighRiskDetected(key.toId(), reason);

        // Notify relevant parties
        riskNotifier.notifyUser(msg.sender, 4, string(abi.encodePacked("CRITICAL risk alert: ", reason)));

        // Execute emergency action
        riskController.executeAction(key, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(key.toId(), IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Get risk metrics for a pool
     */
    function getRiskMetrics(PoolKey calldata key) external view returns (RiskMetrics memory) {
        return poolMetrics[key.toId()];
    }

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(PoolKey calldata key) external onlyOwner {
        riskController.executeAction(key, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(key.toId(), IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Resume pool operations
     */
    function resumeOperations(PoolKey calldata key) external onlyOwner {
        riskController.resetControls(key);
        riskRegistry.activatePool(key);
        poolMetrics[key.toId()].isHighRisk = false;
    }

    /**
     * @notice Get position risk data
     */
    function getPositionRisk(address user, PoolKey calldata key) external view returns (PositionRisk memory) {
        uint256 riskScore = riskAggregator.aggregateUserRisk(user);

        // Get position details from position manager
        IPositionManager.PositionData memory posData = positionManager.getPositionData(user, key.toId());

        // Create and return PositionRisk struct with all required fields
        return PositionRisk({
            size: posData.size,
            tickLower: posData.tickLower,
            tickUpper: posData.tickUpper,
            riskScore: riskScore,
            lastAssessment: block.timestamp
        });
    }

    /**
     * @notice Initialize hooks for a new pool
     */
    function initializePoolHooks(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        if (poolMetrics[poolId].lastUpdateBlock > 0) revert InvalidPool();

        // Initialize all components for the pool using IRiskRegistry.RiskParameters
        IRiskRegistry.RiskParameters memory registryParams = IRiskRegistry.RiskParameters({
            volatilityThreshold: 1000, // 10%
            liquidityThreshold: 1000000, // Base liquidity requirement
            concentrationThreshold: 7500, // 75%
            isActive: true // Active by default
        });

        riskRegistry.registerPool(key, registryParams);

        // Initialize metrics using IUniswapV4RiskAnalyzerHook.RiskMetrics
        poolMetrics[poolId] = RiskMetrics({
            volatilityScore: 0,
            liquidityScore: 0,
            concentrationRisk: 0,
            lastPrice: 0,
            lastUpdateBlock: block.number,
            isHighRisk: false
        });
    }
}
