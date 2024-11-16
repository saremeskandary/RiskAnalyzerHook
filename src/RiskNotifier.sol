// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "./interfaces.sol";

/**
 * @title RiskNotifier
 * @notice Manages risk notifications and alerts for users
 * @dev Implements IRiskNotifier interface
 */
contract RiskNotifier is IRiskNotifier, Ownable, Pausable {
    // Maximum number of notifications per user
    uint256 public constant MAX_NOTIFICATIONS = 100;

    // Notification storage per user
    mapping(address => Notification[]) private userNotifications;

    // Count of notifications per user
    mapping(address => uint256) private notificationCount;

    // Authorized notifiers (other contracts that can send notifications)
    mapping(address => bool) public authorizedNotifiers;

    // Risk level thresholds
    uint256 public constant RISK_LEVEL_LOW = 1;
    uint256 public constant RISK_LEVEL_MEDIUM = 2;
    uint256 public constant RISK_LEVEL_HIGH = 3;
    uint256 public constant RISK_LEVEL_CRITICAL = 4;

    // Events
    event NotifierAdded(address indexed notifier);
    event NotifierRemoved(address indexed notifier);
    event NotificationCleared(address indexed user);
    event NotificationsExpired(address indexed user, uint256 count);

    // Errors
    error UnauthorizedNotifier();
    error InvalidAddress();
    error InvalidRiskLevel();
    error NoNotifications();
    error NotificationLimitExceeded();
    error EmptyMessage();

    constructor() Ownable(msg.sender) {
        // Add deployer as authorized notifier
        authorizedNotifiers[msg.sender] = true;
        emit NotifierAdded(msg.sender);
    }

    /**
     * @notice Modifier to check if caller is authorized notifier
     */
    modifier onlyAuthorizedNotifier() {
        if (!authorizedNotifiers[msg.sender]) revert UnauthorizedNotifier();
        _;
    }

    /**
     * @notice Get notifications for a user
     * @param user Address of the user
     */
    function getUserNotifications(address user) external view override returns (Notification[] memory) {
        if (user == address(0)) revert InvalidAddress();
        return userNotifications[user];
    }

    /**
     * @notice Send notification to user
     * @param user Address of the user
     * @param riskLevel Level of risk (1-4)
     * @param message Notification message
     */
    function notifyUser(address user, uint256 riskLevel, string memory message)
        external
        override
        onlyAuthorizedNotifier
        whenNotPaused
    {
        if (user == address(0)) revert InvalidAddress();
        if (riskLevel < RISK_LEVEL_LOW || riskLevel > RISK_LEVEL_CRITICAL) {
            revert InvalidRiskLevel();
        }
        if (bytes(message).length == 0) revert EmptyMessage();
        if (notificationCount[user] >= MAX_NOTIFICATIONS) {
            revert NotificationLimitExceeded();
        }

        // Create new notification
        Notification memory newNotification =
            Notification({user: user, riskLevel: riskLevel, message: message, timestamp: block.timestamp});

        // Add to storage
        userNotifications[user].push(newNotification);
        notificationCount[user]++;

        emit RiskNotification(user, riskLevel, message);
    }

    /**
     * @notice Clear notifications for a user
     * @param user Address of the user
     */
    function clearNotifications(address user) external override whenNotPaused {
        if (user == address(0)) revert InvalidAddress();
        if (notificationCount[user] == 0) revert NoNotifications();

        delete userNotifications[user];
        notificationCount[user] = 0;

        emit NotificationCleared(user);
    }

    /**
     * @notice Add authorized notifier
     * @param notifier Address to authorize
     */
    function addNotifier(address notifier) external onlyOwner {
        if (notifier == address(0)) revert InvalidAddress();
        authorizedNotifiers[notifier] = true;
        emit NotifierAdded(notifier);
    }

    /**
     * @notice Remove authorized notifier
     * @param notifier Address to remove
     */
    function removeNotifier(address notifier) external onlyOwner {
        authorizedNotifiers[notifier] = false;
        emit NotifierRemoved(notifier);
    }

    /**
     * @notice Clear expired notifications
     * @param user Address of the user
     * @param maxAge Maximum age of notifications to keep (in seconds)
     */
    function clearExpiredNotifications(address user, uint256 maxAge) external whenNotPaused {
        if (user == address(0)) revert InvalidAddress();
        if (notificationCount[user] == 0) revert NoNotifications();

        uint256 currentTime = block.timestamp;
        Notification[] storage notifications = userNotifications[user];
        uint256 originalCount = notifications.length;
        uint256 writeIndex;

        // Keep valid notifications
        for (uint256 readIndex = 0; readIndex < originalCount; readIndex++) {
            if (currentTime - notifications[readIndex].timestamp <= maxAge) {
                if (writeIndex != readIndex) {
                    notifications[writeIndex] = notifications[readIndex];
                }
                writeIndex++;
            }
        }

        // Resize array and update count
        uint256 newLength = writeIndex;
        uint256 removed = originalCount - newLength;

        while (notifications.length > newLength) {
            notifications.pop();
        }

        notificationCount[user] = newLength;

        if (removed > 0) {
            emit NotificationsExpired(user, removed);
        }
    }

    /**
     * @notice Get notification count for user
     * @param user Address of the user
     */
    function getNotificationCount(address user) external view returns (uint256) {
        return notificationCount[user];
    }

    /**
     * @notice Check if address is authorized notifier
     * @param notifier Address to check
     */
    function isAuthorizedNotifier(address notifier) external view returns (bool) {
        return authorizedNotifiers[notifier];
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
     * @notice Batch notify users
     * @param users Array of user addresses
     * @param riskLevel Risk level for all notifications
     * @param message Notification message
     */
    function batchNotify(address[] calldata users, uint256 riskLevel, string calldata message)
        external
        onlyAuthorizedNotifier
        whenNotPaused
    {
        if (riskLevel < RISK_LEVEL_LOW || riskLevel > RISK_LEVEL_CRITICAL) {
            revert InvalidRiskLevel();
        }
        if (bytes(message).length == 0) revert EmptyMessage();

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (user != address(0) && notificationCount[user] < MAX_NOTIFICATIONS) {
                Notification memory newNotification =
                    Notification({user: user, riskLevel: riskLevel, message: message, timestamp: block.timestamp});

                userNotifications[user].push(newNotification);
                notificationCount[user]++;

                emit RiskNotification(user, riskLevel, message);
            }
        }
    }
}
