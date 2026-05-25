// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Ring's FewToken interface — strict 1:1 wrap/unwrap.
/// @dev Mirrors the deployed FewWrappedToken on each Ring chain. Backed by Ring's
///      few-v2-core. wrap/unwrap return the wrapped/unwrapped amount; for non-rebasing
///      ERC20s these equal the input.
interface IFewWrappedToken is IERC20 {
    /// @return The address of the underlying ERC20.
    function token() external view returns (address);

    /// @notice Pulls `amount` of the underlying from caller, mints `amount` fewToken to caller.
    function wrap(uint256 amount) external returns (uint256);

    /// @notice Burns `amount` fewToken from caller, sends `amount` underlying to caller.
    function unwrap(uint256 amount) external returns (uint256);

    /// @notice wrap variant — mints fewToken to a recipient instead of caller.
    function wrapTo(uint256 amount, address to) external returns (uint256);

    /// @notice unwrap variant — sends underlying to a recipient instead of caller.
    function unwrapTo(uint256 amount, address to) external returns (uint256);
}
