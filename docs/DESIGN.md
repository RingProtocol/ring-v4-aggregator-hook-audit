# Ring V4 Aggregator Hook - Ownerless Direct-Only Design

> Last updated: 2026-06-19
> Deployment target: `audit-router-compat-aggregator-interface`
> Status: implementation complete; 83/83 tests passing; Slither triaged; coverage regenerated

---

## 1. Executive Summary

`RingAggregatorHook` exposes existing Ring FewV2 liquidity as Uniswap v4 pools without moving liquidity into v4.

The hook owns a v4 `PoolKey`, but the v4 pool holds zero LP inventory. On every swap it:

1. Takes the input token from `PoolManager`
2. Wraps it 1:1 into the corresponding FewToken
3. Swaps through the direct FewV2 pair
4. Skims 5 bps of the gross FewToken output to `RingUniBurner`
5. Unwraps the remaining FewToken output back to the requested underlying token
6. Settles the output back to `PoolManager` with `BeforeSwapDelta`

The hook is ownerless: no owner, no pause, no upgrade, no route registry, no connector whitelist, no fee setter, and no burner rotation.

---

## 2. Purpose

Without the hook, a user who wants to trade `ETH -> USDC` through Ring liquidity would need to understand the FewToken path:

```text
ETH -> fwETH -> fwUSDC -> USDC
```

The hook collapses that into one v4 pool from the router's perspective:

```text
Universal Router
  -> PoolManager.beforeSwap
  -> RingAggregatorHook
  -> FewToken.wrap
  -> FewV2 direct pair swap
  -> RingUniBurner fee skim
  -> FewToken.unwrap
  -> PoolManager settlement
```

The hook is an adapter over existing liquidity, not a new AMM.

---

## 3. Immutable Trust Model

| Field | Mutability | Purpose |
|---|---:|---|
| `poolManager` | immutable | Uniswap v4 settlement boundary |
| `fewFactory` | immutable | underlying token -> FewToken lookup |
| `fewV2Factory` | immutable | FewToken pair lookup |
| `weth` | immutable | native ETH normalization |
| `feeRecipient` | immutable | destination for permissionless dust sweep |
| `uniBurner` | immutable | destination for 5 bps fee skim |
| `PROTOCOL_FEE_BPS` | constant = 5 | 5 bps fee forwarded to TokenJar through `RingUniBurner` |

The only mutable state in the hook is an internal approval cache:

```solidity
mapping(address => mapping(address => bool)) internal _approved;
```

It is a gas optimization. It does not encode routing, permissions, or governance.

---

## 4. Privileged Roles

`RingAggregatorHook` has no privileged role.

The only privileged role in the system is `RingUniBurner.owner`, on a separate fee adapter. It can pause flushes or emergency-withdraw assets held by the burner. Its worst-case scope is accrued protocol fees sitting in the burner, never user swap funds held by the hook or PoolManager.

Production requirement: transfer `RingUniBurner.owner` to a Gnosis Safe with a timelock before meaningful volume.

---

## 5. Hook Permissions

| Permission | Enabled | Reason |
|---|---:|---|
| `beforeInitialize` | yes | Validate fee, reject wrap pairs, require canonical endpoints and direct FewV2 pair |
| `beforeSwap` | yes | Execute the aggregator swap and return delta |
| `beforeSwapReturnDelta` | yes | Settle the swap inside the hook |
| `beforeAddLiquidity` | yes | Revert all attempts to add v4 liquidity |
| All other permissions | no | Not needed |

`beforeAddLiquidity` always reverts with `LiquidityNotAllowed`.

---

## 6. Pool Initialization

`_beforeInitialize` requires:

1. canonical shell pool parameters: `key.fee == 500` and `key.tickSpacing == 10`
2. The pool is not an underlying/FewToken wrap pair
3. Both endpoints have canonical FewTokens through `fewFactory`
4. The direct FewV2 pair exists through `fewV2Factory`
5. The FewV2 pair has not already been registered by another v4 shell pool

If any condition fails, the pool cannot be initialized under this hook.

---

## 7. Routing Model

The branch is direct-only.

For a pool `(tokenA, tokenB)`, the hook derives:

