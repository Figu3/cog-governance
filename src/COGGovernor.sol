// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICOGGovernor} from "./interfaces/ICOGGovernor.sol";
import {ICOGToken} from "./interfaces/ICOGToken.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

interface ICOGTreasuryExtended {
    function stablecoin() external view returns (address);
    function executeTreasuryTransfer(address recipient, uint256 amount) external;
    function nav() external view returns (uint256);
}

/// @title COGGovernor
/// @notice Consent-by-Ownership Governance - ownership implies consent by default
/// @dev Token holders must actively dissent through veto, rework, or redemption
contract COGGovernor is ICOGGovernor, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ Configuration Constants ============

    /// @notice Base threshold in basis points (12%)
    uint256 public constant BASE_THRESHOLD = 1200;

    /// @notice Impact multiplier scaled by 10000 (0.20)
    uint256 public constant IMPACT_MULTIPLIER = 2000;

    /// @notice Rework threshold as percentage of fail threshold (60%)
    uint256 public constant REWORK_THRESHOLD_RATIO = 6000;

    /// @notice Concentration scalar (50 scaled)
    uint256 public constant CONCENTRATION_SCALAR = 5000;

    /// @notice Max concentration adjustment (10%)
    uint256 public constant CONCENTRATION_CAP = 1000;

    /// @notice Noise baseline (1%)
    uint256 public constant NOISE_BASELINE = 100;

    /// @notice Veto weight (1.0x)
    uint256 public constant VETO_WEIGHT = 10000;

    /// @notice Rework weight (0.5x)
    uint256 public constant REWORK_WEIGHT = 5000;

    /// @notice Partial redemption weight (2.0x)
    uint256 public constant PARTIAL_REDEEM_WEIGHT = 20000;

    /// @notice Full redemption weight (4.0x)
    uint256 public constant FULL_REDEEM_WEIGHT = 40000;

    /// @notice Proposal voting window
    uint256 public constant PROPOSAL_WINDOW = 7 days;

    /// @notice Cooldown between proposals for same proposer
    uint256 public constant PROPOSER_COOLDOWN = 14 days;

    /// @notice Minimum proposer stake (1% of supply)
    uint256 public constant MIN_PROPOSER_STAKE_BPS = 100;

    /// @notice Stake multiplier (10% of proposal value)
    uint256 public constant STAKE_MULTIPLIER_BPS = 1000;

    /// @notice Maximum treasury impact per proposal (50%)
    uint256 public constant MAX_TREASURY_IMPACT_BPS = 5000;

    // ============ State Variables ============

    /// @notice The COG token
    ICOGToken public immutable token;

    /// @notice The treasury contract
    ICOGTreasuryExtended public immutable treasury;

    /// @notice Total number of proposals created
    uint256 public proposalCount;

    /// @notice Currently active proposal ID (0 if none)
    uint256 private _activeProposalId;

    /// @notice Mapping from proposal ID to proposal data
    mapping(uint256 => Proposal) private _proposals;

    /// @notice Last proposal time for each address (cooldown tracking)
    mapping(address => uint256) public lastProposalTime;

    /// @notice Holder actions per proposal
    mapping(uint256 => mapping(address => DissentAction)) public holderActions;

    /// @notice Token balance snapshots at proposal creation
    mapping(uint256 => uint256) public proposalTotalSupply;
    mapping(uint256 => mapping(address => uint256)) public proposalBalanceSnapshot;

    /// @notice HHI snapshot at proposal creation
    mapping(uint256 => uint256) public proposalHHI;

    struct Proposal {
        uint256 id;
        address proposer;
        uint256 treasuryImpact; // basis points
        address recipient;
        uint256 stakeAmount;
        uint256 startTime;
        uint256 endTime;
        ProposalState state;
        uint256 reworkAttempts;
        string description;
        // Dissent tracking
        uint256 vetoWeight;
        uint256 reworkWeight;
        uint256 partialRedeemWeight;
        uint256 fullRedeemWeight;
    }

    // ============ Errors ============

    error ActiveProposalExists();
    error NoActiveProposal();
    error ProposalNotActive();
    error ProposalStillActive();
    error InsufficientStake();
    error CooldownNotElapsed();
    error InvalidTreasuryImpact();
    error InvalidRecipient();
    error AlreadyActed();
    error NoDelegatedPower();
    error NotProposer();
    error CannotRework();
    error OnlyTreasury();
    error ProposalNotFound();
    error InsufficientBalance();
    error ZeroAddress();

    // ============ Modifiers ============

    modifier onlyTreasury() {
        if (msg.sender != address(treasury)) revert OnlyTreasury();
        _;
    }

    // ============ Constructor ============

    constructor(address token_, address treasury_) Ownable(msg.sender) {
        if (token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        token = ICOGToken(token_);
        treasury = ICOGTreasuryExtended(treasury_);
    }

    // ============ Proposal Creation ============

    /// @notice Create a new proposal
    /// @param treasuryImpactBps Percentage of treasury being requested (in basis points)
    /// @param recipient Address to receive treasury funds if passed
    /// @param description Description of the proposal
    /// @return proposalId The ID of the created proposal
    function propose(
        uint256 treasuryImpactBps,
        address recipient,
        string calldata description
    ) external override nonReentrant returns (uint256 proposalId) {
        if (_activeProposalId != 0) revert ActiveProposalExists();
        if (treasuryImpactBps == 0 || treasuryImpactBps > MAX_TREASURY_IMPACT_BPS) revert InvalidTreasuryImpact();
        if (recipient == address(0)) revert InvalidRecipient();

        // Check cooldown (only if user has proposed before)
        uint256 lastTime = lastProposalTime[msg.sender];
        if (lastTime > 0 && block.timestamp < lastTime + PROPOSER_COOLDOWN) {
            revert CooldownNotElapsed();
        }

        // Calculate required stake
        uint256 totalSupply = token.totalSupply();
        uint256 minStake = (totalSupply * MIN_PROPOSER_STAKE_BPS) / 10000;
        uint256 valueBasedStake = (totalSupply * treasuryImpactBps * STAKE_MULTIPLIER_BPS) / (10000 * 10000);
        uint256 requiredStake = minStake > valueBasedStake ? minStake : valueBasedStake;

        // Check proposer has enough tokens
        if (token.balanceOf(msg.sender) < requiredStake) revert InsufficientStake();

        // Lock stake by transferring to governor
        token.transferFrom(msg.sender, address(this), requiredStake);

        // Create proposal
        proposalCount++;
        proposalId = proposalCount;
        _activeProposalId = proposalId;

        Proposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.treasuryImpact = treasuryImpactBps;
        p.recipient = recipient;
        p.stakeAmount = requiredStake;
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + PROPOSAL_WINDOW;
        p.state = ProposalState.ACTIVE;
        p.description = description;

        // Snapshot total supply and HHI
        proposalTotalSupply[proposalId] = totalSupply;
        proposalHHI[proposalId] = calculateHHI();

        lastProposalTime[msg.sender] = block.timestamp;

        emit ProposalCreated(proposalId, msg.sender, treasuryImpactBps, recipient, description);
    }

    // ============ Dissent Actions ============

    /// @notice Cast a veto vote against active proposal
    /// @param proposalId The proposal to veto
    function veto(uint256 proposalId) external override nonReentrant {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalNotFound();
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();
        if (holderActions[proposalId][msg.sender] != DissentAction.NONE) revert AlreadyActed();

        uint256 balance = token.balanceOf(msg.sender);
        if (balance == 0) revert InsufficientBalance();

        // Snapshot balance if not already
        if (proposalBalanceSnapshot[proposalId][msg.sender] == 0) {
            proposalBalanceSnapshot[proposalId][msg.sender] = balance;
        }

        uint256 snapshotBalance = proposalBalanceSnapshot[proposalId][msg.sender];
        uint256 holderShare = (snapshotBalance * 10000) / proposalTotalSupply[proposalId];
        uint256 weight = (holderShare * VETO_WEIGHT) / 10000;

        holderActions[proposalId][msg.sender] = DissentAction.VETO;
        p.vetoWeight += weight;

        emit DissentRecorded(proposalId, msg.sender, DissentAction.VETO, weight);
    }

    /// @notice Request proposal rework
    /// @param proposalId The proposal to request rework for
    function requestRework(uint256 proposalId) external override nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();
        if (holderActions[proposalId][msg.sender] != DissentAction.NONE) revert AlreadyActed();

        uint256 balance = token.balanceOf(msg.sender);
        if (balance == 0) revert InsufficientBalance();

        // Snapshot balance if not already
        if (proposalBalanceSnapshot[proposalId][msg.sender] == 0) {
            proposalBalanceSnapshot[proposalId][msg.sender] = balance;
        }

        uint256 snapshotBalance = proposalBalanceSnapshot[proposalId][msg.sender];
        uint256 holderShare = (snapshotBalance * 10000) / proposalTotalSupply[proposalId];
        uint256 weight = (holderShare * REWORK_WEIGHT) / 10000;

        holderActions[proposalId][msg.sender] = DissentAction.REWORK;
        p.reworkWeight += weight;

        emit DissentRecorded(proposalId, msg.sender, DissentAction.REWORK, weight);
    }

    /// @notice Delegate casts veto with all delegated power
    /// @param proposalId The proposal to veto
    function delegateVeto(uint256 proposalId) external override nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();

        uint256 delegatedPower = token.getDelegatedPower(msg.sender);
        if (delegatedPower == 0) revert NoDelegatedPower();

        // Get all delegators and mark them as having voted
        address[] memory delegators = _getDelegators(msg.sender);
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < delegators.length; i++) {
            address delegator = delegators[i];
            if (holderActions[proposalId][delegator] == DissentAction.NONE) {
                uint256 balance = token.balanceOf(delegator);

                // Snapshot balance if not already
                if (proposalBalanceSnapshot[proposalId][delegator] == 0) {
                    proposalBalanceSnapshot[proposalId][delegator] = balance;
                }

                uint256 snapshotBalance = proposalBalanceSnapshot[proposalId][delegator];
                uint256 holderShare = (snapshotBalance * 10000) / proposalTotalSupply[proposalId];
                uint256 weight = (holderShare * VETO_WEIGHT) / 10000;

                holderActions[proposalId][delegator] = DissentAction.VETO;
                totalWeight += weight;

                emit DissentRecorded(proposalId, delegator, DissentAction.VETO, weight);
            }
        }

        p.vetoWeight += totalWeight;
    }

    /// @notice Delegate requests rework with all delegated power
    /// @param proposalId The proposal to request rework for
    function delegateRework(uint256 proposalId) external override nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();

        uint256 delegatedPower = token.getDelegatedPower(msg.sender);
        if (delegatedPower == 0) revert NoDelegatedPower();

        // Get all delegators and mark them as having voted
        address[] memory delegators = _getDelegators(msg.sender);
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < delegators.length; i++) {
            address delegator = delegators[i];
            if (holderActions[proposalId][delegator] == DissentAction.NONE) {
                uint256 balance = token.balanceOf(delegator);

                // Snapshot balance if not already
                if (proposalBalanceSnapshot[proposalId][delegator] == 0) {
                    proposalBalanceSnapshot[proposalId][delegator] = balance;
                }

                uint256 snapshotBalance = proposalBalanceSnapshot[proposalId][delegator];
                uint256 holderShare = (snapshotBalance * 10000) / proposalTotalSupply[proposalId];
                uint256 weight = (holderShare * REWORK_WEIGHT) / 10000;

                holderActions[proposalId][delegator] = DissentAction.REWORK;
                totalWeight += weight;

                emit DissentRecorded(proposalId, delegator, DissentAction.REWORK, weight);
            }
        }

        p.reworkWeight += totalWeight;
    }

    /// @notice Record redemption as dissent (only treasury)
    /// @param proposalId The active proposal
    /// @param holder The holder who redeemed
    /// @param tokenAmount Amount of tokens redeemed
    /// @param isFullRedeem Whether this was a full redemption
    function recordRedemptionDissent(
        uint256 proposalId,
        address holder,
        uint256 tokenAmount,
        bool isFullRedeem
    ) external override onlyTreasury {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();
        if (holderActions[proposalId][holder] != DissentAction.NONE) revert AlreadyActed();

        // Use the token amount being redeemed for weight calculation
        uint256 holderShare = (tokenAmount * 10000) / proposalTotalSupply[proposalId];
        uint256 weight;

        if (isFullRedeem) {
            holderActions[proposalId][holder] = DissentAction.FULL_REDEEM;
            weight = (holderShare * FULL_REDEEM_WEIGHT) / 10000;
            p.fullRedeemWeight += weight;
        } else {
            holderActions[proposalId][holder] = DissentAction.PARTIAL_REDEEM;
            weight = (holderShare * PARTIAL_REDEEM_WEIGHT) / 10000;
            p.partialRedeemWeight += weight;
        }

        emit DissentRecorded(proposalId, holder, holderActions[proposalId][holder], weight);
    }

    // ============ Resolution ============

    /// @notice Resolve a proposal after voting window ends
    /// @param proposalId The proposal to resolve
    function resolve(uint256 proposalId) external override nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.ACTIVE) revert ProposalNotActive();
        if (block.timestamp < p.endTime) revert ProposalStillActive();

        uint256 threshold = calculateThreshold(proposalId);
        uint256 reworkThreshold = (threshold * REWORK_THRESHOLD_RATIO) / 10000;

        // Calculate dissent totals
        uint256 failDissent = p.vetoWeight + p.partialRedeemWeight + p.fullRedeemWeight;
        // Veto partially signals rework
        uint256 reworkSignal = p.reworkWeight + (p.vetoWeight / 2);

        if (failDissent >= threshold) {
            // FAIL - slash proposer
            p.state = ProposalState.FAILED;
            _slashProposer(proposalId);
            emit ProposalResolved(proposalId, ProposalState.FAILED, failDissent, threshold);
        } else if (
            reworkSignal >= reworkThreshold &&
            p.reworkWeight > p.vetoWeight / 2 &&
            p.reworkAttempts == 0
        ) {
            // REWORK - give proposer another chance
            p.state = ProposalState.REWORK;
            emit ProposalResolved(proposalId, ProposalState.REWORK, failDissent, threshold);
        } else {
            // PASS - execute treasury transfer
            p.state = ProposalState.PASSED;
            _executeTreasuryTransfer(proposalId);
            _returnProposerStake(proposalId);
            emit ProposalResolved(proposalId, ProposalState.PASSED, failDissent, threshold);
        }

        // Clear active proposal if not in rework
        if (p.state != ProposalState.REWORK) {
            _activeProposalId = 0;
        }
    }

    /// @notice Submit a reworked proposal (only original proposer)
    /// @param proposalId The proposal in REWORK state
    /// @param newTreasuryImpactBps New treasury impact (must be <= original)
    /// @param updatedDescription Updated description
    function submitRework(
        uint256 proposalId,
        uint256 newTreasuryImpactBps,
        string calldata updatedDescription
    ) external override nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.state != ProposalState.REWORK) revert CannotRework();
        if (msg.sender != p.proposer) revert NotProposer();
        if (newTreasuryImpactBps == 0 || newTreasuryImpactBps > p.treasuryImpact) {
            revert InvalidTreasuryImpact();
        }

        // Reset dissent weights
        p.vetoWeight = 0;
        p.reworkWeight = 0;
        p.partialRedeemWeight = 0;
        p.fullRedeemWeight = 0;

        // Update proposal
        p.treasuryImpact = newTreasuryImpactBps;
        p.description = updatedDescription;
        p.reworkAttempts++;
        p.state = ProposalState.ACTIVE;
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + PROPOSAL_WINDOW;

        // Update total supply snapshot for new voting period
        proposalTotalSupply[proposalId] = token.totalSupply();

        emit ProposalReworked(proposalId, newTreasuryImpactBps, updatedDescription);
    }

    // ============ View Functions ============

    /// @notice Calculate threshold for a proposal
    /// @param proposalId The proposal ID
    /// @return Threshold in basis points
    function calculateThreshold(uint256 proposalId) public view override returns (uint256) {
        Proposal storage p = _proposals[proposalId];

        // T = B + (I × α) + C - N
        uint256 B = BASE_THRESHOLD;
        uint256 impactAdjustment = (p.treasuryImpact * IMPACT_MULTIPLIER) / 10000;

        // Use snapshotted HHI
        uint256 hhi = proposalHHI[proposalId];
        uint256 C = 0;
        if (hhi > 100) {
            C = ((hhi - 100) * CONCENTRATION_SCALAR) / 10000;
            if (C > CONCENTRATION_CAP) C = CONCENTRATION_CAP;
        }

        uint256 N = NOISE_BASELINE;

        uint256 threshold = B + impactAdjustment + C;
        if (threshold > N) {
            threshold -= N;
        } else {
            threshold = 0;
        }

        return threshold;
    }

    /// @notice Calculate Herfindahl-Hirschman Index for token distribution
    /// @return HHI value (10000 = fully concentrated, ~0 = fully distributed)
    function calculateHHI() public view override returns (uint256) {
        // This is a simplified HHI calculation
        // In production, you'd want to track top holders more efficiently
        uint256 totalSupply = token.totalSupply();
        if (totalSupply == 0) return 0;

        // For gas efficiency, we'll use a simplified proxy
        // A more accurate implementation would iterate top holders
        // Here we return a baseline that assumes reasonable distribution
        return 100; // 1% baseline - can be enhanced with holder tracking
    }

    /// @notice Get dissent breakdown for a proposal
    /// @param proposalId The proposal ID
    function getDissentBreakdown(uint256 proposalId)
        external
        view
        override
        returns (
            uint256 vetoWeight,
            uint256 reworkWeight,
            uint256 partialRedeemWeight,
            uint256 fullRedeemWeight,
            uint256 totalFailDissent,
            uint256 totalReworkSignal
        )
    {
        Proposal storage p = _proposals[proposalId];
        vetoWeight = p.vetoWeight;
        reworkWeight = p.reworkWeight;
        partialRedeemWeight = p.partialRedeemWeight;
        fullRedeemWeight = p.fullRedeemWeight;
        totalFailDissent = vetoWeight + partialRedeemWeight + fullRedeemWeight;
        totalReworkSignal = reworkWeight + (vetoWeight / 2);
    }

    /// @notice Check if an address can propose
    /// @param account Address to check
    function canPropose(address account) external view override returns (bool) {
        if (_activeProposalId != 0) return false;

        // Only check cooldown if user has proposed before
        uint256 lastTime = lastProposalTime[account];
        if (lastTime > 0 && block.timestamp < lastTime + PROPOSER_COOLDOWN) return false;

        uint256 totalSupply = token.totalSupply();
        uint256 minStake = (totalSupply * MIN_PROPOSER_STAKE_BPS) / 10000;

        return token.balanceOf(account) >= minStake;
    }

    /// @notice Get currently active proposal ID
    /// @return Proposal ID or 0 if none
    function activeProposal() external view override returns (uint256) {
        return _activeProposalId;
    }

    /// @notice Get proposal details
    /// @param proposalId The proposal ID
    function getProposal(uint256 proposalId)
        external
        view
        returns (
            address proposer,
            uint256 treasuryImpact,
            address recipient,
            uint256 stakeAmount,
            uint256 startTime,
            uint256 endTime,
            ProposalState state,
            uint256 reworkAttempts,
            string memory description
        )
    {
        Proposal storage p = _proposals[proposalId];
        return (
            p.proposer,
            p.treasuryImpact,
            p.recipient,
            p.stakeAmount,
            p.startTime,
            p.endTime,
            p.state,
            p.reworkAttempts,
            p.description
        );
    }

    // ============ Internal Functions ============

    function _slashProposer(uint256 proposalId) private {
        Proposal storage p = _proposals[proposalId];

        // Burn the staked tokens
        uint256 stakeAmount = p.stakeAmount;
        ERC20Burnable(address(token)).burn(stakeAmount);

        emit ProposerSlashed(proposalId, p.proposer, stakeAmount);
    }

    function _executeTreasuryTransfer(uint256 proposalId) private {
        Proposal storage p = _proposals[proposalId];

        // Calculate amount based on treasury impact
        uint256 treasuryBalance = IERC20(treasury.stablecoin()).balanceOf(address(treasury));
        uint256 transferAmount = (treasuryBalance * p.treasuryImpact) / 10000;

        treasury.executeTreasuryTransfer(p.recipient, transferAmount);
    }

    function _returnProposerStake(uint256 proposalId) private {
        Proposal storage p = _proposals[proposalId];

        // Return stake to proposer
        token.transfer(p.proposer, p.stakeAmount);
    }

    function _getDelegators(address delegate_) private view returns (address[] memory) {
        // Call the token contract to get delegators
        // This requires the token to expose this function
        (bool success, bytes memory data) = address(token).staticcall(
            abi.encodeWithSignature("getDelegators(address)", delegate_)
        );

        if (success && data.length > 0) {
            return abi.decode(data, (address[]));
        }

        return new address[](0);
    }
}
