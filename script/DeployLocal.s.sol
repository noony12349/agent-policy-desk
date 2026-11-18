// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AgentPolicyDesk} from "../src/AgentPolicyDesk.sol";
import {MockAgentRegistry} from "../test/mocks/MockAgentRegistry.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

/// @notice Deploys test doubles plus the real desk onto a local chain.
/// @dev Refuses BSC mainnet (56) and BSC testnet (97). Mocks can mint tokens and assign handles.
///      Never point this script at a public network.
contract DeployLocal is Script {
    error RefusingPublicChain(uint256 chainId);

    function run() external returns (AgentPolicyDesk desk) {
        if (block.chainid == 56 || block.chainid == 97) revert RefusingPublicChain(block.chainid);

        vm.startBroadcast();
        MockAgentRegistry registry = new MockAgentRegistry();
        MockUSDT usdt = new MockUSDT();
        desk = new AgentPolicyDesk(address(registry), address(usdt));
        registry.setAgent(msg.sender, "880");
        usdt.mint(msg.sender, 1_000_000 ether);
        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("AGENT_REGISTRY=%s", address(registry));
        console2.log("USDT=%s", address(usdt));
        console2.log("POLICY_DESK=%s", address(desk));
    }
}