```text
fewA = fewFactory.getWrappedToken(tokenA)
fewB = fewFactory.getWrappedToken(tokenB)
pair = fewV2Factory.getPair(fewA, fewB)
```

The hook executes only:

```text
tokenA -> fewA -> pair(fewA/fewB) -> fewB -> tokenB
```

`hookData` is ignored for routing. This keeps Universal Router / V4Quoter integrations simple and avoids accidental reverts if a caller passes non-empty hookData.

Multi-hop price improvement is delegated to Uniswap routing. If `A -> X -> B` is best, the router can compose it as two v4 pool hops, and each hop invokes the hook once.

For UniRoute aggregator-hook discovery, initialization stores `poolId -> direct route`,
emits `AggregatorPoolRegistered(poolId)`, and exposes:

- `quote(bool zeroForOne, int256 amountSpecified, PoolId poolId)`
- `pseudoTotalValueLocked(PoolId poolId)`
- `HookSwap(poolId, sender, amount0, amount1, swapFee)`

These functions/events are compatibility surface only. They do not introduce an admin
route setter, connector engine, or user-supplied path.

---

## 8. Swap Flow

### Exact Input

```text
amountIn = uint256(-amountSpecified)
take input from PoolManager
wrap input -> fewIn
swap fewIn -> fewOut through direct FewV2 pair
fee = fwOutAmount * 5 / 10_000
transfer fee to RingUniBurner
unwrap fwOutAmount - fee -> output token
settle output to PoolManager
return BeforeSwapDelta(+amountIn, -amountOut)
```

### Exact Output

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

The gross-up invariant is audit-critical: exact-output users must receive the requested output after the 5 bps skim.

---

## 9. Fee Path Into TokenJar

The hook does not swap for UNI and does not burn UNI. It sends 5 bps of gross output FewToken to `RingUniBurner`.

`RingUniBurner`:

1. Receives FewToken balances passively
2. Lets anyone call `flush(fewToken)`
3. Validates the FewToken through `fewFactory`
4. Unwraps FewToken 1:1 to the underlying token
5. Pushes the underlying token to Uniswap's canonical TokenJar

Uniswap's Firepit / protocol-fee pipeline handles downstream UNI burn.

---

## 10. Sweep And Dust

`sweep(address token)` is permissionless and always sends the full balance to immutable `feeRecipient`.

It exists for forced ETH, rounding dust, or accidental token transfers. It is not a governance withdrawal path because the recipient cannot be changed.

---

## 11. External Calls And Guards

| Target | Use | Guard |
|---|---|---|
| `PoolManager` | take / settle | v4 callback boundary |
| `WETH9` | native ETH wrap / unwrap | immutable address |
| `FewToken` | wrap / unwrap | factory-derived, exact return check |
| `FewV2Pair` | reserves and swap | factory-derived, token-shape check, reserve sentinel |
| ERC20 tokens | transfer / approve | `SafeERC20` |
| `uniBurner` | fee transfer | immutable address |
| `feeRecipient` | sweep ETH | immutable address |

Key fail-closed checks:

- zero-address constructor rejection
- `onlyPoolManager`
- `nonReentrant`
- canonical FewToken lookup
- direct pair derivation
- pair token-shape validation
- reserve sentinel
- exact wrap / unwrap return validation
- exact-output underfill guard

---

## 12. Auditor Checklist

Highest-value review targets:

1. `BeforeSwapDelta` signs and settlement ordering
2. Exact-output fee gross-up and rounding
3. Direct FewV2 pair validation
4. Reserve and token-shape checks
5. `hookData` ignored behavior
6. Native ETH / WETH edge cases
7. Sweep semantics and forced ETH
8. `RingUniBurner.flush` and TokenJar push-source conformance
9. `RingUniBurner.owner` blast radius
10. Reentrancy through token, wrapper, or pair calls

---

## 13. Audit Readiness

- Build: green
- Tests: 83/83 passing
- Source coverage: 241/247 lines = 97.57%; 37/37 functions = 100.00%
- Slither: 8 findings triaged as false-positive / by-design; 0 real issues
- Ring-written production review surface: 502 nSLOC
- Hook governance surface: none
- Residual privileged key: only `RingUniBurner.owner`, documented separately

The code is ready for final deployment review from a scope-definition perspective.
