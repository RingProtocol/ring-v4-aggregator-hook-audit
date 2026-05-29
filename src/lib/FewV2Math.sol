// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title FewV2Math
/// @notice Pricing helpers for FewV2 pairs (Uniswap V2 fork with 30bps fee).
/// @dev Identical math to UniswapV2Library.getAmountOut / getAmountIn.
///      `getAmountOut` is the same formula used in Phase E's
///      `contracts/ring-uniswapx-filler/src/lib/FewV2Library.sol`.
///      `getAmountIn` is added here for V4 exact-output support.
library FewV2Math {
    error InsufficientAmount();
    error InsufficientLiquidity();

    /// @notice Output for a given input. Classic V2: amountOut = amountIn * 997 * Rout / (Rin*1000 + amountIn*997)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Input required for a given output. Classic V2: amountIn = (Rin * out * 1000) / ((Rout - out) * 997) + 1
    /// @dev `+1` is the V2-canonical ceil-rounding to prevent under-sourcing the pair.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }
}
