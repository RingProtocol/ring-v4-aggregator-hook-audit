# Documentation Index

This repo is the `audit-r3-direct-only-sor` audit package for Ring's Uniswap v4 aggregator hook.

The hook is ownerless and direct-only: each v4 pool maps to one canonical direct FewV2 pair. If a better `A -> X -> B` price exists, Uniswap routing can compose that as two v4 pool hops, so the hook does not need an internal connector router or calldata path engine.

Current verification status: 73/73 tests passing, V4Quoter fork tests passing, Slither 7 findings / 0 real issues.

---

## Read In This Order

### External Auditor

| # | File | Why |
|---|---|---|
| 1 | [`../AUDIT_SCOPE.md`](../AUDIT_SCOPE.md) | In scope, out of scope, nSLOC, directed questions |
| 2 | [`../README.md`](../README.md) | Repo orientation |
| 3 | [`DIRECT_ONLY_ROUTING.md`](DIRECT_ONLY_ROUTING.md) | Direct-only model and SOR assumption |
| 4 | [`DESIGN.md`](DESIGN.md) | Architecture reference |
| 5 | [`RATIONALE.md`](RATIONALE.md) | Why this design was chosen |
| 6 | [`SLITHER_TRIAGE.md`](SLITHER_TRIAGE.md) | Every static-analysis hit triaged |
| 7 | [`TEST_COVERAGE.md`](TEST_COVERAGE.md) | Coverage and test matrix |
| 8 | [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md) | Residual burner-owner risk |
| 9 | [`UNI_BURN_NOTES.md`](UNI_BURN_NOTES.md) | 5 bps TokenJar / Firepit path |
| 10 | `src/RingAggregatorHook.sol`, `src/RingUniBurner.sol`, `src/lib/FewV2Math.sol` | Production code |

### CTO / Protocol Engineer

| # | File | Goal |
|---|---|---|
| 1 | [`../README.md`](../README.md) | Current branch and status |
| 2 | [`DIRECT_ONLY_ROUTING.md`](DIRECT_ONLY_ROUTING.md) | Product-routing tradeoff |
| 3 | [`DESIGN.md`](DESIGN.md) | Contract-level behavior |
| 4 | [`RATIONALE.md`](RATIONALE.md) | Rejected alternatives |
| 5 | [`TEST_COVERAGE.md`](TEST_COVERAGE.md) | What the tests prove |

### CEO / Ops

| # | File | Goal |
|---|---|---|
| 1 | [`../README.md`](../README.md) | Plain-language status |
| 2 | [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md) | What the remaining key can and cannot do |
| 3 | [`GO_LIVE_MECHANICS.md`](GO_LIVE_MECHANICS.md) | How users eventually reach the hook |
| 4 | [`DEPLOYMENT_FLOW.md`](DEPLOYMENT_FLOW.md) | Audit-to-mainnet plan |

---

## Document Inventory

| File | Audience | Description |
|---|---|---|
| `../README.md` | Everyone | Repo orientation, branch status, build/deploy |
| `../AUDIT_SCOPE.md` | Auditor | Scope, nSLOC, tests, questions |
| `../KNOWN_ISSUES.md` | Auditor | Previously triaged issues |
| `../SECURITY.md` | Researcher | Responsible disclosure |
| `DIRECT_ONLY_ROUTING.md` | Auditor, engineer | Direct-only model and SOR composition |
| `DESIGN.md` | Auditor, engineer | Architecture reference |
| `RATIONALE.md` | Auditor, CTO | Design rationale |
| `SLITHER_TRIAGE.md` | Auditor | Static-analysis triage |
| `TEST_COVERAGE.md` | Auditor | Coverage report |
| `OWNER_KEY_COMPROMISE.md` | CEO, auditor | Residual burner-owner scope |
| `UNI_BURN_NOTES.md` | Auditor, engineer | Fee pipeline |
| `GO_LIVE_MECHANICS.md` | Everyone | Listing / routing mechanics |
| `DEPLOYMENT_FLOW.md` | Ops | Deployment roadmap |
| `MECHANISM_PROVENANCE.md` | Auditor, CTO | Provenance and comparable patterns |

If a document contradicts the contracts, the contracts are the source of truth.
