# Test Coverage — Ownerless Calldata Route Branch

> Last updated: 2026-05-25
> Command: `ETH_RPC_URL=$ETH_RPC_URL forge coverage --ir-minimum --report lcov`
> Result: 88/88 tests passed; `lcov.info` generated

---

## 1. Headline

The `ownerless-calldata-route` branch was coverage-tested against the full suite, including mainnet-fork tests.

| Metric | Result |
|---|---:|
| Test suites | 4 |
| Tests | 88 passed / 0 failed / 0 skipped |
| Unit tests | 25 |
| Invariant tests | 5, 10,000 fuzz runs each |
| Mainnet-fork tests | 58 |
| Source-only line coverage | 382 / 417 = 91.61% |
| Source-only function coverage | 55 / 66 = 83.33% |
| Source-only branch coverage | 73 / 101 = 72.28% |

The repo-wide headline is lower because Foundry includes deployment scripts, tests, and abstract v4 helper stubs in LCOV. For audit purposes, the useful numbers are the in-scope source files below.

---

## 2. In-Scope Source Coverage

| File | Lines | Functions | Branches | Interpretation |
|---|---:|---:|---:|---|
| `src/RingAggregatorHook.sol` | 305/314 = 97.13% | 38/38 = 100.00% | 58/79 = 73.42% | Default auto-route, calldata multi-hop swap path, V4Quoter entrypoints, and red-team checks heavily covered |
| `src/RingUniBurner.sol` | 26/27 = 96.30% | 5/5 = 100.00% | 8/8 = 100.00% | Fee adapter and owner-only paths covered |
| `src/lib/FewV2Math.sol` | 29/34 = 85.29% | 4/5 = 80.00% | 5/11 = 45.45% | V2 math covered by unit and invariant tests |
| `src/base/DeltaResolver.sol` | 9/9 = 100.00% | 2/2 = 100.00% | 1/2 = 50.00% | Local take/settle helper covered |
| `src/utils/BaseHook.sol` | 13/33 = 39.39% | 6/16 = 37.50% | 1/1 = 100.00% | Abstract v4 hook helper; many unused callbacks intentionally unreachable |

---

## 3. Test Suite Breakdown

| Suite | Count | Coverage purpose |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 10 | V2 quote math, rounding, empty reserve behavior, safety invariants |
| `test/unit/RingUniBurner.t.sol` | 15 | TokenJar push adapter, owner-only emergency paths, paused flush, unknown FewToken rejection |
| `test/invariant/RingAggregatorHookInvariants.t.sol` | 5 | Fee/user-output invariants and exact-output gross-up fuzzing |
| `test/fork/RingAggregatorHookFork.t.sol` | 58 | Mainnet-fork integration across real Ring factories, default auto-route, calldata route, V4Quoter, FewTokens, FewV2 pairs, and TokenJar |

---

## 4. Important Covered Behaviors

| Behavior | Covered by |
|---|---|
| Constructor zero-address rejection | Fork tests and burner unit tests |
| Direct hook callback rejection | Fork adversarial tests |
| Pool initialization requires FewFactory endpoints, not direct pair | `test_fork_initAllowsFewFactorySupportedPoolWithoutDirectPair` |
| Empty-hookData default auto-routing chooses best direct-or-fixed-connector route | Fork quote-vs-swap test |
| Official V4Quoter quotes empty-hookData exact input | V4Quoter fork test |
| Official V4Quoter quotes empty-hookData exact output | V4Quoter fork test |
| Real calldata route exact-input execution | `fwETH -> fwUSDT -> fwUSDC` fork test |
| Real calldata route exact-output backward quote | `fwETH -> fwUSDT -> fwUSDC` fork test |
| Calldata route rejects non-default hidden intermediates | Fork red-team test |
| Default connector constructor validates canonical FewTokens and duplicates | Fork red-team tests |
| Calldata route minOut protection | Fork red-team test |
| Calldata route maxIn protection | Fork red-team test |
| Zero amountLimit rejection | Fork red-team test |
| Endpoint mismatch rejection | Fork red-team test |
| Non-canonical FewToken rejection | Fork red-team test |
| Duplicate FewToken rejection | Fork red-team test |
| Missing adjacent pair rejection | Fork red-team test |
| FewToken wrap/unwrap mismatch reverts | Fork adversarial tests |
| Pair token mismatch reverts | Fork adversarial tests |
| Degenerate pair sentinel | Fork adversarial tests + invariant boundary fuzz |
| 5 bps fee skim | Fork TokenJar fee-path tests + invariants |
| End-to-end push to real TokenJar | Fork end-to-end tests |
| Permissionless sweep | Fork tests |
| Sweep reentrancy guard | Fork adversarial test |
| Burner owner-only emergency withdraw | Burner unit tests |

---

## 5. Interpretation For Auditors

This branch intentionally introduces bounded multi-hop loops through default auto-routing and caller-supplied `hookData`. That increases code and review surface, but not admin/governance risk:

- Route choice is per-transaction, not stored.
- Empty-hookData candidate search is fixed to direct plus 6 immutable connectors.
- Pair addresses are derived on-chain from immutable `fewV2Factory`.
- Every path token is validated through immutable `fewFactory`.
- User slippage is enforced by the Universal Router for empty-hookData routes and inside the hook for calldata routes.
- Bad path calldata affects only the caller's own transaction, and hidden intermediates cannot exceed the fixed connector set.

Coverage does not replace review of `BeforeSwapDelta` accounting, exact-output backward quoting, external-call ordering, or SDK/router encoding. It does show that the default route and calldata-route surfaces are exercised by unit, invariant, V4Quoter-level, and real mainnet-fork tests.
