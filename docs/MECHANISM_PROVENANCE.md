# RingAggregatorHook Mechanism Provenance

> Purpose: explain where each important mechanism comes from, which parts are direct reuse of battle-tested patterns, and which parts are new composition on top of Uniswap v4.
>
> Audience: internal alignment, auditor pre-read, and technical due diligence.
>
> Summary: the ownerless calldata-route build removes the prior admin-controlled multi-hop route registry. The hook has no owner, no pause, no timelock, no admin route registry, and no owner-controlled route whitelist. Routing is now ownerless and bounded: empty `hookData` searches the direct route plus a fixed connector set, while non-empty `hookData` may carry a per-swap bounded path whose intermediates must come from that same connector set. Pair addresses are always derived from the immutable `fewV2Factory`.

---

## 1. Comparable Projects

Ring's category is: **zero-liquidity v4 shell pool + full `beforeSwapReturnDelta` absorption + routing to external AMM liquidity**.

| Project | Architecture | External liquidity | Routing model | Audit / validation | Status |
|---|---|---|---|---|---|
| **EulerSwap** | Zero-liquidity v4 pool + full delta absorption | Euler lending vaults / JIT borrowing | Fixed at pool creation | Spearbit + OpenZeppelin + Certora reviews | Mainnet, large production volume |
| **Uniswap Aggregator Hook (Tempo)** | Zero-liquidity v4 pool + full delta absorption | Tempo native stablecoin DEX | Fixed Tempo DEX route | Uniswap Labs internal review | Mainnet on Tempo |
| **RingAggregatorHook** | Zero-liquidity v4 pool + full delta absorption | FewV2 V2-fork AMM | Empty `hookData`: direct + fixed connectors; calldata paths: bounded and factory-derived | Pending external audit | Pre-deploy |

The shared industry pattern is not "single-hop only." The shared pattern is: **do not put route control behind a mutable admin key**. EulerSwap and Tempo bind their external liquidity entry at creation time. Ring binds the liquidity source through immutable factories, a fixed connector set, and live FewV2 pair state. Advanced callers may supply calldata paths, but they cannot supply pair addresses, cannot inject arbitrary intermediates, and cannot modify any global routing state.

The earlier admin design used owner-registered multi-hop routes to cover FewV2 hub-and-spoke paths. This build deletes that owner registry while preserving bounded multi-hop usefulness: default routing considers only direct plus fixed connectors, and explicit calldata paths can only use those same connectors as hidden intermediates. That keeps the Uniswap default-router use case while removing the admin key risk.

---

## 2. Provenance Checklist

### Tier 1: Direct Standard-Library Reuse

| # | Mechanism | Source | Code location | Notes |
|---|---|---|---|---|
| 1 | `ReentrancyGuard` | OpenZeppelin v5 | `import {ReentrancyGuard}` | Direct inheritance |
| 2 | `SafeERC20` / `forceApprove` | OpenZeppelin v5 | `import {SafeERC20}` | Direct library use |
| 3 | `SafeCast` | Uniswap v4-core | `import {SafeCast}` | Direct library use |
| 4 | `BaseHook` + `onlyPoolManager` | Uniswap v4-periphery pattern | `src/utils/BaseHook.sol` | Inlined to pin behavior and avoid dependency drift |
| 5 | `DeltaResolver` take/settle helpers | Uniswap v4-periphery pattern | `src/base/DeltaResolver.sol` | Minimal local helper |
| 6 | Full `beforeSwapReturnDelta` absorption | Uniswap v4 hook interface | `_beforeSwap` return value | Native v4 custom-accounting design |
| 7 | `getAmountOut` / `getAmountIn` math | `UniswapV2Library` formula | `src/lib/FewV2Math.sol` | Same V2 constant-product math and rounding shape |
| 8 | `Ownable2Step` for the burner only | OpenZeppelin v5 | `RingUniBurner.sol` | The hook itself is ownerless; only the fee adapter has an owner |

### Tier 2: Mature Patterns With Clear Precedent

| # | Mechanism | Precedent | Validation history | Code location |
|---|---|---|---|---|
| 9 | `renounceOwnership()` override that reverts, burner only | OpenZeppelin community practice / audit checklists | Multi-year standard | `RingUniBurner.sol` |
| 10 | Direct V2 pair interaction: transfer token in, call `pair.swap()` | 1inch UnoswapRouter, Uniswap V2SwapRouter, MEV searchers | 5+ years of aggregator practice | `_executeFewV2Hop` |
| 11 | Fixed basis-point fee skim | DEX protocol-fee patterns | Standard DEX practice | `_skimUniBurnFee` |
| 12 | Constructor zero-address checks | Audit checklist standard | Standard defensive practice | Constructors |
| 13 | CREATE2 deterministic deployment and salt mining | Standard v4 hook deployment flow | v4 ecosystem standard | `script/MineHookAddress.s.sol` |
| 14 | TokenJar -> Firepit downstream fee pipeline | Uniswap protocol-fees architecture | Uniswap-governed infrastructure | `RingUniBurner.sol` |
| 15 | Zero-liquidity shell pool, liquidity modification reverted | v4 custom-accounting / aggregator-hook pattern | v4 production pattern | `_beforeAddLiquidity` |
| 16 | Minimum-reserve sentinel at 1000 wei | Uniswap V2 `MINIMUM_LIQUIDITY = 1000` | 5+ years of V2 invariant history | Hop reserve checks |
| 17 | `receive() external payable` | Standard Solidity ETH receive pattern | Standard | Hook receive function |
| 18 | Wrap/unwrap return-value equality checks | Defensive integration against lying external contracts | Standard audit hardening | `_wrap` / `_unwrap` |

