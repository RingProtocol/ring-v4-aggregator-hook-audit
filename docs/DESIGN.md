# Ring V4 Aggregator Hook — Ownerless Design

> Last updated: 2026-05-25
> Audit target: `RingAggregatorHook` + `RingUniBurner` on `audit-r3-uniswap-periphery-helpers`, based on frozen tag `audit-ownerless-calldata-route-2026-05-25-r3`
> Status: implementation complete; 88/88 tests passing; V4Quoter fork tests passing; Slither triaged; coverage regenerated

---

## 1. Executive Summary

`RingAggregatorHook` exposes existing FewV2 liquidity as a Uniswap v4 pool without moving that liquidity into v4.

The hook owns the v4 `PoolKey`, but it holds no LP inventory. On every swap it:

1. Takes the input token from `PoolManager`
2. Wraps it 1:1 into the corresponding FewToken
3. Swaps across the best default route (direct FewV2 pair or one fixed connector) or a bounded calldata route
4. Skims 5 bps of the gross FewToken output to `RingUniBurner`
5. Unwraps the user output back to the requested underlying token
6. Settles the output back to `PoolManager` with a `BeforeSwapDelta`

The deployed hook is ownerless:

- No `Ownable`
- No admin functions
- No pause switch
- No route registry
- No admin-controlled routing
- No arbitrary hidden intermediates
- No fee setter
- No burner rotation
- No upgrade path

If the hook is deployed with a bad immutable or a future migration is needed, the answer is redeploy and re-list the new hook. The contract deliberately does not include governance levers to patch itself in place.

---

## 2. What This Hook Is For

Ring already has organic liquidity in FewV2 pairs such as `fwETH/fwUSDC`. Without the aggregator hook, a v4 user who wants `ETH -> USDC` through Ring liquidity needs a route like:

```text
ETH -> fwETH -> fwUSDC -> USDC
```

The aggregator hook collapses that into one v4 pool from the router's perspective:

```text
Universal Router
  -> PoolManager.beforeSwap
  -> RingAggregatorHook
  -> FewToken.wrap
  -> FewV2 pair swap
  -> RingUniBurner fee skim
  -> FewToken.unwrap
  -> PoolManager settlement
```

The hook is an adapter over existing liquidity, not a new AMM.

---

## 3. Trust Model

### 3.1 Immutable Inputs

`RingAggregatorHook` is fully determined by constructor wiring and on-chain FewV2 pair state:

| Field | Mutability | Purpose |
|---|---:|---|
| `poolManager` | immutable | Uniswap v4 settlement boundary |
| `fewFactory` | immutable | Underlying token -> FewToken lookup |
| `fewV2Factory` | immutable | FewToken pair lookup |
| `weth` | immutable | Native ETH normalization |
| `feeRecipient` | immutable | Destination for permissionless dust sweep |
| `uniBurner` | immutable | Destination for 5 bps protocol-fee skim |
| `defaultConnector0..5` | immutable | Fixed FewToken connector set for empty-hookData default routing and calldata-route intermediates |
| `PROTOCOL_FEE_BPS` | constant = 5 | 5 bps fee forwarded to TokenJar through `RingUniBurner`; Firepit handles downstream UNI burn |

There is no setter for any of the above.

### 3.2 Mutable State

The hook has one internal mutable mapping:

```solidity
mapping(address => mapping(address => bool)) internal _approved;
```

This is a gas optimization for one-time max approvals from underlying tokens to FewToken wrappers. It is not externally writeable and does not encode routing, governance, fee policy, or permissions.

### 3.3 Privileged Roles

`RingAggregatorHook` has no privileged role.

The only privileged role in the system is `RingUniBurner.owner`, which lives in a separate adapter contract. Its powers are intentionally bounded:

| Function | Contract | Caller | Blast radius |
|---|---|---|---|
| `setFlushPaused(bool)` | `RingUniBurner` | owner | Stop/resume forwarding accrued fees to TokenJar |
| `emergencyWithdraw(token, to)` | `RingUniBurner` | owner | Rescue accrued fees or stuck ERC20s from the burner |

`RingUniBurner` never controls user funds in the hook. It only receives the 5 bps accrued fee after a swap has already completed its FewV2 execution.

---

## 4. Hook Permissions

The hook enables exactly the v4 callbacks it needs:

| Permission | Enabled | Reason |
|---|---:|---|
| `beforeInitialize` | yes | Validate pool fee, reject wrap pairs, require canonical FewToken endpoints |
| `beforeSwap` | yes | Run the aggregator swap and return delta |
| `beforeSwapReturnDelta` | yes | Settle the swap inside the hook |
| `beforeAddLiquidity` | yes | Revert all attempts to add v4 liquidity |
| All other permissions | no | Not needed |

`beforeAddLiquidity` always reverts with `LiquidityNotAllowed`. Liquidity for these markets lives in FewV2, not in the v4 shell pool.

