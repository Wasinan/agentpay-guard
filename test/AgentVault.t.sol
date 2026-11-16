// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice Test suite for AgentVault. Every guardrail the contract promises
///         is exercised: caps, expiry, allowlist, revocation, caller
///         restriction, and owner-only withdrawal.
contract AgentVaultTest is Test {
    AgentVault internal vault;
    MockTUSD8 internal token;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    uint256 internal constant ONE = 1_000_000; // 1 tUSD8 in 6-decimal units
    uint256 internal constant SESSION_CAP = 500 * ONE;
    uint256 internal constant PER_TX_CAP = 200 * ONE;

    uint256 internal sessionId;

    function setUp() public {
        vm.startPrank(owner);
        token = new MockTUSD8();
        vault = new AgentVault(address(token));

        // Fund the owner, approve the vault, deposit 1,000 tUSD8.
        token.mint(owner, 1_000 * ONE);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000 * ONE);

        // Grant the agent a session: 500 total, 200 per payment, 1 day.
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        sessionId = vault.createSession(agent, SESSION_CAP, PER_TX_CAP, block.timestamp + 1 days, recipients);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------

    function testPaymentWithinGuardrails() public {
        vm.prank(agent);
        vault.executePayment(sessionId, alice, 150 * ONE, "INV-001 design work");

        assertEq(token.balanceOf(alice), 150 * ONE);
        assertEq(vault.vaultBalance(), 850 * ONE);
        assertEq(vault.remainingCap(sessionId), 350 * ONE);
    }

    function testMultiplePaymentsAccumulateSpent() public {
        vm.startPrank(agent);
        vault.executePayment(sessionId, alice, 200 * ONE, "INV-001");
        vault.executePayment(sessionId, bob, 200 * ONE, "INV-002");
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 200 * ONE);
        assertEq(token.balanceOf(bob), 200 * ONE);
        assertEq(vault.remainingCap(sessionId), 100 * ONE);
    }

    function testPaymentAtExactCapsSucceeds() public {
        // Exactly the per-tx cap, then exactly the remaining total cap.
        vm.startPrank(agent);
        vault.executePayment(sessionId, alice, 200 * ONE, "INV-001");
        vault.executePayment(sessionId, alice, 200 * ONE, "INV-002");
        vault.executePayment(sessionId, bob, 100 * ONE, "INV-003");
        vm.stopPrank();

        assertEq(vault.remainingCap(sessionId), 0);
    }

    // ------------------------------------------------------------------
    // Guardrail rejections
    // ------------------------------------------------------------------

    function testRejectsPaymentAbovePerTxCap() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, 201 * ONE, PER_TX_CAP));
        vault.executePayment(sessionId, alice, 201 * ONE, "too big");
    }

    function testRejectsPaymentAboveTotalCap() public {
        vm.startPrank(agent);
        vault.executePayment(sessionId, alice, 200 * ONE, "INV-001");
        vault.executePayment(sessionId, bob, 200 * ONE, "INV-002");
        // Only 100 left of the 500 cap; 101 must revert.
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsSessionCap.selector, 101 * ONE, 100 * ONE));
        vault.executePayment(sessionId, alice, 101 * ONE, "over cap");
        vm.stopPrank();
    }

    function testRejectsPaymentAfterExpiry() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agent);
        vm.expectRevert(AgentVault.SessionExpired.selector);
        vault.executePayment(sessionId, alice, 10 * ONE, "too late");
        assertEq(vault.remainingCap(sessionId), 0);
    }

    function testRejectsPaymentToNonAllowlistedRecipient() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, mallory));
        vault.executePayment(sessionId, mallory, 10 * ONE, "not allowed");
    }

    function testRejectsPaymentAfterRevocation() public {
        vm.prank(owner);
        vault.revokeSession(sessionId);

        vm.prank(agent);
        vm.expectRevert(AgentVault.SessionIsRevoked.selector);
        vault.executePayment(sessionId, alice, 10 * ONE, "revoked");
        assertEq(vault.remainingCap(sessionId), 0);
    }

    function testRejectsPaymentFromNonAgent() public {
        vm.prank(mallory);
        vm.expectRevert(AgentVault.NotSessionAgent.selector);
        vault.executePayment(sessionId, alice, 10 * ONE, "impostor");
    }

    function testRejectsPaymentFromOwnerActingAsAgent() public {
        // Even the owner cannot pay *through* a session; sessions bind
        // exactly one agent address. The owner withdraws instead.
        vm.prank(owner);
        vm.expectRevert(AgentVault.NotSessionAgent.selector);
        vault.executePayment(sessionId, alice, 10 * ONE, "owner is not the agent");
    }

    function testRejectsPaymentAboveVaultBalance() public {
        // Drain most of the vault, leaving less than the payment.
        vm.prank(owner);
        vault.withdraw(950 * ONE);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.InsufficientVaultBalance.selector, 100 * ONE, 50 * ONE));
        vault.executePayment(sessionId, alice, 100 * ONE, "vault too low");
    }

    function testRejectsUnknownSession() public {
        vm.prank(agent);
        vm.expectRevert(AgentVault.SessionNotFound.selector);
        vault.executePayment(99, alice, 10 * ONE, "no such session");
    }

    // ------------------------------------------------------------------
    // Session creation validation
    // ------------------------------------------------------------------

    function testRejectsSessionWithPastExpiry() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        vm.prank(owner);
        vm.expectRevert(AgentVault.InvalidExpiry.selector);
        vault.createSession(agent, 100 * ONE, 50 * ONE, block.timestamp, recipients);
    }

    function testRejectsSessionWithEmptyAllowlist() public {
        address[] memory recipients = new address[](0);
        vm.prank(owner);
        vm.expectRevert(AgentVault.EmptyAllowlist.selector);
        vault.createSession(agent, 100 * ONE, 50 * ONE, block.timestamp + 1 days, recipients);
    }

    function testRejectsSessionWithPerTxCapAboveCap() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        vm.prank(owner);
        vm.expectRevert(AgentVault.InvalidCap.selector);
        vault.createSession(agent, 100 * ONE, 101 * ONE, block.timestamp + 1 days, recipients);
    }

    function testRejectsSessionCreationByNonOwner() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        vm.prank(mallory);
        vm.expectRevert(AgentVault.NotOwner.selector);
        vault.createSession(agent, 100 * ONE, 50 * ONE, block.timestamp + 1 days, recipients);
    }

    // ------------------------------------------------------------------
    // Owner controls
    // ------------------------------------------------------------------

    function testOwnerCanWithdrawRemainingFunds() public {
        vm.prank(agent);
        vault.executePayment(sessionId, alice, 150 * ONE, "INV-001");

        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(850 * ONE);

        assertEq(token.balanceOf(owner), before + 850 * ONE);
        assertEq(vault.vaultBalance(), 0);
    }

    function testNonOwnerCannotWithdraw() public {
        vm.prank(mallory);
        vm.expectRevert(AgentVault.NotOwner.selector);
        vault.withdraw(1 * ONE);
    }

    function testNonOwnerCannotRevoke() public {
        vm.prank(mallory);
        vm.expectRevert(AgentVault.NotOwner.selector);
        vault.revokeSession(sessionId);
    }

    function testAnyoneCanFundTheVault() public {
        token.mint(mallory, 50 * ONE);
        vm.startPrank(mallory);
        token.approve(address(vault), 50 * ONE);
        vault.deposit(50 * ONE);
        vm.stopPrank();
        assertEq(vault.vaultBalance(), 1_050 * ONE);
    }

    // ------------------------------------------------------------------
    // Views and audit events
    // ------------------------------------------------------------------

    function testGetSessionReturnsFullDetails() public view {
        (
            address agent_,
            uint256 cap,
            uint256 perTxCap,
            uint256 expiry,
            uint256 spent,
            bool revoked,
            address[] memory recipients
        ) = vault.getSession(sessionId);

        assertEq(agent_, agent);
        assertEq(cap, SESSION_CAP);
        assertEq(perTxCap, PER_TX_CAP);
        assertEq(spent, 0);
        assertFalse(revoked);
        assertEq(recipients.length, 2);
        assertEq(recipients[0], alice);
        assertEq(recipients[1], bob);
        assertGt(expiry, block.timestamp);
    }

    function testAllowlistView() public view {
        assertTrue(vault.isRecipientAllowed(sessionId, alice));
        assertTrue(vault.isRecipientAllowed(sessionId, bob));
        assertFalse(vault.isRecipientAllowed(sessionId, mallory));
    }

    function testPaymentEmitsAuditEvent() public {
        vm.expectEmit(true, true, true, true);
        emit AgentVault.PaymentExecuted(sessionId, agent, alice, 150 * ONE, "INV-001 design work", 150 * ONE);
        vm.prank(agent);
        vault.executePayment(sessionId, alice, 150 * ONE, "INV-001 design work");
    }
}
