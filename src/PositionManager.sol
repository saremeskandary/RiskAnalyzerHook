pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IRiskRegistry} from "./interfaces.sol";
import "./interfaces.sol";

contract PositionManager is IPositionManager, Ownable, Pausable, ReentrancyGuard {
    // Component dependencies
    IPoolManager public immutable poolManager;
    IRiskRegistry public immutable riskRegistry;

    // Position data storage
    mapping(address => mapping(PoolId => PositionData)) private positions;

    // Events
    event PositionUpdated(address indexed user, PoolId indexed poolId, uint256 size, uint256 riskScore);
    event PositionClosed(address indexed user, PoolId indexed poolId);
    event RiskScoreUpdated(address indexed user, PoolId indexed poolId, uint256 newScore);

    // Risk thresholds
    uint256 public constant MAX_RISK_SCORE = 10000; // 100%
    uint256 public constant HIGH_RISK_THRESHOLD = 7500; // 75%

    // Errors
    error UnauthorizedAccess();
    error InvalidRiskScore();
    error InvalidPosition();
    error PositionNotFound();
    error RiskTooHigh();

    constructor(address _poolManager, address _riskRegistry) Ownable(msg.sender) {
        require(_poolManager != address(0), "Invalid pool manager");
        require(_riskRegistry != address(0), "Invalid risk registry");
        poolManager = IPoolManager(_poolManager);
        riskRegistry = IRiskRegistry(_riskRegistry);
    }

    /**
     * @notice Get position data for a user and pool
     * @param user Address of the position owner
     * @param key Unique identifier of the pool
     * @return Position data including size, ticks, and risk score
     */
    function getPositionData(address user, PoolKey calldata key) external view override returns (PositionData memory) {
        PositionData memory position = positions[user][key.toId()];
        if (position.size == 0) revert PositionNotFound();
        return position;
    }

    /**
     * @notice Update the risk score for a user's position
     * @param user Address of the position owner
     * @param key Unique identifier of the pool
     * @param newRiskScore New risk score to assign
     */
    function updatePositionRisk(address user, PoolKey calldata key, uint256 newRiskScore)
        external
        override
        whenNotPaused
    {
        // Only authorized risk assessors can update risk scores
        if (!riskRegistry.isPoolManager(key, msg.sender)) {
            revert UnauthorizedAccess();
        }

        if (newRiskScore > MAX_RISK_SCORE) revert InvalidRiskScore();

        PositionData storage position = positions[user][key.toId()];
        if (position.size == 0) revert PositionNotFound();

        position.riskScore = newRiskScore;
        position.lastUpdate = block.timestamp;

        emit RiskScoreUpdated(user, key.toId(), newRiskScore);

        // If risk is too high, attempt to close the position
        if (newRiskScore >= HIGH_RISK_THRESHOLD) {
            closeRiskyPosition(user, key);
        }
    }

    /**
     * @notice Close a position that has exceeded risk thresholds
     * @param user Address of the position owner
     * @param key Unique identifier of the pool
     * @return success Whether the position was successfully closed
     */
    function closeRiskyPosition(address user, PoolKey calldata key) public override whenNotPaused returns (bool) {
        PositionData storage position = positions[user][key.toId()];

        if (position.size == 0) revert PositionNotFound();
        if (position.riskScore < HIGH_RISK_THRESHOLD) revert RiskTooHigh();

        // Clear position data
        delete positions[user][key.toId()];

        emit PositionClosed(user, key.toId());
        return true;
    }

    function updatePosition(address user, PoolKey calldata key, uint256 size, int24 tickLower, int24 tickUpper)
        public
        whenNotPaused
        onlyOwner
    {
        // Changed from external to public
        require(size > 0, "Invalid position size");
        require(tickLower < tickUpper, "Invalid tick range");

        positions[user][key.toId()] = PositionData({
            size: size,
            tickLower: tickLower,
            tickUpper: tickUpper,
            riskScore: 0,
            lastUpdate: block.timestamp
        });

        emit PositionUpdated(user, key.toId(), size, 0);
    }

    function batchUpdatePositions(
        address[] calldata users,
        PoolKey[] calldata poolIds,
        uint256[] calldata sizes,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers
    ) external whenNotPaused onlyOwner {
        require(
            users.length == poolIds.length && poolIds.length == sizes.length && sizes.length == tickLowers.length
                && tickLowers.length == tickUppers.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < users.length; i++) {
            updatePosition(users[i], poolIds[i], sizes[i], tickLowers[i], tickUppers[i]);
        }
    }

    /// Admin functions

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
