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
import {IFewWrappedToken} from "./interfaces/IFewWrappedToken.sol";
import {IFewFactory} from "./interfaces/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "./interfaces/IFewV2.sol";
import {FewV2Math} from "./lib/FewV2Math.sol";

/// @title RingAggregatorHook (admin-less variant — no owner, no pause)
/// @notice Permissionless variant of RingAggregatorHook. There is NO owner, NO admin functions,
///         NO pause. Once deployed, contract behavior is fully determined by:
///           - Immutable wiring (fewFactory, fewV2Factory, weth, feeRecipient, uniBurner)
///           - On-chain state of fewV2 pairs (the actual liquidity it routes through)
///
///         Empty `hookData` uses the built-in default router: direct 1-hop plus a fixed
///         deploy-time connector set. Non-empty `hookData` may supply an ownerless calldata
///         route `(address[] fewPath, uint256 amountLimit)`. The hook validates every path
///         element on-chain against `fewFactory`, restricts hidden intermediates to the fixed
///         connector set, and derives every pair from `fewV2Factory`; callers never supply pair
///         addresses.
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
    error InvalidRouteLength();
    error InvalidRouteEndpoint(address actual, address expected);
    error InvalidFewToken(address token);
    error DuplicateRouteToken(address token);
    error DuplicateRoutePair(address pair);
    error InvalidRouteIntermediate(address token);
    error InvalidAmountLimit();
    error SlippageExceeded(uint256 actual, uint256 limit);

    // ============ Constants ============
    /// @notice 5 bps of every swap's gross fewToken output is forwarded to `uniBurner`.
    uint24 public constant PROTOCOL_FEE_BPS = 5;
    uint256 private constant FEE_DENOM = 10_000;
    uint256 private constant DEFAULT_CONNECTOR_COUNT = 6;

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
    /// @notice Deploy-time fixed common FewToken connectors used for empty-hookData auto-routing.
    address public immutable defaultConnector0;
    address public immutable defaultConnector1;
    address public immutable defaultConnector2;
    address public immutable defaultConnector3;
    address public immutable defaultConnector4;
    address public immutable defaultConnector5;

    // ============ Mutable (internal only) ============
    /// @notice Tracks (token, fewToken) approvals — one-time max approval cache. Internal only.
    mapping(address => mapping(address => bool)) internal _approved;

    struct Route {
        address[] tokens;
        address[] pairs;
        uint256 amountLimit;
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
        address _uniBurner,
        address[DEFAULT_CONNECTOR_COUNT] memory _defaultConnectors
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

        for (uint256 i = 0; i < DEFAULT_CONNECTOR_COUNT; ++i) {
            _assertCanonicalFewToken(_defaultConnectors[i]);
            for (uint256 j = 0; j < i; ++j) {
                if (_defaultConnectors[j] == _defaultConnectors[i]) revert DuplicateRouteToken(_defaultConnectors[i]);
            }
        }
        defaultConnector0 = _defaultConnectors[0];
        defaultConnector1 = _defaultConnectors[1];
        defaultConnector2 = _defaultConnectors[2];
        defaultConnector3 = _defaultConnectors[3];
        defaultConnector4 = _defaultConnectors[4];
        defaultConnector5 = _defaultConnectors[5];
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

        // Endpoint FewTokens must exist at init time. Empty-hookData swaps choose
        // direct vs fixed-connector routes at quote/swap time; calldata-routed
        // swaps validate their own path.
        (address fewA, address fewB) = _defaultFewPair(t0, t1);
        if (fewA == address(0) || fewB == address(0)) revert NoFewV2Route();

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
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency inCurr = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outCurr = params.zeroForOne ? key.currency1 : key.currency0;

        Route memory route = _resolveRoute(key, params.zeroForOne, params.amountSpecified, hookData);

        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            return _swapExactInput(sender, key, inCurr, outCurr, params, route);
        } else {
            return _swapExactOutput(sender, key, inCurr, outCurr, params, route);
        }
    }

    // ============ Route resolution ============
    /// @dev `hookData == ""` runs the deploy-time fixed default router. Non-empty hookData
    ///      must be `abi.encode(address[] fewPath, uint256 amountLimit)`.
    ///      For exact-input, `amountLimit` is min output. For exact-output, it is max input.
    function _resolveRoute(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        internal
        view
        returns (Route memory route)
    {
        (address fewA, address fewB) = _defaultFewPair(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (fewA == address(0) || fewB == address(0)) revert NoFewV2Route();

        (address expectedIn, address expectedOut) = zeroForOne ? (fewA, fewB) : (fewB, fewA);
        if (hookData.length == 0) {
            bool exactInput = amountSpecified < 0;
            uint256 quoteAmount = exactInput
                ? uint256(-amountSpecified)
                : (uint256(amountSpecified) * FEE_DENOM + (FEE_DENOM - PROTOCOL_FEE_BPS) - 1)
                    / (FEE_DENOM - PROTOCOL_FEE_BPS);
            return _defaultRoute(expectedIn, expectedOut, exactInput, quoteAmount);
        }

        (address[] memory path, uint256 amountLimit) = abi.decode(hookData, (address[], uint256));
        if (amountLimit == 0) revert InvalidAmountLimit();
        return _calldataRoute(path, expectedIn, expectedOut, amountLimit);
    }

    function _defaultRoute(address fewIn, address fewOut, bool exactInput, uint256 quoteAmount)
        internal
        view
        returns (Route memory route)
    {
        address bestPair0 = address(0);
        address bestPair1 = address(0);
        address bestConnector = address(0);
        uint256 bestQuote = 0;
        uint256 bestHops = 0;

        bool ok;
        address directPair;
        uint256 directQuote;
        if (exactInput) {
            (ok, directPair, directQuote) = _quoteDefaultExactInputDirect(fewIn, fewOut, quoteAmount);
        } else {
            (ok, directPair, directQuote) = _quoteDefaultExactOutputDirect(fewIn, fewOut, quoteAmount);
        }
        if (ok) {
            bestPair0 = directPair;
            bestQuote = directQuote;
            bestHops = 1;
        }

        for (uint256 i = 0; i < DEFAULT_CONNECTOR_COUNT; ++i) {
            address connector = _defaultConnectorAt(i);
            if (connector == fewIn || connector == fewOut) continue;

            if (exactInput) {
                (ok, directPair, bestPair1, directQuote) =
                    _quoteDefaultExactInputVia(fewIn, connector, fewOut, quoteAmount);
            } else {
                (ok, directPair, bestPair1, directQuote) =
                    _quoteDefaultExactOutputVia(fewIn, connector, fewOut, quoteAmount);
            }
            if (!ok) continue;

            if (bestHops == 0 || (exactInput ? directQuote > bestQuote : directQuote < bestQuote)) {
                bestPair0 = directPair;
                bestConnector = connector;
                bestQuote = directQuote;
                bestHops = 2;
            }
        }

        if (bestHops == 0) revert NoFewV2Route();
        if (bestHops == 1) return _route2(fewIn, fewOut, bestPair0, 0);
        return _route3(fewIn, bestConnector, fewOut, bestPair0, bestPair1, 0);
    }

    function _calldataRoute(address[] memory path, address expectedIn, address expectedOut, uint256 amountLimit)
        internal
        view
        returns (Route memory route)
    {
        uint256 length = path.length;
        if (length < 2) revert InvalidRouteLength();
        if (path[0] != expectedIn) revert InvalidRouteEndpoint(path[0], expectedIn);
        if (path[length - 1] != expectedOut) revert InvalidRouteEndpoint(path[length - 1], expectedOut);

        for (uint256 i = 0; i < length; ++i) {
            _assertCanonicalFewToken(path[i]);
            if (i > 0 && i < length - 1 && !_isDefaultConnector(path[i])) revert InvalidRouteIntermediate(path[i]);
            for (uint256 j = 0; j < i; ++j) {
                if (path[j] == path[i]) revert DuplicateRouteToken(path[i]);
            }
        }

        route.tokens = path;
        route.pairs = new address[](length - 1);
        route.amountLimit = amountLimit;

        for (uint256 i = 0; i < route.pairs.length; ++i) {
            address pair = fewV2Factory.getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert NoFewV2Route();
            for (uint256 j = 0; j < i; ++j) {
                if (route.pairs[j] == pair) revert DuplicateRoutePair(pair);
            }
            route.pairs[i] = pair;
        }
    }

    function _route2(address token0, address token1, address pair, uint256 amountLimit)
        internal
        pure
        returns (Route memory route)
    {
        route.tokens = new address[](2);
        route.tokens[0] = token0;
        route.tokens[1] = token1;
        route.pairs = new address[](1);
        route.pairs[0] = pair;
        route.amountLimit = amountLimit;
    }

    function _route3(address token0, address token1, address token2, address pair0, address pair1, uint256 amountLimit)
        internal
        pure
        returns (Route memory route)
    {
        route.tokens = new address[](3);
        route.tokens[0] = token0;
        route.tokens[1] = token1;
        route.tokens[2] = token2;
        route.pairs = new address[](2);
        route.pairs[0] = pair0;
        route.pairs[1] = pair1;
        route.amountLimit = amountLimit;
    }

    function _defaultConnectorAt(uint256 i) internal view returns (address) {
        if (i == 0) return defaultConnector0;
        if (i == 1) return defaultConnector1;
        if (i == 2) return defaultConnector2;
        if (i == 3) return defaultConnector3;
        if (i == 4) return defaultConnector4;
        return defaultConnector5;
    }

    function _isDefaultConnector(address token) internal view returns (bool) {
        for (uint256 i = 0; i < DEFAULT_CONNECTOR_COUNT; ++i) {
            if (_defaultConnectorAt(i) == token) return true;
        }
        return false;
    }

    function _quoteDefaultExactInputDirect(address fewIn, address fewOut, uint256 amountIn)
        internal
        view
        returns (bool ok, address pair, uint256 amountOut)
    {
        pair = fewV2Factory.getPair(fewIn, fewOut);
        if (pair == address(0) || amountIn == 0) return (false, address(0), 0);
        (ok, amountOut) = _tryQuoteExactInputHop(pair, fewIn, fewOut, amountIn);
    }

    function _quoteDefaultExactInputVia(address fewIn, address connector, address fewOut, uint256 amountIn)
        internal
        view
        returns (bool ok, address pair0, address pair1, uint256 amountOut)
    {
        pair0 = fewV2Factory.getPair(fewIn, connector);
        pair1 = fewV2Factory.getPair(connector, fewOut);
        if (pair0 == address(0) || pair1 == address(0) || pair0 == pair1 || amountIn == 0) {
            return (false, address(0), address(0), 0);
        }

        uint256 connectorOut;
        (ok, connectorOut) = _tryQuoteExactInputHop(pair0, fewIn, connector, amountIn);
        if (!ok || connectorOut == 0) return (false, address(0), address(0), 0);
        (ok, amountOut) = _tryQuoteExactInputHop(pair1, connector, fewOut, connectorOut);
        if (!ok || amountOut == 0) return (false, address(0), address(0), 0);
    }

    function _quoteDefaultExactOutputDirect(address fewIn, address fewOut, uint256 amountOut)
        internal
        view
        returns (bool ok, address pair, uint256 amountIn)
    {
        pair = fewV2Factory.getPair(fewIn, fewOut);
        if (pair == address(0) || amountOut == 0) return (false, address(0), 0);
        (ok, amountIn) = _tryQuoteExactOutputHop(pair, fewIn, fewOut, amountOut);
    }

    function _quoteDefaultExactOutputVia(address fewIn, address connector, address fewOut, uint256 amountOut)
        internal
        view
        returns (bool ok, address pair0, address pair1, uint256 amountIn)
    {
        pair0 = fewV2Factory.getPair(fewIn, connector);
        pair1 = fewV2Factory.getPair(connector, fewOut);
        if (pair0 == address(0) || pair1 == address(0) || pair0 == pair1 || amountOut == 0) {
            return (false, address(0), address(0), 0);
        }

        uint256 connectorIn;
        (ok, connectorIn) = _tryQuoteExactOutputHop(pair1, connector, fewOut, amountOut);
        if (!ok || connectorIn == 0) return (false, address(0), address(0), 0);
        (ok, amountIn) = _tryQuoteExactOutputHop(pair0, fewIn, connector, connectorIn);
        if (!ok || amountIn == 0) return (false, address(0), address(0), 0);
    }

    function _tryQuoteExactInputHop(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        uint256 reserveIn;
        uint256 reserveOut;
        (ok, reserveIn, reserveOut,) = _tryHopState(pair, tokenIn, tokenOut);
        if (!ok || amountIn == 0) return (false, 0);
        amountOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
        ok = amountOut != 0;
    }

    function _tryQuoteExactOutputHop(address pair, address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (bool ok, uint256 amountIn)
    {
        uint256 reserveIn;
        uint256 reserveOut;
        (ok, reserveIn, reserveOut,) = _tryHopState(pair, tokenIn, tokenOut);
        if (!ok || amountOut == 0 || amountOut >= reserveOut) return (false, 0);
        amountIn = FewV2Math.getAmountIn(amountOut, reserveIn, reserveOut);
        ok = amountIn != 0;
    }

    function _assertCanonicalFewToken(address fewToken) internal view {
        if (fewToken == address(0)) revert InvalidFewToken(fewToken);
        address underlying = address(0);
        try IFewWrappedToken(fewToken).token() returns (address token) {
            underlying = token;
        } catch {
            revert InvalidFewToken(fewToken);
        }
        if (underlying == address(0) || fewFactory.getWrappedToken(underlying) != fewToken) {
            revert InvalidFewToken(fewToken);
        }
    }

    // ============ Exact-input ============
    function _swapExactInput(
        address sender,
        PoolKey calldata key,
        Currency inCurr,
        Currency outCurr,
        SwapParams calldata params,
        Route memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountIn = uint256(-params.amountSpecified);

        _take(inCurr, address(this), amountIn);
        uint256 fwInAmount = _wrap(inCurr, route.tokens[0], amountIn);
        uint256 fwOutAmount = _executeFewV2Route(route, fwInAmount);

        uint256 fwUserOut = _skimUniBurnFee(key.toId(), route.tokens[route.tokens.length - 1], fwOutAmount);

        uint256 amountOut = _unwrap(route.tokens[route.tokens.length - 1], outCurr, fwUserOut);
        if (route.amountLimit != 0 && amountOut < route.amountLimit) {
            revert SlippageExceeded(amountOut, route.amountLimit);
        }
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
        Route memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountOut = uint256(params.amountSpecified);

        // Gross up so that after `_skimUniBurnFee` the user still receives `amountOut`.
        uint256 fwOutGross =
            (amountOut * FEE_DENOM + (FEE_DENOM - PROTOCOL_FEE_BPS) - 1) / (FEE_DENOM - PROTOCOL_FEE_BPS);
        uint256 fwInRequired = _quoteAmountInForRoute(route, fwOutGross);
        uint256 amountIn = fwInRequired; // 1:1 wrap
        if (route.amountLimit != 0 && amountIn > route.amountLimit) {
            revert SlippageExceeded(amountIn, route.amountLimit);
        }

        _take(inCurr, address(this), amountIn);
        uint256 fwInAmount = _wrap(inCurr, route.tokens[0], amountIn);
        uint256 fwOutAmount = _executeFewV2Route(route, fwInAmount);

        uint256 fwUserOut = _skimUniBurnFee(key.toId(), route.tokens[route.tokens.length - 1], fwOutAmount);

        uint256 actualOut = _unwrap(route.tokens[route.tokens.length - 1], outCurr, fwUserOut);
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

    // ============ FewV2 route execution ============
    function _executeFewV2Route(Route memory route, uint256 amountIn) internal returns (uint256 amountOut) {
        amountOut = amountIn;
        for (uint256 i = 0; i < route.pairs.length; ++i) {
            amountOut = _executeFewV2Hop(route.pairs[i], route.tokens[i], route.tokens[i + 1], amountOut);
        }
    }

    function _quoteAmountInForRoute(Route memory route, uint256 finalOut) internal view returns (uint256 amountIn) {
        amountIn = finalOut;
        for (uint256 i = route.pairs.length; i > 0; --i) {
            amountIn = _quoteAmountInForHop(route.pairs[i - 1], route.tokens[i - 1], route.tokens[i], amountIn);
        }
    }

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

    function _tryHopState(address pair, address tokenIn, address tokenOut)
        internal
        view
        returns (bool ok, uint256 reserveIn, uint256 reserveOut, bool inputIsToken0)
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
            return (false, 0, 0, false);
        }

        ok = reserveIn > MIN_PAIR_RESERVE && reserveOut > MIN_PAIR_RESERVE;
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
    /// @dev Empty-hookData swaps consider this pair plus the fixed default connectors.
    function defaultRouteFor(PoolKey calldata key) external view returns (address fewA, address fewB, address pair) {
        (fewA, fewB) = _defaultFewPair(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (fewA != address(0) && fewB != address(0)) {
            pair = fewV2Factory.getPair(fewA, fewB);
        }
    }

    /// @notice Fixed common connector FewToken at `index`.
    function defaultConnector(uint256 index) external view returns (address) {
        if (index >= DEFAULT_CONNECTOR_COUNT) revert InvalidRouteLength();
        return _defaultConnectorAt(index);
    }

    // ============ Native ETH receive ============
    receive() external payable {}
}
