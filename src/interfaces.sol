// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IRiskAnalyzerHook
 * @notice Interface for the main Risk Analyzer hook contract
 */
interface IRiskAnalyzerHook {
    /**
     * @notice Risk metrics structure
     */
    struct RiskMetrics {
        uint256 volatility;
        uint256 liquidityDepth;
        uint256 concentrationRisk;
        uint256 lastUpdateBlock;
        int256 lastPrice;
        uint256 updateCounter;
    }

    /**
     * @notice Circuit breaker configuration structure
     */
    struct CircuitBreaker {
        uint256 threshold;
        uint256 cooldownPeriod;
        uint256 lastTriggered;
        bool isActive;
    }

    /**
     * @notice Emitted when risk score is updated
     */
    event RiskScoreUpdated(bytes32 indexed poolId, uint256 newRiskScore);

    /**
     * @notice Emitted when high risk is detected
     */
    event HighRiskAlert(bytes32 indexed poolId, uint256 riskScore, string reason);

    /**
     * @notice Emitted when position risk is updated
     */
    event PositionRiskUpdated(address indexed user, bytes32 indexed poolId, uint256 riskScore);

    /**
     * @notice Get risk metrics for a pool
     */
    function getPoolRiskMetrics(bytes32 poolId) external view returns (RiskMetrics memory);

    /**
     * @notice Get position risk score for a user
     */
    function getPositionRiskScore(address user, bytes32 poolId) external view returns (uint256);

    /**
     * @notice Get circuit breaker status
     */
    function getCircuitBreaker(bytes32 poolId) external view returns (CircuitBreaker memory);

    /**
     * @notice Update risk parameters
     */
    function updateRiskParameters(bytes32 poolId, uint256 newVolatilityThreshold, uint256 newLiquidityThreshold)
        external;

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(bytes32 poolId) external;

    /**
     * @notice Resume pool operations
     */
    function resumeOperations(bytes32 poolId) external;
}

/**
 * @title ILiquidityScoring
 * @notice Interface for liquidity scoring functionality
 */
interface ILiquidityScoring {
    /**
     * @notice Token information structure
     */
    struct TokenInfo {
        uint256 marketCap;
        uint256 dailyVolume;
        uint256 lastUpdate;
    }

    /**
     * @notice Historical liquidity data structure
     */
    struct LiquidityHistory {
        uint256[] liquidityValues;
        uint256[] timestamps;
        uint256 currentIndex;
        uint256 windowSize;
    }

    /**
     * @notice Calculate comprehensive liquidity score
     */
    function calculateLiquidityScore(
        uint256 totalLiquidity,
        int256 currentPrice,
        address token0,
        address token1,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256);

    /**
     * @notice Calculate market cap based score
     */
    function calculateMarketCapScore(uint256 totalLiquidity, address token0, address token1)
        external
        view
        returns (uint256);

    /**
     * @notice Calculate distribution score
     */
    function calculateDistributionScore(uint256 totalLiquidity, int256 currentPrice, int24 tickLower, int24 tickUpper)
        external
        pure
        returns (uint256);

    /**
     * @notice Calculate stability score
     */
    function calculateStabilityScore(bytes32 poolId, uint256 currentLiquidity) external view returns (uint256);
}

/**
 * @title IRiskNotifier
 * @notice Interface for risk notification system
 */
interface IRiskNotifier {
    /**
     * @notice Notification structure
     */
    struct Notification {
        address user;
        uint256 riskLevel;
        string message;
        uint256 timestamp;
    }

    /**
     * @notice Emitted when risk notification is sent
     */
    event RiskNotification(address indexed user, uint256 riskLevel, string message);

    /**
     * @notice Get notifications for a user
     */
    function getUserNotifications(address user) external view returns (Notification[] memory);

    /**
     * @notice Send notification to user
     */
    function notifyUser(address user, uint256 riskLevel, string memory message) external;

    /**
     * @notice Clear notifications for a user
     */
    function clearNotifications(address user) external;
}

/**
 * @title IVolatilityOracle
 * @notice Interface for volatility calculations
 */
interface IVolatilityOracle {
    /**
     * @notice Volatility data structure
     */
    struct VolatilityData {
        int256[] prices;
        uint256 windowSize;
        uint256 currentIndex;
    }

    /**
     * @notice Get volatility data for a pool
     */
    function getVolatilityData(bytes32 poolId) external view returns (VolatilityData memory);

    /**
     * @notice Calculate volatility score
     */
    function calculateVolatility(bytes32 poolId, int256 newPrice) external returns (uint256);

    /**
     * @notice Update volatility window size
     */
    function updateVolatilityWindow(bytes32 poolId, uint256 newWindowSize) external;
}

/**
 * @title IRiskRegistry
 * @notice Interface for risk registry management
 */
interface IRiskRegistry {
    /**
     * @notice Risk parameter structure
     */
    struct RiskParameters {
        uint256 volatilityThreshold;
        uint256 liquidityThreshold;
        uint256 concentrationThreshold;
        bool isActive;
    }

    /**
     * @notice Register new pool for risk monitoring
     */
    function registerPool(bytes32 poolId, RiskParameters memory params) external;

    /**
     * @notice Update risk parameters for pool
     */
    function updatePoolParameters(bytes32 poolId, RiskParameters memory newParams) external;

    /**
     * @notice Get risk parameters for pool
     */
    function getPoolParameters(bytes32 poolId) external view returns (RiskParameters memory);

    /**
     * @notice Deactivate pool monitoring
     */
    function deactivatePool(bytes32 poolId) external;