### Tier 3: Mature Pattern, Conservative Variant

| # | Ring implementation | Precedent | Ring variant | Risk assessment |
|---|---|---|---|---|
| 19 | Permissionless sweep with immutable destination | Uniswap V3 `PeripheryPayments.sweepToken` | Caller can trigger sweep, but cannot choose recipient | Lower recipient-risk surface than caller-selected sweep |
| 20 | Approval cache with `_approved[token][spender]` | Router approval helpers and max-approval patterns | Boolean cache after max approval; spenders are canonical fewTokens or derived pairs | Acceptable because swaps are atomic and the hook keeps no idle funds by design |
| 21 | Immutable liquidity source factories | Universal Router-style immutable trust wiring | Factory migration requires a new hook deployment | Removes governance attack surface |

### Tier 4: New v4 Composition From Standard Parts

| # | Mechanism | Assessment |
|---|---|---|
| 22 | `wrap -> bounded FewV2 route -> fee skim -> unwrap` as a full v4 custom-accounting hook | Each part is known; the composition is Ring's integration work. Audit focus: end-to-end accounting, exact-output gross-up, route selection, and hook deltas. |
| 23 | Fixed connector set plus calldata-path on-chain validation | The sub-mechanisms are standard: fixed candidate set, canonical token validation, factory-derived pairs, duplicate token/pair rejection, and caller slippage. Audit focus: boundedness and edge cases. |
| 24 | v4 hook fee push into TokenJar via a dedicated adapter | TokenJar accepts push-source fees; using a v4 hook as a push source is new because v4 hooks are new, but both sides of the pipeline are standard components. |

---

## 3. What Ownerless Removed

The earlier admin version's hardest mechanism to justify was the owner-controlled multi-hop route registry (`proposeRoute` / `executeProposedRoute` plus a timelock and approved-intermediate list). Governance timelocks are a known pattern, but using them to control hot-path swap routing was still an avoidable risk.

The ownerless calldata-route build deletes that admin surface. It also removes hook-level `Ownable2Step`, global swap pause, hook-level `renounceOwnership` overrides, `uniBurner` rotation, and mutable global route registration.

The result:

1. **No admin-controlled route mechanism remains.** The remaining route surface is fixed connectors plus per-transaction calldata-path validation. Bad calldata can affect the caller's own transaction, not global state.
2. **Governance attack surface is zero inside the hook.** There is no owner, no pause, no upgrade, no route setter, no fee setter, and no burner setter. The only residual key is the `RingUniBurner.owner`, and that key is outside the swap path and bounded to accrued fee balances.

Bounded multi-hop is retained because the product goal requires V4Quoter and Uniswap default-routing compatibility under empty `hookData`. The hook compares direct plus six immutable connector candidates by itself. Advanced calldata paths are still constrained to the same connector set and factory-derived pairs. This is easier to audit than an admin route book: no global state changes, no owner updates, no caller-supplied pair addresses.

---

## 4. Auditor Positioning

RingAggregatorHook belongs to the v4 aggregator-hook category:

> Zero-liquidity virtual pool + `beforeSwapReturnDelta` full absorption + routing to external liquidity.

The build uses standard components and removes the custom admin route registry from the earlier design:

- **Permissions:** the hook has no owner, no pause, and no upgrade path. This follows the same immutable-router philosophy as Universal Router. The only owner is on the separate `RingUniBurner` fee adapter.
- **Hook base:** local `BaseHook` and `DeltaResolver` follow v4-periphery patterns.
- **AMM math:** V2 constant-product math matches the `UniswapV2Library` shape.
- **Route execution:** direct V2 pair interaction follows 1inch / Uniswap router practice; route candidates are bounded.
- **Liquidity source:** `fewFactory` and `fewV2Factory` are immutable.
- **Fee pipeline:** the hook pushes fees into a TokenJar adapter; Uniswap's Firepit/releaser layer handles downstream UNI burn.

Compared with the earlier admin build, this version removes the only governance-heavy route mechanism and all hook-owner powers. Routing is determined by immutable factories, a fixed connector set, caller-provided per-transaction calldata when present, and live on-chain pair state.

**Custom admin/governance mechanisms: zero.** The route composition itself is Ring integration work on a new v4 platform and is decomposed above into auditable sub-mechanisms.

---

*Document version: 2026-05-25. Based on the ownerless calldata-route audit build.*
