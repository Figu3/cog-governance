// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {COGToken} from "../src/COGToken.sol";
import {COGTreasury} from "../src/COGTreasury.sol";
import {COGGovernor} from "../src/COGGovernor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ICOGTreasury} from "../src/interfaces/ICOGTreasury.sol";

contract COGTreasuryTest is Test {
    COGToken public token;
    COGTreasury public treasury;
    COGGovernor public governor;
    MockERC20 public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    event Deposit(address indexed from, uint256 amount);
    event Redemption(address indexed holder, uint256 tokensRedeemed, uint256 stablecoinsOut, ICOGTreasury.RedemptionType redemptionType);

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

        // Mint tokens to users
        token.mint(alice, 1000e18);
        token.mint(bob, 500e18);

        // Fund treasury with 1500 USDC (matching 1500 tokens = 1:1 NAV)
        usdc.mint(address(treasury), 1500e6);

        // Give users some USDC for deposits
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 500e6);
    }

    // ============ NAV Tests ============

    function test_NAV_InitialValue() public view {
        // 1500 USDC / 1500 tokens = 1:1 NAV
        // NAV returns in 18 decimals: 1e18 = 1 stablecoin per token
        assertEq(treasury.nav(), 1e18);
    }

    function test_NAV_AfterDeposit() public {
        // Add more USDC to treasury
        usdc.mint(address(treasury), 1500e6);

        // 3000 USDC / 1500 tokens = 2:1 NAV
        assertEq(treasury.nav(), 2e18);
    }

    function test_NAV_ZeroSupply() public {
        // Deploy fresh treasury with no tokens
        COGToken newToken = new COGToken("New", "NEW");
        COGTreasury newTreasury = new COGTreasury(address(usdc), address(newToken));

        // Default NAV when no supply
        assertEq(newTreasury.nav(), 1e18);
    }

    // ============ Deposit Tests ============

    function test_Deposit() public {
        vm.prank(alice);
        usdc.approve(address(treasury), 100e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Deposit(alice, 100e6);
        treasury.deposit(100e6);

        assertEq(usdc.balanceOf(address(treasury)), 1600e6);
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(COGTreasury.ZeroAmount.selector);
        treasury.deposit(0);
    }

    // ============ Redemption Tests ============

    function test_Redeem_NoActiveProposal() public {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceTokensBefore = token.balanceOf(alice);

        vm.prank(alice);
        treasury.redeem(100e18);

        // No haircut when no active proposal
        // 100 tokens * 1 NAV = 100 USDC
        assertEq(token.balanceOf(alice), aliceTokensBefore - 100e18);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 100e6);
    }

    function test_RedeemAll_NoActiveProposal() public {
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        treasury.redeemAll();

        // Alice redeems all 1000 tokens for 1000 USDC
        assertEq(token.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 1000e6);
    }

    function test_Redeem_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(COGTreasury.ZeroAmount.selector);
        treasury.redeem(0);
    }

    function test_Redeem_RevertInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(COGTreasury.InsufficientBalance.selector);
        treasury.redeem(2000e18);
    }

    function test_RedeemAll_RevertZeroBalance() public {
        vm.prank(charlie); // charlie has no tokens
        vm.expectRevert(COGTreasury.ZeroAmount.selector);
        treasury.redeemAll();
    }

    function test_Redeem_BurnsTokens() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        treasury.redeem(100e18);

        assertEq(token.totalSupply(), supplyBefore - 100e18);
    }

    function test_Redeem_WithActiveProposal_AppliesHaircut() public {
        // Give alice enough tokens to propose (need 1% + some)
        token.mint(alice, 1000e18);

        // Mint matching USDC to treasury to keep 1:1 NAV
        usdc.mint(address(treasury), 1000e6);

        // Alice creates a proposal
        vm.prank(alice);
        token.approve(address(governor), type(uint256).max);

        vm.prank(alice);
        governor.propose(1000, bob, "Test proposal");

        // Verify proposal is active
        assertTrue(governor.activeProposal() > 0);
        assertTrue(treasury.activeProposal());

        // Bob's starting USDC balance
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        // Now bob redeems - should have 2% haircut
        // NAV should be ~1:1 (2500 USDC / 2500 tokens, minus alice's stake)
        vm.prank(bob);
        treasury.redeem(100e18);

        // With 2% haircut, bob should get ~98 USDC (NAV is approximately 1:1)
        uint256 bobReceived = usdc.balanceOf(bob) - bobUsdcBefore;
        // Allow for small variance due to stake being locked
        assertGt(bobReceived, 90e6);
        assertLt(bobReceived, 100e6);

        // Fees accumulated should be around 2% of redemption
        assertGt(treasury.accumulatedFees(), 0);
    }

    function test_Redeem_EmitsCorrectEventType() public {
        // Partial redeem
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Redemption(alice, 100e18, 100e6, ICOGTreasury.RedemptionType.PARTIAL);
        treasury.redeem(100e18);

        // Full redeem
        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit Redemption(bob, 500e18, 500e6, ICOGTreasury.RedemptionType.FULL);
        treasury.redeemAll();
    }

    // ============ Access Control Tests ============

    function test_SetGovernor_RevertAlreadySet() public {
        vm.expectRevert(COGTreasury.GovernorAlreadySet.selector);
        treasury.setGovernor(address(0x5));
    }

    function test_SetGovernor_RevertZeroAddress() public {
        COGTreasury newTreasury = new COGTreasury(address(usdc), address(token));

        vm.expectRevert(COGTreasury.ZeroAddress.selector);
        newTreasury.setGovernor(address(0));
    }

    function test_SetGovernor_OnlyOwner() public {
        COGTreasury newTreasury = new COGTreasury(address(usdc), address(token));

        vm.prank(alice);
        vm.expectRevert();
        newTreasury.setGovernor(address(governor));
    }

    function test_SetRedemptionHaircut_OnlyOwner() public {
        treasury.setRedemptionHaircut(300); // 3%
        assertEq(treasury.redemptionHaircut(), 300);

        vm.prank(alice);
        vm.expectRevert();
        treasury.setRedemptionHaircut(400);
    }

    function test_WithdrawFees_OnlyOwner() public {
        // Create scenario with fees
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(address(governor), type(uint256).max);
        vm.prank(alice);
        governor.propose(1000, bob, "Test");

        vm.prank(bob);
        treasury.redeem(100e18);

        uint256 fees = treasury.accumulatedFees();
        assertTrue(fees > 0);

        vm.prank(alice);
        vm.expectRevert();
        treasury.withdrawFees(alice);

        treasury.withdrawFees(owner);
        assertEq(usdc.balanceOf(owner), fees);
    }

    function test_ExecuteTreasuryTransfer_OnlyGovernor() public {
        vm.prank(alice);
        vm.expectRevert(COGTreasury.OnlyGovernor.selector);
        treasury.executeTreasuryTransfer(alice, 100e6);
    }

    // ============ Constructor Tests ============

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(COGTreasury.ZeroAddress.selector);
        new COGTreasury(address(0), address(token));

        vm.expectRevert(COGTreasury.ZeroAddress.selector);
        new COGTreasury(address(usdc), address(0));
    }

    // ============ Fuzz Tests ============

    function testFuzz_Redeem(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 tokensBefore = token.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 nav = treasury.nav();

        vm.prank(alice);
        treasury.redeem(amount);

        assertEq(token.balanceOf(alice), tokensBefore - amount);

        // Calculate expected USDC (no haircut without active proposal)
        uint256 expectedUsdc = (amount * nav) / (1e18 * 1e12);
        assertEq(usdc.balanceOf(alice), usdcBefore + expectedUsdc);
    }
}
