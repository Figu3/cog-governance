// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICOGToken} from "./interfaces/ICOGToken.sol";

/// @title COGToken
/// @notice ERC20 token with soft delegation for COG governance
/// @dev Delegation is "soft" - delegates can vote on behalf but cannot trigger redemptions
contract COGToken is ERC20, ERC20Burnable, Ownable, ICOGToken {
    /// @notice Mapping from holder to their delegate
    mapping(address => address) public override delegates;

    /// @notice Mapping from delegate to total delegated balance
    mapping(address => uint256) public override delegatedPower;

    /// @notice Set of addresses that have delegated to each delegate (for iteration)
    mapping(address => address[]) private _delegators;
    mapping(address => mapping(address => uint256)) private _delegatorIndex;
    mapping(address => mapping(address => bool)) private _isDelegator;

    /// @notice Treasury contract that can burn tokens
    address public treasury;

    error SelfDelegationNotAllowed();
    error AlreadyDelegatedToThisAddress();
    error NotDelegated();
    error OnlyTreasury();
    error TreasuryAlreadySet();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice Set the treasury address (can only be set once)
    /// @param treasury_ The treasury contract address
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury != address(0)) revert TreasuryAlreadySet();
        treasury = treasury_;
    }

    /// @notice Mint new tokens (only owner)
    /// @param to Address to mint to
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    /// @notice Delegate voting power to another address
    /// @dev Self-delegation is not allowed (wastes gas, no effect)
    /// @param delegatee Address to delegate to
    function delegate(address delegatee) external override {
        if (delegatee == msg.sender) revert SelfDelegationNotAllowed();

        address currentDelegate = delegates[msg.sender];
        if (currentDelegate == delegatee) revert AlreadyDelegatedToThisAddress();

        uint256 balance = balanceOf(msg.sender);

        // Remove from previous delegate if exists
        if (currentDelegate != address(0)) {
            delegatedPower[currentDelegate] -= balance;
            _removeDelegator(currentDelegate, msg.sender);
        }

        // Add to new delegate (or undelegate if delegatee is zero)
        if (delegatee != address(0)) {
            delegates[msg.sender] = delegatee;
            delegatedPower[delegatee] += balance;
            _addDelegator(delegatee, msg.sender);
        } else {
            delegates[msg.sender] = address(0);
        }

        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }

    /// @notice Remove delegation
    function undelegate() external override {
        address currentDelegate = delegates[msg.sender];
        if (currentDelegate == address(0)) revert NotDelegated();

        uint256 balance = balanceOf(msg.sender);
        delegatedPower[currentDelegate] -= balance;
        _removeDelegator(currentDelegate, msg.sender);
        delegates[msg.sender] = address(0);

        emit DelegateChanged(msg.sender, currentDelegate, address(0));
    }

    /// @notice Get the total delegated power for a delegate
    /// @param delegate_ Address to check
    /// @return Total balance delegated to this address
    function getDelegatedPower(address delegate_) external view override returns (uint256) {
        return delegatedPower[delegate_];
    }

    /// @notice Get effective voting power (own balance + delegated)
    /// @param account Address to check
    /// @return Total voting power
    function getEffectiveVotingPower(address account) external view override returns (uint256) {
        // If account has delegated, their own balance doesn't count
        if (delegates[account] != address(0)) {
            return delegatedPower[account];
        }
        return balanceOf(account) + delegatedPower[account];
    }

    /// @notice Get list of delegators for a delegate
    /// @param delegate_ Address to check
    /// @return Array of delegator addresses
    function getDelegators(address delegate_) external view returns (address[] memory) {
        return _delegators[delegate_];
    }

    /// @notice Check if an address is a delegator to a delegate
    /// @param delegate_ The delegate address
    /// @param delegator The potential delegator address
    /// @return True if delegator has delegated to delegate_
    function isDelegatorOf(address delegate_, address delegator) external view returns (bool) {
        return _isDelegator[delegate_][delegator];
    }

    /// @notice Burn tokens from an account (only treasury can call)
    /// @param account Address to burn from
    /// @param amount Amount to burn
    function burnFrom(address account, uint256 amount) public override(ERC20Burnable, ICOGToken) {
        if (msg.sender == treasury) {
            // Treasury can burn without allowance
            _burn(account, amount);
        } else {
            // Others need allowance
            super.burnFrom(account, amount);
        }
    }

    /// @dev Update delegated power on transfers
    function _update(address from, address to, uint256 amount) internal override {
        // Update delegated power for sender
        if (from != address(0)) {
            address fromDelegate = delegates[from];
            if (fromDelegate != address(0)) {
                delegatedPower[fromDelegate] -= amount;
            }
        }

        // Update delegated power for receiver
        if (to != address(0)) {
            address toDelegate = delegates[to];
            if (toDelegate != address(0)) {
                delegatedPower[toDelegate] += amount;
            }
        }

        super._update(from, to, amount);
    }

    function _addDelegator(address delegate_, address delegator) private {
        if (!_isDelegator[delegate_][delegator]) {
            _delegatorIndex[delegate_][delegator] = _delegators[delegate_].length;
            _delegators[delegate_].push(delegator);
            _isDelegator[delegate_][delegator] = true;
        }
    }

    function _removeDelegator(address delegate_, address delegator) private {
        if (_isDelegator[delegate_][delegator]) {
            uint256 index = _delegatorIndex[delegate_][delegator];
            uint256 lastIndex = _delegators[delegate_].length - 1;

            if (index != lastIndex) {
                address lastDelegator = _delegators[delegate_][lastIndex];
                _delegators[delegate_][index] = lastDelegator;
                _delegatorIndex[delegate_][lastDelegator] = index;
            }

            _delegators[delegate_].pop();
            delete _delegatorIndex[delegate_][delegator];
            _isDelegator[delegate_][delegator] = false;
        }
    }
}
