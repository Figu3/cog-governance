// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {COGToken} from "../src/COGToken.sol";
import {COGTreasury} from "../src/COGTreasury.sol";
import {COGGovernor} from "../src/COGGovernor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ICOGGovernor} from "../src/interfaces/ICOGGovernor.sol";

contract COGGovernorTest is Test {
    COGToken public token;
    COGTreasury public treasury;
    COGGovernor public governor;
    MockERC20 public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public dave = address(0x4);
    address public recipient = address(0x5);

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, uint256 treasuryImpact, address recipient, string description);
    event DissentRecorded(uint256 indexed proposalId, address indexed holder, ICOGGovernor.DissentAction action, uint256 weight);
    event ProposalResolved(uint256 indexed proposalId, ICOGGovernor.ProposalState outcome, uint256 totalDissent, uint256 threshold);
    event ProposerSlashed(uint256 indexed proposalId, address indexed proposer, uint256 stakeSlashed);
    event ProposalReworked(uint256 indexed proposalId, uint256 newTreasuryImpact, string updatedDescription);

    function setUp() public {
        // Deploy USDC mock (6 decimals)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy token
        token = new COGToken("COG Token", "COG");

        // Deploy treasury
        treasury = new COGTreasury(address(usdc), address(token));

        // Deploy governor
        governor = new COGGovernor(address(token), address(treasury));

        // Setup connections
        token.setTreasury(address(treasury));
        treasury.setGovernor(address(governor));

        // Distribute tokens
        // Total supply: 10000 tokens
        token.mint(alice, 2000e18);   // 20%
        token.mint(bob, 3000e18);     // 30%
        token.mint(charlie, 2500e18); // 25%
        token.mint(dave, 2500e18);    // 25%

        // Fund treasury
        usdc.mint(address(treasury), 10000e6);

        // Approve governor for all users
        vm.prank(alice);
        token.approve(address(governor), type(uint256).max);
        vm.prank(bob);
        token.approve(address(governor), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(governor), type(uint256).max);
        vm.prank(dave);
        token.approve(address(governor), type(uint256).max);
    }

    // ============ Proposal Creation Tests ============

    function test_Propose() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(1, alice, 1000, recipient, "Test proposal");
        uint256 proposalId = governor.propose(1000, recipient, "Test proposal");

        assertEq(proposalId, 1);
        assertEq(governor.activeProposal(), 1);
        assertEq(governor.proposalCount(), 1);
    }

    function test_Propose_StakeLocked() public {
        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        governor.propose(1000, recipient, "Test proposal");

        // Min stake is 1% of supply = 100 tokens
        // Value-based stake is 10% * 1000 * 10% = 10 tokens (less than min)
        // So stake should be 100 tokens
        uint256 expectedStake = (token.totalSupply() * 100) / 10000;
        assertEq(token.balanceOf(alice), aliceBalanceBefore - expectedStake);
        assertEq(token.balanceOf(address(governor)), expectedStake);
    }

    function test_Propose_RevertActiveProposalExists() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test 1");

        vm.prank(bob);
        vm.expectRevert(COGGovernor.ActiveProposalExists.selector);
        governor.propose(1000, recipient, "Test 2");
    }

    function test_Propose_RevertInvalidTreasuryImpact() public {
        vm.prank(alice);
        vm.expectRevert(COGGovernor.InvalidTreasuryImpact.selector);
        governor.propose(0, recipient, "Zero impact");

        vm.prank(alice);
        vm.expectRevert(COGGovernor.InvalidTreasuryImpact.selector);
        governor.propose(6000, recipient, "Too high impact"); // Max is 50%
    }

    function test_Propose_RevertInvalidRecipient() public {
        vm.prank(alice);
        vm.expectRevert(COGGovernor.InvalidRecipient.selector);
        governor.propose(1000, address(0), "Invalid recipient");
    }

    function test_Propose_RevertCooldownNotElapsed() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test 1");

        // Fast forward past proposal window
        vm.warp(block.timestamp + 7 days + 1);

        // Resolve the proposal
        governor.resolve(1);

        // Try to propose again immediately
        vm.prank(alice);
        vm.expectRevert(COGGovernor.CooldownNotElapsed.selector);
        governor.propose(1000, recipient, "Test 2");

        // Fast forward past cooldown
        vm.warp(block.timestamp + 14 days);

        // Now it should work
        vm.prank(alice);
        governor.propose(1000, recipient, "Test 2");
    }

    function test_Propose_RevertInsufficientStake() public {
        // Create a user with minimal tokens
        address poorUser = address(0x99);
        token.mint(poorUser, 50e18); // 0.5% of supply
        vm.prank(poorUser);
        token.approve(address(governor), type(uint256).max);

        vm.prank(poorUser);
        vm.expectRevert(COGGovernor.InsufficientStake.selector);
        governor.propose(1000, recipient, "Test");
    }

    // ============ Veto Tests ============

    function test_Veto() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        vm.expectEmit(true, true, false, false);
        emit DissentRecorded(1, bob, ICOGGovernor.DissentAction.VETO, 0);
        governor.veto(1);

        (uint256 vetoWeight,,,,, ) = governor.getDissentBreakdown(1);
        // Bob has 30% of supply, veto weight is 1.0x
        // (3000 * 10000 / 10000) * 10000 / 10000 = 3000
        assertEq(vetoWeight, 3000);
    }

    function test_Veto_RevertAlreadyActed() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        governor.veto(1);

        vm.prank(bob);
        vm.expectRevert(COGGovernor.AlreadyActed.selector);
        governor.veto(1);
    }

    function test_Veto_RevertProposalNotFound() public {
        vm.prank(bob);
        vm.expectRevert(COGGovernor.ProposalNotFound.selector);
        governor.veto(1);
    }

    function test_Veto_RevertInsufficientBalance() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        address emptyUser = address(0x99);
        vm.prank(emptyUser);
        vm.expectRevert(COGGovernor.InsufficientBalance.selector);
        governor.veto(1);
    }

    // ============ Rework Request Tests ============

    function test_RequestRework() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        governor.requestRework(1);

        (, uint256 reworkWeight,,,, ) = governor.getDissentBreakdown(1);
        // Bob has 30%, rework weight is 0.5x = 1500
        assertEq(reworkWeight, 1500);
    }

    // ============ Delegate Voting Tests ============

    function test_DelegateVeto() public {
        // Bob delegates to charlie
        vm.prank(bob);
        token.delegate(charlie);

        // Dave delegates to charlie
        vm.prank(dave);
        token.delegate(charlie);

        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Charlie votes with delegated power
        vm.prank(charlie);
        governor.delegateVeto(1);

        (uint256 vetoWeight,,,,, ) = governor.getDissentBreakdown(1);
        // Bob has 30%, Dave has 25% = 55% delegated
        // Veto weight = 5500
        assertEq(vetoWeight, 5500);
    }

    function test_DelegateVeto_RevertNoDelegatedPower() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Charlie has no delegated power
        vm.prank(charlie);
        vm.expectRevert(COGGovernor.NoDelegatedPower.selector);
        governor.delegateVeto(1);
    }

    function test_DelegateRework() public {
        vm.prank(bob);
        token.delegate(charlie);

        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(charlie);
        governor.delegateRework(1);

        (, uint256 reworkWeight,,,, ) = governor.getDissentBreakdown(1);
        // Bob has 30%, rework weight is 0.5x = 1500
        assertEq(reworkWeight, 1500);
    }

    // ============ Resolution Tests ============

    function test_Resolve_Pass() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Fast forward past voting window
        vm.warp(block.timestamp + 7 days + 1);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, false);
        emit ProposalResolved(1, ICOGGovernor.ProposalState.PASSED, 0, 0);
        governor.resolve(1);

        // Check proposal passed
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));

        // Check treasury transfer executed (10% of 10000 = 1000)
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + 1000e6);

        // Check no active proposal
        assertEq(governor.activeProposal(), 0);
    }

    function test_Resolve_Fail_VetoOverThreshold() public {
        vm.prank(alice);
        uint256 proposalId = governor.propose(1000, recipient, "Test");

        // Get stake amount for later verification
        (,,, uint256 stakeAmount,,,,,) = governor.getProposal(proposalId);

        // Bob (30%) and Charlie (25%) veto = 55% > threshold
        vm.prank(bob);
        governor.veto(proposalId);

        vm.prank(charlie);
        governor.veto(proposalId);

        vm.warp(block.timestamp + 7 days + 1);

        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit ProposerSlashed(proposalId, alice, stakeAmount);
        governor.resolve(proposalId);

        // Check proposal failed
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.FAILED));

        // Check stake was slashed (burned)
        assertEq(token.totalSupply(), supplyBefore - stakeAmount);

        // Check no active proposal
        assertEq(governor.activeProposal(), 0);
    }

    function test_Resolve_Rework() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Request rework with enough votes (need 60% of threshold)
        // Threshold is ~11% (BASE 12% - NOISE 1% + impact adjustment)
        // We need rework signal > 0.6 * 11 = 6.6%
        // Bob (30%) + Charlie (25%) requesting rework = 27.5% (with 0.5x weight) = 13.75%
        vm.prank(bob);
        governor.requestRework(1);

        vm.prank(charlie);
        governor.requestRework(1);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectEmit(true, false, false, false);
        emit ProposalResolved(1, ICOGGovernor.ProposalState.REWORK, 0, 0);
        governor.resolve(1);

        // Check proposal in rework state
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.REWORK));

        // Active proposal still exists (waiting for rework submission)
        assertEq(governor.activeProposal(), 1);
    }

    function test_Resolve_RevertProposalStillActive() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Try to resolve before window ends
        vm.expectRevert(COGGovernor.ProposalStillActive.selector);
        governor.resolve(1);
    }

    // ============ Rework Submission Tests ============

    function test_SubmitRework() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Get to rework state
        vm.prank(bob);
        governor.requestRework(1);
        vm.prank(charlie);
        governor.requestRework(1);
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        // Submit rework
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ProposalReworked(1, 500, "Reduced proposal");
        governor.submitRework(1, 500, "Reduced proposal");

        // Check proposal is active again
        (,,,,,, ICOGGovernor.ProposalState state, uint256 reworkAttempts,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.ACTIVE));
        assertEq(reworkAttempts, 1);
    }

    function test_SubmitRework_RevertNotProposer() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        governor.requestRework(1);
        vm.prank(charlie);
        governor.requestRework(1);
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        vm.prank(bob);
        vm.expectRevert(COGGovernor.NotProposer.selector);
        governor.submitRework(1, 500, "Not my proposal");
    }

    function test_SubmitRework_RevertCannotIncreaseTreasuryImpact() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        governor.requestRework(1);
        vm.prank(charlie);
        governor.requestRework(1);
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        vm.prank(alice);
        vm.expectRevert(COGGovernor.InvalidTreasuryImpact.selector);
        governor.submitRework(1, 1500, "Trying to increase");
    }

    function test_SubmitRework_OnlyOnce() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // First rework cycle
        vm.prank(bob);
        governor.requestRework(1);
        vm.prank(charlie);
        governor.requestRework(1);
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        // Check it's in rework state
        (,,,,,, ICOGGovernor.ProposalState state, uint256 reworkAttempts,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.REWORK));
        assertEq(reworkAttempts, 0);

        vm.prank(alice);
        governor.submitRework(1, 500, "Reduced");

        // After rework submission, reworkAttempts should be 1
        (,,,,,, state, reworkAttempts,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.ACTIVE));
        assertEq(reworkAttempts, 1);

        // Since bob and charlie already voted, only dave can vote now
        // But dave alone (25%) won't hit rework threshold
        vm.prank(dave);
        governor.requestRework(1);

        vm.warp(block.timestamp + 14 days + 2);
        governor.resolve(1);

        // Should pass (not enough dissent for rework, and rework already used once)
        (,,,,,, state,,) = governor.getProposal(1);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));
    }

    // ============ Threshold Calculation Tests ============

    function test_CalculateThreshold() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        uint256 threshold = governor.calculateThreshold(1);

        // BASE_THRESHOLD = 1200 (12%)
        // Impact adjustment = 1000 * 2000 / 10000 = 200
        // Concentration adjustment = ~0 (simplified HHI)
        // Noise = 100 (1%)
        // Threshold = 1200 + 200 + 0 - 100 = 1300 (13%)
        assertEq(threshold, 1300);
    }

    function test_CalculateThreshold_HigherImpact() public {
        vm.prank(alice);
        governor.propose(3000, recipient, "Higher impact"); // 30%

        uint256 threshold = governor.calculateThreshold(1);

        // Impact adjustment = 3000 * 2000 / 10000 = 600
        // Threshold = 1200 + 600 - 100 = 1700 (17%)
        assertEq(threshold, 1700);
    }

    // ============ View Function Tests ============

    function test_CanPropose() public {
        // Alice can propose
        assertTrue(governor.canPropose(alice));

        // Alice proposes
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // No one else can propose while active
        assertFalse(governor.canPropose(bob));

        // Resolve proposal
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        // Alice still in cooldown
        assertFalse(governor.canPropose(alice));

        // Bob can propose now
        assertTrue(governor.canPropose(bob));
    }

    function test_GetDissentBreakdown() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        vm.prank(bob);
        governor.veto(1);

        vm.prank(charlie);
        governor.requestRework(1);

        (
            uint256 vetoWeight,
            uint256 reworkWeight,
            uint256 partialRedeemWeight,
            uint256 fullRedeemWeight,
            uint256 totalFailDissent,
            uint256 totalReworkSignal
        ) = governor.getDissentBreakdown(1);

        assertEq(vetoWeight, 3000); // Bob 30% * 1.0x
        assertEq(reworkWeight, 1250); // Charlie 25% * 0.5x
        assertEq(partialRedeemWeight, 0);
        assertEq(fullRedeemWeight, 0);
        assertEq(totalFailDissent, 3000);
        assertEq(totalReworkSignal, 1250 + 1500); // rework + veto/2
    }

    // ============ Redemption Dissent Tests ============

    function test_RedemptionDissent_PartialRedeem() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Bob redeems some tokens
        vm.prank(bob);
        treasury.redeem(1500e18); // Half of his 3000 tokens

        (,, uint256 partialRedeemWeight,,,) = governor.getDissentBreakdown(1);
        // 1500 / 10000 = 15% * 2.0x = 3000
        assertEq(partialRedeemWeight, 3000);
    }

    function test_RedemptionDissent_FullRedeem() public {
        vm.prank(alice);
        governor.propose(1000, recipient, "Test");

        // Bob redeems all tokens
        vm.prank(bob);
        treasury.redeemAll();

        (,,, uint256 fullRedeemWeight,,) = governor.getDissentBreakdown(1);
        // 3000 / 10000 = 30% * 4.0x = 12000
        assertEq(fullRedeemWeight, 12000);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Propose_TreasuryImpact(uint256 impact) public {
        impact = bound(impact, 1, 5000);

        vm.prank(alice);
        governor.propose(impact, recipient, "Test");

        (,uint256 treasuryImpact,,,,,,,) = governor.getProposal(1);
        assertEq(treasuryImpact, impact);
    }

    function testFuzz_CalculateThreshold(uint256 impact) public {
        impact = bound(impact, 1, 5000);

        vm.prank(alice);
        governor.propose(impact, recipient, "Test");

        uint256 threshold = governor.calculateThreshold(1);

        // Verify threshold is within expected range
        uint256 expectedMin = 1100; // BASE - NOISE
        uint256 expectedMax = 1200 + (5000 * 2000 / 10000) + 1000; // BASE + max impact + max concentration

        assertTrue(threshold >= expectedMin);
        assertTrue(threshold <= expectedMax);
    }
}
