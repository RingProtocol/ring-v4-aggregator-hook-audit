# Deployment Flow

> Branch: `audit-r3-direct-only-sor`
> Purpose: audit-to-mainnet checklist for the direct-only ownerless hook

---

## 1. Current State

| Item | Status |
|---|---|
| Direct-only hook implementation | Done |
| RingUniBurner fee adapter | Done |
| Tests | 73/73 passing |
| Slither | 7 findings triaged, 0 real issues |
| Audit scope | 395 nSLOC Ring-written production code |
| External audit | Pending |
| Burner owner multisig/timelock | Pending |
| Mainnet deployment | Pending audit |
| Uniswap hooklist / routing allowlist | Pending deployment and audit report |

---

## 2. Audit Package

Send auditors:

```text
Repo: github.com/RingProtocol/ring-v4-aggregator-hook-audit
Branch: audit-r3-direct-only-sor
Build: forge build
Hermetic tests: forge test --offline --no-match-path "test/fork/*"
Full tests: ETH_RPC_URL=<mainnet RPC> forge test
Primary scope: src/RingAggregatorHook.sol, src/RingUniBurner.sol, src/lib/FewV2Math.sol
```

Reading order:

1. `AUDIT_SCOPE.md`
2. `README.md`
3. `docs/DIRECT_ONLY_ROUTING.md`
4. `docs/DESIGN.md`
5. `docs/RATIONALE.md`
6. `docs/SLITHER_TRIAGE.md`
7. `docs/TEST_COVERAGE.md`
8. `docs/OWNER_KEY_COMPROMISE.md`
9. `docs/UNI_BURN_NOTES.md`

---

## 3. Audit Phase

Expected work:

1. Auditor reviews the frozen branch / commit.
2. Ring answers integration questions, especially around v4 settlement, direct-pair routing, and TokenJar fee flow.
3. Auditor delivers draft findings.
4. Ring fixes Critical / High / Medium findings.
5. Auditor performs fix review.
6. Auditor delivers public final report.

Do not deploy meaningful mainnet volume before the final report is complete and reviewed internally.

---

## 4. Pre-Deploy Requirements

| Requirement | Reason |
|---|---|
| Public audit report | Needed for router / hooklist reviewers and public trust |
| All Critical / High / Medium findings fixed | Production safety |
| `RingUniBurner.owner` moved to Gnosis Safe | EOA owner is not acceptable |
| Timelock or equivalent delay on emergency actions | Limits burner-owner compromise blast radius |
| Deployment addresses reviewed by two engineers | Prevent immutable wiring mistakes |
| Smoke-test plan ready | Confirm wrap -> swap -> skim -> unwrap -> settle path |
| Monitoring configured | Catch revert spikes, fee flush failures, abnormal balances |

---

## 5. Deployment Steps

1. Deploy `RingUniBurner` with chain TokenJar, `fewFactory`, and temporary deployer owner.
2. Transfer `RingUniBurner.owner` to the production Safe/timelock.
3. Mine the hook CREATE2 salt for the required v4 hook flags.
4. Deploy `RingAggregatorHook` with immutable `poolManager`, `fewFactory`, `fewV2Factory`, `weth`, `feeRecipient`, and `uniBurner`.
5. Verify source on Etherscan.
6. Initialize the v4 shell pools for pairs with canonical FewTokens and direct FewV2 pairs.
7. Run a small exact-input smoke swap.
8. Run a small exact-output smoke swap.
9. Flush the accrued fee through `RingUniBurner` into TokenJar.
10. Confirm the hook and burner hold no unexpected balances.

---

## 6. Post-Deploy Review

Collect:

- hook address
- burner address
- Safe/timelock address
- verified source links
- initialized PoolKeys
- smoke-test transaction hashes
- TokenJar flush transaction hash
- final audit report link
- Slither triage link
- test/coverage summary

---

## 7. Uniswap Submission Path

1. Submit the hook to the Uniswap hooklist registry with source, addresses, metadata, and audit report.
2. Apply for routing allowlist / routing-api inclusion with:
   - hook address
   - verified source
   - public audit report
   - direct-only routing explanation
   - monitoring policy
   - multisig/timelock address
   - gas and smoke-test data
3. If requested, provide proof that the hook has no owner, no pause, no upgrade, and no mutable route state.

Hooklist listing improves discoverability. Routing allowlist / routing-api inclusion is the part that can create Uniswap frontend traffic.

---

## 8. Emergency Response

The hook has no pause. Response tools are:

- route/hook delisting at routing layer
- no new pool initialization
- redeploy fixed hook if needed
- `RingUniBurner.setFlushPaused(true)` for fee-adapter incidents
- `RingUniBurner.emergencyWithdraw` only for accrued fee balances or stuck tokens in the burner

The hook should never rely on a privileged key to protect user swap funds.

---

## 9. Go / No-Go Gates

| Gate | Owner | Required before continuing |
|---|---|---|
| Audit kickoff | Engineering | Frozen branch and scope confirmed |
| Audit completion | Engineering / leadership | Public report accepted internally |
| Mainnet deployment | Engineering / Safe signers | Audit fixes complete, multisig live |
| Routing submission | Engineering / BD | Deployment verified and smoke-tested |
| Meaningful volume | Leadership | Monitoring live and routing path approved |
