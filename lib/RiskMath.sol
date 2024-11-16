// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RiskMath
 * @notice Library for risk-related mathematical calculations
 * @dev Uses fixed point arithmetic with 18 decimals precision
 */
library RiskMath {
    // Constants for fixed-point arithmetic (18 decimals)
    uint256 public constant PRECISION = 1e18;
    uint256 public constant HALF_PRECISION = 5e17;
    
    // Constants for risk calculations
    uint256 public constant MAX_VOLATILITY_THRESHOLD = 1e20;  // 100 * PRECISION
    uint256 public constant MIN_LIQUIDITY_THRESHOLD = 1e16;   // 0.01 * PRECISION
    
    /**
     * @notice Calculate exponential weighted moving average (EWMA)
     * @param currentValue Current value
     * @param previousEWMA Previous EWMA value
     * @param smoothingFactor Smoothing factor (alpha) in 18 decimal fixed-point
     * @return Updated EWMA value
     */
    function calculateEWMA(
        uint256 currentValue,
        uint256 previousEWMA,
        uint256 smoothingFactor
    ) public pure returns (uint256) {
        require(smoothingFactor <= PRECISION, "Invalid smoothing factor");
        
        uint256 complement = PRECISION - smoothingFactor;
        
        return (currentValue * smoothingFactor + previousEWMA * complement) / PRECISION;
    }
    
    /**
     * @notice Calculate volatility using standard deviation
     * @param prices Array of historical prices
     * @param mean Mean price
     * @return Standard deviation of prices
     */
    function calculateVolatility(int256[] memory prices, int256 mean) public pure returns (uint256) {
        require(prices.length > 0, "Empty price array");
        
        uint256 sumSquaredDiff;
        
        for (uint256 i = 0; i < prices.length; i++) {
            int256 diff = prices[i] - mean;
            // Convert to unsigned for multiplication
            uint256 absDiff = diff < 0 ? uint256(-diff) : uint256(diff);
            sumSquaredDiff += (absDiff * absDiff) / PRECISION;
        }
        
        return sqrt((sumSquaredDiff * PRECISION) / prices.length);
    }
    
    /**
     * @notice Calculate mean of price array
     * @param prices Array of prices
     * @return Mean price
     */
    function calculateMean(int256[] memory prices) public pure returns (int256) {
        require(prices.length > 0, "Empty price array");
        
        int256 sum;
        for (uint256 i = 0; i < prices.length; i++) {
            sum += prices[i];
        }
        
        return sum / int256(prices.length);
    }
    
    /**
     * @notice Calculate liquidity concentration score
     * @param liquidityPoints Array of liquidity values at different price points
     * @return Concentration score (higher means more concentrated)
     */
    function calculateConcentration(uint256[] memory liquidityPoints) public pure returns (uint256) {
        require(liquidityPoints.length > 0, "Empty liquidity array");
        
        uint256 totalLiquidity;
        uint256 maxLiquidity;
        
        for (uint256 i = 0; i < liquidityPoints.length; i++) {
            totalLiquidity += liquidityPoints[i];
            if (liquidityPoints[i] > maxLiquidity) {
                maxLiquidity = liquidityPoints[i];
            }
        }
        
        if (totalLiquidity == 0) return 0;
        
        // Return ratio of max liquidity to total liquidity
        return (maxLiquidity * PRECISION) / totalLiquidity;
    }
    
    /**
     * @notice Calculate weighted risk score
     * @param metrics Array of risk metrics
     * @param weights Array of weights for each metric
     * @return Weighted risk score
     */
    function calculateWeightedRisk(
        uint256[] memory metrics,
        uint256[] memory weights
    ) public pure returns (uint256) {
        require(metrics.length == weights.length, "Length mismatch");
        require(metrics.length > 0, "Empty arrays");
        
        uint256 totalWeight;
        uint256 weightedSum;
        
        for (uint256 i = 0; i < metrics.length; i++) {
            weightedSum += (metrics[i] * weights[i]);
            totalWeight += weights[i];
        }
        
        require(totalWeight > 0, "Zero total weight");
        return weightedSum / totalWeight;
    }
    
    /**
     * @notice Babylonian method to calculate square root
     * @param y Number to calculate square root of
     * @return Square root of y
     */
    function sqrt(uint256 y) internal pure returns (uint256) {
        if (y > 3) {
            uint256 z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
            return z;
        } else if (y != 0) {
            return 1;
        } else {
            return 0;
        }
    }
}