---

## 5. Pool Initialization

`_beforeInitialize` is a fail-closed admission check.

It requires:

1. `key.fee != 0`
2. The pool is not a direct underlying/FewToken wrap pair
3. `fewFactory.getWrappedToken(token0)` and `fewFactory.getWrappedToken(token1)` both exist

If any condition fails, the pool cannot be initialized under this hook.

This is important because there is no later admin route registration step. A pool is admitted only if both endpoints have canonical FewTokens. Direct and fixed-connector pair existence is checked at quote/swap time, so pools can become routeable when FewV2 liquidity is created without any hook admin action.

---

## 6. Routing Model

### 6.1 Empty `hookData`: Default Auto-Route

For a pool `(tokenA, tokenB)`, the hook derives the route every time:

```text
fewA = fewFactory.getWrappedToken(tokenA)
fewB = fewFactory.getWrappedToken(tokenB)
```

With empty `hookData`, the hook compares:

```text
tokenA -> fewA -> pair(fewA/fewB) -> fewB -> tokenB
tokenA -> fewA -> pair(fewA/connector) -> connector -> pair(connector/fewB) -> fewB -> tokenB
```

using exactly 6 deploy-time immutable connectors:

```text
fwWETH, fwWBTC, fwUSDC, fwUSDT, fwDAI, fwUSDR
```

Exact-input chooses the highest gross FewToken output. Exact-output chooses the lowest required input for the grossed-up target. Direct is evaluated first and wins ties.

### 6.2 Non-Empty `hookData`: Explicit Bounded Route

Non-empty `hookData` decodes as:

```solidity
abi.encode(address[] fewPath, uint256 amountLimit)
```

The hook accepts the path only if:

- first/last FewToken match the PoolKey endpoints
- every FewToken is canonical through `fewFactory`
- every intermediate is in the fixed connector set
- tokens and pairs are not duplicated
- pairs are derived from immutable `fewV2Factory`
- calldata-route `amountLimit` enforces min output or max input

Callers supply path intent, never pair addresses.

### 6.3 Why Routing Is Bounded

Earlier designs explored owner-managed custom routes. That design was removed. The ownerless calldata-route build allows extra routing surface only where it stays bounded:

- The default connector set is immutable and canonical-checked at construction.
- Empty-hookData route search is exactly direct + 6 one-connector candidates.
- Calldata intermediates cannot be arbitrary assets.
- There is no governance key capable of selecting a malicious route.
- `beforeSwap` loops are bounded by the fixed connector set and duplicate-token rejection.

The tradeoff is explicit: this improves Uniswap frontend/default-router reach without recreating an admin route book.

---

## 7. Swap Flow

### 7.1 Exact Input

For `amountSpecified < 0`:

```text
amountIn = uint256(-amountSpecified)
take input from PoolManager
wrap input -> fewIn
swap fewIn -> fewOut on one FewV2 pair
fee = fwOutAmount * 5 / 10_000
transfer fee to RingUniBurner
unwrap fwOutAmount - fee -> output token
settle output to PoolManager
return BeforeSwapDelta(+amountIn, -amountOut)
```

The user receives the FewV2 output after the 5 bps skim.

### 7.2 Exact Output

For `amountSpecified > 0`:

```text
amountOut = uint256(amountSpecified)
fwOutGross = ceil(amountOut * 10_000 / 9_995)
fwInRequired = FewV2Math.getAmountIn(fwOutGross, reserves)
take input from PoolManager
wrap input -> fewIn
swap fewIn -> fewOut
skim 5 bps
unwrap user output
require actualOut >= amountOut
settle exactly amountOut
return BeforeSwapDelta(-amountOut, +amountIn)
```

The gross-up is the key invariant: exact-output users still receive the requested output after the fee skim.

---

## 8. Fee Path Into TokenJar

`PROTOCOL_FEE_BPS = 5` is a compile-time constant.

The fee is taken in the output FewToken and transferred to `RingUniBurner`. The burner:

1. Accepts FewToken balances passively
2. Lets anyone call `flush(fewToken)`
3. Verifies the FewToken via `fewFactory`
4. Unwraps FewToken 1:1 to the underlying ERC20
5. Pushes the underlying ERC20 to Uniswap's canonical `TokenJar`

The hook never swaps for UNI and never burns UNI itself. It feeds Uniswap's protocol-fee pipeline: Ring pushes underlying tokens to TokenJar, and Uniswap's Firepit/releaser layer handles downstream UNI burn according to Uniswap governance.

`RingUniBurner` is intentionally shaped as a small TokenJar push-source adapter. A key audit question is whether this adapter conforms to Uniswap's fee-adapter model: canonical token validation, no self-rolled swap, no self-rolled burn, and final transfer into the immutable chain TokenJar.

