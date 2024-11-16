// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PriceLib
 * @notice Library for price-related calculations and conversions
 */
library PriceLib {
    // Constants for tick math
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;
    
    /**
     * @notice Convert sqrt price X96 to human readable price
     * @param sqrtPriceX96 The sqrt price in X96 format
     * @return price The human readable price
     */
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
    }
    
    /**
     * @notice Convert tick to price
     * @param tick The tick to convert
     * @return price The price corresponding to the tick
     */
    function tickToPrice(int24 tick) internal pure returns (uint256) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");
        return uint256(1e18) * uint256(1.0001 ** uint256(tick));
    }
    
    /**
     * @notice Calculate price impact percentage
     * @param initialPrice Initial price
     * @param finalPrice Final price
     * @return impact Price impact as a percentage with 18 decimals precision
     */
    function calculatePriceImpact(
        uint256 initialPrice,
        uint256 finalPrice
    ) internal pure returns (uint256 impact) {
        if (initialPrice == 0) return 0;
        
        if (finalPrice > initialPrice) {
            impact = ((finalPrice - initialPrice) * 1e18) / initialPrice;
        } else {
            impact = ((initialPrice - finalPrice) * 1e18) / initialPrice;
        }
    }
    
    /**
     * @notice Check if price movement exceeds threshold
     * @param oldPrice Previous price
     * @param newPrice Current price
     * @param threshold Maximum allowed price movement percentage
     * @return bool True if price movement exceeds threshold
     */
    function isPriceMovementExcessive(
        uint256 oldPrice,
        uint256 newPrice,
        uint256 threshold
    ) internal pure returns (bool) {
        return calculatePriceImpact(oldPrice, newPrice) > threshold;
    }
}