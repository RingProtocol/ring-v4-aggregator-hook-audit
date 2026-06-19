# Mechanism Provenance

> Last updated: 2026-06-19
> Branch: `audit-router-compat-aggregator-interface`

This document records where the major mechanisms come from and what is novel.

---

## Summary

The audit branch removes the prior admin-controlled route registry and also removes the later calldata-route / connector router surface. The remaining hook is a direct adapter:

```text
v4 pool endpoint tokens
  -> canonical FewTokens from fewFactory
  -> direct FewV2 pair from fewV2Factory
  -> PoolManager settlement
```

There is no owner, no pause, no upgrade, no mutable route state, and no user-supplied pair address.

The final deployment branch adds UniRoute-facing aggregator-hook compatibility:
pool registration events, swap events, direct `quote`, and `pseudoTotalValueLocked`.
This is a discovery/quoting surface around the same direct FewV2 path, not an
admin-controlled router.

---

## Mechanism Table

| Mechanism | Precedent / category | Ring usage | Audit focus |
|---|---|---|---|
| v4 hook callback model | Uniswap v4 core/periphery | `BaseHook` and `beforeSwapReturnDelta` | Delta signs and settlement ordering |
| Zero-liquidity shell pool | v4 hook design pattern | v4 pool routes to external liquidity | Pool init, no LP assumptions |
| External AMM adapter | Aggregator / adapter pattern | FewV2 direct pair executes swap | External-call ordering |
| Factory-derived pair lookup | Uniswap V2-style pair derivation | Pair comes from immutable `fewV2Factory` | Fake pair / token-shape checks |
| Canonical wrapped token lookup | FEW wrapper system | FewToken comes from immutable `fewFactory` | Fake wrapper prevention |
| Constant protocol fee | Static fee policy | 5 bps gross output skim | Exact-output gross-up |
| TokenJar push source | Uniswap protocol-fee pipeline | `RingUniBurner` unwraps and forwards fees | Adapter conformance |
| Ownerless hook | Immutable router philosophy | No hook admin powers | Hidden privileged path review |
| Permissionless sweep | Dust recovery pattern | Sweep always to immutable recipient | Forced ETH and dust handling |
| Aggregator hook discovery | UniRoute external-liquidity hook pattern | `AggregatorPoolRegistered`, `HookSwap`, `quote`, `pseudoTotalValueLocked` | Routing/indexing compatibility |

---

## What Is Not Novel

- The hook uses official Uniswap v4 callback/periphery patterns.
- The AMM math is standard V2 `getAmountOut` / `getAmountIn`.
- FewV2 pair lookup follows a V2-factory style model.
- Fees are pushed into Uniswap's TokenJar rather than burned by Ring.
- `RingUniBurner` uses OpenZeppelin ownership and reentrancy guards.

---

## What Is Ring-Specific

- The FEW wrapping layer: underlying ERC20s are wrapped to FewTokens before the FewV2 swap and unwrapped after the swap.
- The 5 bps fee is taken in the output FewToken before unwrap.
- The hook maps a v4 pool to an existing direct FewV2 pair.
- The hook enforces one canonical v4 shell pool per FewV2 pair to avoid double-counting external liquidity.

---

## Removed Mechanisms

The current branch deliberately excludes:

- hook owner
- global pause
- route registry
- route timelocks
- connector list
- in-hook route search
- calldata path engine
- fee setter
- fee recipient setter
- burner rotation

The design preference is redeploy-and-relist over dormant admin power.

---

## Audit Implication

Auditors should focus on whether the remaining small adapter is correct:

1. direct pair admission and validation
2. wrap / swap / skim / unwrap ordering
3. exact-output fee gross-up
4. `BeforeSwapDelta` signs
5. reentrancy and callback boundaries
6. `RingUniBurner` owner blast radius

Document version: 2026-06-19. Based on `audit-router-compat-aggregator-interface`.
