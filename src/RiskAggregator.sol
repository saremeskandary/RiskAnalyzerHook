// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import "../lib/RiskMath.sol";
import "./interfaces.sol";

/**
 * @title RiskAggregator
 * @notice Aggregates risk metrics from various sources to provide comprehensive risk assessment
 * @dev Implements IRiskAggregator interface
 */
abstract contract RiskAggregator is IRiskAggregator, Ownable, Pausable {
    using PoolIdLibrary for PoolKey;

    // Component interfaces
    IVolatilityOracle public immutable volatilityOracle;
    ILiquidityScoring public immutable liquidityScoring;
    IPositionManager public immutable positionManager;
    IRiskRegistry public immutable riskRegistry;

    // Risk metric weights
    uint256 public constant VOLATILITY_WEIGHT = 35; // 35%
    uint256 public constant LIQUIDITY_WEIGHT = 35; // 35%
    uint256 public constant POSITION_WEIGHT = 30; // 30%

    // Risk thresholds
    uint256 public constant HIGH_RISK_THRESHOLD = 7500; // 75%
    uint256 public constant RISK_DECIMALS = 2;
    uint256 public constant MAX_RISK_SCORE = 10000; // 100%

    // Cache duration
    uint256 public constant CACHE_DURATION = 5 minutes;

    // Cached risk scores
    struct RiskCache {
        uint256 riskScore;
        uint256 lastUpdate;
    }

    // Risk score cache
    mapping(PoolId => RiskCache) public poolRiskCache;
    mapping(address => RiskCache) public userRiskCache;

    // System metrics
    struct SystemMetrics {
        uint256 totalRisk;
        uint256 riskCount;
        uint256 highRiskCount;
        uint256 lastUpdate;
    }

    SystemMetrics public systemMetrics;

    // Events
    event RiskScoreUpdated(PoolId indexed poolId, uint256 newScore, uint256 timestamp);

    event UserRiskUpdated(address indexed user, uint256 newScore, uint256 timestamp);

    event SystemRiskUpdated(uint256 totalRisk, uint256 averageRisk, uint256 highRiskCount, uint256 timestamp);

    // Errors
    error InvalidAddress();
    error StaleCache();
    error InvalidPoolId();

    constructor(address _volatilityOracle, address _liquidityScoring, address _positionManager, address _riskRegistry)
        Ownable(msg.sender)
    {
        if (
            _volatilityOracle == address(0) || _liquidityScoring == address(0) || _positionManager == address(0)
                || _riskRegistry == address(0)
        ) {
            revert InvalidAddress();
        }

        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        liquidityScoring = ILiquidityScoring(_liquidityScoring);
        positionManager = IPositionManager(_positionManager);
        riskRegistry = IRiskRegistry(_riskRegistry);
    }

    /**
     * @notice Aggregate risk metrics for a pool
     * @param key Pool identifier
     */
    function aggregatePoolRisk(PoolKey calldata key) external whenNotPaused returns (uint256 totalRiskScore) {
        // if (key.toId() == bytes32(0)) revert InvalidPoolId();
        if (keccak256(abi.encode(key)) == keccak256(abi.encode(bytes32(0)))) revert InvalidPoolId();

        RiskCache storage cache = poolRiskCache[key.toId()];

        // Return cached value if fresh
        if (block.timestamp - cache.lastUpdate <= CACHE_DURATION) {
            return cache.riskScore;
        }

        // Get volatility metrics
        IVolatilityOracle.VolatilityData memory volData = volatilityOracle.getVolatilityData(key);

        // Calculate volatility score
        uint256 volatilityScore = _calculateVolatilityScore(volData);

        // Get liquidity metrics and score
        uint256 liquidityScore = _calculateLiquidityScore(key);

        // Get position risk metrics
        uint256 positionScore = _calculatePositionScore(key);

        // Calculate weighted risk score
        uint256[] memory scores = new uint256[](3);
        uint256[] memory weights = new uint256[](3);

        scores[0] = volatilityScore;
        scores[1] = liquidityScore;
        scores[2] = positionScore;

        weights[0] = VOLATILITY_WEIGHT;
        weights[1] = LIQUIDITY_WEIGHT;
        weights[2] = POSITION_WEIGHT;

        totalRiskScore = RiskMath.calculateWeightedRisk(scores, weights);

        // Update cache
        cache.riskScore = totalRiskScore;
        cache.lastUpdate = block.timestamp;

        // Update system metrics
        _updateSystemMetrics(totalRiskScore);

        emit RiskScoreUpdated(key.toId(), totalRiskScore, block.timestamp);

        return totalRiskScore;
    }

    /**
     * @notice Aggregate risk metrics for a user
     * @param user User address
     */
function aggregateUserRisk(address user) external view override whenNotPaused returns (uint256 totalRiskScore) {
    if (user == address(0)) revert InvalidAddress();

    RiskCache storage cache = userRiskCache[user];

    // Return cached value if fresh
    if (block.timestamp - cache.lastUpdate <= CACHE_DURATION) {
        return cache.riskScore;
    }

    // Get all pools
    PoolKey[] memory pools = riskRegistry.getAllPools();
    uint256 totalPositions;
    uint256 totalRisk;

    // Calculate risk for each position
    for (uint256 i = 0; i < pools.length; i++) {
        // Create a new calldata-compatible PoolKey
        PoolKey memory currentPool = pools[i];
        
        IPositionManager.PositionData memory position = positionManager.getPositionData(user, currentPool);
        
        if (position.size > 0) {
            uint256 poolRisk = this.calculatePoolRisk(currentPool); // Use this. to force external call
            totalRisk += (poolRisk * position.size);
            totalPositions += position.size;
        }
    }

    // Calculate weighted average risk
    totalRiskScore = totalPositions > 0 ? totalRisk / totalPositions : 0;

    return totalRiskScore;
}

// Add a public version of calculatePoolRisk that can handle memory parameters
function calculatePoolRisk(PoolKey memory key) public view returns (uint256) {
    // Implementation of risk calculation
    // This can now be called both internally and externally
    return _calculatePoolRisk(key);
}

// Keep the internal function for direct internal calls
function _calculatePoolRisk(PoolKey memory key) internal view returns (uint256) {
    // Original implementation
    // ...
}
    /**
     * @notice Get system-wide risk metrics
     */
    function getSystemRisk()
        external
        view
        override
        returns (uint256 totalRisk, uint256 averageRisk, uint256 highRiskCount)
    {
        if (block.timestamp - systemMetrics.lastUpdate > CACHE_DURATION) {
            revert StaleCache();
        }

        totalRisk = systemMetrics.totalRisk;
        averageRisk = systemMetrics.riskCount > 0 ? totalRisk / systemMetrics.riskCount : 0;
        highRiskCount = systemMetrics.highRiskCount;
    }

    /**
     * @notice Calculate volatility score
     */
    function _calculateVolatilityScore(IVolatilityOracle.VolatilityData memory volData)
        internal
        pure
        returns (uint256)
    {
        if (volData.prices.length == 0) return 0;

        int256 mean = RiskMath.calculateMean(volData.prices);
        return RiskMath.calculateVolatility(volData.prices, mean);
    }

    /**
     * @notice Calculate liquidity score
     */
    function _calculateLiquidityScore(PoolKey calldata key) internal view returns (uint256) {
        IRiskRegistry.RiskParameters memory params = riskRegistry.getPoolParameters(key);

        uint256 liquidityThreshold = params.liquidityThreshold;
        if (liquidityThreshold == 0) return MAX_RISK_SCORE;

        uint256 currentLiquidity = liquidityScoring.calculateStabilityScore(key, liquidityThreshold);

        return currentLiquidity >= liquidityThreshold
            ? 0
            : ((liquidityThreshold - currentLiquidity) * MAX_RISK_SCORE) / liquidityThreshold;
    }

    /**
     * @notice Calculate position score
     */
    function _calculatePositionScore(PoolKey calldata key) internal view returns (uint256) {
        IPositionManager.PositionData memory position = positionManager.getPositionData(address(this), key);

        return position.riskScore;
    }

    /**
     * @notice Update system metrics
     */
    function _updateSystemMetrics(uint256 newRiskScore) internal {
        systemMetrics.totalRisk += newRiskScore;
        systemMetrics.riskCount++;

        if (newRiskScore >= HIGH_RISK_THRESHOLD) {
            systemMetrics.highRiskCount++;
        }

        systemMetrics.lastUpdate = block.timestamp;

        emit SystemRiskUpdated(
            systemMetrics.totalRisk,
            systemMetrics.totalRisk / systemMetrics.riskCount,
            systemMetrics.highRiskCount,
            block.timestamp
        );
    }

    /**
     * @notice Force cache refresh for pool
     */
    function refreshPoolCache(PoolKey calldata key) external onlyOwner {
        delete poolRiskCache[key.toId()];
    }

    /**
     * @notice Force cache refresh for user
     */
    function refreshUserCache(address user) external onlyOwner {
        delete userRiskCache[user];
    }

    /**
     * @notice Reset system metrics
     */
    function resetSystemMetrics() external onlyOwner {
        delete systemMetrics;
        systemMetrics.lastUpdate = block.timestamp;
    }

    /**
     * @notice Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Get raw risk components for pool
     */
    function getRiskComponents(PoolKey calldata key)
        external
        view
        returns (uint256 volatilityRisk, uint256 liquidityRisk, uint256 positionRisk)
    {
        IVolatilityOracle.VolatilityData memory volData = volatilityOracle.getVolatilityData(key);

        volatilityRisk = _calculateVolatilityScore(volData);
        liquidityRisk = _calculateLiquidityScore(key);
        positionRisk = _calculatePositionScore(key);
    }
}
