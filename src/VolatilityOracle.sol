// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import "../lib/PriceLib.sol";
import "../lib/RiskMath.sol";
import "./interfaces.sol";
/**
 * @title VolatilityOracle
 * @notice Implements volatility calculations for pool risk analysis
 */

contract VolatilityOracle is IVolatilityOracle, Ownable {
    // Storage for volatility data per pool
    mapping(bytes32 => VolatilityData) private volatilityData;

    // Default window size for volatility calculation
    uint256 private constant DEFAULT_WINDOW_SIZE = 24; // 24 data points

    // Minimum required data points for volatility calculation
    uint256 private constant MIN_DATA_POINTS = 2;

    // Events
    event WindowSizeUpdated(PoolId indexed poolId, uint256 newSize);
    event PriceDataAdded(PoolId indexed poolId, int256 price, uint256 timestamp);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Initialize volatility tracking for a new pool
     * @param poolId Pool identifier
     * @param windowSize Size of the rolling window for volatility calculation
     */
    function initializePool(PoolId poolId, uint256 windowSize) external onlyOwner {
        require(volatilityData[poolId].windowSize == 0, "Pool already initialized");
        require(windowSize >= MIN_DATA_POINTS, "Window size too small");

        volatilityData[poolId] =
            VolatilityData({prices: new int256[](windowSize), windowSize: windowSize, currentIndex: 0});
    }

    /**
     * @notice Get volatility data for a pool
     * @param poolId Pool identifier
     */
    function getVolatilityData(PoolId poolId) external view override returns (VolatilityData memory) {
        return volatilityData[poolId];
    }

    /**
     * @notice Calculate volatility based on new price data
     * @param poolId Pool identifier
     * @param newPrice Latest price observation
     */
    function calculateVolatility(PoolId poolId, int256 newPrice) external override returns (uint256) {
        VolatilityData storage data = volatilityData[poolId];
        require(data.windowSize > 0, "Pool not initialized");

        // Update price array
        data.prices[data.currentIndex] = newPrice;
        data.currentIndex = (data.currentIndex + 1) % data.windowSize;

        // Count valid price points
        uint256 validPoints;
        int256[] memory validPrices = new int256[](data.windowSize);
        uint256 validIndex;

        for (uint256 i = 0; i < data.windowSize; i++) {
            if (data.prices[i] != 0) {
                validPrices[validIndex] = data.prices[i];
                validIndex++;
                validPoints++;
            }
        }

        // Require minimum data points
        require(validPoints >= MIN_DATA_POINTS, "Insufficient data points");

        // Calculate mean of valid prices
        int256 mean = RiskMath.calculateMean(validPrices);

        // Calculate volatility using standard deviation
        uint256 volatility = RiskMath.calculateVolatility(validPrices, mean);

        emit PriceDataAdded(poolId, newPrice, block.timestamp);

        return volatility;
    }

    /**
     * @notice Update volatility window size
     * @param poolId Pool identifier
     * @param newWindowSize New window size
     */
    function updateVolatilityWindow(PoolId poolId, uint256 newWindowSize) external override onlyOwner {
        require(newWindowSize >= MIN_DATA_POINTS, "Window size too small");
        VolatilityData storage data = volatilityData[poolId];
        require(data.windowSize > 0, "Pool not initialized");

        // Create new price array with new size
        int256[] memory newPrices = new int256[](newWindowSize);
        uint256 oldSize = data.windowSize;
        uint256 copySize = newWindowSize < oldSize ? newWindowSize : oldSize;

        // Copy existing prices to new array
        for (uint256 i = 0; i < copySize; i++) {
            uint256 oldIndex = (data.currentIndex + i) % oldSize;
            newPrices[i] = data.prices[oldIndex];
        }

        // Update storage
        data.prices = newPrices;
        data.windowSize = newWindowSize;
        data.currentIndex = copySize % newWindowSize;

        emit WindowSizeUpdated(poolId, newWindowSize);
    }

    /**
     * @notice Calculate exponential volatility (EWMA-based)
     * @param poolId Pool identifier
     * @param smoothingFactor Smoothing factor for EWMA calculation
     */
    function calculateExponentialVolatility(PoolId poolId, uint256 smoothingFactor) external view returns (uint256) {
        VolatilityData storage data = volatilityData[poolId];
        require(data.windowSize > 0, "Pool not initialized");

        uint256 validPoints;
        uint256 ewmaVolatility;
        int256 lastPrice = 0;

        for (uint256 i = 0; i < data.windowSize; i++) {
            if (data.prices[i] != 0) {
                if (lastPrice != 0) {
                    uint256 priceChange =
                        uint256(data.prices[i] > lastPrice ? data.prices[i] - lastPrice : lastPrice - data.prices[i]);
                    ewmaVolatility = RiskMath.calculateEWMA(priceChange, ewmaVolatility, smoothingFactor);
                    validPoints++;
                }
                lastPrice = data.prices[i];
            }
        }

        require(validPoints >= MIN_DATA_POINTS, "Insufficient data points");
        return ewmaVolatility;
    }

    /**
     * @notice Clear volatility data for a pool
     * @param poolId Pool identifier
     */
    function clearVolatilityData(PoolId poolId) external onlyOwner {
        delete volatilityData[poolId];
    }
}
