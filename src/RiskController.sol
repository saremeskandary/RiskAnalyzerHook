// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces.sol";

/**
 * @title RiskController
 * @notice Controls and executes risk management actions
 * @dev Implements IRiskController interface
 */
contract RiskController is IRiskController, Ownable, Pausable, ReentrancyGuard {
    // Component interfaces
    IRiskRegistry public immutable registry;
    IRiskNotifier public immutable notifier;
    IPositionManager public immutable positionManager;

    // Control status storage
    struct ControlStatus {
        bool isPaused;
        bool isThrottled;
        uint256 lastActionTimestamp;
        uint256 throttleEndTime;
        uint256 actionCount;
        ActionType lastAction;
    }

    // Mapping of pool ID to control status
    mapping(bytes32 => ControlStatus) public poolStatus;

    // Cooldown periods for different actions (in seconds)
    uint256 public constant WARNING_COOLDOWN = 1 hours;
    uint256 public constant THROTTLE_COOLDOWN = 4 hours;
    uint256 public constant PAUSE_COOLDOWN = 12 hours;
    uint256 public constant EMERGENCY_COOLDOWN = 24 hours;

    // Throttling parameters
    uint256 public constant THROTTLE_DURATION = 1 hours;
    uint256 public constant MAX_ACTIONS_BEFORE_THROTTLE = 3;

    // Events
    event ActionExecuted(bytes32 indexed poolId, ActionType indexed actionType, uint256 timestamp);

    event ControlsReset(bytes32 indexed poolId, uint256 timestamp);

    event ThrottleActivated(bytes32 indexed poolId, uint256 endTime);

    event EmergencyAction(bytes32 indexed poolId, string reason);

    // Errors
    error ActionCoolingDown();
    error InvalidPoolId();
    error InvalidAction();
    error AlreadyInState();
    error CooldownNotExpired();
    error UnauthorizedAction();

    constructor(address _registry, address _notifier, address _positionManager) Ownable(msg.sender) {
        if (_registry == address(0) || _notifier == address(0) || _positionManager == address(0)) {
            revert InvalidAddress();
        }

        registry = IRiskRegistry(_registry);
        notifier = IRiskNotifier(_notifier);
        positionManager = IPositionManager(_positionManager);
    }

    /**
     * @notice Execute risk control action
     * @param poolId Pool identifier
     * @param actionType Type of action to execute
     */
    function executeAction(bytes32 poolId, ActionType actionType)
        external
        override
        onlyOwner
        whenNotPaused
        returns (bool)
    {
        if (poolId == bytes32(0)) revert InvalidPoolId();

        ControlStatus storage status = poolStatus[poolId];

        // Check cooldown periods
        _checkCooldown(status, actionType);

        // Execute action based on type
        bool success = _executeSpecificAction(poolId, actionType);
        if (!success) revert ActionFailed();

        // Update status
        status.lastAction = actionType;
        status.lastActionTimestamp = block.timestamp;
        status.actionCount++;

        // Check if throttling should be activated
        if (status.actionCount >= MAX_ACTIONS_BEFORE_THROTTLE) {
            _activateThrottle(poolId);
        }

        emit ActionExecuted(poolId, actionType, block.timestamp);
        return true;
    }

    /**
     * @notice Get current control status
     * @param poolId Pool identifier
     */
    function getControlStatus(bytes32 poolId)
        external
        view
        override
        returns (bool isPaused, bool isThrottled, uint256 lastActionTimestamp)
    {
        ControlStatus storage status = poolStatus[poolId];
        return (status.isPaused, status.isThrottled, status.lastActionTimestamp);
    }

    /**
     * @notice Reset control status
     * @param poolId Pool identifier
     */
    function resetControls(bytes32 poolId) external override onlyOwner {
        ControlStatus storage status = poolStatus[poolId];

        status.isPaused = false;
        status.isThrottled = false;
        status.actionCount = 0;
        status.throttleEndTime = 0;

        emit ControlsReset(poolId, block.timestamp);
    }

    /**
     * @notice Check if action is allowed based on cooldown
     */
    function _checkCooldown(ControlStatus storage status, ActionType actionType) internal view {
        uint256 cooldown = _getCooldownPeriod(actionType);
        if (status.lastActionTimestamp + cooldown > block.timestamp && status.lastAction == actionType) {
            revert ActionCoolingDown();
        }
    }

    /**
     * @notice Get cooldown period for action type
     */
    function _getCooldownPeriod(ActionType actionType) internal pure returns (uint256) {
        if (actionType == ActionType.WARNING) return WARNING_COOLDOWN;
        if (actionType == ActionType.THROTTLE) return THROTTLE_COOLDOWN;
        if (actionType == ActionType.PAUSE) return PAUSE_COOLDOWN;
        if (actionType == ActionType.EMERGENCY) return EMERGENCY_COOLDOWN;
        revert InvalidAction();
    }

    /**
     * @notice Execute specific action type
     */
    function _executeSpecificAction(bytes32 poolId, ActionType actionType) internal returns (bool) {
        ControlStatus storage status = poolStatus[poolId];

        if (actionType == ActionType.WARNING) {
            return _executeWarning(poolId);
        } else if (actionType == ActionType.THROTTLE) {
            return _executeThrottle(poolId);
        } else if (actionType == ActionType.PAUSE) {
            return _executePause(poolId);
        } else if (actionType == ActionType.EMERGENCY) {
            return _executeEmergency(poolId);
        }

        return false;
    }

    /**
     * @notice Execute warning action
     */
    function _executeWarning(bytes32 poolId) internal returns (bool) {
        string memory message = "Risk level elevated - Warning issued";
        notifier.notifyUser(msg.sender, 1, message);
        return true;
    }

    /**
     * @notice Execute throttle action
     */
    function _executeThrottle(bytes32 poolId) internal returns (bool) {
        ControlStatus storage status = poolStatus[poolId];
        if (status.isThrottled) revert AlreadyInState();

        _activateThrottle(poolId);
        return true;
    }

    /**
     * @notice Execute pause action
     */
    function _executePause(bytes32 poolId) internal returns (bool) {
        ControlStatus storage status = poolStatus[poolId];
        if (status.isPaused) revert AlreadyInState();

        status.isPaused = true;
        registry.deactivatePool(poolId);

        string memory message = "Pool operations paused due to high risk";
        notifier.notifyUser(msg.sender, 3, message);

        return true;
    }

    /**
     * @notice Execute emergency action
     */
    function _executeEmergency(bytes32 poolId) internal returns (bool) {
        ControlStatus storage status = poolStatus[poolId];

        status.isPaused = true;
        registry.deactivatePool(poolId);

        string memory message = "EMERGENCY: Critical risk level detected - Pool frozen";
        notifier.notifyUser(msg.sender, 4, message);

        emit EmergencyAction(poolId, message);
        return true;
    }

    /**
     * @notice Activate throttling for a pool
     */
    function _activateThrottle(bytes32 poolId) internal {
        ControlStatus storage status = poolStatus[poolId];

        status.isThrottled = true;
        status.throttleEndTime = block.timestamp + THROTTLE_DURATION;

        emit ThrottleActivated(poolId, status.throttleEndTime);
    }

    /**
     * @notice Emergency pause all operations
     */
    function emergencyPauseAll() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume operations
     */
    function resumeOperations() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Check if pool is currently throttled
     */
    function isPoolThrottled(bytes32 poolId) external view returns (bool) {
        ControlStatus storage status = poolStatus[poolId];
        return status.isThrottled && block.timestamp < status.throttleEndTime;
    }

    /**
     * @notice Get detailed control metrics
     */
    function getControlMetrics(bytes32 poolId)
        external
        view
        returns (uint256 actionCount, uint256 throttleEndTime, ActionType lastAction, bool isPaused, bool isThrottled)
    {
        ControlStatus storage status = poolStatus[poolId];
        return (status.actionCount, status.throttleEndTime, status.lastAction, status.isPaused, status.isThrottled);
    }
}