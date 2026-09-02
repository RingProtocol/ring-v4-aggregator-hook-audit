# Deployment Flow

> Branch: `audit-router-compat-aggregator-interface`
> Purpose: mainnet deployment checklist for the direct-only ownerless hook with UniRoute aggregator compatibility

---

## 1. Current State

| Item | Status |
|---|---|
| Direct-only hook implementation | Done |
| UniRoute aggregator compatibility | Done |
| RingUniBurner fee adapter | Done |
| Tests | 83/83 passing |
| Slither | 7 current outputs triaged; no code change required |
| Audit scope | 502 nSLOC Ring-written production code |
| External audit | ABDK public report v1.1 covers the direct-only core and reviewed fixes; router-compatible delta review pending |
| Uniswap code-path decision | Pending: official contribution versus independent hook |
| Uniswap fee decision | Pending: fixed Ring skim versus classified-hook protocol fee |
| Aggregator address ID | Pending assignment from Uniswap |
| Burner owner multisig/timelock | Pending |
| Replacement mainnet deployment | Blocked on the decisions and reviews above |
| Uniswap hooklist | PR #601 merged for the older deployed direct-only hook |
| Uniswap Labs routing | PR #1404 open with no reviews recorded on the public PR page for the older deployed address |

---

## 2. Audit Package

Send auditors:

```text
Repo: github.com/RingProtocol/ring-v4-aggregator-hook-audit
Branch: audit-router-compat-aggregator-interface
Build: forge build
Hermetic tests: forge test --offline --no-match-path "test/fork/*"
Full tests: ETH_RPC_URL=<mainnet RPC> forge test
Primary scope: src/RingAggregatorHook.sol, src/RingUniBurner.sol, src/lib/FewV2Math.sol
Audit report: docs/ABDK_Ring_Aggregator_Hook_Audit_Report_v1.1.pdf
```

Reading order:

1. `AUDIT_SCOPE.md`
2. `README.md`
3. `docs/DIRECT_ONLY_ROUTING.md`
4. `docs/DESIGN.md`
5. `KNOWN_ISSUES.md`
6. `docs/ABDK_FIX_MATRIX.md`
7. `docs/SLITHER_TRIAGE.md`
8. `docs/TEST_COVERAGE.md`
9. `docs/OWNER_KEY_COMPROMISE.md`

---

## 3. Uniswap Architecture Gate

Before freezing a replacement deployment commit, obtain written answers for:

1. official `v4-hooks-public` contribution versus independent Ring implementation;
2. one protocol-fee path, including `IFeeClassifiedHook` and PoolManager fee configuration;
3. assigned first-byte aggregator-hook address ID;
4. required current ABI, events, PoolKey behavior, and version reporting;
5. UniRoute, indexing, gas-calibration, allowlist, and delisting owners;
6. accepted security evidence and the exact delta-review scope.

Do not mine a replacement address or change fee logic until these decisions are recorded.

---

## 4. Audit Phase

Expected work:

1. Auditor reviews the frozen branch / commit.
2. Ring answers integration questions, especially around v4 settlement, direct-pair routing, and TokenJar fee flow.
3. Auditor delivers draft findings.
4. Ring fixes Critical / High / Medium findings.
5. Auditor performs fix review.
6. Auditor delivers public final report.

Do not deploy meaningful mainnet volume before the final report is complete and reviewed internally.

---

## 5. Pre-Deploy Requirements

| Requirement | Reason |
|---|---|
| Public audit report | Included for hooklist / routing reviewers and public trust |
| All Critical / High / Medium findings fixed | Production safety |
| Router-compatible delta independently reviewed | ABDK report does not cover `14abfbd...df9752f` |
| Uniswap fee and address-ID decisions implemented | Prevents fee duplication and incompatible deployment address |
| `RingUniBurner.owner` moved to Gnosis Safe | EOA owner is not acceptable |
| Timelock or equivalent delay on emergency actions | Limits burner-owner compromise blast radius |
| Deployment addresses reviewed by two engineers | Prevent immutable wiring mistakes |
| Smoke-test plan ready | Confirm wrap -> swap -> skim -> unwrap -> settle path |
| Monitoring configured | Catch revert spikes, fee flush failures, abnormal balances |

