# Documentation Index

> One-page guide to every document in this repo, organised by audience and reading order. This repository is **fully self-contained** — every referenced doc lives inside it.

---

## Quick orientation (30 seconds)

You're looking at **Ring V4 Aggregator Hook** — a Uniswap V4 hook that exposes Ring's FewV2 AMM (~$130M TVL) as native V4 pools, with a 5 bps protocol fee that is pushed into Uniswap's canonical TokenJar; Uniswap's Firepit handles the downstream UNI burn. This helper-externalized audit branch is based on `audit-ownerless-calldata-route-2026-05-25-r3`; code is complete + tested (**88/88** passing: 25 unit + 5 invariant + 58 mainnet-fork), with V4Quoter empty-hookData coverage and a dedicated calldata-route red-team pass.

**Branch note**: the historical `ownerless` branch remains the smaller direct-route package. This audit build extends it: empty `hookData` runs a built-in default router over direct + fixed connectors, while non-empty `hookData` enables ownerless calldata routes with chain-validated FewToken paths, fixed-connector intermediates, and hook-level slippage bounds. The pre-ownerless `main` branch is archived as `archive/pre-ownerless-main-2026-05-25`. See [`CALLDATA_ROUTE_SECURITY.md`](CALLDATA_ROUTE_SECURITY.md).

---

## Read in this order

### If you are the **CEO** (private key holder)

| # | File | Read time | Goal |
|---|---|---|---|
| 1 | [`../README.md`](../README.md) | 5 min | What this is + permission model + status |
| 2 | [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md) | 15 min | The hook is ownerless; worst-case for the one residual key (RingUniBurner owner) |
| 3 | [`DEPLOYMENT_FLOW.md`](DEPLOYMENT_FLOW.md) | 25 min | 5-month roadmap from now to Uniswap routing-api PR merged |

**Total: ~45 min**. Read once before approving any audit / multisig setup.

### If you are the **CTO** (technical decision maker)

| # | File | Read time | Goal |
|---|---|---|---|
| 1 | [`../README.md`](../README.md) | 5 min | Architecture one-liner + permission model |
| 2 | [`DESIGN.md`](DESIGN.md) | 90 min | Architecture spec (canonical reference) |
| 3 | [`RATIONALE.md`](RATIONALE.md) | 60 min | Why every design decision (ownerless, immutable wiring, bounded routing) |
| 4 | [`UNI_BURN_NOTES.md`](UNI_BURN_NOTES.md) | 25 min | 3-anchor 5 bps rationale + TokenJar/Firepit architecture |
| 5 | [`CALLDATA_ROUTE_SECURITY.md`](CALLDATA_ROUTE_SECURITY.md) | 20 min | New branch-specific route ABI, validation, red-team coverage, Slither triage |
| 6 | [`SLITHER_TRIAGE.md`](SLITHER_TRIAGE.md) | 20 min | Ownerless calldata-route static analysis baseline |
| 7 | [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md) | 20 min | Threat model + countermeasures |

**Total: ~3.5 hours**. Read before signing off on the audit-firm contract.

### If you are an **external audit firm** (Cantina / Spearbit / Code4rena)

| # | File | Why |
|---|---|---|
| 1 | [`../AUDIT_SCOPE.md`](../AUDIT_SCOPE.md) | **Start here.** In/out-of-scope, nSLOC, severity framework, 8 directed questions |
| 2 | [`../KNOWN_ISSUES.md`](../KNOWN_ISSUES.md) | What we already triaged — avoid re-reporting |
| 3 | [`../README.md`](../README.md) | Repo orientation + status |
| 4 | [`DESIGN.md`](DESIGN.md) | The "what" we're building |
| 5 | [`RATIONALE.md`](RATIONALE.md) | The "why" of every hardening decision |
| 6 | [`SLITHER_TRIAGE.md`](SLITHER_TRIAGE.md) | Every Slither hit triaged — focus your energy elsewhere |
| 7 | [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md) | Threat model we already wrote |
| 8 | [`UNI_BURN_NOTES.md`](UNI_BURN_NOTES.md) | Economic + political 5 bps rationale |
| 9 | [`CALLDATA_ROUTE_SECURITY.md`](CALLDATA_ROUTE_SECURITY.md) | Route ABI, validation model, and red-team coverage |
| 10 | [`TEST_COVERAGE.md`](TEST_COVERAGE.md) | Per-file coverage report |
| 11 | `src/RingAggregatorHook.sol` + `src/RingUniBurner.sol` | The contracts |
| 12 | `test/` directory | 88 tests (25 unit + 5 invariant + 58 fork, incl. V4Quoter and calldata-route red-team cases) |

