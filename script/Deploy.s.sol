// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AgentPolicyDesk} from "../src/AgentPolicyDesk.sol";

/// @notice Deploys the immutable policy desk.
/// @dev Reads AGENT_REGISTRY and USDT from the environment. Refuses every chain except 56
///      so a local anvil or a testnet RPC cannot be broadcast by mistake.
///      The deployer receives no admin role. Do not commit a private key to run this.
contract Deploy is Script {
    error UnexpectedChain(uint256 chainId);

    function run() external returns (AgentPolicyDesk desk) {
        if (block.chainid != 56) revert UnexpectedChain(block.chainid);

        address registry = vm.envAddress("AGENT_REGISTRY");
        address usdt = vm.envAddress("USDT");

        vm.startBroadcast();
        desk = new AgentPolicyDesk(registry, usdt);
        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("AgentPolicyDesk", address(desk));
        console2.log("agentRegistry", registry);
        console2.log("usdt", usdt);
    }
}
