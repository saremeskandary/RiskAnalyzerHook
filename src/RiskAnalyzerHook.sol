// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces.sol";

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
    mapping(bytes32 => RiskMetrics) public poolMetrics;

    // Events
    event PoolRiskUpdated(bytes32 indexed poolId, RiskMetrics metrics);
    event HighRiskDetected(bytes32 indexed poolId, string reason);
    event ActionTriggered(bytes32 indexed poolId, IRiskController.ActionType actionType);

    // Errors
    error RiskTooHigh();
    error InvalidPool();
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

    /**
     * @notice Hook callback before swap
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        
        bytes32 poolId = key.toId();
        RiskMetrics storage metrics = poolMetrics[poolId];
        
        // Update volatility with new price
        metrics.volatilityScore = volatilityOracle.calculateVolatility(
            poolId,
            params.sqrtPriceLimitX96 > 0 ? int256(uint256(params.sqrtPriceLimitX96)) : metrics.lastPrice
        );
        
        // Check if risk is too high
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(poolId);
        if (totalRisk >= CRITICAL_RISK_THRESHOLD) {
            _handleCriticalRisk(poolId, "Critical risk level detected before swap");
            revert RiskTooHigh();
        }
        
        return BaseHook.beforeSwap.selector;
    }

    /**
     * @notice Hook callback after swap
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        
        bytes32 poolId = key.toId();
        _updatePoolMetrics(poolId, params.sqrtPriceLimitX96, uint256(delta.amount0()));
        
        return BaseHook.afterSwap.selector;
    }

    /**
     * @notice Hook callback before modify position
     */
    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        
        bytes32 poolId = key.toId();
        RiskMetrics storage metrics = poolMetrics[poolId];
        
        // Update position risk
        positionManager.updatePosition(
            sender,
            poolId,
            uint256(params.liquidityDelta),
            params.tickLower,
            params.tickUpper,
            metrics.lastPrice
        );
        
        // Check concentration risk
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(poolId);
        if (totalRisk >= HIGH_RISK_THRESHOLD) {
            _handleHighRisk(poolId, "High concentration risk detected");
        }
        
        return BaseHook.beforeModifyPosition.selector;
    }

    /**
     * @notice Hook callback after modify position
     */
    function afterModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        BalanceDelta delta
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        
        bytes32 poolId = key.toId();
        _updatePoolMetrics(poolId, 0, uint256(delta.amount0()));
        
        return BaseHook.afterModifyPosition.selector;
    }

    /**
     * @notice Update pool metrics
     */
    function _updatePoolMetrics(
        bytes32 poolId,
        uint160 sqrtPriceX96,
        uint256 amount
    ) internal {
        RiskMetrics storage metrics = poolMetrics[poolId];
        
        // Update metrics
        metrics.lastPrice = sqrtPriceX96 > 0 ? 
            int256(uint256(sqrtPriceX96)) : metrics.lastPrice;
        metrics.lastUpdateBlock = block.number;
        metrics.updateCounter++;
        
        // Calculate new metrics
        metrics.volatilityScore = volatilityOracle.calculateVolatility(
            poolId,
            metrics.lastPrice
        );
        
        metrics.liquidityScore = liquidityScoring.calculateStabilityScore(
            poolId,
            amount
        );
        
        // Update risk registry
        uint256 totalRisk = riskAggregator.aggregatePoolRisk(poolId);
        metrics.isHighRisk = totalRisk >= HIGH_RISK_THRESHOLD;
        
        emit PoolRiskUpdated(poolId, metrics);
        
        if (metrics.isHighRisk) {
            _handleHighRisk(poolId, "High risk detected during metric update");
        }
    }

    /**
     * @notice Handle high risk situation
     */
    function _handleHighRisk(bytes32 poolId, string memory reason) internal {
        emit HighRiskDetected(poolId, reason);
        
        // Notify relevant parties
        riskNotifier.notifyUser(
            msg.sender,
            3,
            string(abi.encodePacked("High risk alert: ", reason))
        );
        
        // Execute risk control action
        riskController.executeAction(poolId, IRiskController.ActionType.WARNING);
        emit ActionTriggered(poolId, IRiskController.ActionType.WARNING);
    }

    /**
     * @notice Handle critical risk situation
     */
    function _handleCriticalRisk(bytes32 poolId, string memory reason) internal {
        emit HighRiskDetected(poolId, reason);
        
        // Notify relevant parties
        riskNotifier.notifyUser(
            msg.sender,
            4,
            string(abi.encodePacked("CRITICAL risk alert: ", reason))
        );
        
        // Execute emergency action
        riskController.executeAction(poolId, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(poolId, IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Get risk metrics for a pool
     */
    function getRiskMetrics(bytes32 poolId) 
        external 
        view 
        override
        returns (RiskMetrics memory) 
    {
        return poolMetrics[poolId];
    }

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(bytes32 poolId) external override onlyOwner {
        riskController.executeAction(poolId, IRiskController.ActionType.EMERGENCY);
        emit ActionTriggered(poolId, IRiskController.ActionType.EMERGENCY);
    }

    /**
     * @notice Resume pool operations
     */
    function resumeOperations(bytes32 poolId) external override onlyOwner {
        riskController.resetControls(poolId);
        riskRegistry.activatePool(poolId);
        poolMetrics[poolId].isHighRisk = false;
    }

    /**
     * @notice Get position risk data
     */
    function getPositionRisk(
        address user,
        bytes32 poolId
    ) external view returns (uint256 riskScore) {
        return riskAggregator.aggregateUserRisk(user);
    }

    /**
     * @notice Initialize hooks for a new pool
     */
    function initializePoolHooks(PoolKey calldata key) external {
        bytes32 poolId = key.toId();
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