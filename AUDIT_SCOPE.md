# Audit Scope

> **For**: external audit firm (Spearbit / Cantina / Code4rena / OpenZeppelin / Sherlock)
> **Prepared by**: Ring Protocol engineering

This document defines exactly what to audit, what is out of scope and why, and what we have already done so audit hours are spent on net-new analysis rather than re-deriving context.

---

## 1. Commit & build

| | |
|---|---|
| **Repository** | `github.com/RingProtocol/ring-v4-aggregator-hook-audit` |
| **Build** | The **ownerless calldata-route** hook + 5 bps TokenJar fee pipeline, based on `audit-ownerless-calldata-route-2026-05-25-r3` and simplified to inherit Uniswap v4-periphery helpers directly. No owner, no pause, no admin routes, immutable wiring, empty-hookData default auto-routing over direct + fixed connectors, and bounded calldata paths. The hook does **not** burn UNI itself; it pushes fees into Uniswap's TokenJar via `RingUniBurner`, and Uniswap's Firepit handles downstream UNI burn. |
| **Audit branch** | `audit-r3-uniswap-periphery-helpers` |
| **Base tag** | `audit-ownerless-calldata-route-2026-05-25-r3` |
| **Compiler** | Solidity `0.8.26`, `via_ir = true`, optimizer 200 runs, EVM Cancun |
| **Framework** | Foundry |

There is a **single canonical build** — no 0 bps fallback or multi-branch variants in scope.

Clone:
```bash
git clone --recurse-submodules git@github.com:RingProtocol/ring-v4-aggregator-hook-audit.git
cd ring-v4-aggregator-hook-audit
git checkout audit-r3-uniswap-periphery-helpers
forge build
ETH_RPC_URL=https://… forge test          # 88 tests
forge test --no-match-path "test/fork/*"   # 30 hermetic tests (no RPC needed)
```

---

## 2. In scope (the Ring-written production logic you bill for)

Line counts below are **nSLOC**: comments, blank lines, tests, scripts, interfaces, docs, and third-party dependencies excluded.
NatSpec and security-boundary comments are intentionally retained for reviewer clarity and are not included in the nSLOC totals.

| Contract | nSLOC | Role | Priority |
|---|---:|---|---|
| `src/RingAggregatorHook.sol` | 588 | The V4 hook. Default direct-or-fixed-connector routing, bounded calldata routing, wrap/unwrap, 5 bps fee skim, permissionless sweep. **Ownerless** — no admin, no pause, immutable wiring. | **CRITICAL — primary focus** |
| `src/RingUniBurner.sol` | 54 | TokenJar push-source adapter. Unwraps fewToken → underlying → forwards to Uniswap TokenJar. **Owner-managed** (the only privileged role in the system). | **HIGH** |
| `src/lib/FewV2Math.sol` | 64 | V2 `getAmountOut` / `getAmountIn` (30 bps fee math). | **HIGH** (math correctness) |

**Total Ring-written production review surface: 706 nSLOC.**

---

## 3. ABI-only local interfaces

These are minimal ABI declarations against existing deployed systems. They contain no logic and should not be billed as production logic.

| File | nSLOC | Purpose |
|---|---:|---|---|
| `src/interfaces/external/IFewFactory.sol` | 4 | `getWrappedToken` lookup only |
| `src/interfaces/external/IFewWrappedToken.sol` | 6 | `token`, `wrap`, `unwrap` only |
| `src/interfaces/external/IFewV2.sol` | 10 | FewV2 factory/pair ABI only |

**Total ABI-only interface surface: 20 nSLOC.**

---

## 4. Pinned third-party helpers and libraries (dependency review only)

The repo deliberately imports standard helper code instead of copying it into `src/`. These dependencies are pinned and should be treated as upstream dependency code, not Ring-written production logic.

