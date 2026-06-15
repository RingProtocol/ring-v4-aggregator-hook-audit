// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {RingAggregatorHook} from "../../src/RingAggregatorHook.sol";
import {RingUniBurner} from "../../src/RingUniBurner.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}

// ════════════════════════════════════════════════════════════════════════════
// Adversarial test helpers
// ════════════════════════════════════════════════════════════════════════════

/// @dev Force-feeds ETH to a target via selfdestruct. Same-tx selfdestruct still
///      transfers balance to target post-Cancun.
contract SelfDestructAttacker {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Reentrant `receive()` that tries to re-enter `hook.sweep`. nonReentrant must block.
contract ReentrantSweepReceiver {
    RingAggregatorHook public immutable hookContract;

    constructor(address _hook) {
        hookContract = RingAggregatorHook(payable(_hook));
    }

    receive() external payable {
        hookContract.sweep(address(0));
    }
}

/// @dev Test-only subclass that skips BaseHook's address-bit validation, so we can
///      deploy at any address to exercise constructor-body reverts (zero-address checks).
contract HookNoAddressCheck is RingAggregatorHook {
    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        address _feeRecipient,
        address _uniBurner
    ) RingAggregatorHook(_pm, _fewFactory, _fewV2Factory, _weth, _feeRecipient, _uniBurner) {}
    function validateHookAddress(BaseHook) internal pure override {}

    function exposedExactInputAmount(int256 amountSpecified) external pure returns (uint256, int128) {
        return _exactInputAmount(amountSpecified);
    }
}

