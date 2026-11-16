// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentVault} from "../src/AgentVault.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Fund the deployed AgentVault on Aevum and create the demo session.
///         Run with the OWNER (deployer) keystore:
///           forge script script/FundAndSession.s.sol \
///             --rpc-url https://rpc-test.qday.info \
///             --keystore <owner-keystore> --password-file <pw-file> \
///             --sender <owner-address> --broadcast
///
///         Amounts are tUSD8 BASE units (6 decimals): 1 tUSD8 = 1_000_000.
///         The faucet drips 1 tUSD8, so the live demo uses small amounts:
///         deposit 0.6 tUSD8, session cap 0.5, per-tx cap 0.2, 24h expiry,
///         allowlist of the three invoice payees (INV-004's payee is
///         deliberately excluded). Pairs with agent/invoices-aevum.json.
///         (Session 0 on the live vault was created with early tiny caps
///         and is unused; this script creates the working session.)
contract FundAndSession is Script {
    address internal constant VAULT = 0xf41aA12e0F4152953e7bAe68a1E562a6CD7967B8;
    address internal constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    address internal constant AGENT = 0x0f4F58B850AFBd1347e3307DdaB4C701b54F6524;

    function run() external {
        address[] memory recipients = new address[](3);
        recipients[0] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Alice
        recipients[1] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // Bob
        recipients[2] = 0x15D34aAF54267db7EE8cd6Fb0802D8c9e47E9F11; // Carol

        vm.startBroadcast();
        IERC20Minimal(TUSD8).approve(VAULT, 600_000);
        AgentVault(VAULT).deposit(600_000);
        uint256 sessionId = AgentVault(VAULT).createSession(
            AGENT, 500_000, 200_000, block.timestamp + 24 hours, recipients
        );
        vm.stopBroadcast();

        console.log("Vault funded: 600000 tUSD8 base units (0.6 tUSD8)");
        console.log("Session id:", sessionId);
        console.log("Agent:", AGENT);
    }
}