`uniBurner` is immutable in the hook. If a future TokenJar migration requires a new adapter, the hook is redeployed rather than rotated in place. The current V1 keeps `RingUniBurner.emergencyWithdraw` as a narrow operational escape hatch for accrued fees. A future V2 may remove that function to make the burner closer to fully ownerless, accepting the tradeoff that TokenJar migrations or wrapper breakage could strand fee balances.

---

## 9. Sweep And Dust

`sweep(address token)` is permissionless. It sends the full balance of `token` to immutable `feeRecipient`.

This function exists for:

- Forced native ETH
- Rounding dust
- Accidental token transfers

It is not a governance withdrawal path because the destination is fixed forever. Anyone can trigger it; nobody can redirect it.

---

## 10. External Calls And Failure Modes

External calls in the hook are limited to:

| Target | Use | Guard |
|---|---|---|
| `PoolManager` | take/settle | v4 callback boundary |
| `WETH9` | native ETH wrap/unwrap | immutable address |
| `FewToken` | wrap/unwrap | factory-derived address, exact 1:1 return check |
| `FewV2Pair` | quote, swap, and reserves | factory-derived pair, token-shape check, reserve sentinel |
| ERC20 tokens | transfer/approve | `SafeERC20` |
| `uniBurner` | transfer fee | immutable address |
| `feeRecipient` | sweep native ETH | immutable address |

Key fail-closed checks:

- Constructor rejects zero addresses
- `onlyPoolManager` comes from the pinned Uniswap v4-periphery `BaseHook`
- `nonReentrant` covers swap and sweep
- `WrapMismatch` and `UnwrapMismatch` reject non-1:1 wrapper behavior
- `InvalidRouteIntermediate` rejects hidden calldata intermediates outside the fixed connector set
- `DuplicateRouteToken` / `DuplicateRoutePair` reject cycles
- `TokenMismatch` rejects pairs whose token layout does not match the route
- `DegeneratePair` rejects pairs at or below the minimum reserve sentinel
- `ExactOutputUnderfilled` rejects fee or rounding underfills

---

## 11. Event Surface

`RingAggregatorHook` emits:

| Event | Meaning |
|---|---|
| `SwapAggregated` | Swap telemetry: pool, router, origin, direction, specified amount, input, output, gross FewToken output |
| `UniFeeAccrued` | 5 bps FewToken fee transferred to `RingUniBurner` |
| `Sweep` | Permissionless sweep to immutable `feeRecipient` |

`RingUniBurner` emits:

| Event | Meaning |
|---|---|
| `Flushed` | FewToken unwrapped and pushed to TokenJar |
| `FlushPausedSet` | Owner toggled fee forwarding |
| `EmergencyWithdrawn` | Owner rescued accrued fees or stuck ERC20s |
| `OwnershipTransferStarted` / `OwnershipTransferred` | Inherited `Ownable2Step` ownership flow |

There are no hook admin-route events, pause events, fee-update events, or ownership events because the hook has none of those mechanisms.

---

## 12. Auditor Checklist

The highest-value review targets are:

1. `BeforeSwapDelta` signs and settlement ordering
2. Exact-output fee gross-up and rounding
3. Empty-hookData best-route selection and exact-output backward quoting
4. Calldata-route endpoint, connector, duplicate-token, and duplicate-pair validation
5. FewV2 reserve and token-shape validation
6. Native ETH / WETH edge cases
7. Sweep semantics and forced ETH
8. `RingUniBurner.flush` validation, TokenJar fee-adapter conformance, and emergency-owner blast radius
9. Whether any unexpected external call can reenter despite `nonReentrant`
10. Whether the ownerless trust model is fully reflected in deployment and monitoring docs

Known accepted risks are documented in `KNOWN_ISSUES.md`; Slither triage is in `docs/SLITHER_TRIAGE.md`; coverage is in `docs/TEST_COVERAGE.md`.

---

## 13. Deployment Model

The deployer must:

1. Deploy `RingUniBurner` with chain-specific TokenJar, `fewFactory`, and a Gnosis Safe + timelock owner
2. Mine a hook address with the required v4 permission bits
3. Deploy `RingAggregatorHook` with immutable factory, WETH, fee recipient, and burner addresses
4. Run post-deploy assertions on all immutables and permissions
5. Initialize pools whose endpoints have canonical FewTokens
6. Submit the audited hook for router/hooklist inclusion

No post-deploy hook configuration exists. Changing factories, fee sink, fee recipient, or connector set requires a new hook deployment and routing-layer migration.

---

## 14. Audit Readiness

As of this update:

- Build: green
- Tests: 88/88 passing
- Coverage: regenerated from `forge coverage --ir-minimum --report lcov`
- Slither: 22 findings triaged as false positive / by-design; 0 real findings
- Governance surface: hook has none
- Residual key: only `RingUniBurner.owner`, documented separately

The code is ready for third-party audit from a scope-definition perspective. The primary remaining work before production is external: auditor sign-off, deployment ceremony, and router/hooklist review.
