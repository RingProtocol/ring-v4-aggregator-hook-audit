# Audit Scope

> **For**: external audit firm
> **Prepared by**: Ring Protocol engineering
> **Branch**: `audit-router-compat-aggregator-interface`

> **ABDK coverage boundary**: report v1.1 covers the direct-only core and its reviewed fixes. The later UniRoute compatibility commits `14abfbd...df9752f` are part of this review target but are not covered by that report.

This document defines what should be audited, what is out of scope, and what we have already tested.

---

## 1. Commit And Build

| | |
|---|---|
| **Repository** | `github.com/RingProtocol/ring-v4-aggregator-hook-audit` |
| **Final deployment branch** | `audit-router-compat-aggregator-interface` |
| **Base** | ABDK-reviewed direct-only package plus a later UniRoute aggregator-hook compatibility layer that still requires delta review |
| **Compiler** | Solidity `0.8.26`, `via_ir = true`, optimizer 200 runs, EVM Cancun |
| **Framework** | Foundry |
| **Build** | Ownerless direct-only hook + UniRoute compatibility + 5 bps TokenJar fee adapter |
| **Public audit report** | [`docs/ABDK_Ring_Aggregator_Hook_Audit_Report_v1.1.pdf`](docs/ABDK_Ring_Aggregator_Hook_Audit_Report_v1.1.pdf) |

Clone and test:

```bash
git clone --recurse-submodules git@github.com:RingProtocol/ring-v4-aggregator-hook-audit.git
cd ring-v4-aggregator-hook-audit
git checkout audit-router-compat-aggregator-interface
forge build
forge test --offline --no-match-path "test/fork/*"
ETH_RPC_URL=https://... forge test
```

---

## 2. In Scope

Line counts below are nSLOC: comments, blank lines, tests, scripts, interfaces, docs, and third-party dependencies excluded.

| Contract | nSLOC | Role | Priority |
|---|---:|---|---|
| `src/RingAggregatorHook.sol` | 406 | Direct-only Uniswap v4 hook. Wraps input, swaps through the direct FewV2 pair, skims 5 bps, unwraps output, settles via PoolManager, and exposes UniRoute aggregator-hook compatibility (`AggregatorPoolRegistered`, `HookSwap`, `quote`, `pseudoTotalValueLocked`). Ownerless. | Critical |
| `src/RingUniBurner.sol` | 64 | TokenJar push-source adapter. Unwraps fee FewTokens and forwards underlying tokens to Uniswap TokenJar. Owner-managed. | High |
| `src/lib/FewV2Math.sol` | 32 | V2 `getAmountOut` / `getAmountIn` math used for exact-in and exact-out quoting. | High |

**Total Ring-written production review surface: 502 nSLOC.**

---

## 3. ABI-Only Interfaces

These files are minimal ABI declarations for deployed systems. They contain no implementation logic.

| File | nSLOC | Purpose |
|---|---:|---|
| `src/interfaces/external/IFewFactory.sol` | 4 | `getWrappedToken` lookup only |
| `src/interfaces/external/IFewWrappedToken.sol` | 6 | `token`, `wrap`, `unwrap` only |
| `src/interfaces/external/IFewV2.sol` | 10 | FewV2 factory/pair ABI only |

**Total ABI-only interface surface: 20 nSLOC.**

---

## 4. Dependency Review Only

These are pinned upstream dependencies and should not be billed as Ring-written production logic.

| Dependency | Used for |
|---|---|
| `lib/v4-core` | PoolManager interfaces, hook types, currencies, deltas, SafeCast |
| `lib/v4-periphery` | `BaseHook`, `DeltaResolver`, `HookMiner`, `IWETH9` |
| `lib/openzeppelin-contracts` | `SafeERC20`, `ReentrancyGuard`, `Ownable2Step` |
| `lib/permit2`, `lib/solmate`, `lib/forge-std` | upstream / test / tooling dependencies |

---

## 5. Out Of Scope

| Item | Why out of scope |
|---|---|
| `lib/v4-core` and `lib/v4-periphery` | Official Uniswap code imported from pinned submodules. |
| OpenZeppelin / Solmate / Permit2 / forge-std | Upstream dependencies. |
| Ring Few Protocol wrappers | Separately audited Ring system. The hook checks `wrap` / `unwrap` return values exactly. |
| Ring FewV2 AMM pair/factory | Separately audited Ring system. The hook validates pair token layout and reserves. |
| Uniswap TokenJar / Firepit | Uniswap-governed protocol-fee pipeline. |
| `script/` | Deployment reference only, not production contract logic. |
| `test/` | Executable spec, not production logic. |
| `docs/` | Audit context and threat model, not contract logic. |

---

## 6. What Changed Versus The Calldata-Route R3 Package

This branch removes the route features that were increasing audit surface:

