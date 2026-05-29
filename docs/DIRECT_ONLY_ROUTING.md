# Direct-Only Routing Model

> Branch: `audit-r3-direct-only-sor`
> Scope: ownerless direct FewV2 pair routing inside the hook

---

## 1. Summary

This branch deliberately removes the in-hook route engine.

For each v4 pool `(tokenA, tokenB)`, the hook derives:

```text
fewA = fewFactory.getWrappedToken(tokenA)
fewB = fewFactory.getWrappedToken(tokenB)
pair = fewV2Factory.getPair(fewA, fewB)
```

The swap then uses exactly that direct FewV2 pair.

If a better price exists through an intermediate token, for example `A -> X -> B`, that route should be composed by Uniswap routing as two v4 pool hops:

```text
Pool 1: A -> X through hook
Pool 2: X -> B through hook
```

This means good FewV2 liquidity is still usable by routing, but the hook itself stays small.

---

## 2. What Was Removed

Compared with the calldata-route R3 package, this branch removes:

- deploy-time connector immutables
- default connector quote search
- explicit `hookData` route decoding
- hook-level route `amountLimit`
- arbitrary per-swap path arrays
- duplicate token / duplicate pair route checks
- multi-hop execution loops
- exact-output backward path loops
- connector constructor checks
- connector deploy script configuration

The result is a smaller contract and a smaller audit surface.

---

## 3. `hookData` Behavior

`hookData` is ignored for routing.

Reason:

- Uniswap / router integrations may pass empty or non-empty hookData depending on their plumbing.
- The direct-only branch has no route data to decode.
- Ignoring hookData avoids accidental integration reverts while preserving deterministic direct-pair routing.

All user slippage protection should be enforced by the router around the v4 swap, through `amountOutMinimum` / `amountInMaximum` style bounds.

---

## 4. On-Chain Validation

The hook still validates the direct path on-chain:

| Check | Purpose |
|---|---|
| Canonical endpoint FewTokens | Prevent fake FewToken endpoints |
| Direct pair exists at initialization | Avoid shell pools without direct FewV2 liquidity |
| Direct pair re-derived at swap time | Prevent caller-supplied pair injection |
| Pair `token0` / `token1` shape check | Prevent fake or mismatched pair layout |
| Reserve sentinel | Reject drained / degenerate pairs |
| Exact wrap / unwrap return checks | Fail closed on wrapper mismatch |
| `nonReentrant` | Close reentrancy through swap and sweep paths |
| `onlyPoolManager` | Reject direct external hook callbacks |

There is no admin-controlled routing state.

---

## 5. Product Tradeoff

Direct-only is not as expressive as an in-hook route engine, but it is easier to audit and explain:

| Direct-only hook | In-hook route engine |
|---|---|
| Smaller code surface | Larger code surface |
| No path decoding | Requires calldata ABI and validation |
| No route loops | Multi-hop quote/execution loops |
| No connector whitelist | Needs connector policy |
| Relies on Uniswap SOR for multi-hop composition | Finds connector routes inside the hook |

The product assumption for this branch is:

> If `A -> X -> B` is better than `A -> B`, Uniswap routing can compose two hook pools and still route volume through Ring liquidity.

Auditors should review this assumption as an integration question, but it is intentionally outside the hook's admin or custody risk.

---

## 6. Test Coverage

The fork suite covers:

- direct route resolution
- pool initialization revert when no direct FewV2 pair exists
- V4Quoter exact-input direct quote
- V4Quoter exact-output direct quote
- non-empty hookData still using the direct route
- exact-input and exact-output swaps in both directions
- no-liquidity v4 pool behavior
- force-fed ETH / sweep behavior
- pair mismatch and degenerate reserve failures
- 5 bps fee skim and TokenJar forwarding

Current result: 73/73 tests passing.
