// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICOGTreasury} from "./interfaces/ICOGTreasury.sol";
import {ICOGToken} from "./interfaces/ICOGToken.sol";
import {ICOGGovernor} from "./interfaces/ICOGGovernor.sol";

/// @title COGTreasury
/// @notice 100% stablecoin treasury with NAV-based redemption
/// @dev Redemptions include haircut only during active proposals
contract COGTreasury is ICOGTreasury, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The stablecoin held in treasury (USDC or similar)
    IERC20 public immutable stablecoinToken;

    /// @notice The COG token
    ICOGToken public immutable cogToken;

    /// @notice The governor contract
    ICOGGovernor public governor;

    /// @notice Redemption haircut in basis points (200 = 2%)
    uint256 public override redemptionHaircut = 200;

    /// @notice Accumulated haircut fees
    uint256 public accumulatedFees;

    error ZeroAmount();
    error InsufficientBalance();
    error GovernorAlreadySet();
    error OnlyGovernor();
    error ZeroAddress();

    modifier onlyGovernor() {
        if (msg.sender != address(governor)) revert OnlyGovernor();
        _;
    }

    constructor(address stablecoin_, address token_) Ownable(msg.sender) {
        if (stablecoin_ == address(0) || token_ == address(0)) revert ZeroAddress();
        stablecoinToken = IERC20(stablecoin_);
        cogToken = ICOGToken(token_);
    }

    /// @notice Set the governor address (can only be set once)
    /// @param governor_ The governor contract address
    function setGovernor(address governor_) external onlyOwner {
        if (address(governor) != address(0)) revert GovernorAlreadySet();
        if (governor_ == address(0)) revert ZeroAddress();
        governor = ICOGGovernor(governor_);
    }

    /// @notice Returns the stablecoin address
    function stablecoin() external view override returns (address) {
        return address(stablecoinToken);
    }

    /// @notice Returns the token address
    function token() external view override returns (address) {
        return address(cogToken);
    }

    /// @notice Calculate Net Asset Value per token (scaled to 18 decimals)
    /// @return NAV value in stablecoin terms (1e18 = 1 stablecoin per token)
    function nav() public view override returns (uint256) {
        uint256 supply = cogToken.totalSupply();
        if (supply == 0) return 1e18; // Default NAV of 1:1

        uint256 treasuryBalance = stablecoinToken.balanceOf(address(this));
        // NAV = (treasury balance * 1e18) / total supply
        // Adjust for stablecoin decimals (assuming 6 for USDC)
        return (treasuryBalance * 1e18 * 1e12) / supply;
    }

    /// @notice Check if there's an active proposal
    function activeProposal() public view override returns (bool) {
        if (address(governor) == address(0)) return false;
        return governor.activeProposal() > 0;
    }

    /// @notice Deposit stablecoins to treasury
    /// @param amount Amount of stablecoins to deposit
    function deposit(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        stablecoinToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Partial redemption - redeem specific amount of tokens
    /// @param tokenAmount Amount of tokens to redeem
    function redeem(uint256 tokenAmount) external override nonReentrant {
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 holderBalance = cogToken.balanceOf(msg.sender);
        if (tokenAmount > holderBalance) revert InsufficientBalance();

        bool isFullRedeem = (tokenAmount == holderBalance);
        _executeRedemption(msg.sender, tokenAmount, isFullRedeem);
    }

    /// @notice Full redemption - redeem all tokens
    function redeemAll() external override nonReentrant {
        uint256 tokenAmount = cogToken.balanceOf(msg.sender);
        if (tokenAmount == 0) revert ZeroAmount();

        _executeRedemption(msg.sender, tokenAmount, true);
    }

    /// @notice Execute treasury transfer for passed proposal (only governor)
    /// @param recipient Address to receive funds
    /// @param amount Amount of stablecoins to transfer
    function executeTreasuryTransfer(address recipient, uint256 amount) external onlyGovernor {
        if (recipient == address(0)) revert ZeroAddress();
        stablecoinToken.safeTransfer(recipient, amount);
    }

    /// @notice Set redemption haircut (only owner)
    /// @param newHaircut New haircut in basis points
    function setRedemptionHaircut(uint256 newHaircut) external onlyOwner {
        redemptionHaircut = newHaircut;
    }

    /// @notice Withdraw accumulated fees (only owner)
    /// @param to Address to send fees to
    function withdrawFees(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 fees = accumulatedFees;
        accumulatedFees = 0;
        stablecoinToken.safeTransfer(to, fees);
    }

    function _executeRedemption(address holder, uint256 tokenAmount, bool isFullRedeem) private {
        uint256 navValue = nav();

        // Apply haircut only during active proposals
        uint256 haircut = activeProposal() ? redemptionHaircut : 0;

        // Calculate stablecoins out
        // stablecoinsOut = (tokenAmount * navValue * (10000 - haircut)) / (10000 * 1e18)
        // Then convert back to stablecoin decimals (divide by 1e12)
        uint256 stablecoinsOut = (tokenAmount * navValue * (10000 - haircut)) / (10000 * 1e18 * 1e12);

        // Track fees from haircut
        if (haircut > 0) {
            uint256 fullValue = (tokenAmount * navValue) / (1e18 * 1e12);
            accumulatedFees += fullValue - stablecoinsOut;
        }

        // Burn tokens first (CEI pattern)
        cogToken.burnFrom(holder, tokenAmount);

        // Transfer stablecoins
        stablecoinToken.safeTransfer(holder, stablecoinsOut);

        // Notify governor of redemption dissent if active proposal
        uint256 activeProposalId = address(governor) != address(0) ? governor.activeProposal() : 0;
        if (activeProposalId > 0) {
            governor.recordRedemptionDissent(activeProposalId, holder, tokenAmount, isFullRedeem);
        }

        emit Redemption(
            holder,
            tokenAmount,
            stablecoinsOut,
            isFullRedeem ? RedemptionType.FULL : RedemptionType.PARTIAL
        );
    }
}
