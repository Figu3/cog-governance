// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {COGToken} from "../src/COGToken.sol";

contract COGTokenTest is Test {
    COGToken public token;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public treasury = address(0x4);

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    function setUp() public {
        token = new COGToken("COG Token", "COG");
        token.mint(alice, 1000e18);
        token.mint(bob, 500e18);
        token.mint(charlie, 500e18);
        token.setTreasury(treasury);
    }

    // ============ Basic ERC20 Tests ============

    function test_Name() public view {
        assertEq(token.name(), "COG Token");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "COG");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_TotalSupply() public view {
        assertEq(token.totalSupply(), 2000e18);
    }

    function test_BalanceOf() public view {
        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 500e18);
    }

    function test_Transfer() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(bob), 600e18);
    }

    // ============ Delegation Tests ============

    function test_Delegate() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit DelegateChanged(alice, address(0), bob);
        token.delegate(bob);

        assertEq(token.delegates(alice), bob);
        assertEq(token.delegatedPower(bob), 1000e18);
    }

    function test_Delegate_MultipleDelegators() public {
        vm.prank(alice);
        token.delegate(charlie);

        vm.prank(bob);
        token.delegate(charlie);

        assertEq(token.delegatedPower(charlie), 1500e18);
        assertEq(token.getEffectiveVotingPower(charlie), 2000e18); // 500 own + 1500 delegated
    }

    function test_Delegate_RevertSelfDelegation() public {
        vm.prank(alice);
        vm.expectRevert(COGToken.SelfDelegationNotAllowed.selector);
        token.delegate(alice);
    }

    function test_Delegate_RevertAlreadyDelegated() public {
        vm.prank(alice);
        token.delegate(bob);

        vm.prank(alice);
        vm.expectRevert(COGToken.AlreadyDelegatedToThisAddress.selector);
        token.delegate(bob);
    }

    function test_Undelegate() public {
        vm.prank(alice);
        token.delegate(bob);

        assertEq(token.delegatedPower(bob), 1000e18);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit DelegateChanged(alice, bob, address(0));
        token.undelegate();

        assertEq(token.delegates(alice), address(0));
        assertEq(token.delegatedPower(bob), 0);
    }

    function test_Undelegate_RevertNotDelegated() public {
        vm.prank(alice);
        vm.expectRevert(COGToken.NotDelegated.selector);
        token.undelegate();
    }

    function test_DelegateToZero_ActsAsUndelegate() public {
        vm.prank(alice);
        token.delegate(bob);

        vm.prank(alice);
        token.delegate(address(0));

        assertEq(token.delegates(alice), address(0));
        assertEq(token.delegatedPower(bob), 0);
    }

    function test_ChangeDelegation() public {
        vm.prank(alice);
        token.delegate(bob);

        assertEq(token.delegatedPower(bob), 1000e18);
        assertEq(token.delegatedPower(charlie), 0);

        vm.prank(alice);
        token.delegate(charlie);

        assertEq(token.delegatedPower(bob), 0);
        assertEq(token.delegatedPower(charlie), 1000e18);
    }

    // ============ Delegation Power Updates on Transfer ============

    function test_Transfer_UpdatesDelegatedPower() public {
        vm.prank(alice);
        token.delegate(charlie);

        assertEq(token.delegatedPower(charlie), 1000e18);

        // Alice transfers half to bob
        vm.prank(alice);
        token.transfer(bob, 500e18);

        assertEq(token.delegatedPower(charlie), 500e18);
    }

    function test_Transfer_FromDelegatorToAnotherDelegator() public {
        vm.prank(alice);
        token.delegate(charlie);

        vm.prank(bob);
        token.delegate(charlie);

        assertEq(token.delegatedPower(charlie), 1500e18);

        // Alice transfers to bob (both delegated to charlie)
        vm.prank(alice);
        token.transfer(bob, 500e18);

        // Delegated power should remain the same
        assertEq(token.delegatedPower(charlie), 1500e18);
    }

    // ============ Effective Voting Power Tests ============

    function test_EffectiveVotingPower_NoDelegation() public view {
        assertEq(token.getEffectiveVotingPower(alice), 1000e18);
    }

    function test_EffectiveVotingPower_WithDelegation() public {
        vm.prank(alice);
        token.delegate(bob);

        // Alice has delegated, so her effective power is 0 (only delegated power counts)
        assertEq(token.getEffectiveVotingPower(alice), 0);
        // Bob has his own 500 + 1000 delegated = 1500
        assertEq(token.getEffectiveVotingPower(bob), 1500e18);
    }

    function test_EffectiveVotingPower_AsDelegate() public {
        vm.prank(alice);
        token.delegate(bob);

        vm.prank(charlie);
        token.delegate(bob);

        // Bob has 500 own + 1500 delegated
        assertEq(token.getEffectiveVotingPower(bob), 2000e18);
    }

    // ============ Delegator Tracking Tests ============

    function test_GetDelegators() public {
        vm.prank(alice);
        token.delegate(charlie);

        vm.prank(bob);
        token.delegate(charlie);

        address[] memory delegators = token.getDelegators(charlie);
        assertEq(delegators.length, 2);
        assertEq(delegators[0], alice);
        assertEq(delegators[1], bob);
    }

    function test_IsDelegatorOf() public {
        vm.prank(alice);
        token.delegate(charlie);

        assertTrue(token.isDelegatorOf(charlie, alice));
        assertFalse(token.isDelegatorOf(charlie, bob));
    }

    function test_RemoveDelegator_UpdatesDelegatorList() public {
        vm.prank(alice);
        token.delegate(charlie);

        vm.prank(bob);
        token.delegate(charlie);

        // Bob undelegates
        vm.prank(bob);
        token.undelegate();

        address[] memory delegators = token.getDelegators(charlie);
        assertEq(delegators.length, 1);
        assertEq(delegators[0], alice);
        assertFalse(token.isDelegatorOf(charlie, bob));
    }

    // ============ Treasury Tests ============

    function test_SetTreasury_RevertAlreadySet() public {
        vm.expectRevert(COGToken.TreasuryAlreadySet.selector);
        token.setTreasury(address(0x5));
    }

    function test_BurnFrom_TreasuryNeedsNoAllowance() public {
        vm.prank(treasury);
        token.burnFrom(alice, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_BurnFrom_NonTreasuryNeedsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.prank(bob);
        token.burnFrom(alice, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_BurnFrom_NonTreasuryRevertWithoutAllowance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 100e18);
    }

    // ============ Access Control Tests ============

    function test_Mint_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100e18);
    }

    function test_SetTreasury_OnlyOwner() public {
        COGToken newToken = new COGToken("New", "NEW");

        vm.prank(alice);
        vm.expectRevert();
        newToken.setTreasury(treasury);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Delegate(address delegator, address delegatee) public {
        vm.assume(delegator != address(0) && delegatee != address(0));
        vm.assume(delegator != delegatee);
        vm.assume(delegator != address(this));
        // Exclude setup addresses to avoid interference with existing balances/delegations
        vm.assume(delegator != alice && delegator != bob && delegator != charlie && delegator != treasury);
        vm.assume(delegatee != alice && delegatee != bob && delegatee != charlie && delegatee != treasury);

        // Record delegatee's power before delegation
        uint256 powerBefore = token.delegatedPower(delegatee);

        token.mint(delegator, 100e18);

        vm.prank(delegator);
        token.delegate(delegatee);

        assertEq(token.delegates(delegator), delegatee);
        // Check that delegated power INCREASED by 100e18 (not equals 100e18)
        assertEq(token.delegatedPower(delegatee), powerBefore + 100e18);
    }

    function testFuzz_Transfer_UpdatesDelegatedPower(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        vm.prank(alice);
        token.delegate(charlie);

        uint256 powerBefore = token.delegatedPower(charlie);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 powerAfter = token.delegatedPower(charlie);
        assertEq(powerAfter, powerBefore - amount);
    }
}