---

## 6. Deployment Steps

1. Deploy the final `RingUniBurner` with chain TokenJar, `fewFactory`, and production Safe/timelock owner.
2. Set `UNI_BURNER_ADDRESS` to the deployed burner.
3. Mine the hook CREATE2 salt for the required v4 hook flags.
4. Deploy `RingAggregatorHook` with immutable `poolManager`, `fewFactory`, `fewV2Factory`, `weth`, `feeRecipient`, and `uniBurner`.
5. Verify source on Etherscan.
6. Initialize the v4 shell pools for pairs with canonical FewTokens and direct FewV2 pairs. The canonical shell key is `fee = 500`, `tickSpacing = 10`.
7. Run a small exact-input ETH -> USDC smoke swap through `SmokeSwapEthUsdc`.
8. Flush the accrued fee through `RingUniBurner` into TokenJar.
9. Confirm the hook and burner hold no unexpected balances.

Recommended commands:

```bash
# 1. Deploy final burner.
forge script script/DeployUniBurner.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --via-ir

# 2. Mine the router-compatible hook address.
forge script script/MineHookAddress.s.sol \
  --rpc-url "$RPC_URL" \
  --via-ir

# 3. Deploy the hook. Set SKIP_INIT_POOL=true if you want initialization as a separate transaction.
forge script script/DeployMainnet.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --via-ir

# 4. Initialize recommended pools after deployment.
forge script script/InitializeRecommendedPools.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --via-ir

# 5. Tiny ETH -> USDC smoke swap.
forge script script/SmokeSwapEthUsdc.s.sol \
  --tc SmokeSwapEthUsdc \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --via-ir
```

---

## 7. Post-Deploy Review

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

## 8. Uniswap Submission Path

1. Submit the new hook to the Uniswap hooklist registry with source, addresses, metadata, and audit report.
2. Submit the Uniswap Labs hook routing allowlist form with:
   - hook address
   - verified source
   - public audit report
   - direct-only routing explanation
   - `quote` and `pseudoTotalValueLocked` support
   - monitoring policy
   - multisig/timelock address
   - gas and smoke-test data
3. If requested, provide proof that the hook has no owner, no pause, no upgrade, and no mutable route state.

Hooklist listing improves discoverability. Labs routing allowlist / UniRoute inclusion is the part that can create Uniswap frontend traffic.

Routing inclusion only makes the hook eligible for selection. The router still compares price, gas, and route quality for every quote, so neither listing nor allowlisting guarantees transaction volume.

---

## 9. Emergency Response

The hook has no pause. Response tools are:

- route/hook delisting at routing layer
- no new pool initialization
- redeploy fixed hook if needed
- `RingUniBurner.setFlushPaused(true)` for fee-adapter incidents
- `RingUniBurner.emergencyWithdraw` only for accrued fee balances or stuck tokens in the burner

The hook should never rely on a privileged key to protect user swap funds.

---

## 10. Go / No-Go Gates

| Gate | Owner | Required before continuing |
|---|---|---|
| Architecture alignment | Engineering / Uniswap reviewer | Code path, fee, address ID, ABI, and integration owners confirmed |
| Audit kickoff | Engineering | Frozen branch and scope confirmed |
| Audit completion | Engineering / leadership | Public report accepted internally |
| Mainnet deployment | Engineering / Safe signers | Official decisions implemented, delta review complete, multisig live |
| Routing submission | Engineering / BD | Deployment verified and smoke-tested |
| Meaningful volume | Leadership | Monitoring live and routing path approved |
