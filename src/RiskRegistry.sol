// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { PoolId } from "lib/v4-core/src/types/PoolId.sol";
import "./interfaces.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import "../lib/RiskMath.sol";

/**
 * @title RiskRegistry
 * @notice Central registry for pool risk parameters and management
 * @dev Implements IRiskRegistry interface
 */
contract RiskRegistry is IRiskRegistry, Ownable, Pausable, ReentrancyGuard {
    // Mapping of pool ID to risk parameters
    mapping(PoolId => RiskParameters) public poolParameters;

    // Mapping of pool ID to authorized managers
    mapping(PoolId => mapping(address => bool)) public poolManagers;

    // List of registered pools
    PoolId[] public registeredPools;

    // Errors
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error UnauthorizedManager();
    error InvalidParameters();
    error PoolInactive();

    event ManagerAdded(PoolId indexed poolId, address indexed manager);
    event ManagerRemoved(PoolId indexed poolId, address indexed manager);
    event PoolRegistered(PoolId indexed poolId, address indexed registrar);
    event RiskParametersUpdated(PoolId indexed poolId, RiskParameters params);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Modifier to check if caller is authorized manager
     */
    modifier onlyPoolManager(PoolKey calldata key) {
        if (!poolManagers[key.toId()][msg.sender] && msg.sender != owner()) {
            revert UnauthorizedManager();
        }
        _;
    }

    /**
     * @notice Register new pool for risk monitoring
     * @param key Unique identifier for the pool
     * @param params Initial risk parameters
     */
    function registerPool(PoolKey calldata key, RiskParameters memory params) external override onlyOwner {
        if (poolParameters[key.toId()].isActive) revert PoolAlreadyRegistered();
        if (params.volatilityThreshold == 0 || params.liquidityThreshold == 0) {
            revert InvalidParameters();
        }

        poolParameters[key.toId()] = params;
        poolParameters[key.toId()].isActive = true;
        registeredPools.push(key.toId());

        emit PoolRegistered(key.toId(), msg.sender);
        emit RiskParametersUpdated(key.toId(), params);
    }

    /**
 * @notice Calculates the volatility score for a given pool
 * @param poolId The ID of the pool to calculate volatility for
 * @param historicalPrices An array of historical prices
 * @param windowSize The number of periods to consider for volatility calculation
 * @return The calculated volatility score
 */
/**
 * @notice Calculates the volatility score for a given pool
 * @param volatilityData The volatility data for the pool
 * @return The calculated volatility score
 */
function calculateVolatilityScore(VolatilityData memory volatilityData) 
    external 
    pure 
    returns (uint256) 
{
    require(volatilityData.prices.length >= volatilityData.windowSize, "Insufficient historical data");

    // Calculate the standard deviation
    uint256 sum = 0;
    uint256 sqSum = 0;

    for (uint256 i = volatilityData.prices.length - volatilityData.windowSize; i < volatilityData.prices.length; i++) {
        int256 price = volatilityData.prices[i];
        sum += uint256(price);
        sqSum += uint256(price) ** 2;
    }

    uint256 mean = sum / volatilityData.windowSize;
    uint256 variance = (sqSum / volatilityData.windowSize) - (mean ** 2);

    // Calculate the standard deviation
    uint256 stdDev = RiskMath.sqrt(variance);

    // Normalize the standard deviation to a score between 0 and 100
    uint256 normalizedStdDev = (stdDev * 100) / (RiskMath.sqrt(mean ** 2));

    // Ensure the score doesn't exceed 100
    return normalizedStdDev > 100 ? 100 : normalizedStdDev;
}

    /**
     * @notice Update risk parameters for pool
     * @param key Pool identifier
     * @param newParams Updated risk parameters
     */
    function updatePoolParameters(PoolKey calldata key, RiskParameters memory newParams)
        external
        onlyPoolManager(key)
        whenNotPaused
    {
        if (!poolParameters[key.toId()].isActive) revert PoolInactive();
        if (newParams.volatilityThreshold == 0 || newParams.liquidityThreshold == 0) {
            revert InvalidParameters();
        }

        poolParameters[key.toId()] = newParams;
        poolParameters[key.toId()].isActive = true;

        emit RiskParametersUpdated(key.toId(), newParams);
    }

    /**
     * @notice Get risk parameters for pool
     * @param key Pool identifier
     */
    function getPoolParameters(PoolKey calldata key) external view  returns (RiskParameters memory) {
        if (!poolParameters[key.toId()].isActive) revert PoolInactive();
        return poolParameters[key.toId()];
    }

    /**
     * @notice Deactivate pool monitoring
     * @param key Pool identifier
     */
    function deactivatePool(PoolKey calldata key) external onlyOwner {
        if (!poolParameters[key.toId()].isActive) revert PoolInactive();
        poolParameters[key.toId()].isActive = false;
    }

    /**
     * @notice Activate pool monitoring
     * @param key Pool identifier
     */
    function activatePool(PoolKey calldata key) external onlyOwner {
        if (poolParameters[key.toId()].volatilityThreshold == 0) revert PoolNotRegistered();
        poolParameters[key.toId()].isActive = true;
    }

    /**
     * @notice Add authorized manager for pool
     */
    function addPoolManager(PoolKey calldata key, address manager) external onlyOwner whenNotPaused {
        if (!poolParameters[key.toId()].isActive) revert PoolInactive();
        poolManagers[key.toId()][manager] = true;
        emit ManagerAdded(key.toId(), manager);
    }

    /**
     * @notice Remove authorized manager for pool
     */
    function removePoolManager(PoolKey calldata key, address manager) external onlyOwner {
        poolManagers[key.toId()][manager] = false;
        emit ManagerRemoved(key.toId(), manager);
    }

    /**
     * @notice Get all registered pools
     */
    function getAllPools() external view returns (PoolId[] memory registeredPools) {
        registeredPools = new PoolId[](0);
        return registeredPools;
    }

    /**
     * @notice Get detailed information for all pools
     * @return poolInfos Array of pool information including parameters and status
     */
    function getAllPoolInfo() external view returns (PoolInfo[] memory poolInfos) {
        uint256 count = registeredPools.length;
        poolInfos = new PoolInfo[](count);

        for (uint256 i = 0; i < count; i++) {
            PoolId poolId = registeredPools[i];
            poolInfos[i] = PoolInfo({
                poolId: poolId,
                parameters: poolParameters[poolId],
                registrationTime: block.timestamp, // Note: This would need a registration time mapping in actual implementation
                isRegistered: poolParameters[poolId].isActive
            });
        }
    }

    /**
     * @notice Check if a pool is registered
     * @param key The pool ID to check
     * @return isRegistered True if the pool is registered
     */
    function isPoolRegistered(PoolKey calldata key) external view returns (bool isRegistered) {
        return poolParameters[key.toId()].isActive;
    }

    /**
     * @notice Check if address is authorized manager
     */
    function isPoolManager(PoolKey calldata key, address manager) external view returns (bool) {
        return poolManagers[key.toId()][manager];
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
     * @notice Batch update risk parameters
     * @dev Allows updating multiple pools in a single transaction
     */
    function batchUpdateParameters(PoolKey[] calldata keys, RiskParameters[] calldata newParams)
        external
        onlyOwner
        whenNotPaused
    {
        if (keys.length != newParams.length) revert InvalidParameters();
        
        for (uint256 i = 0; i < keys.length; i++) {
            if (poolParameters[keys[i].toId()].isActive) {
                if (newParams[i].volatilityThreshold == 0 || newParams[i].liquidityThreshold == 0) {
                    continue;
                }

                poolParameters[keys[i].toId()] = newParams[i];
                poolParameters[keys[i].toId()].isActive = true;

                emit RiskParametersUpdated(keys[i].toId(), newParams[i]);
            }
        }
    }
}
