// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice LOCAL ONLY: deploy MockTUSD8 + AgentVault to a local anvil chain
///         and fund the deployer with mock tUSD8.
///
///         Usage:
///           anvil &  # in a separate terminal
///           forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
///         Deployed addresses are printed and also recorded in
///         broadcast/DeployLocal.s.sol/31337/run-latest.json, which the
///         demo agent reads for its config. Never point this script at
///         Aevum: the mock token must never leave a local chain.
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        MockTUSD8 token = new MockTUSD8();
        AgentVault vault = new AgentVault(address(token));

        // Fund the deployer with 10,000 mock tUSD8 for demo purposes.
        token.mint(msg.sender, 10_000 * 1e6);

        vm.stopBroadcast();

        console.log("MockTUSD8 deployed:", address(token));
        console.log("AgentVault deployed:", address(vault));
        console.log("Deployer funded with 10000 mock tUSD8");
    }
}
