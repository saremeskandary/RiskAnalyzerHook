// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";

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
    event RiskScoreUpdated(PoolId indexed poolId, uint256 newRiskScore);

    /**
     * @notice Emitted when high risk is detected
     */
    event HighRiskAlert(PoolId indexed poolId, uint256 riskScore, string reason);

    /**
     * @notice Emitted when position risk is updated
     */
    event PositionRiskUpdated(address indexed user, PoolId indexed poolId, uint256 riskScore);

    /**
     * @notice Get risk metrics for a pool
     */
    function getPoolRiskMetrics(PoolKey calldata key) external view returns (RiskMetrics memory);

    /**
     * @notice Get position risk score for a user
     */
    function getPositionRiskScore(address user, PoolKey calldata key) external view returns (uint256);

    /**
     * @notice Get circuit breaker status
     */
    function getCircuitBreaker(PoolKey calldata key) external view returns (CircuitBreaker memory);

    /**
     * @notice Update risk parameters
     */
    function updateRiskParameters(PoolKey calldata key, uint256 newVolatilityThreshold, uint256 newLiquidityThreshold)
        external;

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(PoolKey calldata key) external;

    /**
     * @notice Resume pool operations
     */
    function resumeOperations(PoolKey calldata key) external;
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
        PoolKey calldata key,
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
    function calculateStabilityScore(PoolKey calldata key, uint256 currentLiquidity) external view returns (uint256);
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
    function getVolatilityData(PoolKey calldata key) external view returns (VolatilityData memory);

    /**
     * @notice Calculate volatility score
     */
    function calculateVolatility(PoolKey calldata key, int256 newPrice) external returns (uint256);

    /**
     * @notice Update volatility window size
     */
    function updateVolatilityWindow(PoolKey calldata key, uint256 newWindowSize) external;
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

    struct VolatilityData {
        int256[] prices;
        uint256 windowSize;
        uint256 currentIndex;
    }

    struct PoolInfo {
        PoolKey key;
        RiskParameters parameters;
        uint256 registrationTime;
        bool isRegistered;
    }

    function calculateVolatilityScore(VolatilityData memory volatilityData) external pure returns (uint256);
    /**
     * @notice Register new pool for risk monitoring
     */
    function registerPool(PoolKey calldata key, RiskParameters memory params) external;

    /**
     * @notice Update risk parameters for pool
     */
    function updatePoolParameters(PoolKey calldata key, RiskParameters memory newParams) external;

    /**
     * @notice Get risk parameters for pool
     */
    function getPoolParameters(PoolKey calldata key) external view returns (RiskParameters memory);
    function isPoolManager(PoolKey calldata key, address manager) external view returns (bool);

    function getAllPools() external view returns (PoolKey[] calldata registeredPools);
    /**
     * @notice Deactivate pool monitoring
     */
    function deactivatePool(PoolKey calldata key) external;

    /**
     * @notice Activate pool monitoring
     */
    function activatePool(PoolKey calldata key) external;
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
    function getPositionData(address user, PoolKey calldata key) external view returns (PositionData memory);

    /**
     * @notice Update position risk score
     */
    function updatePositionRisk(address user, PoolKey calldata key, uint256 newRiskScore) external;

    /**
     * @notice Close high risk positions
     */
    function closeRiskyPosition(address user, PoolKey calldata key) external returns (bool);
}

/**
 * @title IRiskAggregator
 * @notice Interface for aggregating risk metrics
 */
interface IRiskAggregator {
    /**
     * @notice Aggregate risk metrics for a pool
     */
    function aggregatePoolRisk(PoolKey calldata key) external returns (uint256 totalRiskScore);

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
    function executeAction(PoolKey calldata key, ActionType actionType) external returns (bool);

    /**
     * @notice Get current control status
     */
    function getControlStatus(PoolKey calldata key)
        external
        view
        returns (bool isPaused, bool isThrottled, uint256 lastActionTimestamp);

    /**
     * @notice Reset control status
     */
    function resetControls(PoolKey calldata key) external;
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
    event RiskParametersUpdated(PoolKey indexed key, RiskParameters parameters);

    /**
     * @notice Emitted when high risk is detected
     */
    event HighRiskDetected(PoolKey indexed key, uint256 riskScore, string reason);

    /**
     * @notice Emitted when circuit breaker is triggered
     */
    event CircuitBreakerTriggered(PoolKey indexed key, uint256 timestamp);

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
        IPoolManager.ModifyLiquidityParams calldata params
    ) external returns (bytes4);

    /**
     * @notice Hook called after modifying position
     * @dev Implements the afterModifyPosition hook required by Uniswap v4
     */
    function afterModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta
    ) external returns (bytes4);

    /**
     * @notice Get current risk metrics for a pool
     */
    function getRiskMetrics(PoolKey calldata key) external view returns (RiskMetrics memory);

    /**
     * @notice Get position risk data
     */
    function getPositionRisk(address user, PoolKey calldata key) external view returns (PositionRisk memory);

    /**
     * @notice Get current risk parameters
     */
    function getRiskParameters(PoolKey calldata key) external view returns (RiskParameters memory);

    /**
     * @notice Update risk parameters for a pool
     */
    function updateRiskParameters(PoolKey calldata key, RiskParameters calldata newParams) external;

    /**
     * @notice Emergency shutdown of pool
     */
    function emergencyShutdown(PoolKey calldata key) external;

    /**
     * @notice Resume pool operations after shutdown
     */
    function resumeOperations(PoolKey calldata key) external;

    /**
     * @notice Get aggregate risk metrics for the system
     */
    function getSystemRisk()
        external
        view
        returns (uint256 totalRisk, uint256 averageRisk, uint256 highRiskPoolCount);
}
