// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title BaseHook (minimal, inlined)
/// @notice Trimmed-down V4 BaseHook. Audit-equivalent to the canonical
///         https://github.com/Uniswap/v4-periphery/blob/main/src/utils/BaseHook.sol
///         with unused entry points reverting `HookNotImplemented` instead of being
///         left to default-revert. Inlined here so this project does not depend on
///         a specific v4-periphery commit.
abstract contract BaseHook is IHooks {
    error NotPoolManager();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        _validateHookAddress(this);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Verifies the deployment address has the correct permission flag bits.
    ///      Override in test contracts to skip during fuzz/unit tests where
    ///      `vm.etch` is used instead of CREATE2 mining.
    function _validateHookAddress(BaseHook _this) internal pure virtual {
        Hooks.validateHookPermissions(IHooks(address(_this)), getHookPermissions());
    }

    /// @notice The static hook permission set the deployment address must encode.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // ────────── Initialize ──────────
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    // ────────── Add liquidity ──────────
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    // ────────── Remove liquidity ──────────
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    // ────────── Swap ──────────
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    // ────────── Donate ──────────
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
