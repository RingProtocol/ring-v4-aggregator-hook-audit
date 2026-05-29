// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";
import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "./interfaces/external/IFewV2.sol";
import {FewV2Math} from "./lib/FewV2Math.sol";

/// @title RingAggregatorHook (admin-less variant — no owner, no pause)
/// @notice Permissionless variant of RingAggregatorHook. There is NO owner, NO admin functions,
///         NO pause. Once deployed, contract behavior is fully determined by:
///           - Immutable wiring (fewFactory, fewV2Factory, weth, feeRecipient, uniBurner)
///           - On-chain state of fewV2 pairs (the actual liquidity it routes through)
///
///         Each v4 pool maps to one direct FewV2 pair. Multi-hop price improvement is left to
///         Uniswap routing, which can compose A-X-B as two independent v4 hook pool hops.
///
/// @dev FULLY-IMMUTABLE PERMISSION MODEL (zero governance attack surface):
///      ┌────────────────────────────────────────────────────────────────────────┐
///      │  STATE         │ mutable?      │ Role                                   │
///      │────────────────│───────────────│────────────────────────────────────────│
///      │  _approved     │ internal only │ Approval cache (gas optimization)      │
///      │────────────────│───────────────│────────────────────────────────────────│
///      │  uniBurner     │ NO immutable  │ TokenJar fee adapter                    │
///      │  feeRecipient  │ NO immutable  │ Sweep destination (dust only)          │
///      │  PROTOCOL_FEE  │ NO constant=5 │ 5 bps -> uniBurner -> TokenJar         │
///      │  fewFactory    │ NO immutable  │ Ring fewFactory                        │
///      │  fewV2Factory  │ NO immutable  │ Ring FewV2Factory                      │
///      │  weth          │ NO immutable  │ Chain WETH                             │
///      └────────────────────────────────────────────────────────────────────────┘
///
///      `sweep(token)` is PERMISSIONLESS — destination is locked at deploy.
///      No owner. No pause. No upgrade path. If something is broken: redeploy V2.
///
/// @dev Compared to RingAggregatorHookSimple (which had `swapsPaused` + owner) this
///      version REMOVES:
///      - `Ownable2Step` inheritance and `_owner` constructor parameter
///      - `swapsPaused` state variable + `setSwapsPaused` function
///      - `renounceOwnership` override
///      - `SwapsPaused`, `CannotRenounce` errors and `PausedSwap` event
///
///      Trade-off: no emergency stop. If a fewToken or fewV2 pair is exploited, the only
///      recovery is for the affected fewV2Factory pair to be drained (rendering this hook's
///      route revert via `DegeneratePair`/`NoFewV2Route`) or for ring.exchange / Uniswap
///      routing-api to delist this hook at the routing layer.
contract RingAggregatorHook is BaseHook, DeltaResolver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error InvalidPoolFee();
    error UseFewTokenHookForWrapPairs();
    error NoFewV2Route();
    error LiquidityNotAllowed();
    error TokenMismatch(address pair);
    error ExactOutputUnderfilled(uint256 actual, uint256 expected);
    error EthForwardFailed();
    error ZeroAddress();
    error WrapMismatch(uint256 expected, uint256 actual);
    error UnwrapMismatch(uint256 expected, uint256 actual);
    error DegeneratePair(address pair);

    // ============ Constants ============
    /// @notice 5 bps of every swap's gross fewToken output is forwarded to `uniBurner`.
    uint24 public constant PROTOCOL_FEE_BPS = 5;
    uint256 private constant FEE_DENOM = 10_000;

    /// @notice Reserve sanity sentinel. V2 pairs lock `MINIMUM_LIQUIDITY = 1000 wei` at creation;
    ///         a pair at or below this level is fully drained — reject explicitly.
    uint256 private constant MIN_PAIR_RESERVE = 1000;

    // ============ Immutable ============
    /// @notice Ring fewFactory (ERC20→fewToken wrapper) and fewV2Factory (the AMM this hook
    ///         routes liquidity through). Both are deliberately IMMUTABLE.
    /// @dev    Pre-empts the auditor question "what if FewV2 migrates its factory?": these are
    ///         core Ring infrastructure, stable for years (same tier as the fewToken contracts
    ///         themselves). A factory migration is a near-zero, multi-year event, handled by
    ///         redeploying this hook (re-mine address → re-init pools → re-allowlist) — an
    ///         accepted, clean path. We intentionally expose NO owner setter for them: a mutable
    ///         liquidity-source pointer is a DoS surface (a compromised owner could repoint at a
    ///         griefing factory) and would drag an owner + timelock + multisig back into an
    ///         otherwise ownerless contract, all to buy a lever used ~never. Atomicity +
    ///         wrap/unwrap mismatch checks + caller-side slippage already cap worst-case abuse at
    ///         revert / bad-rate (no fund-theft path), so a setter would only add attack surface.
    IFewFactory public immutable fewFactory;
    ISwapV2Factory public immutable fewV2Factory;
    IWETH9 public immutable weth;
    /// @notice Permissionless `sweep` target. Set once at deploy, never changeable.
    address public immutable feeRecipient;
    /// @notice TokenJar fee adapter. Set once at deploy, never changeable.
    address public immutable uniBurner;

    // ============ Mutable (internal only) ============
    /// @notice Tracks (token, fewToken) approvals — one-time max approval cache. Internal only.
    mapping(address => mapping(address => bool)) internal _approved;

    struct DirectRoute {
        address fewIn;
        address fewOut;
        address pair;
    }

    // ============ Events ============
    event SwapAggregated(
        PoolId indexed poolId,
        address indexed router,
        address indexed origin,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fwOutAmount
    );
    event Sweep(address indexed token, address indexed to, uint256 amount, address indexed triggeredBy);
    event UniFeeAccrued(PoolId indexed poolId, address indexed fewToken, uint256 amount);

    // ============ Constructor ============
    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        address _feeRecipient,
        address _uniBurner
    ) BaseHook(_pm) {
        if (address(_fewFactory) == address(0)) revert ZeroAddress();
        if (address(_fewV2Factory) == address(0)) revert ZeroAddress();
        if (address(_weth) == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_uniBurner == address(0)) revert ZeroAddress();

        fewFactory = _fewFactory;
        fewV2Factory = _fewV2Factory;
        weth = _weth;
        feeRecipient = _feeRecipient;
        uniBurner = _uniBurner;
    }

    // ============ Hook permissions ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ DeltaResolver payment glue ============
    function _pay(
        Currency currency,
        address,
        /* payer */
        uint256 amount
    )
        internal
        override
    {
        currency.transfer(address(poolManager), amount);
    }

    // ============ beforeInitialize ============
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (key.fee == 0) revert InvalidPoolFee();

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);

        // Refuse 1:1 wrap pairs — those belong to FewTokenHook, not this hook.
        if (_isFewTokenOf(t0, t1) || _isFewTokenOf(t1, t0)) revert UseFewTokenHookForWrapPairs();

        // Endpoint FewTokens and their direct FewV2 pair must exist at init time.
        (address fewA, address fewB) = _defaultFewPair(t0, t1);
        if (fewA == address(0) || fewB == address(0)) revert NoFewV2Route();
        if (fewV2Factory.getPair(fewA, fewB) == address(0)) revert NoFewV2Route();

        return IHooks.beforeInitialize.selector;
    }

    function _isFewTokenOf(address a, address b) internal view returns (bool) {
        if (b == address(0)) {
            address fewWETH = fewFactory.getWrappedToken(address(weth));
            return a == fewWETH && fewWETH != address(0);
        }
        return fewFactory.getWrappedToken(b) == a && a != address(0);
    }

    function _defaultFewPair(address t0, address t1) internal view returns (address fewA, address fewB) {
        address u0 = t0 == address(0) ? address(weth) : t0;
        address u1 = t1 == address(0) ? address(weth) : t1;
        fewA = fewFactory.getWrappedToken(u0);
        fewB = fewFactory.getWrappedToken(u1);
    }

    // ============ beforeAddLiquidity ============
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    // ============ beforeSwap ============
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency inCurr = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outCurr = params.zeroForOne ? key.currency1 : key.currency0;

        DirectRoute memory route = _resolveDirectRoute(key, params.zeroForOne);

        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            return _swapExactInput(sender, key, inCurr, outCurr, params, route);
        } else {
            return _swapExactOutput(sender, key, inCurr, outCurr, params, route);
        }
    }

    // ============ Direct route resolution ============
    function _resolveDirectRoute(PoolKey calldata key, bool zeroForOne)
        internal
        view
        returns (DirectRoute memory route)
    {
        (address fewA, address fewB) = _defaultFewPair(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (fewA == address(0) || fewB == address(0)) revert NoFewV2Route();

        (route.fewIn, route.fewOut) = zeroForOne ? (fewA, fewB) : (fewB, fewA);
        route.pair = fewV2Factory.getPair(route.fewIn, route.fewOut);
        if (route.pair == address(0)) revert NoFewV2Route();
    }

    // ============ Exact-input ============
    function _swapExactInput(
        address sender,
        PoolKey calldata key,
        Currency inCurr,
        Currency outCurr,
        SwapParams calldata params,
        DirectRoute memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountIn = uint256(-params.amountSpecified);

        _take(inCurr, address(this), amountIn);
        uint256 fwInAmount = _wrap(inCurr, route.fewIn, amountIn);
        uint256 fwOutAmount = _executeFewV2Hop(route.pair, route.fewIn, route.fewOut, fwInAmount);

        uint256 fwUserOut = _skimUniBurnFee(key.toId(), route.fewOut, fwOutAmount);

        uint256 amountOut = _unwrap(route.fewOut, outCurr, fwUserOut);
        _settle(outCurr, address(this), amountOut);

        emit SwapAggregated(
            key.toId(), sender, tx.origin, params.zeroForOne, params.amountSpecified, amountIn, amountOut, fwOutAmount
        );

        BeforeSwapDelta swapDelta =
            toBeforeSwapDelta((-params.amountSpecified).toInt128(), -amountOut.toInt256().toInt128());
        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    // ============ Exact-output ============
    function _swapExactOutput(
        address sender,
        PoolKey calldata key,
        Currency inCurr,
        Currency outCurr,
        SwapParams calldata params,
        DirectRoute memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountOut = uint256(params.amountSpecified);

        // Gross up so that after `_skimUniBurnFee` the user still receives `amountOut`.
        uint256 fwOutGross =
            (amountOut * FEE_DENOM + (FEE_DENOM - PROTOCOL_FEE_BPS) - 1) / (FEE_DENOM - PROTOCOL_FEE_BPS);
        uint256 fwInRequired = _quoteAmountInForHop(route.pair, route.fewIn, route.fewOut, fwOutGross);
        uint256 amountIn = fwInRequired; // 1:1 wrap

        _take(inCurr, address(this), amountIn);
        uint256 fwInAmount = _wrap(inCurr, route.fewIn, amountIn);
        uint256 fwOutAmount = _executeFewV2Hop(route.pair, route.fewIn, route.fewOut, fwInAmount);

        uint256 fwUserOut = _skimUniBurnFee(key.toId(), route.fewOut, fwOutAmount);

        uint256 actualOut = _unwrap(route.fewOut, outCurr, fwUserOut);
        if (actualOut < amountOut) revert ExactOutputUnderfilled(actualOut, amountOut);

        _settle(outCurr, address(this), amountOut);

        emit SwapAggregated(
            key.toId(), sender, tx.origin, params.zeroForOne, params.amountSpecified, amountIn, amountOut, fwOutAmount
        );

        BeforeSwapDelta swapDelta =
            toBeforeSwapDelta((-params.amountSpecified).toInt128(), amountIn.toInt256().toInt128());
        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    // ============ TokenJar fee ============
    function _skimUniBurnFee(PoolId pid, address fewToken, uint256 fwOutAmount) internal returns (uint256 fwUserOut) {
        uint256 fee = (fwOutAmount * PROTOCOL_FEE_BPS) / FEE_DENOM;
        if (fee == 0) return fwOutAmount;

        IERC20(fewToken).safeTransfer(uniBurner, fee);
        emit UniFeeAccrued(pid, fewToken, fee);

        return fwOutAmount - fee;
    }

    // ============ Wrap / unwrap ============
    function _wrap(Currency inCurr, address fewToken, uint256 amount) internal returns (uint256) {
        if (inCurr.isAddressZero()) {
            weth.deposit{value: amount}();
            _ensureApproval(address(weth), fewToken);
            uint256 minted = IFewWrappedToken(fewToken).wrap(amount);
            if (minted != amount) revert WrapMismatch(amount, minted);
            return minted;
        }
        address underlying = Currency.unwrap(inCurr);
        _ensureApproval(underlying, fewToken);
        uint256 m = IFewWrappedToken(fewToken).wrap(amount);
        if (m != amount) revert WrapMismatch(amount, m);
        return m;
    }

    function _unwrap(address fewToken, Currency outCurr, uint256 fwAmount) internal returns (uint256) {
        if (outCurr.isAddressZero()) {
            uint256 underlyingAmt = IFewWrappedToken(fewToken).unwrap(fwAmount);
            if (underlyingAmt != fwAmount) revert UnwrapMismatch(fwAmount, underlyingAmt);
            weth.withdraw(underlyingAmt);
            return underlyingAmt;
        }
        uint256 amt = IFewWrappedToken(fewToken).unwrap(fwAmount);
        if (amt != fwAmount) revert UnwrapMismatch(fwAmount, amt);
        return amt;
    }

    function _ensureApproval(address token, address spender) internal {
        if (_approved[token][spender]) return;
        IERC20(token).forceApprove(spender, type(uint256).max);
        _approved[token][spender] = true;
    }

    // ============ FewV2 direct-pair execution ============
    function _executeFewV2Hop(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut, bool inputIsToken0) = _hopState(pair, tokenIn, tokenOut);

        amountOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
        (uint256 a0Out, uint256 a1Out) = inputIsToken0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

        IERC20(tokenIn).safeTransfer(pair, amountIn);
        ISwapV2Pair(pair).swap(a0Out, a1Out, address(this), "");
    }

    function _quoteAmountInForHop(address pair, address tokenIn, address tokenOut, uint256 finalOut)
        internal
        view
        returns (uint256 amountIn)
    {
        (uint256 reserveIn, uint256 reserveOut,) = _hopState(pair, tokenIn, tokenOut);
        amountIn = FewV2Math.getAmountIn(finalOut, reserveIn, reserveOut);
    }

    function _hopState(address pair, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut, bool inputIsToken0)
    {
        address t0 = ISwapV2Pair(pair).token0();
        address t1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        if (tokenIn == t0 && tokenOut == t1) {
            inputIsToken0 = true;
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == t1 && tokenOut == t0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            revert TokenMismatch(pair);
        }

        if (reserveIn <= MIN_PAIR_RESERVE || reserveOut <= MIN_PAIR_RESERVE) revert DegeneratePair(pair);
    }

    // ============ Permissionless sweep ============

    /// @notice Sweep `token` balance to the immutable `feeRecipient`. Anyone may call.
    /// @param  token  ERC20 to sweep, or `address(0)` for native ETH.
    function sweep(address token) external nonReentrant {
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            if (amount > 0) {
                (bool ok,) = payable(feeRecipient).call{value: amount}("");
                if (!ok) revert EthForwardFailed();
            }
        } else {
            amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) IERC20(token).safeTransfer(feeRecipient, amount);
        }
        emit Sweep(token, feeRecipient, amount, msg.sender);
    }

    // ============ Views ============
    /// @notice The direct 1-hop FewV2 route derived from fewFactory for a pool.
    function defaultRouteFor(PoolKey calldata key) external view returns (address fewA, address fewB, address pair) {
        (fewA, fewB) = _defaultFewPair(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (fewA != address(0) && fewB != address(0)) {
            pair = fewV2Factory.getPair(fewA, fewB);
        }
    }

    // ============ Native ETH receive ============
    receive() external payable {}
}
