// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title DeltaResolver (minimal, inlined)
/// @notice Helper for hooks that need to take input from / settle output back to PoolManager.
/// @dev Audit-equivalent to the take/settle pattern in
///      https://github.com/Uniswap/v4-periphery/blob/main/src/base/DeltaResolver.sol .
///      The inheriting contract supplies the actual transfer in `_pay` and exposes the
///      PoolManager via `_poolManager()`.
abstract contract DeltaResolver {
    using CurrencyLibrary for Currency;

    /// @notice Take `amount` of `currency` from PoolManager to `recipient`.
    /// @dev PoolManager records a credit to the hook's transient ledger that must be settled.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        _poolManager().take(currency, recipient, amount);
    }

    /// @notice Settle `amount` of `currency` to PoolManager.
    ///         For native ETH: forwards `amount` as msg.value.
    ///         For ERC20: sync → _pay → settle (canonical order).
    function _settle(Currency currency, address payer, uint256 amount) internal {
        IPoolManager pm = _poolManager();
        if (currency.isAddressZero()) {
            pm.settle{value: amount}();
        } else {
            pm.sync(currency);
            _pay(currency, payer, amount);
            pm.settle();
        }
    }

    /// @notice Implementing contract performs the ERC20 transfer to PoolManager.
    /// @param currency Token being settled (never address(0) here).
    /// @param payer    Who pays — usually `address(this)`.
    /// @param amount   How much.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice Implementing contract returns the PoolManager (typically an immutable from BaseHook).
    function _poolManager() internal view virtual returns (IPoolManager);
}