| Dependency | Commit / source | Used for |
|---|---|---|
| `lib/v4-core` | `59d3ecf5` | PoolManager interfaces, hook types, currencies, deltas, SafeCast |
| `lib/v4-periphery` | `ad04c9f` (`v1.0.2`) | `BaseHook`, `DeltaResolver`, `HookMiner`, `IWETH9` |
| `lib/openzeppelin-contracts` | `dbb6104c` | `SafeERC20`, `ReentrancyGuard`, `Ownable2Step` |
| `lib/permit2`, `lib/solmate`, `lib/forge-std` | pinned submodules | upstream / test / tooling dependencies |

---

## 5. Out of scope (do not bill as Ring production logic)

| Item | Why out of scope |
|---|---|
| `lib/v4-core` (Uniswap V4 PoolManager) | Audited by Uniswap (OpenZeppelin, Spearbit, Trail of Bits, ABDK, …). Pinned commit `59d3ecf5`. |
| `lib/v4-periphery` | Official Uniswap periphery helpers. The hook imports `BaseHook`, `DeltaResolver`, `HookMiner`, and `IWETH9` from pinned commit `ad04c9f`. |
| `lib/openzeppelin-contracts` | OZ's own audited releases. Pinned `dbb6104c`. |
| `lib/permit2`, `lib/solmate`, `lib/forge-std` | Upstream-audited / test-only. |
| Ring **Few Protocol** fewToken contracts | Separately audited Ring codebase. The hook treats `wrap`/`unwrap` as 1:1 and **verifies the return value equals input** (`WrapMismatch`/`UnwrapMismatch` reverts) — so a misbehaving fewToken fails closed. |
| Ring **FewV2** AMM pair/factory | Separately audited Ring codebase (V2 fork). The hook validates pair token ordering + reserves on every swap. |
| Uniswap **TokenJar** / **Firepit** | Uniswap-governed protocol-fees pipeline (`github.com/Uniswap/protocol-fees`). RingUniBurner only `safeTransfer`s to the immutable TokenJar address. |
| `script/` deploy scripts | Deployment reference only, not production contract logic and not part of the security boundary. Reviewable on request; they run post-deploy state assertions for all hook immutables, including the 6 default connectors. |
| `test/` | Not billed; useful as executable spec. |

---

## 6. What we have already done (don't re-derive)

| Artifact | File | What it gives you |
|---|---|---|
| Static analysis | [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md) | Slither on the ownerless calldata-route build: **22 hits, 0 real**. The `calls-loop` findings are bounded by the fixed 6-connector set and per-transaction calldata paths. Every hit triaged. |
| Threat model | [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md) | The hook is ownerless; this inventories the one residual privileged key — the RingUniBurner owner — and its bounded blast radius. |
| Known/accepted risks | [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) | M1/M2 + M3 (resolved-by-design) + L1-L5 internal findings, with disposition. **Read this first to avoid re-reporting.** |
| Architecture | `docs/DESIGN.md` | Full design spec. |
| Decision rationale | `docs/RATIONALE.md` | Why every design decision exists. |
| Economic rationale | [`docs/UNI_BURN_NOTES.md`](docs/UNI_BURN_NOTES.md) | 5 bps + TokenJar/Firepit architecture. |
| Test coverage | [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) | `forge coverage` report + interpretation. |
| Gas baseline | `.gas-snapshot` | Per-test gas, for regression flagging. |

Internal CTO pre-audit review classified findings as: **0 Critical · 0 High · 2 Medium (mitigated) + 1 resolved-by-design · 5 Low**. We are explicitly asking the firm to challenge that classification.

---

## 7. Test status (the executable spec)

| Suite | Count | Notes |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 10 | Hermetic V2 math + safety invariants |
| `test/unit/RingUniBurner.t.sol` | 15 | Hermetic, mocked TokenJar/fewFactory |
| `test/invariant/RingAggregatorHookInvariants.t.sol` | 5 | Property fuzz, 10 000 runs each (fee math, gross-up, sentinel) |
| `test/fork/RingAggregatorHookFork.t.sol` | 58 | Mainnet fork vs real Few factory/pairs/TokenJar, incl. V4Quoter and adversarial tests |
| **Total** | **88** | 100% passing on the audit commit |

