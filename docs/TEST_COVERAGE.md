# Test Coverage

> Last updated: 2026-05-29
> Branch: `audit-r3-direct-only-sor`
> Command: `ETH_RPC_URL=$ETH_RPC_URL forge coverage --ir-minimum --report lcov`
> Result: 73/73 tests passed; `lcov.info` generated

---

## Headline

| Metric | Result |
|---|---:|
| Test suites | 4 |
| Tests | 73 passed / 0 failed / 0 skipped |
| Unit tests | 21 |
| Invariant tests | 5 |
| Mainnet-fork tests | 47 |
| Source-only line coverage | 182 / 185 = 98.38% |
| Source-only function coverage | 27 / 27 = 100.00% |
| Source-only branch coverage | 37 / 47 = 78.72% |

The repo-wide LCOV output also includes tests and scripts. The source-only numbers above are the useful audit view for Ring-written production code.

---

## In-Scope Source Coverage

| File | Lines | Functions | Branches | Notes |
|---|---:|---:|---:|---|
| `src/RingAggregatorHook.sol` | 142/144 = 98.61% | 20/20 = 100.00% | 26/34 = 76.47% | Direct swap path, V4Quoter, fee skim, sweep, and adversarial checks covered |
| `src/RingUniBurner.sol` | 26/27 = 96.30% | 5/5 = 100.00% | 8/8 = 100.00% | Fee adapter and owner-only paths covered |
| `src/lib/FewV2Math.sol` | 14/14 = 100.00% | 2/2 = 100.00% | 3/5 = 60.00% | V2 math covered by unit and invariant tests |

---

## Test Suite Breakdown

| Suite | Count | Coverage purpose |
|---|---:|---|
| `test/unit/FewV2Math.t.sol` | 6 | V2 quote math and rounding |
| `test/unit/RingUniBurner.t.sol` | 15 | TokenJar push adapter, owner-only emergency paths, paused flush, unknown FewToken rejection |
| `test/invariant/RingAggregatorHookInvariants.t.sol` | 5 | Fee accounting, exact-output gross-up, reserve sentinel |
| `test/fork/RingAggregatorHookFork.t.sol` | 47 | Mainnet-fork integration across real Ring factories, direct FewV2 pair, V4Quoter, FewTokens, FewV2 pairs, and TokenJar |

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

This branch removes the prior calldata-route and default-connector route loops. The remaining review focus is narrower:

- `BeforeSwapDelta` accounting
- direct pair validation and reserve checks
- exact-output fee gross-up
- external-call ordering
- `hookData` being ignored rather than decoded
- `RingUniBurner` fee custody and TokenJar push-source behavior

Coverage does not replace manual review, but it shows the direct-only execution path is exercised through unit, invariant, V4Quoter-level, and real mainnet-fork tests.
