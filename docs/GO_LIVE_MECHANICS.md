# Go-Live Mechanics — How a Uniswap User Ends Up Trading Against FewV2

> **Audience**: anyone who needs the mental model for *how the hook actually gets used*.
> Answers the recurring question: "after audit + merge, what do **we** do, what do **users** do,
> and do we need to add liquidity?"
>
> **Companion doc**: [`DEPLOYMENT_FLOW.md`](DEPLOYMENT_FLOW.md) is the project timeline / cost /
> PR-submission process (the *when* and *who*). This doc is the *mechanism* (the *how* and *why*).

---

## TL;DR

```
We do ONE on-chain action per pair:  PoolManager.initialize(poolKey)   ← creates an empty shell pool
We do NOT add liquidity.             (the hook blocks it on purpose)
Users do NOTHING new.                They swap on app.uniswap.org as always.

Once the hook is on Uniswap's routing-api allowlist and classic routing considers this
hook address, the router can quote our pool with empty `hookData`. If FewV2's direct
or fixed-connector quote is best, the user's swap silently executes against FewV2.
The user never sees "Ring", never picks a hook, never adds liquidity.
```

---

## 1. The core concept: a zero-liquidity shell pool

This is the single idea that confuses everyone first. **Our V4 pool holds no liquidity and never will.**

### Normal V4 pool

```
user swap → PoolManager runs AMM math against the pool's own reserves → done
```

A normal pool *must* have liquidity added before anyone can swap. No liquidity → no trade.

### Our hook pool

```
user swap → PoolManager calls hook.beforeSwap()
         → hook intercepts the ENTIRE swap, routes it through FewV2 itself
         → hook tells PoolManager "handled it: user paid X, give them Y"
         → PoolManager NEVER runs its own AMM math
```

The V4 pool is a **shell / entry point**. Its only job is to make the pair
"ETH/USDC + our hook address" exist so the router can find it. The actual liquidity
lives in the FewV2 pair, and the hook reaches into FewV2 on every swap.

| | Normal pool | Our hook pool |
|---|---|---|
| Needs liquidity added? | Yes | **No** |
| Where does liquidity live? | In the pool | **In the FewV2 pair** |
| Who runs the pricing math? | PoolManager (AMM) | **The hook (routes to FewV2)** |
| Can someone add liquidity? | Yes | **No — `beforeAddLiquidity` reverts `LiquidityNotAllowed`** |

---

## 2. The mechanism: `beforeSwapReturnDelta`

The magic is one permission flag the hook declares:

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeSwap: true,
        beforeSwapReturnsDelta: true,  // ← "I will take over the entire swap"
        beforeAddLiquidity: true,      // ← used to BLOCK liquidity adds
        beforeInitialize: true,        // ← used to validate canonical FewToken endpoints
        ...
    });
}
```

When `beforeSwapReturnsDelta == true`, PoolManager's behavior changes:

- **Normal pool**: PoolManager computes the AMM price, moves the tick, updates reserves.
- **Our pool**: PoolManager **skips all AMM logic** and uses whatever `BeforeSwapDelta`
  the hook returns as the final settlement.

The hook returns:

```solidity
// "user paid amountIn, I delivered amountOut"
BeforeSwapDelta swapDelta = toBeforeSwapDelta(
    (-params.amountSpecified).toInt128(),   // hook consumed the full input
    -amountOut.toInt256().toInt128()         // hook provided the full output
);
return (IHooks.beforeSwap.selector, swapDelta, 0);
```

PoolManager settles on that delta and never asks where the liquidity came from.
Internally the hook did: `tokenIn → fewToken.wrap → direct-or-connector FewV2 route → fewToken.unwrap → tokenOut`.

---

## 3. The minimal on-chain action: `initialize` ≠ add liquidity

These are two different operations. We do the first, never the second.

| Operation | What it does | Do we do it? |
|---|---|---|
| `PoolManager.initialize(poolKey, price)` | **Creates** the pool — registers "this pair + this hook exists" | ✅ Yes, once per pair |
| `modifyLiquidity(...)` (add liquidity) | Deposits tokens as LP reserves | ❌ No — and the hook reverts it anyway |

One transaction per pair we want to support:

```solidity
IPoolManager(V4_PM).initialize(
    PoolKey({
        currency0: Currency.wrap(address(0)),   // ETH
        currency1: Currency.wrap(USDC),
        fee: 3000,                               // 30 bps — a routing LABEL, not a real charge
        tickSpacing: 60,
        hooks: IHooks(<our hook address>)
    }),
    INIT_PRICE
);
```

`beforeInitialize` validates that both endpoints have canonical FewTokens. The actual
FewV2 route is checked at quote/swap time: empty `hookData` tries the direct pair plus
the fixed connector set (`fwWETH`, `fwWBTC`, `fwUSDC`, `fwUSDT`, `fwDAI`, `fwUSDR`);
if none is available, the quote/swap reverts `NoFewV2Route`.

Initialize one pool per pair we want live:

- ETH/USDC — fwETH/fwUSDC pair exists ✅
- ETH/WBTC — direct fwETH/fwWBTC or a fixed-connector route such as fwETH/fwUSDC/fwWBTC
- USDC/DAI — direct fwUSDC/fwDAI or a fixed-connector route
- … etc.

**Why `initialize` is necessary at all**: the router discovers tradable pairs by indexing
PoolManager's `Initialize` events. No `initialize` → no event → the router never knows
we exist. After `initialize`, the pool is live but holds zero liquidity — because the
hook intercepts every swap and uses FewV2's liquidity instead.

---

## 4. What WE do vs what USERS do

```
WE (one-time setup, via deploy script):
  1. deploy hook + RingUniBurner
  2. PoolManager.initialize(poolKey)  for each pair      ← the only required on-chain action
  3. submit to Uniswap hooklist                          ← registry listing
  4. apply to routing-api allowlist                      ← the gate that turns on traffic

