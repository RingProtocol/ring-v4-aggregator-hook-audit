# Ring V4 Aggregator Hook - Direct-Only Rationale

> Last updated: 2026-05-29
> Audience: auditor, reviewer, protocol engineer

---

## 1. TL;DR

This branch makes the hook smaller by removing the in-hook route engine. The hook now executes only the direct FewV2 pair for the v4 pool endpoints.

```text
input token -> FewToken.wrap -> direct FewV2 pair -> skim 5 bps -> FewToken.unwrap -> output token
```

If `A -> X -> B` is a better route, Uniswap routing should compose that as two v4 pool hops. This keeps useful routing available while removing connector search, path decoding, and multi-hop loops from the hook contract itself.

---

## 2. Why Ownerless

The hook is intended to be acceptable to routers and Uniswap-facing review processes. Those reviewers should not need to trust a Ring admin key for the swap path.

`RingAggregatorHook` therefore has:

- no owner
- no pause
- no fee setter
- no route registry
- no connector admin
- no burner rotation
- no upgrade path

If an immutable address or design assumption needs to change, the remedy is redeploy and re-list, not mutate the deployed hook.

---

## 3. Why Direct-Only

The prior calldata-route package solved routing inside the hook. That was powerful, but it increased audit surface:

- connector immutables
- default route search
- path calldata ABI
- hook-level route limits
- duplicate token / pair validation
- multi-hop execution loops
- exact-output backward quote loops

The direct-only branch removes those surfaces.

The product bet is that Uniswap SOR can compose multiple hook pools. For example, if `fwETH/fwUSDC/fwWBTC` is better than `fwETH/fwWBTC`, then routing can call:

```text
ETH -> USDC via hook pool 1
USDC -> WBTC via hook pool 2
```

Each hop still contributes volume to Ring's FewV2 liquidity.

---

## 4. Why Ignore `hookData`

The direct-only branch has no route data to decode. Reverting on non-empty `hookData` would create integration fragility for routers or quoting tools that pass bytes through by default.

Ignoring it is deterministic:

- route is always the direct FewV2 pair
- pair is always derived from immutable `fewV2Factory`
- user-supplied pair/path data is never trusted
- slippage remains a router-level protection

---

## 5. Why No Pause

A pause key would add a governance DoS surface to a contract that does not custody LP inventory.

Failure response should be:

1. Swap reverts through fail-closed checks
2. Router/hooklist delists the pool or hook
3. Ring redeploys a new hook if needed

That response is slower than a pause button, but it avoids adding a privileged key to the swap path.

---

## 6. Why Immutable Factories

`fewFactory` and `fewV2Factory` define the entire liquidity source. If either were mutable, a key could silently redirect all routing.

Immutability gives reviewers a simple invariant:

```text
All FewTokens and FewV2 pairs are derived from these exact factory addresses.
```

Factory migration means a new hook deployment.

---

## 7. Why 5 bps Is Constant

`PROTOCOL_FEE_BPS = 5` is fixed at compile time.

Reasons:

- no fee-governance risk
- simpler exact-output math
- stable audit target
- clear integration expectation
- fee path goes to Uniswap TokenJar / Firepit, not a Ring-controlled burn

---

## 8. Why `RingUniBurner` Is Separate

The hook should not perform UNI swaps or burns. It should only push the fee into Uniswap's fee pipeline.

`RingUniBurner`:

1. Receives FewToken fees
2. Validates the FewToken through `fewFactory`
3. Unwraps it to the underlying token
4. Transfers the underlying token to TokenJar

The burner keeps a limited owner role for pause / emergency rescue of fee balances. That owner cannot affect user swap funds in the hook.

---

## 9. Accepted Tradeoffs

| Decision | Gain | Tradeoff |
|---|---|---|
| Ownerless hook | No governance attack surface in swap path | No hot patching |
| Direct-only routing | Much smaller audit surface | Depends on router-level multi-hop composition |
| Ignore `hookData` | Integration-tolerant default behavior | No advanced path injection |
| Immutable factories | No silent liquidity-source rotation | Factory migration requires redeploy |
| Constant 5 bps fee | Simple math and social commitment | No fee tuning |
| Owner-managed burner | Recovery path for fee adapter issues | Residual key over accrued fees |
| Permissionless sweep | No stuck dust | Recipient fixed forever |

---

## 10. Risk Register

| Risk | Status | Rationale |
|---|---|---|
| Wrong `BeforeSwapDelta` sign | Tested | Fork exact-in / exact-out in both directions |
| No direct pair | Mitigated | Initialization and swap resolution require direct FewV2 pair |
| Exact-output underfill | Mitigated | Fee gross-up plus `ExactOutputUnderfilled` guard |
| Fake FewToken endpoint | Mitigated | Canonical `fewFactory` lookup |
| Fake pair or wrong token layout | Mitigated | Pair derived from factory and token-shape checked |
| Drained pair | Mitigated | Reserve sentinel |
| Wrapper not 1:1 | Mitigated | `WrapMismatch` / `UnwrapMismatch` |
| Reentrancy | Mitigated | `nonReentrant` plus tests |
| Forced ETH / accidental tokens | Mitigated | Permissionless sweep to immutable recipient |
| Burner owner compromise | Accepted | Bounded to accrued fees in `RingUniBurner` |
| Router cannot compose multi-hop hook pools | Integration risk | Not a hook custody risk; should be validated during routing integration |

---

## 11. Test Strategy

| Suite | Purpose |
|---|---|
| `FewV2Math.t.sol` | V2 quote math and rounding |
| `RingUniBurner.t.sol` | Fee adapter, owner paths, pause, unknown FewToken rejection |
| `RingAggregatorHookInvariants.t.sol` | Fee accounting, gross-up, reserve sentinel |
| `RingAggregatorHookFork.t.sol` | Real mainnet factories, FewTokens, FewV2 pairs, V4Quoter, TokenJar |

Current result: 73/73 tests passing.

---

## 12. Coverage

| File | Line coverage | Function coverage |
|---|---:|---:|
| `src/RingAggregatorHook.sol` | 142/144 = 98.61% | 20/20 = 100.00% |
| `src/RingUniBurner.sol` | 26/27 = 96.30% | 5/5 = 100.00% |
| `src/lib/FewV2Math.sol` | 14/14 = 100.00% | 2/2 = 100.00% |

---

## 13. Final Position

This branch is the smaller audit target:

- 395 nSLOC of Ring-written production logic
- no hook owner
- no in-hook connector router
- no calldata path engine
- no user-supplied pair addresses
- one immutable fee
- one immutable fee sink
- one residual owner isolated to the fee adapter

The main remaining review questions are swap accounting, exact-output math, direct pair validation, reentrancy, and whether the TokenJar adapter model is correct.
