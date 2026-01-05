// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {COGToken} from "../src/COGToken.sol";
import {COGTreasury} from "../src/COGTreasury.sol";
import {COGGovernor} from "../src/COGGovernor.sol";
import {COGDelegateRegistry} from "../src/COGDelegateRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ICOGGovernor} from "../src/interfaces/ICOGGovernor.sol";

/// @title Integration Tests for COG Governance System
/// @notice Tests full proposal lifecycle scenarios
contract IntegrationTest is Test {
    COGToken public token;
    COGTreasury public treasury;
    COGGovernor public governor;
    COGDelegateRegistry public registry;
    MockERC20 public usdc;

    address public owner = address(this);
    address public proposer = address(0x1);
    address public vetoer1 = address(0x2);
    address public vetoer2 = address(0x3);
    address public delegate1 = address(0x4);
    address public smallHolder = address(0x5);
    address public recipient = address(0x6);

    function setUp() public {
        // Deploy system
        usdc = new MockERC20("USD Coin", "USDC", 6);
        token = new COGToken("COG Token", "COG");
        treasury = new COGTreasury(address(usdc), address(token));
        governor = new COGGovernor(address(token), address(treasury));
        registry = new COGDelegateRegistry(address(governor));

        // Setup connections
        token.setTreasury(address(treasury));
        treasury.setGovernor(address(governor));

        // Distribute tokens (total 10000)
        token.mint(proposer, 2000e18);      // 20%
        token.mint(vetoer1, 1500e18);       // 15%
        token.mint(vetoer2, 1500e18);       // 15%
        token.mint(delegate1, 500e18);      // 5%
        token.mint(smallHolder, 4500e18);   // 45%

        // Fund treasury with 10000 USDC
        usdc.mint(address(treasury), 10000e6);

        // Approve governor
        vm.prank(proposer);
        token.approve(address(governor), type(uint256).max);
        vm.prank(vetoer1);
        token.approve(address(governor), type(uint256).max);
        vm.prank(vetoer2);
        token.approve(address(governor), type(uint256).max);
    }

    // ============ Full Lifecycle: Proposal → Pass ============

    function test_Lifecycle_ProposalPasses() public {
        // 1. Proposer creates proposal for 10% of treasury
        vm.prank(proposer);
        uint256 proposalId = governor.propose(1000, recipient, "Fund development");

        assertEq(governor.activeProposal(), proposalId);
        assertEq(treasury.activeProposal(), true);

        // 2. Small opposition (not enough to fail)
        // Threshold = 1200 + 200 - 100 = 1300 (13%)
        // Using delegate1 who has 5% < 13% threshold
        vm.prank(delegate1);
        governor.veto(proposalId);

        // Check dissent recorded
        (uint256 vetoWeight,,,,, ) = governor.getDissentBreakdown(proposalId);
        assertEq(vetoWeight, 500); // 5% * 1.0x

        // 3. Fast forward past voting window
        vm.warp(block.timestamp + 7 days + 1);

        // 4. Resolve proposal
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        governor.resolve(proposalId);

        // 5. Verify passed and funds transferred
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));

        // 10% of 10000 USDC = 1000 USDC
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + 1000e6);

        // Proposer got stake back
        assertEq(governor.activeProposal(), 0);
    }

    // ============ Full Lifecycle: Proposal → Fail (Veto) ============

    function test_Lifecycle_ProposalFailsFromVeto() public {
        // 1. Proposer creates proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(1000, recipient, "Fund development");

        uint256 proposerStake;
        (,,, proposerStake,,,,,) = governor.getProposal(proposalId);

        // 2. Major opposition vetoes
        vm.prank(vetoer1);
        governor.veto(proposalId);

        vm.prank(vetoer2);
        governor.veto(proposalId);

        // 3. Delegate registers and delegates vote
        vm.prank(delegate1);
        token.delegate(vetoer1);

        // Vetoer1 now has delegated power
        vm.prank(vetoer1);
        governor.delegateVeto(proposalId);

        // Check total dissent
        (uint256 vetoWeight,,,,uint256 totalDissent,) = governor.getDissentBreakdown(proposalId);
        // vetoer1: 15%, vetoer2: 15%, delegate1: 5% = 35%
        assertEq(totalDissent, 3500);

        // 4. Fast forward and resolve
        vm.warp(block.timestamp + 7 days + 1);

        uint256 supplyBefore = token.totalSupply();
        governor.resolve(proposalId);

        // 5. Verify failed and stake slashed
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.FAILED));

        // Stake was burned
        assertEq(token.totalSupply(), supplyBefore - proposerStake);

        // No funds transferred
        assertEq(usdc.balanceOf(recipient), 0);
    }

    // ============ Full Lifecycle: Proposal → Rework → Pass ============

    function test_Lifecycle_ProposalReworkedThenPasses() public {
        // 1. Proposer creates proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(2000, recipient, "Large request"); // 20%

        // 2. Community requests rework (not outright rejection)
        vm.prank(vetoer1);
        governor.requestRework(proposalId);

        vm.prank(vetoer2);
        governor.requestRework(proposalId);

        // Check rework signal
        (, uint256 reworkWeight,,,,uint256 totalReworkSignal) = governor.getDissentBreakdown(proposalId);
        // 30% * 0.5x = 15%
        assertEq(reworkWeight, 1500);

        // 3. Resolve to rework state
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(proposalId);

        (,,,,,, ICOGGovernor.ProposalState state, uint256 reworkAttempts,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.REWORK));
        assertEq(reworkAttempts, 0);

        // 4. Proposer submits reworked proposal with lower ask
        vm.prank(proposer);
        governor.submitRework(proposalId, 1000, "Reduced request"); // Now 10%

        // Verify state reset
        uint256 treasuryImpact;
        (,treasuryImpact,,,,,state, reworkAttempts,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.ACTIVE));
        assertEq(treasuryImpact, 1000);
        assertEq(reworkAttempts, 1);

        // 5. Resolve again - should pass with lower ask
        vm.warp(block.timestamp + 14 days + 2);

        uint256 recipientBefore = usdc.balanceOf(recipient);
        governor.resolve(proposalId);

        (,,,,,, state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));

        // 10% of remaining treasury
        uint256 treasuryBalance = usdc.balanceOf(address(treasury));
        assertGt(usdc.balanceOf(recipient), recipientBefore);
    }

    // ============ Full Lifecycle: Proposal → Redemption Dissent → Fail ============

    function test_Lifecycle_ProposalFailsFromRedemptions() public {
        // 1. Proposer creates proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(3000, recipient, "Big ask"); // 30%

        // 2. Holders express dissent through redemption
        // Full redemption has 4x weight, so needs fewer holders

        // smallHolder redeems all (45% of supply * 4x = 180% weight = 18000 bps)
        vm.prank(smallHolder);
        treasury.redeemAll();

        // Check dissent
        (,, uint256 partialWeight, uint256 fullWeight, uint256 totalDissent,) = governor.getDissentBreakdown(proposalId);
        assertEq(fullWeight, 18000); // 45% * 4.0x
        assertEq(totalDissent, 18000);

        // 3. Resolve
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(proposalId);

        // 4. Verify failed
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.FAILED));
    }

    // ============ Complex Scenario: Mixed Dissent Actions ============

    function test_Lifecycle_MixedDissentActions() public {
        // 1. Create proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(2000, recipient, "Test");

        // 2. Various dissent actions
        // Vetoer1 vetoes (15% * 1x = 1500)
        vm.prank(vetoer1);
        governor.veto(proposalId);

        // Vetoer2 requests rework (15% * 0.5x = 750)
        vm.prank(vetoer2);
        governor.requestRework(proposalId);

        // Small holder partially redeems (22.5% * 2x = 4500)
        vm.prank(smallHolder);
        treasury.redeem(2250e18); // Half their tokens

        // Check breakdown
        (
            uint256 vetoWeight,
            uint256 reworkWeight,
            uint256 partialRedeemWeight,
            uint256 fullRedeemWeight,
            uint256 totalFailDissent,
            uint256 totalReworkSignal
        ) = governor.getDissentBreakdown(proposalId);

        assertEq(vetoWeight, 1500);
        assertEq(reworkWeight, 750);
        assertEq(partialRedeemWeight, 4500);
        assertEq(fullRedeemWeight, 0);
        assertEq(totalFailDissent, 6000); // veto + partial = 1500 + 4500
        assertEq(totalReworkSignal, 750 + 750); // rework + veto/2

        // 3. Resolve - should fail given high dissent
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(proposalId);

        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.FAILED));
    }

    // ============ Delegation Integration ============

    function test_Lifecycle_DelegationWorkflow() public {
        // 1. Setup delegation
        // Small holder delegates to delegate1
        vm.prank(smallHolder);
        token.delegate(delegate1);

        // Verify delegation
        assertEq(token.delegatedPower(delegate1), 4500e18);
        assertEq(token.getEffectiveVotingPower(delegate1), 5000e18); // own + delegated

        // 2. Create proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(1000, recipient, "Test");

        // 3. Delegate votes on behalf of delegators
        vm.prank(delegate1);
        governor.delegateVeto(proposalId);

        // 4. Verify vote weight
        (uint256 vetoWeight,,,,, ) = governor.getDissentBreakdown(proposalId);
        // smallHolder: 45% * 1x = 4500
        assertEq(vetoWeight, 4500);

        // 5. Small holder cannot vote again (already marked via delegation)
        vm.prank(smallHolder);
        vm.expectRevert(COGGovernor.AlreadyActed.selector);
        governor.veto(proposalId);
    }

    // ============ Treasury NAV Changes During Proposal ============

    function test_Lifecycle_NAVChanges() public {
        // Initial NAV: 10000 USDC / 10000 tokens = 1:1
        assertEq(treasury.nav(), 1e18);

        // 1. Create proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(1000, recipient, "Test");

        // 2. Small redemption during proposal (not enough to fail)
        // Partial redemption counts as 2x weight
        // 200 tokens = 2% * 2x = 4% weight < 13% threshold
        vm.prank(vetoer1);
        treasury.redeem(200e18);

        // NAV should be slightly higher due to haircut
        uint256 navAfter = treasury.nav();
        assertGt(navAfter, 1e18); // Slightly higher due to haircut

        // 3. Pass proposal
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(proposalId);

        // 4. Verify passed and funds transferred
        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));

        // Treasury transfer should have happened
        uint256 transferred = usdc.balanceOf(recipient);
        assertGt(transferred, 0);
    }

    // ============ Delegate Registry Integration ============

    function test_Lifecycle_DelegateRegistryWorkflow() public {
        // 1. Delegate registers
        vm.prank(delegate1);
        registry.register("Trusty Delegate", "Experienced voter", "Conservative approach");

        // Verify registration
        (string memory name,,,,,, bool isActive) = registry.getProfile(delegate1);
        assertEq(name, "Trusty Delegate");
        assertTrue(isActive);

        // 2. Get all delegates
        address[] memory delegates = registry.getActiveDelegates();
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate1);

        // 3. Update profile
        vm.prank(delegate1);
        registry.updateProfile("Updated Name", "New description", "Aggressive approach");

        (name,,,,,, isActive) = registry.getProfile(delegate1);
        assertEq(name, "Updated Name");

        // 4. Deactivate
        vm.prank(delegate1);
        registry.deactivate();

        delegates = registry.getActiveDelegates();
        assertEq(delegates.length, 0);

        // 5. Reactivate
        vm.prank(delegate1);
        registry.reactivate();

        delegates = registry.getActiveDelegates();
        assertEq(delegates.length, 1);
    }

    // ============ Edge Case: Proposal Just Under Threshold ============

    function test_Lifecycle_ProposalJustUnderThreshold() public {
        // Create proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(1000, recipient, "Test");

        uint256 threshold = governor.calculateThreshold(proposalId);
        // Threshold should be ~1300 (13%)
        assertEq(threshold, 1300);

        // Get just under threshold
        // delegate1 (5%) vetoes - well under 13% threshold
        vm.prank(delegate1);
        governor.veto(proposalId);

        (,,,, uint256 totalDissent,) = governor.getDissentBreakdown(proposalId);
        assertLt(totalDissent, threshold);
        assertEq(totalDissent, 500); // 5% * 1.0x = 500

        // Resolve - should pass
        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(proposalId);

        (,,,,,, ICOGGovernor.ProposalState state,,) = governor.getProposal(proposalId);
        assertEq(uint256(state), uint256(ICOGGovernor.ProposalState.PASSED));
    }

    // ============ Edge Case: Multiple Sequential Proposals ============

    function test_Lifecycle_SequentialProposals() public {
        // First proposal
        vm.prank(proposer);
        governor.propose(1000, recipient, "First");

        vm.warp(block.timestamp + 7 days + 1);
        governor.resolve(1);

        // Try second proposal - proposer in cooldown
        vm.prank(proposer);
        vm.expectRevert(COGGovernor.CooldownNotElapsed.selector);
        governor.propose(1000, recipient, "Second");

        // Different proposer can propose
        vm.prank(vetoer1);
        token.approve(address(governor), type(uint256).max);
        vm.prank(vetoer1);
        uint256 secondId = governor.propose(500, recipient, "Second by vetoer1");

        assertEq(secondId, 2);

        // Resolve second
        vm.warp(block.timestamp + 14 days + 2);
        governor.resolve(2);

        // Wait for original proposer cooldown
        vm.warp(block.timestamp + 28 days);

        // Original proposer can now propose again
        vm.prank(proposer);
        uint256 thirdId = governor.propose(500, recipient, "Third");
        assertEq(thirdId, 3);
    }
}
