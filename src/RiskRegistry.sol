// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import "./interfaces.sol";

/**
 * @title RiskRegistry
 * @notice Central registry for pool risk parameters and management
 * @dev Implements IRiskRegistry interface
 */
contract RiskRegistry is IRiskRegistry, Ownable, Pausable, ReentrancyGuard {
    // Mapping of pool ID to risk parameters
    mapping(bytes32 => RiskParameters) public poolParameters;

    // Mapping of pool ID to authorized managers
    mapping(bytes32 => mapping(address => bool)) public poolManagers;

    // List of registered pools
    bytes32[] public registeredPools;

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
    modifier onlyPoolManager(PoolId poolId) {
        if (!poolManagers[poolId][msg.sender] && msg.sender != owner()) {
            revert UnauthorizedManager();
        }
        _;
    }

    /**
     * @notice Register new pool for risk monitoring
     * @param poolId Unique identifier for the pool
     * @param params Initial risk parameters
     */
    function registerPool(PoolId poolId, RiskParameters memory params) external override onlyOwner {
        if (poolParameters[poolId].isActive) revert PoolAlreadyRegistered();
        if (params.volatilityThreshold == 0 || params.liquidityThreshold == 0) {
            revert InvalidParameters();
        }

        poolParameters[poolId] = params;
        poolParameters[poolId].isActive = true;
        registeredPools.push(poolId);

        emit PoolRegistered(poolId, msg.sender);
        emit RiskParametersUpdated(poolId, params);
    }

    /**
     * @notice Update risk parameters for pool
     * @param poolId Pool identifier
     * @param newParams Updated risk parameters
     */
    function updatePoolParameters(PoolId poolId, RiskParameters memory newParams)
        external
        override
        onlyPoolManager(poolId)
        whenNotPaused
    {
        if (!poolParameters[poolId].isActive) revert PoolInactive();
        if (newParams.volatilityThreshold == 0 || newParams.liquidityThreshold == 0) {
            revert InvalidParameters();
        }

        poolParameters[poolId] = newParams;
        poolParameters[poolId].isActive = true;

        emit RiskParametersUpdated(poolId, newParams);
    }

    /**
     * @notice Get risk parameters for pool
     * @param poolId Pool identifier
     */
    function getPoolParameters(PoolId poolId) external view override returns (RiskParameters memory) {
        if (!poolParameters[poolId].isActive) revert PoolInactive();
        return poolParameters[poolId];
    }

    /**
     * @notice Deactivate pool monitoring
     * @param poolId Pool identifier
     */
    function deactivatePool(PoolId poolId) external override onlyOwner {
        if (!poolParameters[poolId].isActive) revert PoolInactive();
        poolParameters[poolId].isActive = false;
    }

    /**
     * @notice Activate pool monitoring
     * @param poolId Pool identifier
     */
    function activatePool(PoolId poolId) external override onlyOwner {
        if (poolParameters[poolId].volatilityThreshold == 0) revert PoolNotRegistered();
        poolParameters[poolId].isActive = true;
    }

    /**
     * @notice Add authorized manager for pool
     */
    function addPoolManager(PoolId poolId, address manager) external onlyOwner whenNotPaused {
        if (!poolParameters[poolId].isActive) revert PoolInactive();
        poolManagers[poolId][manager] = true;
        emit ManagerAdded(poolId, manager);
    }

    /**
     * @notice Remove authorized manager for pool
     */
    function removePoolManager(PoolId poolId, address manager) external onlyOwner {
        poolManagers[poolId][manager] = false;
        emit ManagerRemoved(poolId, manager);
    }

    /**
     * @notice Get all registered pools
     */
    function getAllPools() external view returns (bytes32[] memory) {
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
     * @param poolId The pool ID to check
     * @return isRegistered True if the pool is registered
     */
    function isPoolRegistered(PoolId poolId) external view returns (bool isRegistered) {
        return poolParameters[poolId].isActive;
    }

    /**
     * @notice Check if address is authorized manager
     */
    function isPoolManager(PoolId poolId, address manager) external view returns (bool) {
        return poolManagers[poolId][manager];
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
    function batchUpdateParameters(bytes32[] calldata poolIds, RiskParameters[] calldata newParams)
        external
        onlyOwner
        whenNotPaused
    {
        if (poolIds.length != newParams.length) revert InvalidParameters();

        for (uint256 i = 0; i < poolIds.length; i++) {
            if (poolParameters[poolIds[i]].isActive) {
                if (newParams[i].volatilityThreshold == 0 || newParams[i].liquidityThreshold == 0) {
                    continue;
                }

                poolParameters[poolIds[i]] = newParams[i];
                poolParameters[poolIds[i]].isActive = true;

                emit RiskParametersUpdated(poolIds[i], newParams[i]);
            }
        }
    }
}
