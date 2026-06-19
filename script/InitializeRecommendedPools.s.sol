// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RingAggregatorHook} from "../src/RingAggregatorHook.sol";
import {ISwapV2Pair} from "../src/interfaces/external/IFewV2.sol";

/// @notice Initializes the recommended Ethereum mainnet Ring hook pools.
/// @dev    These pools do not hold v4 liquidity. Swaps route through the hook
///         into existing direct FewV2 pairs. Low-liquidity dust pairs are
///         intentionally excluded to avoid routing noise.
///
/// Required:
///   HOOK_ADDRESS=0x...
///
/// Optional:
///   V4_POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
///   FEW_FACTORY=0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD
///   FEW_V2_FACTORY=0xeb2A625B704d73e82946D8d026E1F588Eed06416
///   WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
///   INCLUDE_USDR=true
contract InitializeRecommendedPools is Script {
    using PoolIdLibrary for PoolKey;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant FEW_V2_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;

    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDR = 0x4EA40dcee961675683e0a2e1721Bd49CB9bca913;

    uint160 constant INIT_PRICE = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant MIN_PAIR_RESERVE = 1000;

    struct PoolSpec {
        string label;
        address tokenA;
        address tokenB;
        bool isUsdrPool;
    }

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", FEW_V2_FACTORY_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        bool includeUsdr = vm.envOr("INCLUDE_USDR", true);

        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        require(poolManager.code.length > 0, "V4_POOL_MANAGER has no code");

        RingAggregatorHook deployed = RingAggregatorHook(payable(hook));
        require(address(deployed.poolManager()) == poolManager, "poolManager mismatch");
        require(address(deployed.fewFactory()) == fewFactory, "fewFactory mismatch");
        require(address(deployed.fewV2Factory()) == fewV2Factory, "fewV2Factory mismatch");
        require(address(deployed.weth()) == weth, "weth mismatch");

        console2.log("=== Ring recommended pool init ===");
        console2.log("Pool manager:", poolManager);
        console2.log("Hook:        ", hook);
        console2.log("INCLUDE_USDR:", includeUsdr);

        PoolSpec[8] memory specs = [
            PoolSpec({label: "ETH/USDC", tokenA: address(0), tokenB: USDC, isUsdrPool: false}),
            PoolSpec({label: "ETH/USDT", tokenA: address(0), tokenB: USDT, isUsdrPool: false}),
            PoolSpec({label: "ETH/DAI", tokenA: address(0), tokenB: DAI, isUsdrPool: false}),
            PoolSpec({label: "ETH/WBTC", tokenA: address(0), tokenB: WBTC, isUsdrPool: false}),
            PoolSpec({label: "WBTC/USDC", tokenA: WBTC, tokenB: USDC, isUsdrPool: false}),
            PoolSpec({label: "WBTC/USDT", tokenA: WBTC, tokenB: USDT, isUsdrPool: false}),
            PoolSpec({label: "WBTC/DAI", tokenA: WBTC, tokenB: DAI, isUsdrPool: false}),
            PoolSpec({label: "ETH/USDR", tokenA: address(0), tokenB: USDR, isUsdrPool: true})
        ];

        vm.startBroadcast();
        for (uint256 i = 0; i < specs.length; i++) {
            if (specs[i].isUsdrPool && !includeUsdr) {
                console2.log("skip", specs[i].label, "(INCLUDE_USDR=false)");
                continue;
            }
            _initializeIfNeeded(deployed, IPoolManager(poolManager), IHooks(hook), specs[i]);
        }
        vm.stopBroadcast();
    }

    function _initializeIfNeeded(
        RingAggregatorHook deployed,
        IPoolManager poolManager,
        IHooks hook,
        PoolSpec memory spec
    ) internal {
        (address currency0, address currency1) = _sortCurrencies(spec.tokenA, spec.tokenB);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        PoolId poolId = key.toId();
        (address few0, address few1, address pair) = deployed.defaultRouteFor(key);
        require(few0 != address(0), "fewToken0 missing");
        require(few1 != address(0), "fewToken1 missing");
        require(pair != address(0), "FewV2 pair missing");

        (uint256 reserve0, uint256 reserve1) = _routeReserves(pair, few0, few1);
        require(reserve0 > MIN_PAIR_RESERVE && reserve1 > MIN_PAIR_RESERVE, "FewV2 pair too thin");

        (uint160 beforeSqrtPriceX96, int24 beforeTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        console2.log("");
        console2.log("Pool:", spec.label);
        console2.log("currency0:", currency0);
        console2.log("currency1:", currency1);
        console2.log("few0:     ", few0);
        console2.log("few1:     ", few1);
        console2.log("pair:     ", pair);
        console2.log("reserve0: ", reserve0);
        console2.log("reserve1: ", reserve1);
        console2.logBytes32(PoolId.unwrap(poolId));

        if (beforeSqrtPriceX96 != 0) {
            console2.log("already initialized; skipping");
            console2.log("sqrtPriceX96:", beforeSqrtPriceX96);
            console2.log("tick:        ", beforeTick);
            return;
        }

        int24 tick = poolManager.initialize(key, INIT_PRICE);
        (uint160 afterSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(afterSqrtPriceX96 == INIT_PRICE, "post-init sqrtPrice mismatch");
        console2.log("initialized");
        console2.log("tick:", tick);
    }

    function _sortCurrencies(address tokenA, address tokenB)
        internal
        pure
        returns (address currency0, address currency1)
    {
        require(tokenA != tokenB, "duplicate currencies");
        return uint160(tokenA) < uint160(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _routeReserves(address pair, address few0, address few1)
        internal
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        address pairToken0 = ISwapV2Pair(pair).token0();
        address pairToken1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        if (pairToken0 == few0 && pairToken1 == few1) {
            return (uint256(r0), uint256(r1));
        }
        if (pairToken0 == few1 && pairToken1 == few0) {
            return (uint256(r1), uint256(r0));
        }
        revert("FewV2 pair token mismatch");
    }
}
