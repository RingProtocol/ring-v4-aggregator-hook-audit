# Test Coverage

> Last updated: 2026-06-19
> Branch: `audit-router-compat-aggregator-interface`
> Command: `ETH_RPC_URL=$ETH_RPC_URL forge coverage --ir-minimum --report summary`
> Result: 83/83 tests passed

> **Freshness note (September 1, 2026):** the same 83 tests were rerun successfully, including all 55 mainnet-fork tests. Coverage percentages below remain the June 19 snapshot and were not represented as a new coverage run.

---

## Headline

| Metric | Result |
|---|---:|
| Test suites | 4 |
| Tests | 83 passed / 0 failed / 0 skipped |
| Unit tests | 23 |
| Invariant tests | 5 |
| Mainnet-fork tests | 55 |
| Source-only line coverage | 241 / 247 = 97.57% |
| Source-only function coverage | 37 / 37 = 100.00% |
| Source-only branch coverage | 44 / 59 = 74.58% |

The repo-wide coverage output also includes tests and deployment scripts. The source-only numbers above are the useful audit view for Ring-written production code.

---

## In-Scope Source Coverage

| File | Lines | Functions | Branches | Notes |
|---|---:|---:|---:|---|
| `src/RingAggregatorHook.sol` | 194/199 = 97.49% | 30/30 = 100.00% | 30/41 = 73.17% | Direct swap path, V4Quoter, aggregator quote, pseudo TVL, fee skim, sweep, and adversarial checks covered |
| `src/RingUniBurner.sol` | 32/33 = 96.97% | 5/5 = 100.00% | 10/12 = 83.33% | Fee adapter and owner-only paths covered |
| `src/lib/FewV2Math.sol` | 15/15 = 100.00% | 2/2 = 100.00% | 4/6 = 66.67% | V2 math covered by unit and invariant tests |

---

## Test Suite Breakdown

| Suite | Count | Coverage purpose |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 7 | V2 quote math and rounding |
| `test/unit/RingUniBurner.t.sol` | 16 | TokenJar push adapter, owner-only emergency paths, paused flush, unknown FewToken rejection, native ETH rescue |
| `test/invariant/RingAggregatorHookInvariants.t.sol` | 5 | Fee accounting, exact-output gross-up, reserve sentinel |
| `test/fork/RingAggregatorHookFork.t.sol` | 55 | Mainnet-fork integration across real Ring factories, direct FewV2 pair, V4Quoter, aggregator quote, pseudo TVL, FewTokens, FewV2 pairs, and TokenJar |

---

## Important Covered Behaviors

| Behavior | Covered by |
|---|---|
| Constructor zero-address rejection | Fork tests and burner unit tests |
| Direct hook callback rejection | Fork adversarial tests |
| Pool initialization requires canonical endpoints and a direct FewV2 pair | Fork tests |
| Direct-route exact-input swap | Fork e2e tests |
| Direct-route exact-output swap | Fork e2e tests |
| Official V4Quoter quotes empty-hookData exact input | V4Quoter fork test |
| Official V4Quoter quotes empty-hookData exact output | V4Quoter fork test |
| Aggregator `quote` matches direct FewV2 quote | Fork tests |
| `pseudoTotalValueLocked` matches FewV2 reserves | Fork test |
| Duplicate v4 shell pool for same FewV2 pair reverts | Fork adversarial test |
| Non-canonical shell pool fee reverts | Fork adversarial test |
| Non-empty hookData still uses direct route | Fork integration tests |
| FewToken wrap/unwrap mismatch reverts | Fork adversarial tests |
| Pair token mismatch reverts | Fork adversarial tests |
| Degenerate pair sentinel | Fork adversarial tests and invariant fuzzing |
| 5 bps fee skim | Fork TokenJar fee-path tests and invariants |
| End-to-end push to real TokenJar | Fork end-to-end tests |
| Permissionless sweep | Fork tests |
| Sweep reentrancy guard | Fork adversarial test |
| Burner owner-only emergency withdraw | Burner unit tests |

---

## Interpretation For Auditors

This branch removes the prior calldata-route and default-connector route loops. The remaining review focus is:

- `BeforeSwapDelta` accounting
- direct pair validation and reserve checks
- exact-output fee gross-up
- external-call ordering
- `hookData` being ignored rather than decoded
- UniRoute compatibility reads/events: `AggregatorPoolRegistered`, `HookSwap`, `quote`, `pseudoTotalValueLocked`
- `RingUniBurner` fee custody and TokenJar push-source behavior

Coverage does not replace manual review, but it shows the direct-only execution path and router-compatibility layer are exercised through unit, invariant, V4Quoter-level, aggregator-quote, and real mainnet-fork tests.