Submit findings as GitHub issues on this repo, or in the agreed Slack/Discord channel per contract.

### If you are an **engineer joining the project**

| # | File | Read time | Goal |
|---|---|---|---|
| 1 | [`../README.md`](../README.md) | 5 min | Build / test / deploy basics |
| 2 | [`DESIGN.md`](DESIGN.md) | 90 min | Architecture reference |
| 3 | `src/RingAggregatorHook.sol` source | 1 hr | Read top-to-bottom |
| 4 | `test/fork/RingAggregatorHookFork.t.sol` | 1 hr | 58 fork tests are the executable spec on this branch |
| 5 | [`RATIONALE.md`](RATIONALE.md) | 60 min | Design decisions and rejected alternatives |

---

## Document inventory (full list — repo is self-contained)

### Repo root — audit submission package (read first)

| File | Audience | Description |
|---|---|---|
| `README.md` | Everyone | Repo orientation, branch model, build/deploy |
| `AUDIT_SCOPE.md` | Auditor | In-scope vs out-of-scope, nSLOC, commit, severity framework, 8 directed questions |
| `KNOWN_ISSUES.md` | Auditor | M1/M2 mitigated+accepted, M3 fixed, low-risk internal findings, Slither triage on the ownerless calldata-route build |
| `SECURITY.md` | Researcher | Responsible disclosure, scope, bounty intent, safe harbor |

### Inside repo `docs/` (11 files)

| File | Audience |
|---|---|
| `INDEX.md` (this file) | Everyone — start here |
| `DESIGN.md` | CTO, auditor — full architecture spec |
| `RATIONALE.md` | CTO, auditor — why every hardening decision |
| `UNI_BURN_NOTES.md` | Auditor, engineer — 5 bps + TokenJar/Firepit architecture |
| `CALLDATA_ROUTE_SECURITY.md` | Auditor, engineer — calldata-route ABI, validation, red-team coverage, branch-specific Slither triage |
| `SLITHER_TRIAGE.md` | Auditor — every detector hit triaged on the ownerless calldata-route build |
| `TEST_COVERAGE.md` | Auditor — per-file lcov (Hook 97.12%, Burner 96.30%) |
| `OWNER_KEY_COMPROMISE.md` | CEO, auditor — residual-key threat model (hook is ownerless; covers the RingUniBurner owner) |
| `DEPLOYMENT_FLOW.md` | CEO, ops team — current-state → routing-api roadmap (the *when/who*) |
| `GO_LIVE_MECHANICS.md` | Everyone — how a user's swap reaches FewV2: shell pool, initialize ≠ add liquidity, hooklist vs allowlist (the *how/why*) |
| `MECHANISM_PROVENANCE.md` | Auditor, CTO — mechanism provenance and comparable production patterns |

No external/workspace dependencies. Internal operational, onboarding, and business-growth playbooks are intentionally kept outside this audit branch.

---

## Total reading time estimates

| Audience | Time |
|---|---|
| CEO (decision making) | ~45 min |
| CTO (technical sign-off) | ~3.5 hrs |
| Auditor (full review) | ~5 hrs reading + 2-8 weeks code review |
| Engineer (onboarding) | ~4.5 hrs |

---

## Provenance / authorship

All `docs/` files are AI-authored (Claude Code) and reviewed + edited by the Ring engineering team. Treat them as **specifications written in English**, not marketing — every claim is intended to be technically defensible under audit scrutiny.

If anything contradicts the source code, **the source code wins**. Open an issue and we'll fix the doc.
