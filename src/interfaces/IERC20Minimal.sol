// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice ERC-20 surface AgentPolicyDesk needs. Return values are checked by SafeToken.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
