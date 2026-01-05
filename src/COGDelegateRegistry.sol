// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICOGGovernor} from "./interfaces/ICOGGovernor.sol";

/// @title COGDelegateRegistry
/// @notice Registry for delegate metadata and voting records
/// @dev Optional contract for UX improvement - stores delegate profiles
contract COGDelegateRegistry {
    struct DelegateProfile {
        string name;
        string description;
        string votingPhilosophy;
        uint256 proposalsOpposed;
        uint256 proposalsReworked;
        uint256 proposalsSupported; // implicit - no action taken
        bool isActive;
    }

    /// @notice Mapping from delegate address to their profile
    mapping(address => DelegateProfile) public delegates;

    /// @notice List of all registered delegates
    address[] public delegateList;

    /// @notice Mapping to check if address is in delegateList
    mapping(address => bool) public isRegistered;

    /// @notice The governor contract for tracking votes
    ICOGGovernor public governor;

    event DelegateRegistered(address indexed delegate, string name);
    event DelegateUpdated(address indexed delegate, string name);
    event DelegateDeactivated(address indexed delegate);
    event DelegateVotingRecord(
        address indexed delegate,
        uint256 indexed proposalId,
        ICOGGovernor.DissentAction action
    );

    error AlreadyRegistered();
    error NotRegistered();
    error EmptyName();

    constructor(address governor_) {
        governor = ICOGGovernor(governor_);
    }

    /// @notice Register as a delegate with profile info
    /// @param name Display name for the delegate
    /// @param description Description of the delegate
    /// @param votingPhilosophy Delegate's voting philosophy/strategy
    function register(
        string calldata name,
        string calldata description,
        string calldata votingPhilosophy
    ) external {
        if (bytes(name).length == 0) revert EmptyName();
        if (isRegistered[msg.sender]) revert AlreadyRegistered();

        delegates[msg.sender] = DelegateProfile({
            name: name,
            description: description,
            votingPhilosophy: votingPhilosophy,
            proposalsOpposed: 0,
            proposalsReworked: 0,
            proposalsSupported: 0,
            isActive: true
        });

        delegateList.push(msg.sender);
        isRegistered[msg.sender] = true;

        emit DelegateRegistered(msg.sender, name);
    }

    /// @notice Update delegate profile
    /// @param name New display name
    /// @param description New description
    /// @param votingPhilosophy New voting philosophy
    function updateProfile(
        string calldata name,
        string calldata description,
        string calldata votingPhilosophy
    ) external {
        if (!isRegistered[msg.sender]) revert NotRegistered();
        if (bytes(name).length == 0) revert EmptyName();

        DelegateProfile storage profile = delegates[msg.sender];
        profile.name = name;
        profile.description = description;
        profile.votingPhilosophy = votingPhilosophy;

        emit DelegateUpdated(msg.sender, name);
    }

    /// @notice Deactivate delegate profile
    function deactivate() external {
        if (!isRegistered[msg.sender]) revert NotRegistered();

        delegates[msg.sender].isActive = false;

        emit DelegateDeactivated(msg.sender);
    }

    /// @notice Reactivate delegate profile
    function reactivate() external {
        if (!isRegistered[msg.sender]) revert NotRegistered();

        delegates[msg.sender].isActive = true;
    }

    /// @notice Record a voting action (called after delegate votes)
    /// @param delegate The delegate who voted
    /// @param proposalId The proposal voted on
    /// @param action The action taken
    function recordVote(
        address delegate,
        uint256 proposalId,
        ICOGGovernor.DissentAction action
    ) external {
        if (!isRegistered[delegate]) return;

        DelegateProfile storage profile = delegates[delegate];

        if (action == ICOGGovernor.DissentAction.VETO) {
            profile.proposalsOpposed++;
        } else if (action == ICOGGovernor.DissentAction.REWORK) {
            profile.proposalsReworked++;
        } else if (action == ICOGGovernor.DissentAction.NONE) {
            profile.proposalsSupported++;
        }

        emit DelegateVotingRecord(delegate, proposalId, action);
    }

    /// @notice Get number of registered delegates
    /// @return Count of delegates
    function getDelegateCount() external view returns (uint256) {
        return delegateList.length;
    }

    /// @notice Get all active delegates
    /// @return Array of active delegate addresses
    function getActiveDelegates() external view returns (address[] memory) {
        uint256 activeCount = 0;

        // Count active delegates
        for (uint256 i = 0; i < delegateList.length; i++) {
            if (delegates[delegateList[i]].isActive) {
                activeCount++;
            }
        }

        // Build array
        address[] memory activeDelegates = new address[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < delegateList.length; i++) {
            if (delegates[delegateList[i]].isActive) {
                activeDelegates[index] = delegateList[i];
                index++;
            }
        }

        return activeDelegates;
    }

    /// @notice Get delegate profile
    /// @param delegate Address to query
    /// @return name Delegate name
    /// @return description Delegate description
    /// @return votingPhilosophy Delegate voting philosophy
    /// @return proposalsOpposed Number of proposals opposed
    /// @return proposalsReworked Number of proposals reworked
    /// @return proposalsSupported Number of proposals supported
    /// @return isActive Whether delegate is active
    function getProfile(address delegate)
        external
        view
        returns (
            string memory name,
            string memory description,
            string memory votingPhilosophy,
            uint256 proposalsOpposed,
            uint256 proposalsReworked,
            uint256 proposalsSupported,
            bool isActive
        )
    {
        DelegateProfile storage profile = delegates[delegate];
        return (
            profile.name,
            profile.description,
            profile.votingPhilosophy,
            profile.proposalsOpposed,
            profile.proposalsReworked,
            profile.proposalsSupported,
            profile.isActive
        );
    }

    /// @notice Get paginated list of delegates
    /// @param offset Starting index
    /// @param limit Maximum delegates to return
    /// @return Array of delegate addresses
    function getDelegatesPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        uint256 total = delegateList.length;
        if (offset >= total) {
            return new address[](0);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = delegateList[offset + i];
        }

        return result;
    }
}