USERS (nothing new — exactly what they already do):
  • open app.uniswap.org
  • type "swap 1 ETH → USDC"
  • click Swap
  → router silently routes through our hook if FewV2's price wins
```

Users never: see the hook address, choose a hook pool, add liquidity, or know Ring
was involved. It is completely transparent.

---

## 5. Two lists, do not confuse them: hooklist ≠ routing-api allowlist

This is the most common misunderstanding. Getting into the hooklist does **not** get you traffic.

| | `Uniswap/hooklist` | `Uniswap/routing-api` allowlist |
|---|---|---|
| What it is | Public registry of all known V4 hooks ("yellow pages") | The per-chain list of hooks the router is *allowed to route through* |
| Effect | Discoverability / catalog only | **Turns on actual user traffic** |
| How to get in | Open an issue (chain + hook address); their Claude Code workflow analyzes source, opens a PR, maintainer merges | Submit the allowlist PR / form with audit report + metrics |
| Audit required? | No (optional metadata) | **De facto yes** — the router won't allowlist an unaudited hook that front-end users implicitly trust |
| Traffic if listed here only? | **None** | **Yes** |

So the order is: deploy → initialize → hooklist (registry) → **routing-api allowlist (the real gate)**.

---

## 6. End-to-end user flow (after allowlist approval)

```
1. user opens app.uniswap.org, enters ETH → USDC
2. routing-api queries every available pool (V2, V3, V4, V4+hooks)
3. our hook pool is in the candidate set (because it's allowlisted)
4. routing-api / V4Quoter calls our hook's quote with empty `hookData`
   → hook computes the best direct-or-fixed-connector output via FewV2
5. if our quote is best (whole route OR one leg of a split), the swap is routed to us
6. user's swap executes: tokenIn → wrap → FewV2 swap → unwrap → tokenOut
7. 5 bps of output is skimmed to RingUniBurner -> TokenJar; Firepit handles downstream UNI burn
8. user receives tokenOut — completely unaware Ring/FewV2 was involved
```

```
WE do:    deploy hook → initialize pools → submit hooklist → apply allowlist / routing merge
                                                                    ↓
                                                            allowlist approved
USER (auto):  app.uniswap.org → router finds our pool → quote best? → swap → FewV2
```

---

## 7. Reality check: allowlist ≠ volume

Being allowlisted only makes us *eligible*. The router still picks the best price every time,
so we only win the trades where FewV2's quote actually beats the alternatives.

| Factor | Our situation |
|---|---|
| Our cost | FewV2 pair price: 30 bps LP fee + 5 bps protocol fee = **35 bps** total |
| Competition | V3 ETH/USDC 0.05% pool (5 bps), native V4 pools |
| Where we win | **Large swaps** ($100K+) where FEW amplification makes effective depth deeper than V3 concentrated liquidity → smaller slippage |
| Where we lose | **Small swaps** — we almost never beat a 5 bps V3 pool on a $1K trade |

The practical takeaway: don't expect to win small trades. The edge is large-size routing,
where FewV2's amplified depth produces less slippage than a comparable concentrated-liquidity
pool.

---

## 8. Supporting tasks (not on the critical path, but required for a healthy launch)

| Task | Why |
|---|---|
| Etherscan verify the contracts | hooklist's automated source analysis needs verified source |
| Subgraph / indexer support | so our pool's swap events are indexed and visible |
| ring.exchange front-end integration | serve swaps through our own front-end too, independent of Uniswap |
| Keeper bot for `RingUniBurner.flush()` | periodically push the 5 bps skim to TokenJar |
| Monitoring | deploy Tenderly / Etherscan / Defender alerts before mainnet |
| Multi-chain expansion | hooklist supports Base, Arbitrum, etc. — if FewV2 is deployed there, replicate this same flow |

---

## One-sentence summary

We run `initialize` once per pair (no liquidity, ever), get the exact hook address into
Uniswap's hook/routing allowlist path, and from then on every Uniswap user can
automatically trade against FewV2 whenever its empty-hookData quote is best — with zero
action and zero awareness on their part.