- removed deploy-time connector set
- removed built-in direct-plus-connector route search
- removed explicit calldata path decoding
- removed hook-level route `amountLimit`
- removed duplicate token / duplicate pair path validation
- removed multi-hop execution and backward exact-out loops
- removed connector constructor checks and deploy script connector wiring

The hook now uses only the direct FewV2 pair for each v4 pool. Multi-hop paths are expected to be composed by Uniswap routing as multiple pool hops, for example `A -> X` then `X -> B`.

`hookData` is ignored for routing in this branch. This keeps default router / quoter integrations from needing Ring-specific calldata while avoiding a revert if an integrator passes non-empty hookData.

The router-compatible final branch adds only UniRoute-facing compatibility:

- `AggregatorPoolRegistered(poolId)` emitted during pool initialization
- `HookSwap(poolId, sender, amount0, amount1, swapFee)` emitted during swaps
- `quote(bool zeroForOne, int256 amountSpecified, PoolId poolId)` for direct aggregator quoting
- `pseudoTotalValueLocked(PoolId poolId)` so external FewV2 liquidity is visible to routing
- canonical shell pool enforcement: `fee = 500`, `tickSpacing = 10`
- one v4 shell pool per FewV2 pair to avoid double-counting the same external liquidity

The swap business logic is unchanged: direct-only FewV2 route, no connector engine, no user-supplied path, no route setter, no admin, no pause, no upgrade.

---

## 7. Tests

| Suite | Count | Notes |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 7 | V2 math and rounding |
| `test/unit/RingUniBurner.t.sol` | 16 | TokenJar adapter, owner-only paths, pause, unknown FewToken rejection, native ETH rescue |
| `test/invariant/RingAggregatorHookInvariants.t.sol` | 5 | Fee math, exact-output gross-up, reserve sentinel |
| `test/fork/RingAggregatorHookFork.t.sol` | 55 | Mainnet fork with real Ring factories, FewTokens, FewV2 pairs, V4Quoter, aggregator quote, pseudo TVL, TokenJar path, and adversarial cases |
| **Total** | **83** | 100% passing |

Covered adversarial cases include direct hook calls, bad initialization, no direct pair, wrap/unwrap mismatch, pair token mismatch, degenerate reserves, forced ETH, permissionless sweep, sweep reentrancy, fee skim correctness, and end-to-end TokenJar forwarding.

---

## 8. Static Analysis And Coverage

| Artifact | Result |
|---|---|
| [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md) | Current local Slither run: 7 outputs, all triaged |
| [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) | Test matrix: 83/83 passing |

---

## 9. Trust Model

1. `RingAggregatorHook` has no owner, no admin function, no pause, no upgrade, and no mutable route setter.
2. Each v4 pool requires canonical FewToken endpoints, canonical fee/tick spacing, and a direct FewV2 pair at initialization.
3. During swap, the route is read from initialization-time registration and remains bound to immutable `fewFactory` / `fewV2Factory`; callers never supply pair addresses.
4. User slippage is enforced by the Uniswap router around the v4 swap. Direct `PoolManager` callers are using a low-level interface and accept their own slippage risk.
5. `RingUniBurner.owner` is the only privileged role and is isolated to accrued protocol fees held by the burner.

---

## 10. Questions For Auditors

1. Are `BeforeSwapDelta` signs and PoolManager settlement correct for exact-in and exact-out, both directions?
2. Is exact-output gross-up for the 5 bps fee free of an under-quote edge case?
3. Does direct pair validation fully prevent fake FewTokens, fake pairs, pair token mismatch, and reserve-edge failures?
4. Does ignoring `hookData` introduce any integration or security concern for Universal Router / V4Quoter / UniRoute usage?
5. Is the hook genuinely ownerless with no hidden route-control, pause, fee-control, or upgrade surface?
6. Can any external token, wrapper, pair, or callback path reenter despite `nonReentrant`?
7. Can the 5 bps fee transfer to immutable `uniBurner` be griefed or used to affect user settlement?
8. Is `RingUniBurner.owner` correctly scoped to accrued protocol fees and unable to reach user swap funds?
9. Does `RingUniBurner` fit Uniswap's TokenJar push-source / fee-adapter model?
10. Is the UniRoute compatibility layer (`quote`, `pseudoTotalValueLocked`, canonical pool registration) correctly read-only / event-only around the unchanged swap path?
11. Which changes are required to align with the current official `BaseAggregatorHook`, `IFeeClassifiedHook`, protocol-fee family, and first-byte address-ID system?
12. Would the candidate's fixed 5 bps skim overlap with the current PoolManager classified-hook protocol fee, and what single fee path should be retained?

---

## 11. Deliverables Needed

1. Public PDF report suitable for Uniswap hooklist / routing allowlist review.
2. Findings as GitHub issues or in the agreed audit channel.
3. One post-fix re-review pass.
