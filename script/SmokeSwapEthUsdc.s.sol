// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {RingAggregatorHook} from "../src/RingAggregatorHook.sol";
import {ISwapV2Pair} from "../src/interfaces/external/IFewV2.sol";
import {FewV2Math} from "../src/lib/FewV2Math.sol";

/// @notice Tiny exact-input ETH->USDC smoke swap helper for the deployed hook.
/// @dev    This router is for post-deploy verification only. It exists so the
///         smoke swap has an atomic minOut check while using PoolManager
///         directly.
contract RingV4SmokeSwapRouter {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    struct CallbackData {
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    error OnlyPoolManager();
    error OnlyNativeCurrency0();
    error ZeroInput();
    error InputTooLarge();
    error NoOutput();
    error TooLittleReceived(uint256 actual, uint256 minimum);

    event SmokeSwap(address indexed recipient, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    receive() external payable {}

    function swapExactInputNative(PoolKey memory key, uint256 minAmountOut, bytes calldata hookData)
        external
        payable
        returns (uint256 amountOut)
    {
        if (!key.currency0.isAddressZero()) revert OnlyNativeCurrency0();
        if (msg.value == 0) revert ZeroInput();
        if (msg.value > uint256(type(int256).max)) revert InputTooLarge();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(msg.value), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        BalanceDelta delta = abi.decode(
            manager.unlock(
                abi.encode(CallbackData({recipient: msg.sender, key: key, params: params, hookData: hookData}))
            ),
            (BalanceDelta)
        );

        int128 outDelta = delta.amount1();
        if (outDelta <= 0) revert NoOutput();
        amountOut = uint256(uint128(outDelta));
        if (amountOut < minAmountOut) revert TooLittleReceived(amountOut, minAmountOut);

        uint256 refund = address(this).balance;
        if (refund > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, refund);

        emit SmokeSwap(msg.sender, msg.value, amountOut);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        if (delta.amount0() < 0) {
            data.key.currency0.settle(manager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            data.key.currency1.settle(manager, address(this), uint256(uint128(-delta.amount1())), false);
        }
        if (delta.amount0() > 0) {
            data.key.currency0.take(manager, data.recipient, uint256(uint128(delta.amount0())), false);
        }
        if (delta.amount1() > 0) {
            data.key.currency1.take(manager, data.recipient, uint256(uint128(delta.amount1())), false);
        }

        return abi.encode(delta);
    }
}

/// @notice Quotes and executes a tiny ETH->USDC smoke swap through the deployed hook.
///
/// Required:
///   HOOK_ADDRESS=0x...
///
/// Optional:
///   SMOKE_ETH_IN=100000000000000       (default 0.0001 ETH)
///   SMOKE_MIN_USDC_OUT=...             (default 95% of script's FewV2 quote)
///   SMOKE_ROUTER_ADDRESS=0x...         (reuse an already deployed helper)
contract SmokeSwapEthUsdc is Script {
    using PoolIdLibrary for PoolKey;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant USDC_DEFAULT = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant DEFAULT_SMOKE_ETH_IN = 0.0001 ether;
    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant FEE_DENOM = 10_000;
    uint256 constant PROTOCOL_FEE_BPS = 5;

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address usdc = vm.envOr("USDC", USDC_DEFAULT);
        uint256 amountIn = vm.envOr("SMOKE_ETH_IN", DEFAULT_SMOKE_ETH_IN);
        address routerAddress = vm.envOr("SMOKE_ROUTER_ADDRESS", address(0));

        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        require(poolManager.code.length > 0, "V4_POOL_MANAGER has no code");
        require(amountIn > 0, "SMOKE_ETH_IN is zero");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        require(sqrtPriceX96 != 0, "ETH/USDC hook pool not initialized");

        (uint256 expectedNetOut, address pair) = _quoteExpectedNetOut(hook, key, amountIn);
        uint256 minOut = vm.envOr("SMOKE_MIN_USDC_OUT", (expectedNetOut * 95) / 100);
        require(minOut > 0, "minOut is zero");

        console2.log("=== Ring ETH/USDC smoke swap ===");
        console2.log("Pool manager: ", poolManager);
        console2.log("Hook:         ", hook);
        console2.log("FewV2 pair:   ", pair);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("ETH in:       ", amountIn);
        console2.log("Quoted USDC:  ", expectedNetOut);
        console2.log("Min USDC out: ", minOut);

        vm.startBroadcast();

        RingV4SmokeSwapRouter router;
        if (routerAddress == address(0)) {
            router = new RingV4SmokeSwapRouter(IPoolManager(poolManager));
            routerAddress = address(router);
            console2.log("Smoke router deployed:", routerAddress);
        } else {
            require(routerAddress.code.length > 0, "SMOKE_ROUTER_ADDRESS has no code");
            router = RingV4SmokeSwapRouter(payable(routerAddress));
            require(address(router.manager()) == poolManager, "smoke router manager mismatch");
            console2.log("Smoke router reused:  ", routerAddress);
        }

        uint256 amountOut = router.swapExactInputNative{value: amountIn}(key, minOut, "");

        vm.stopBroadcast();

        console2.log("=== Smoke swap complete ===");
        console2.log("Smoke router: ", routerAddress);
        console2.log("USDC out:     ", amountOut);
    }

    function _quoteExpectedNetOut(address hook, PoolKey memory key, uint256 amountIn)
        internal
        view
        returns (uint256 expectedNetOut, address pair)
    {
        (address fewEth, address fewUsdc, address routePair) = RingAggregatorHook(payable(hook)).defaultRouteFor(key);
        require(fewEth != address(0), "fwETH missing");
        require(fewUsdc != address(0), "fwUSDC missing");
        require(routePair != address(0), "FewV2 ETH/USDC pair missing");

        address token0 = ISwapV2Pair(routePair).token0();
        address token1 = ISwapV2Pair(routePair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(routePair).getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        if (fewEth == token0 && fewUsdc == token1) {
            reserveIn = uint256(r0);
            reserveOut = uint256(r1);
        } else if (fewEth == token1 && fewUsdc == token0) {
            reserveIn = uint256(r1);
            reserveOut = uint256(r0);
        } else {
            revert("FewV2 pair token mismatch");
        }

        uint256 grossOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
        expectedNetOut = grossOut - ((grossOut * PROTOCOL_FEE_BPS) / FEE_DENOM);
        pair = routePair;
    }
}