/// @notice Mainnet fork e2e for RingAggregatorHook (admin-less variant).
///         Coverage scope: core swap correctness, ETH abuse + sweep, mocked-external
///         pair attacks, constructor zero-address checks, fee skim (5 bps -> uniBurner),
///         end-to-end push to mainnet TokenJar. NO owner / pause / route-management
///         tests, since V1 has no such surface.
///         Skipped if `ETH_RPC_URL` is not set.
contract RingAggregatorHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Mainnet addresses
    address constant V4_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant FW_USDS = 0xD777151C92C05fEa839b2c21b345a78e1F1163Fe;
    address constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;
    address constant FEWV2_PAIR = 0x54222F404dcfAc705322045F01D100380b871450;
    /// @notice Mainnet TokenJar (canonical Uniswap fee collector).
    address constant TOKEN_JAR_MAINNET = 0xf38521f130fcCF29dB1961597bc5d2B60F995f85;

    uint256 constant FEE_DENOM = 10_000;
    uint256 constant PROTOCOL_FEE_BPS = 5;
    uint256 constant MIN_PAIR_RESERVE = 1000;
    uint160 constant INIT_PRICE = 79228162514264337593543950336;
    uint24 constant CANONICAL_POOL_FEE = 500;
    int24 constant CANONICAL_TICK_SPACING = 10;

    address constant FEE_RECIPIENT = address(0xFEE);
    address constant USER = address(0xBEEF);
    /// @notice Owner of the RingUniBurner (separate concern from the hook — the hook itself
    ///         has no owner). Used only inside RingUniBurner for emergency-withdraw etc.
    address constant BURNER_OWNER = address(0xCAFE);

    bool forked;
    RingAggregatorHook hook;
    RingUniBurner burner;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyRouter;
    PoolKey ethUsdcKey;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        // 1. Deploy RingUniBurner first (immutable in V1 — must be set at hook construction).
        burner = new RingUniBurner(TOKEN_JAR_MAINNET, FEW_FACTORY, BURNER_OWNER);

        // 2. Mine a salt for the hook permission flags.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory creationCode = type(RingAggregatorHook).creationCode;
        bytes memory ctorArgs = abi.encode(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            FEE_RECIPIENT,
            address(burner)
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, ctorArgs);

        // 3. Deploy the hook using CREATE2 with mined salt.
        hook = new RingAggregatorHook{salt: salt}(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            FEE_RECIPIENT,
            address(burner)
        );
        require(address(hook) == mined, "Hook address mismatch");

        // 4. V4 test helpers.
        swapRouter = new PoolSwapTest(IPoolManager(V4_PM));
        modifyRouter = new PoolModifyLiquidityTest(IPoolManager(V4_PM));

        // 5. Pool key for ETH/USDC.
        ethUsdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // 6. Initialize the pool.
        IPoolManager(V4_PM).initialize(ethUsdcKey, INIT_PRICE);
    }

    modifier requireFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _netAfterFee(uint256 grossFwOut) internal pure returns (uint256) {
        return grossFwOut - (grossFwOut * PROTOCOL_FEE_BPS) / FEE_DENOM;
    }

    function _grossUpForFee(uint256 userOut) internal pure returns (uint256) {
        return (userOut * FEE_DENOM + (FEE_DENOM - PROTOCOL_FEE_BPS) - 1) / (FEE_DENOM - PROTOCOL_FEE_BPS);
    }

    function _v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / ((reserveIn * 1000) + amountInWithFee);
    }

    function _v2AmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return ((reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997)) + 1;
    }

    function _quoteHopExactInput(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        if (pair == address(0) || amountIn == 0) return (false, 0);
        address token0 = ISwapV2Pair(pair).token0();
        address token1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0 && tokenOut == token1) {
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == token1 && tokenOut == token0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            return (false, 0);
        }

        if (reserveIn <= MIN_PAIR_RESERVE || reserveOut <= MIN_PAIR_RESERVE) return (false, 0);
        amountOut = _v2AmountOut(amountIn, reserveIn, reserveOut);
        ok = amountOut != 0;
    }

    function _quoteHopExactOutput(address pair, address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (bool ok, uint256 amountIn)
    {
        if (pair == address(0) || amountOut == 0) return (false, 0);
        address token0 = ISwapV2Pair(pair).token0();
        address token1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0 && tokenOut == token1) {
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == token1 && tokenOut == token0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            return (false, 0);
        }

        if (reserveIn <= MIN_PAIR_RESERVE || reserveOut <= MIN_PAIR_RESERVE || amountOut >= reserveOut) {
            return (false, 0);
        }
        amountIn = _v2AmountIn(amountOut, reserveIn, reserveOut);
        ok = amountIn != 0;
    }

    function _bestDefaultExactInput(address fewIn, address fewOut, uint256 amountIn)
        internal
        view
        returns (uint256 bestGrossOut)
    {
        address pair = ISwapV2Factory(RING_FACTORY).getPair(fewIn, fewOut);
        (bool found, uint256 grossOut) = _quoteHopExactInput(pair, fewIn, fewOut, amountIn);
        require(found, "no direct exact-in route");
        return grossOut;
    }

    function _bestDefaultExactOutput(address fewIn, address fewOut, uint256 grossOut)
        internal
        view
        returns (uint256 bestAmountIn)
    {
        address pair = ISwapV2Factory(RING_FACTORY).getPair(fewIn, fewOut);
        (bool found, uint256 amountIn) = _quoteHopExactOutput(pair, fewIn, fewOut, grossOut);
        require(found, "no direct exact-out route");
        return amountIn;
    }

    // ─────────── Sanity ───────────

    function test_fork_setUpInitializedHookPool() public requireFork {
        assertEq(address(ethUsdcKey.hooks), address(hook));
    }

    function test_fork_defaultRouteResolves() public requireFork {
        (address fewA, address fewB, address pair) = hook.defaultRouteFor(ethUsdcKey);
        assertEq(fewA, FW_ETH, "fewA == fwETH");
        assertEq(fewB, FW_USDC, "fewB == fwUSDC");
        assertEq(pair, FEWV2_PAIR, "pair == real fewV2 pair");
    }

    function test_fork_registeredRouteResolves() public requireFork {
        (address few0, address few1, address pair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(few0, FW_ETH, "registered few0 == fwETH");
        assertEq(few1, FW_USDC, "registered few1 == fwUSDC");
        assertEq(pair, FEWV2_PAIR, "registered pair == real fewV2 pair");
        assertTrue(hook.fewV2PairRegistered(FEWV2_PAIR), "pair registered");
        assertEq(PoolId.unwrap(hook.poolIdForFewV2Pair(FEWV2_PAIR)), PoolId.unwrap(ethUsdcKey.toId()));
    }

    function test_fork_pseudoTotalValueLocked_matchesFewV2Reserves() public requireFork {
        (uint256 tvl0, uint256 tvl1) = hook.pseudoTotalValueLocked(ethUsdcKey.toId());
        address pairToken0 = ISwapV2Pair(FEWV2_PAIR).token0();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();

        uint256 expected0 = pairToken0 == FW_ETH ? uint256(r0) : uint256(r1);
        uint256 expected1 = pairToken0 == FW_USDC ? uint256(r0) : uint256(r1);

        assertEq(tvl0, expected0, "pseudo TVL token0");
        assertEq(tvl1, expected1, "pseudo TVL token1");
        assertGt(tvl0, MIN_PAIR_RESERVE, "nonzero token0 TVL");
        assertGt(tvl1, MIN_PAIR_RESERVE, "nonzero token1 TVL");
    }

    function test_fork_aggregatorQuote_matchesDirectQuote_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedNetOut = _netAfterFee(_bestDefaultExactInput(FW_ETH, FW_USDC, amountIn));

        uint256 quotedAmountOut = hook.quote(true, -int256(amountIn), ethUsdcKey.toId());

        assertEq(quotedAmountOut, expectedNetOut, "aggregator quote exact-in");
    }

    function test_fork_aggregatorQuote_matchesDirectQuote_exactOutput() public requireFork {
        uint256 amountOut = 10_000;
        uint256 expectedIn = _bestDefaultExactOutput(FW_ETH, FW_USDC, _grossUpForFee(amountOut));

        uint256 quotedAmountIn = hook.quote(true, int256(amountOut), ethUsdcKey.toId());

        assertEq(quotedAmountIn, expectedIn, "aggregator quote exact-out");
    }

    function test_fork_aggregatorQuote_unknownPool_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(1), PoolId.wrap(bytes32(uint256(1))));
    }

    function test_fork_emptyHookData_directRoute_matchesDirectQuote_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedNetOut = _netAfterFee(_bestDefaultExactInput(FW_ETH, FW_USDC, amountIn));

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(received, expectedNetOut, "empty hookData used direct route");
    }

    function test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedNetOut = _netAfterFee(_bestDefaultExactInput(FW_ETH, FW_USDC, amountIn));

        (uint256 quotedAmountOut, uint256 gasEstimate) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: ethUsdcKey, zeroForOne: true, exactAmount: uint128(amountIn), hookData: ""
                })
            );
        assertEq(quotedAmountOut, expectedNetOut, "V4Quoter sees direct route");
        assertGt(gasEstimate, 0, "V4Quoter returns gas estimate");

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 actualAmountOut = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(quotedAmountOut, actualAmountOut, "V4Quoter quote matches actual swap");
    }

    function test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactOutput() public requireFork {
        uint256 amountOut = 10_000;
        uint256 expectedIn = _bestDefaultExactOutput(FW_ETH, FW_USDC, _grossUpForFee(amountOut));

        (uint256 quotedAmountIn, uint256 gasEstimate) = IV4Quoter(V4_QUOTER)
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: ethUsdcKey, zeroForOne: true, exactAmount: uint128(amountOut), hookData: ""
                })
            );
        assertEq(quotedAmountIn, expectedIn, "V4Quoter sees direct exact-out route");
        assertGt(gasEstimate, 0, "V4Quoter returns gas estimate");

        vm.deal(USER, quotedAmountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: quotedAmountIn}(ethUsdcKey, params, settings, "");

        uint256 actualAmountOut = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(actualAmountOut, amountOut, "actual swap returns exact output");
        assertEq(uint256(uint128(-delta.amount0())), quotedAmountIn, "V4Quoter quote matches actual input");
    }

    function test_fork_revertsInitWithoutDirectFewV2Pair() public requireFork {
        assertEq(ISwapV2Factory(RING_FACTORY).getPair(FW_ETH, FW_USDS), address(0), "test assumes no direct pair");

        PoolKey memory ethUsdsKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDS),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert();
        IPoolManager(V4_PM).initialize(ethUsdsKey, INIT_PRICE);
    }

    // ─────────── Initialize is rejected for invalid configs ───────────

    function test_fork_revertsInitOnNonCanonicalFee() public requireFork {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(badKey, INIT_PRICE);
    }

    function test_fork_revertsInitOnFewWrapPair() public requireFork {
        // ETH/fwETH would be a 1:1 wrapper pair — beforeInitialize must refuse.
        PoolKey memory wrapKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(FW_ETH),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(wrapKey, INIT_PRICE);
    }

    function test_fork_revertsInitDuplicateFewV2Pair() public requireFork {
        PoolKey memory duplicateKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // BaseHook wraps hook reverts when called through PoolManager.initialize.
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(duplicateKey, INIT_PRICE);
        assertEq(PoolId.unwrap(hook.poolIdForFewV2Pair(FEWV2_PAIR)), PoolId.unwrap(ethUsdcKey.toId()));
    }

    // ─────────── e2e × 4: ExactIn/Out × zeroForOne/oneForZero ───────────

    function test_fork_e2e_ETH_to_USDC_exactInput() public requireFork {
        uint256 amountIn = 0.5 ether;
        vm.deal(USER, 1 ether);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertGt(received, 0, "user must receive USDC");

        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Hook USDC residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d0), -int256(amountIn), "delta.amount0 mismatch");
        assertEq(int256(d1), int256(received), "delta.amount1 mismatch");
    }

    function test_fork_e2e_USDC_to_ETH_exactInput() public requireFork {
        uint256 amountIn = 2000e6;
        deal(USDC, USER, amountIn);
        vm.prank(USER);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);

        uint256 userEthBefore = USER.balance;

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(ethUsdcKey, params, settings, "");

        uint256 received = USER.balance - userEthBefore;
        assertGt(received, 0, "user must receive ETH");

        assertEq(IERC20(FW_ETH).balanceOf(address(hook)), 0, "Hook fwETH residue should be 0");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "Hook fwUSDC residue should be 0");
        assertEq(address(hook).balance, 0, "Hook ETH residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d1), -int256(amountIn), "delta.amount1 mismatch");
        assertApproxEqAbs(int256(d0), int256(received), 10, "delta.amount0 within 10 wei of received");
    }

    function test_fork_e2e_ETH_to_USDC_exactOutput() public requireFork {
        uint256 amountOut = 500e6;

        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();
        bool fwEthIsToken0 = ISwapV2Pair(FEWV2_PAIR).token0() == FW_ETH;
        (uint256 reserveIn, uint256 reserveOut) =
            fwEthIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expectedIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
        require(expectedIn < 1 ether, "Expected < 1 ETH for 500 USDC - reserves too thin?");

        uint256 ethBudget = expectedIn + 0.05 ether;
        vm.deal(USER, ethBudget);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: ethBudget}(ethUsdcKey, params, settings, "");

        uint256 usdcReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertGe(usdcReceived, amountOut, "Should receive at least exact USDC amount");
        assertLe(usdcReceived, amountOut + 10, "USDC received within 10 wei of target");

        assertEq(address(hook).balance, 0, "Hook ETH residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d1), int256(amountOut), "delta.amount1 should be +amountOut");
        assertLt(int256(d0), 0, "delta.amount0 should be negative");
    }

    function test_fork_e2e_USDC_to_ETH_exactOutput() public requireFork {
        uint256 amountOut = 0.2 ether;

        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();
        bool fwEthIsToken0 = ISwapV2Pair(FEWV2_PAIR).token0() == FW_ETH;
        (uint256 reserveIn, uint256 reserveOut) =
            fwEthIsToken0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        uint256 expectedIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;

        uint256 usdcBudget = expectedIn * 101 / 100;
        deal(USDC, USER, usdcBudget);
        vm.prank(USER);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);

        uint256 userEthBefore = USER.balance;

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(ethUsdcKey, params, settings, "");

        uint256 ethReceived = USER.balance - userEthBefore;
        assertGe(ethReceived, amountOut, "Should receive at least exact ETH amount");
        assertLe(ethReceived, amountOut + 10, "ETH received within 10 wei of target");

        // ExactOut intentionally leaves rounding surplus in the hook (sweepable).
        assertLt(address(hook).balance, amountOut, "Hook surplus should be << amountOut");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d0), int256(amountOut), "delta.amount0 should be +amountOut");
        assertLt(int256(d1), 0, "delta.amount1 should be negative");
    }

    // ─────────── Non-empty hookData is ignored in direct-only mode ───────────

    function test_fork_nonEmptyHookData_ETH_to_USDC_exactInput_usesDirectRoute() public requireFork {
        uint256 amountIn = 0.01 ether;
        bytes memory hookData = hex"01";
        uint256 expectedNetOut = _netAfterFee(_bestDefaultExactInput(FW_ETH, FW_USDC, amountIn));

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 burnerFwUsdcBefore = IERC20(FW_USDC).balanceOf(address(burner));

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, hookData);

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        uint256 feeAccrued = IERC20(FW_USDC).balanceOf(address(burner)) - burnerFwUsdcBefore;
        assertEq(received, expectedNetOut, "non-empty hookData still uses direct route");
        assertGt(feeAccrued, 0, "burner accrues output-token fee");
        assertEq(int256(delta.amount0()), -int256(amountIn), "delta.amount0 mismatch");
        assertEq(int256(delta.amount1()), int256(received), "delta.amount1 mismatch");
    }

    function test_fork_nonEmptyHookData_ETH_to_USDC_exactOutput_usesDirectRoute() public requireFork {
        uint256 amountOut = 10_000;
        bytes memory hookData = hex"01";

        vm.deal(USER, 1 ether);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 burnerFwUsdcBefore = IERC20(FW_USDC).balanceOf(address(burner));

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(ethUsdcKey, params, settings, hookData);

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        uint256 feeAccrued = IERC20(FW_USDC).balanceOf(address(burner)) - burnerFwUsdcBefore;
        assertEq(received, amountOut, "user receives exact output through direct route");
        assertGt(feeAccrued, 0, "burner accrues output-token fee");
        assertEq(int256(delta.amount1()), int256(amountOut), "delta.amount1 mismatch");
        assertLt(int256(delta.amount0()), 0, "delta.amount0 should be negative");
    }

    // ─────────── Liquidity is blocked ───────────

    function test_fork_modifyLiquidityReverts_addPosition() public requireFork {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        vm.expectRevert();
        modifyRouter.modifyLiquidity(ethUsdcKey, params, "");
    }

    function test_fork_modifyLiquidityReverts_removePosition() public requireFork {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)});
        vm.expectRevert();
        modifyRouter.modifyLiquidity(ethUsdcKey, params, "");
    }

    // ─────────── Permissionless sweep ───────────

    function test_fork_sweep_isPermissionlessAndSendsToFeeRecipient() public requireFork {
        deal(USDC, address(hook), 1234e6);
        vm.deal(address(hook), 0.5 ether);

        uint256 feeRecipientUsdcBefore = IERC20(USDC).balanceOf(FEE_RECIPIENT);
        uint256 feeRecipientEthBefore = FEE_RECIPIENT.balance;

        address randomCaller = address(0xDEADBEEF);
        vm.prank(randomCaller);
        hook.sweep(USDC);

        vm.prank(randomCaller);
        hook.sweep(address(0));

        assertEq(
            IERC20(USDC).balanceOf(FEE_RECIPIENT) - feeRecipientUsdcBefore, 1234e6, "FEE_RECIPIENT receives swept USDC"
        );
        assertEq(FEE_RECIPIENT.balance - feeRecipientEthBefore, 0.5 ether, "FEE_RECIPIENT receives swept ETH");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Hook USDC drained");
        assertEq(address(hook).balance, 0, "Hook ETH drained");
    }

    function test_fork_sweep_zeroBalanceNoOps() public requireFork {
        vm.prank(address(0xBEEF));
        hook.sweep(USDC);
        vm.prank(address(0xBEEF));
        hook.sweep(address(0));
    }

    // ─────────── Immutable invariants (compile-time guarantees) ───────────

    function test_fork_feeRecipientIsImmutable() public requireFork {
        assertEq(hook.feeRecipient(), FEE_RECIPIENT);
    }

    function test_fork_uniBurnerIsImmutable() public requireFork {
        assertEq(hook.uniBurner(), address(burner));
    }

    function test_fork_protocolFeeBpsIsConstant() public requireFork {
        assertEq(uint256(hook.PROTOCOL_FEE_BPS()), 5);
        assertEq(uint256(hook.CANONICAL_POOL_FEE()), CANONICAL_POOL_FEE);
        assertEq(int256(hook.CANONICAL_TICK_SPACING()), int256(CANONICAL_TICK_SPACING));
    }

    // ════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL / RED-TEAM
    // ════════════════════════════════════════════════════════════════════════

    // ─── A. Direct-call attacks (verify onlyPoolManager) ───
    // Defends against Cork Protocol $11M (2025-05): beforeSwap without onlyPoolManager.

    function test_attack_directBeforeSwap_revertsNotPoolManager() public requireFork {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), ethUsdcKey, p, "");
    }

    function test_attack_directBeforeInitialize_revertsNotPoolManager() public requireFork {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), ethUsdcKey, INIT_PRICE);
    }

    function test_attack_directBeforeAddLiquidity_revertsNotPoolManager() public requireFork {
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), ethUsdcKey, p, "");
    }

    function test_attack_exactInputAmount_rejectsUnrepresentableDeltas() public requireFork {
        HookNoAddressCheck harness = new HookNoAddressCheck(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            FEE_RECIPIENT,
            address(burner)
        );

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        harness.exposedExactInputAmount(type(int256).min);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        harness.exposedExactInputAmount(int256(type(int128).min));
    }

    // ─── B. ETH abuse (verify sweep recovers + no fund loss) ───

    function test_attack_unsolicitedETH_isSweepableNotLost() public requireFork {
        address attacker = address(0xBAD);
        vm.deal(attacker, 5 ether);

        vm.prank(attacker);
        (bool ok,) = payable(address(hook)).call{value: 5 ether}("");
        require(ok, "ETH transfer failed");

        assertEq(address(hook).balance, 5 ether);

        uint256 feeBefore = FEE_RECIPIENT.balance;

        vm.prank(attacker);
        hook.sweep(address(0));

        assertEq(address(hook).balance, 0);
        assertEq(FEE_RECIPIENT.balance, feeBefore + 5 ether);
    }

    function test_attack_selfdestructForcedETH_isSweepable() public requireFork {
        vm.deal(address(this), 3 ether);
        new SelfDestructAttacker{value: 3 ether}(payable(address(hook)));

        assertEq(address(hook).balance, 3 ether);

        uint256 feeBefore = FEE_RECIPIENT.balance;
        hook.sweep(address(0));
        assertEq(address(hook).balance, 0);
        assertEq(FEE_RECIPIENT.balance, feeBefore + 3 ether);
    }

    // ─── C. Mocked-external-return attacks ───

    function test_attack_wrapReturnsLess_revertsWrapMismatch() public requireFork {
        vm.mockCall(FW_ETH, abi.encodeWithSelector(IFewWrappedToken.wrap.selector), abi.encode(uint256(0)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_wrapReturnsMore_revertsWrapMismatch() public requireFork {
        vm.mockCall(FW_ETH, abi.encodeWithSelector(IFewWrappedToken.wrap.selector), abi.encode(type(uint256).max));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_unwrapReturnsLess_revertsUnwrapMismatch() public requireFork {
        vm.mockCall(FW_USDC, abi.encodeWithSelector(IFewWrappedToken.unwrap.selector), abi.encode(uint256(0)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    // ─── D. Pair sanity attacks (DegeneratePair / TokenMismatch) ───

    function test_attack_pairZeroReserves_swapReverts() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(0), uint112(0), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_pairAtMinimumLiquidity_revertsDegeneratePair() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(1000), uint112(1000), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_pairOneSideAtSentinel_revertsDegeneratePair() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(1000), uint112(1e18), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_pairJustAboveSentinel_noDegeneratePairRevert() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(1001), uint112(1001), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        try swapRouter.swap{value: 100}(ethUsdcKey, p, s, "") {
        // OK
        }
        catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            assertTrue(
                sel != RingAggregatorHook.DegeneratePair.selector,
                "must not revert with DegeneratePair at 1001 wei reserves"
            );
        }

        vm.clearMockedCalls();
    }

    function test_attack_pairLiesAboutToken0_revertsTokenMismatch() public requireFork {
        vm.mockCall(FEWV2_PAIR, abi.encodeWithSelector(ISwapV2Pair.token0.selector), abi.encode(address(0xDEAD)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    // ─── E. Reentrancy ───

    function test_attack_sweepReentrancy_blockedByNonReentrant() public requireFork {
        ReentrantSweepReceiver template = new ReentrantSweepReceiver(address(hook));
        vm.etch(FEE_RECIPIENT, address(template).code);

        vm.deal(address(hook), 1 ether);

        vm.expectRevert();
        hook.sweep(address(0));

        assertEq(address(hook).balance, 1 ether, "ETH safe in hook, no partial drain");
    }

    // ─── F. Constructor zero-address checks ───

    function _deployRaw(
        address fewFactory_,
        address fewV2Factory_,
        address weth_,
        address feeRecipient_,
        address uniBurner_
    ) internal {
        new HookNoAddressCheck(
            IPoolManager(V4_PM),
            IFewFactory(fewFactory_),
            ISwapV2Factory(fewV2Factory_),
            IWETH9(weth_),
            feeRecipient_,
            uniBurner_
        );
    }

    function test_attack_constructor_zeroFewFactory_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.ZeroAddress.selector);
        _deployRaw(address(0), RING_FACTORY, WETH, FEE_RECIPIENT, address(burner));
    }

    function test_attack_constructor_zeroFewV2Factory_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, address(0), WETH, FEE_RECIPIENT, address(burner));
    }

    function test_attack_constructor_zeroWeth_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, address(0), FEE_RECIPIENT, address(burner));
    }

    function test_attack_constructor_zeroFeeRecipient_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, WETH, address(0), address(burner));
    }

    function test_attack_constructor_zeroUniBurner_reverts() public requireFork {
        vm.expectRevert(RingAggregatorHook.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, WETH, FEE_RECIPIENT, address(0));
    }

    // ════════════════════════════════════════════════════════════════════════
    // UNI burn (5 bps protocol fee) behavior
    // ════════════════════════════════════════════════════════════════════════

    /// @notice ExactInput: burner accrues exactly 5 bps of the gross fwUSDC output.
    function test_fork_uniBurn_exactInput_5bps_skim() public requireFork {
        uint256 ethIn = 0.5 ether;
        vm.deal(USER, ethIn);

        uint256 burnerFwUsdcBefore = IERC20(FW_USDC).balanceOf(address(burner));
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");

        uint256 burnerSkimmed = IERC20(FW_USDC).balanceOf(address(burner)) - burnerFwUsdcBefore;
        uint256 userReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;

        uint256 grossFwOut = burnerSkimmed + userReceived;
        uint256 expectedSkim = (grossFwOut * 5) / 10000;

        assertEq(burnerSkimmed, expectedSkim, "burner skim must equal 5 bps of gross output");
        assertGt(burnerSkimmed, 0, "burner must accrue fee");
        assertLt(userReceived, grossFwOut, "user must pay fee");
    }

    /// @notice ExactOutput: user receives the exact target; burner accrues 5 bps from the grossed-up route.
    function test_fork_uniBurn_exactOutput_userReceivesTarget() public requireFork {
        uint256 usdcTarget = 100e6;
        vm.deal(USER, 5 ether);

        uint256 burnerBefore = IERC20(FW_USDC).balanceOf(address(burner));
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: int256(usdcTarget), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: 5 ether}(ethUsdcKey, p, s, "");

        uint256 burnerSkimmed = IERC20(FW_USDC).balanceOf(address(burner)) - burnerBefore;
        uint256 userReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;

        assertEq(userReceived, usdcTarget, "user must receive exact amountOut target");
        assertGt(burnerSkimmed, 0, "burner must accrue fee even for exact-out");
        uint256 approxExpected = (usdcTarget * 5) / 9995;
        assertApproxEqRel(burnerSkimmed, approxExpected, 0.2e18, "skim within 20% of analytical estimate");
    }

    /// @notice Fee accounting: gross output = user output + burner skim. No tokens lost.
    function test_fork_uniBurn_noTokensLost_exactInput() public requireFork {
        uint256 ethIn = 0.3 ether;
        vm.deal(USER, ethIn);

        uint256 hookFwBefore = IERC20(FW_USDC).balanceOf(address(hook));

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");

        uint256 hookFwDelta = IERC20(FW_USDC).balanceOf(address(hook)) - hookFwBefore;

        assertEq(hookFwDelta, 0, "hook must not retain fwUSDC dust on exact-in");
    }

    /// @notice UniFeeAccrued event is emitted on each swap.
    function test_fork_uniBurn_emitsUniFeeAccruedEvent() public requireFork {
        uint256 ethIn = 0.1 ether;
        vm.deal(USER, ethIn);

        vm.expectEmit(true, true, false, false, address(hook));
        emit RingAggregatorHook.UniFeeAccrued(ethUsdcKey.toId(), FW_USDC, 0);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");
    }

    /// @notice Official aggregator-hook event is emitted for UniRoute/subgraph compatibility.
    function test_fork_emitsHookSwapEvent_exactInput() public requireFork {
        uint256 ethIn = 0.1 ether;
        uint256 expectedNetOut = _netAfterFee(_bestDefaultExactInput(FW_ETH, FW_USDC, ethIn));
        vm.deal(USER, ethIn);

        vm.expectEmit(true, true, false, true, address(hook));
        emit RingAggregatorHook.HookSwap(
            ethUsdcKey.toId(), address(swapRouter), int256(ethIn), -int256(expectedNetOut), 500
        );

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");
    }

    // ════════════════════════════════════════════════════════════════════════
    // End-to-end: hook -> RingUniBurner -> mainnet Uniswap TokenJar
    // (No rotation step in V1 — uniBurner is wired at construction in setUp.)
    // ════════════════════════════════════════════════════════════════════════

    function test_fork_endToEnd_skimToTokenJar() public requireFork {
        uint256 ethIn = 1 ether;
        vm.deal(USER, ethIn);

        uint256 jarUsdcBefore = IERC20(USDC).balanceOf(TOKEN_JAR_MAINNET);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");

        uint256 burnerFwBalance = IERC20(FW_USDC).balanceOf(address(burner));
        assertGt(burnerFwBalance, 0, "burner accrued fwUSDC");

        // Anyone can call flush — prove permissionless.
        address keeper = address(0xDA02);
        vm.prank(keeper);
        uint256 forwarded = burner.flush(FW_USDC);

        assertEq(forwarded, burnerFwBalance, "all fwUSDC unwrapped + forwarded");
        assertEq(
            IERC20(USDC).balanceOf(TOKEN_JAR_MAINNET) - jarUsdcBefore,
            burnerFwBalance,
            "TokenJar received exactly the unwrapped USDC"
        );
        assertEq(IERC20(FW_USDC).balanceOf(address(burner)), 0, "no fwUSDC left in burner");
        assertEq(IERC20(USDC).balanceOf(address(burner)), 0, "no USDC dust in burner");
    }

    function test_fork_endToEnd_flushZeroBalance_noOp() public requireFork {
        // Empty burner; just call flush — should return 0 and not revert.
        RingUniBurner emptyBurner = new RingUniBurner(TOKEN_JAR_MAINNET, FEW_FACTORY, BURNER_OWNER);
        uint256 forwarded = emptyBurner.flush(FW_USDC);
        assertEq(forwarded, 0);
    }

    function test_fork_endToEnd_multipleSwapsBatchedFlush() public requireFork {
        uint256 jarBefore = IERC20(USDC).balanceOf(TOKEN_JAR_MAINNET);

        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        for (uint256 i = 0; i < 3; ++i) {
            vm.deal(USER, 0.3 ether);
            vm.prank(USER);
            swapRouter.swap{value: 0.3 ether}(ethUsdcKey, p, s, "");
        }

        uint256 burnerAccumulated = IERC20(FW_USDC).balanceOf(address(burner));
        assertGt(burnerAccumulated, 0, "burner accrued from 3 swaps");

        burner.flush(FW_USDC);

        assertEq(
            IERC20(USDC).balanceOf(TOKEN_JAR_MAINNET) - jarBefore,
            burnerAccumulated,
            "all 3 swaps' fee accumulation reached TokenJar in one flush"
        );
        assertEq(IERC20(FW_USDC).balanceOf(address(burner)), 0);
    }
}
