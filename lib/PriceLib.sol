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
    
    // Q96 and precision constants
    uint256 private constant Q96 = 0x1000000000000000000000000;
    uint256 private constant PRECISION = 1e18;
    
    /**
     * @notice Convert sqrt price X96 to human readable price
     * @param sqrtPriceX96 The sqrt price in X96 format
     * @return price The human readable price
     */
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * PRECISION) >> 192;
    }
    
    /**
     * @notice Convert tick to price
     * @param tick The tick to convert
     * @return price The price corresponding to the tick
     */
    function tickToPrice(int24 tick) internal pure returns (uint256) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");
        
        // Convert negative ticks to positive and invert the result later
        bool negative = tick < 0;
        // Safe conversion from int24 to uint256 after handling negative case
        uint256 absTick;
        if (negative) {
            // Convert negative tick to positive
            absTick = uint256(uint24(-tick));
        } else {
            // Convert positive tick directly
            absTick = uint256(uint24(tick));
        }
        
        // Calculate the result using bit manipulation
        uint256 result = PRECISION;
        
        // Base price change for each tick is 1.0001
        // We implement this as a series of multiplications
        uint256[14] memory powers = [
            uint256(1000100000000000000), // 1.0001
            uint256(1000200010000000000), // 1.0001^2
            uint256(1000400060004000000), // 1.0001^4
            uint256(1000800240024009600), // 1.0001^8
            uint256(1001601201201201201), // 1.0001^16
            uint256(1003210121012101210), // 1.0001^32
            uint256(1006430484068903587), // 1.0001^64
            uint256(1012915496811418993), // 1.0001^128
            uint256(1026019424579799264), // 1.0001^256
            uint256(1052494381755614435), // 1.0001^512
            uint256(1108130432626880000), // 1.0001^1024
            uint256(1227826599170471000), // 1.0001^2048
            uint256(1509853358634340000), // 1.0001^4096
            uint256(2281380256409510000)  // 1.0001^8192
        ];
        
        for (uint256 i = 0; i < powers.length; i++) {
            if (absTick & (1 << i) != 0) {
                result = (result * powers[i]) / PRECISION;
            }
        }
        
        // If tick was negative, we need to invert the result
        if (negative) {
            result = (PRECISION * PRECISION) / result;
        }
        
        return result;
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
            impact = ((finalPrice - initialPrice) * PRECISION) / initialPrice;
        } else {
            impact = ((initialPrice - finalPrice) * PRECISION) / initialPrice;
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