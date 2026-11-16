// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentVault} from "../src/AgentVault.sol";

/// @notice Deploy AgentVault to QDay Aevum testnet (chain 44005) against the
///         REAL tUSD8 stablecoin. No tokens are minted and no mock is
///         deployed: tUSD8 is already live at the address below.
///
///         The deployer key is NEVER in this repo. Sign with a Foundry
///         keystore account (import the deployer keystore first):
///
///           cast wallet import aevum --keystore <path-to-keystore.json>
///           forge script script/DeployAevum.s.sol \
///             --rpc-url https://rpc-test.qday.info \
///             --account aevum --sender <deployer-address> --broadcast
///
///         The deployer needs tQDAY for gas (faucet: https://faucet.qday.info).
///         After deploying, verify on the explorer and record the address in
///         README.md + web/index.html (VAULT_ADDRESS).
contract DeployAevum is Script {
    /// @dev Real tUSD8 on Aevum testnet: ERC-20, 6 decimals.
    address internal constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external {
        vm.startBroadcast();
        AgentVault vault = new AgentVault(TUSD8);
        vm.stopBroadcast();

        console.log("AgentVault deployed on Aevum:", address(vault));
        console.log("tUSD8:", TUSD8);
        console.log("Owner (deployer):", vault.owner());
    }
}
