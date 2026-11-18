// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @notice Return-value handling for ERC-20 tokens, including tokens that return no data.
/// @dev Empty calldata success is accepted only when the token address has code.
///      A `false` return or a revert bubbles as `TransferFailed` (or the token's own error).
library SafeToken {
    error TransferFailed();

    function safeTransfer(IERC20Minimal token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
    }

    function safeTransferFrom(IERC20Minimal token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
    }

    function _call(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        if (!success) {
            _bubble(returndata);
        }
        if (returndata.length == 0) {
            if (token.code.length == 0) revert TransferFailed();
            return;
        }
        if (returndata.length < 32 || !abi.decode(returndata, (bool))) {
            revert TransferFailed();
        }
    }

    function _bubble(bytes memory returndata) private pure {
        if (returndata.length == 0) revert TransferFailed();
        assembly {
            revert(add(returndata, 32), mload(returndata))
        }
    }
}