Adversarial tests already cover: Cork-style direct-call (`onlyPoolManager`), Bunni-style lying fewToken (`WrapMismatch`/`UnwrapMismatch`), force-fed ETH + permissionless sweep, reentrant sweep (`nonReentrant`), degenerate / token-mismatched pair, constructor zero-address checks, default-connector canonical/duplicate checks, calldata endpoint/fake-token/duplicate/missing-pair/slippage checks, V4Quoter empty-hookData exact-in/out, 5 bps skim correctness, and end-to-end push to the real mainnet TokenJar.

---

## 8. Trust model & assumptions (please challenge these)

1. **The hook is ownerless.** No owner, no admin functions, no pause, no upgrade path. Behaviour is fixed at deploy by immutable wiring + the on-chain state of the FewV2 pairs. The hook's only inbound trust boundary is `onlyPoolManager`. There is no owner key to compromise.
2. **RingUniBurner owner** → the *only* privileged role, on a *separate* contract that custodies accrued 5 bps fees before permissionless `flush()` pushes them to TokenJar. Production requirement: Gnosis Safe 3/5+ with a 24h Safe-module timelock on `emergencyWithdraw` and `setFlushPaused`. **Audit assumption: this owner is honest-but-compromisable; worst case is bounded to in-flight fees (never user funds), see `OWNER_KEY_COMPROMISE.md`.**
3. **fewFactory / fewV2Factory** → immutable, Ring-controlled, separately audited. Empty-hookData routing is direct + fixed deploy-time connectors. Non-empty calldata routes can use multiple hops, but hidden intermediates are limited to that same fixed connector set. Pair addresses are always derived from `fewV2Factory`; callers never supply pairs.
4. **TokenJar** → immutable Uniswap-governed address per chain.
5. **V4 PoolManager** → trusted (audited Uniswap core).

---

## 9. Specific questions we want answered

1. Is the `BeforeSwapDelta` sign convention correct in **all four** directions (ExactIn/ExactOut × zeroForOne/oneForZero)? Tests assert this; we want an independent proof.
2. Confirm the hook is genuinely ownerless — no leftover privileged path, no `delegatecall`/upgrade surface, no storage an external party can mutate to influence routing.
3. Is the empty-hookData default-router quote selection correct for both exact-in and exact-out, including ties, missing pairs, reserve sentinels, and 5 bps gross-up?
4. Is the ExactOutput gross-up ceildiv (`fwOutGross = ceil(amountOut·1e4 / (1e4-feeBps))`) free of an under-quote edge case? (Invariant test asserts ≥; want a formal argument.)
5. Any cross-contract reentrancy path through `fewV2Pair.swap()` callback that `nonReentrant` on `_beforeSwap` does **not** close?
6. `uniBurner` is immutable and zero-rejected at construction, and the 5 bps skim `safeTransfer`s to it on every swap. Confirm there is no griefing/DoS surface in this fixed fee path (e.g. a way to force the transfer to revert).
7. RingUniBurner `emergencyWithdraw`: confirm it cannot reach *user swap funds* or *settled pool funds* — only the burner's own transient balance (bounded to fees since the last `flush()`), per KNOWN_ISSUES M2.
8. Confirm `RingUniBurner` fits Uniswap's fee-adapter / push-source model: no self-rolled UNI swap, no self-rolled burn, canonical FewToken validation before unwrap, and a final `safeTransfer` of underlying tokens to the immutable chain TokenJar.

---

## 10. Severity framework we expect

Standard Immunefi/Code4rena severity (Critical = direct fund loss / theft; High = conditional fund loss or protocol insolvency; Medium = griefing / unbounded gas / value-at-risk under burner-owner compromise; Low = best-practice). We will fix all Critical/High/Medium; Low at discretion with written justification.

---

## 11. Deliverables we need from the firm

1. Public PDF report (required for the Uniswap routing-api allowlist PR and Hooks Marketplace application).
2. Findings as GitHub issues on this repo (or agreed Slack/Discord channel).
3. One post-fix re-review pass included.