    /**
     * @notice Activate pool monitoring
     */
    function activatePool(bytes32 poolId) external;
}

/**
 * @title IPositionManager
 * @notice Interface for position risk management
 */
interface IPositionManager {
    /**
     * @notice Position data structure
     */
    struct PositionData {
        uint256 size;
        int24 tickLower;
        int24 tickUpper;
        uint256 riskScore;
        uint256 lastUpdate;
    }

    /**
     * @notice Get position data
     */
    function getPositionData(address user, bytes32 poolId) external view returns (PositionData memory);

    /**
     * @notice Update position risk score
     */
    function updatePositionRisk(address user, bytes32 poolId, uint256 newRiskScore) external;

    /**
     * @notice Close high risk positions
     */
    function closeRiskyPosition(address user, bytes32 poolId) external returns (bool);
}

/**
 * @title IRiskAggregator
 * @notice Interface for aggregating risk metrics
 */
interface IRiskAggregator {
    /**
     * @notice Aggregate risk metrics for a pool
     */
    function aggregatePoolRisk(bytes32 poolId) external view returns (uint256 totalRiskScore);

    /**
     * @notice Aggregate risk metrics for a user
     */
    function aggregateUserRisk(address user) external view returns (uint256 totalRiskScore);

    /**
     * @notice Get system-wide risk metrics
     */
    function getSystemRisk() external view returns (uint256 totalRisk, uint256 averageRisk, uint256 highRiskCount);
}

/**
 * @title IRiskController
 * @notice Interface for risk control actions
 */
interface IRiskController {
    /**
     * @notice Risk control action types
     */
    enum ActionType {
        WARNING,
        THROTTLE,
        PAUSE,
        EMERGENCY
    }

    /**
     * @notice Execute risk control action
     */
    function executeAction(bytes32 poolId, ActionType actionType) external returns (bool);

    /**
     * @notice Get current control status
     */
    function getControlStatus(bytes32 poolId)
        external
        view
        returns (bool isPaused, bool isThrottled, uint256 lastActionTimestamp);

    /**
     * @notice Reset control status
     */
    function resetControls(bytes32 poolId) external;
}

/**
 * @title IUniswapV4RiskAnalyzerHook
 * @notice Interface for Uniswap v4 Risk Analyzer hook
 * @dev Implements risk analysis and management for Uniswap v4 pools
 */
interface IUniswapV4RiskAnalyzerHook {
    /**
     * @notice Core risk metrics for a pool
     */
    struct RiskMetrics {
        uint256 volatilityScore; // Current volatility measurement
        uint256 liquidityScore; // Liquidity depth and distribution score
        uint256 concentrationRisk; // Measure of liquidity concentration
        int256 lastPrice; // Last recorded price
        uint256 lastUpdateBlock; // Block number of last update
        bool isHighRisk; // Current high risk status
    }

    /**
     * @notice Position-specific risk data
     */
    struct PositionRisk {
        uint256 size; // Position size
        int24 tickLower; // Lower tick bound
        int24 tickUpper; // Upper tick bound
        uint256 riskScore; // Calculated risk score
        uint256 lastAssessment; // Timestamp of last assessment
    }

    /**
     * @notice Risk control parameters
     */
    struct RiskParameters {
        uint256 maxVolatility; // Maximum acceptable volatility
        uint256 minLiquidity; // Minimum required liquidity
        uint256 maxConcentration; // Maximum acceptable concentration
        uint256 cooldownPeriod; // Period between risk assessments
        bool circuitBreakerEnabled; // Circuit breaker status
    }

    /**
     * @notice Emitted when risk parameters are updated
     */
    event RiskParametersUpdated(bytes32 indexed poolId, RiskParameters parameters);

    /**
     * @notice Emitted when high risk is detected
     */
    event HighRiskDetected(bytes32 indexed poolId, uint256 riskScore, string reason);

    /**
     * @notice Emitted when circuit breaker is triggered
     */
    event CircuitBreakerTriggered(bytes32 indexed poolId, uint256 timestamp);

    /**
     * @notice Hook called before swap
     * @dev Implements the beforeSwap hook required by Uniswap v4
     */
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (bytes4);

    /**
     * @notice Hook called after swap
     * @dev Implements the afterSwap hook required by Uniswap v4
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) external returns (bytes4);

    /**
     * @notice Hook called before modifying position
     * @dev Implements the beforeModifyPosition hook required by Uniswap v4
     */
    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external returns (bytes4);

    /**
     * @notice Hook called after modifying position
     * @dev Implements the afterModifyPosition hook required by Uniswap v4
     */
    function afterModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        BalanceDelta delta
    ) external returns (bytes4);

    /**
     * @notice Get current risk metrics for a pool
     */
    function getRiskMetrics(bytes32 poolId) external view returns (RiskMetrics memory);

    /**
     * @notice Get position risk data
     */
    function getPositionRisk(address user, bytes32 poolId) external view returns (PositionRisk memory);

    /**
     * @notice Get current risk parameters
     */
    function getRiskParameters(bytes32 poolId) external view returns (RiskParameters memory);

    /**
     * @notice Update risk parameters for a pool
     */
    function updateRiskParameters(bytes32 poolId, RiskParameters calldata newParams) external;

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(bytes32 poolId) external;

    /**
     * @notice Resume pool operations after shutdown
     */
    function resumeOperations(bytes32 poolId) external;

    /**
     * @notice Get aggregate risk metrics for the system
     */
    function getSystemRisk()
        external
        view
        returns (uint256 totalRisk, uint256 averageRisk, uint256 highRiskPoolCount);
}
