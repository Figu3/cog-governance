// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICOGGovernor {
    enum ProposalState { ACTIVE, PASSED, REWORK, FAILED }
    enum DissentAction { NONE, VETO, REWORK, PARTIAL_REDEEM, FULL_REDEEM }

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint256 treasuryImpact,
        address recipient,
        string description
    );
    event DissentRecorded(uint256 indexed proposalId, address indexed holder, DissentAction action, uint256 weight);
    event ProposalResolved(uint256 indexed proposalId, ProposalState outcome, uint256 totalDissent, uint256 threshold);
    event ProposerSlashed(uint256 indexed proposalId, address indexed proposer, uint256 stakeSlashed);
    event ProposalReworked(uint256 indexed proposalId, uint256 newTreasuryImpact, string updatedDescription);

    function propose(
        uint256 treasuryImpactBps,
        address recipient,
        string calldata description
    ) external returns (uint256 proposalId);

    function veto(uint256 proposalId) external;
    function requestRework(uint256 proposalId) external;
    function delegateVeto(uint256 proposalId) external;
    function delegateRework(uint256 proposalId) external;
    function resolve(uint256 proposalId) external;
    function submitRework(
        uint256 proposalId,
        uint256 newTreasuryImpactBps,
        string calldata updatedDescription
    ) external;

    function recordRedemptionDissent(
        uint256 proposalId,
        address holder,
        uint256 tokenAmount,
        bool isFullRedeem
    ) external;

    function calculateThreshold(uint256 proposalId) external view returns (uint256);
    function calculateHHI() external view returns (uint256);
    function getDissentBreakdown(uint256 proposalId) external view returns (
        uint256 vetoWeight,
        uint256 reworkWeight,
        uint256 partialRedeemWeight,
        uint256 fullRedeemWeight,
        uint256 totalFailDissent,
        uint256 totalReworkSignal
    );
    function canPropose(address account) external view returns (bool);
    function activeProposal() external view returns (uint256);
}
