// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Local stand-in for the Agent ID registry. Not a soulbound NFT and not for a public chain.
/// @dev `setAgent` is permissionless so a local demo can register the connected wallet.
///      Production deployment must use the real registry, not this mock.
contract MockAgentRegistry {
    mapping(address owner => uint256 balance) public balanceOf;
    mapping(address owner => string handle) public handleOf;

    error ZeroAddress();

    function setAgent(address account, string calldata handle) external {
        if (account == address(0)) revert ZeroAddress();
        balanceOf[account] = 1;
        handleOf[account] = handle;
    }

    function revoke(address account) external {
        balanceOf[account] = 0;
        handleOf[account] = "";
    }
}
