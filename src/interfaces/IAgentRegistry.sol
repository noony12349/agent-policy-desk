// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal SPACE ID Agent ID registry surface used by AgentPolicyDesk.
/// @dev Eligibility is `balanceOf(account) > 0`. `handleOf` is display-only.
///      Handles are soulbound; this interface does not transfer them.
interface IAgentRegistry {
    function balanceOf(address owner) external view returns (uint256);

    function handleOf(address owner) external view returns (string memory);
}
