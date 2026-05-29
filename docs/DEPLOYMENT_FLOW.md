# Deployment Flow — current state → Uniswap routing-api PR merged

> **Audience**: CEO + CTO + ops team. The complete 5-month roadmap from this commit to the day the hook receives uniswap.org main traffic.
>
> **Status**: code complete · pre-audit · pre-multisig · pre-deploy

---

## Goal

```
            T+0 (now)                            T+5 months (target)
              ▼                                          ▼
  RingProtocol/ring-v4-aggregator-hook-audit → uniswap.org users automatically
  pushed to GitHub                              route through Ring's hook for
                                                ETH/USDC and other pairs
```

---

## Phase 1 — Code freeze + pre-audit prep (1-2 weeks)

Already mostly done. Remaining items:

| Task | Status | Owner | Effort |
|---|---|---|---|
| `lib/` symlinks → git submodules | ✅ done | engineer | 0.5 day |
| Slither static analysis | ✅ done ([triage](SLITHER_TRIAGE.md)) | engineer | 0.5 day |
| Bump fuzz runs 256 → 10000 | ✅ done | engineer | 1 line |
| Invariant tests (5-10) | ✅ done | engineer | 1-2 days |
| `OWNER_KEY_COMPROMISE.md` written | ✅ done | CTO/engineer | done |
| Production monitoring checklist | ⬜ pending | CTO/engineer | 0.5 day |
| `UNI_BURN_NOTES.md` written (feat) | ✅ done | engineer | done |
| Code freeze on the helper-externalized ownerless calldata-route audit branch | ✅ done | engineer | 30 min |

### Build decision (settled)

There is a **single canonical build**: the ownerless hook + 5 bps TokenJar fee pipeline. There
is no `main` vs `feat` / 0 bps fork to choose between — this version pushes fees into Uniswap's
official TokenJar, with downstream UNI burn handled by Firepit, making it Hooks-Marketplace-eligible
and Foundation-aligned. Audit cost ~$30-50K (Cantina lite).

---

## Phase 2 — Audit firm selection + contract (2-3 weeks)

### Vendor shortlist

| Firm | Style | Duration | Cost | Notes |
|---|---|---|---|---|
| **Cantina** | Team audit + competition + fixes review | 3-5 weeks | $80-150K | V4 specialists, Foundation relationships |
| **Spearbit** | Slack-channel + lead auditor | 4-6 weeks | $100-200K | Top-tier, hardest to book |
| **Code4rena** | Public 5-7 day competition + multiple wardens | 7-14 days | $50-100K (incl. award pool) | Fast + breadth, less depth |
| **OpenZeppelin** | Slow, thorough, reputable | 6-8 weeks | $150-250K | Conservative timeline |
| **Sherlock** | Competition + built-in insurance | 10-14 days | $80-120K | Insurance is the differentiator |

**Recommendation (Ring V1 budget)**: Cantina lite review (~$30K, 2 weeks) — small independent review well-suited for "V1 medium-size project that needs a sign-off".

### Action items

| # | Action | Owner |
|---|---|---|
| 1 | Email 3 firms requesting quotes | CEO |
| 2 | Provide audit package (repo URL + frozen commit + all docs) | CTO |
| 3 | Negotiate scope + cost + timeline | CEO |
| 4 | Contract signed, kickoff scheduled | CEO |

### Audit package contents

When emailing firms, attach or link:

```
1. Repo: github.com/RingProtocol/ring-v4-aggregator-hook-audit
2. Branch: `audit-r3-uniswap-periphery-helpers` (based on the frozen `audit-ownerless-calldata-route-2026-05-25-r3` tag)
3. Base audit tag: `audit-ownerless-calldata-route-2026-05-25-r3`
4. Build instructions: README.md "Build & test" section
5. Docs to read (in order):
   - README.md
   - docs/INDEX.md → leads to all other docs
   - workspace DESIGN.md (architecture)
   - workspace RATIONALE.md (decisions)
6. Test status: 88/88 passing (25 unit + 5 invariant + 58 fork)
7. Static analysis: docs/SLITHER_TRIAGE.md (0 real findings)
8. Threat model: docs/OWNER_KEY_COMPROMISE.md
```

---

## Phase 3 — Audit execution (2-8 weeks)

### Standard timeline (Cantina/Spearbit-style)

```
Week 1-2:  Audit team reads code + docs, runs their own tooling (slither/mythril/echidna)
Week 3-4:  Findings list delivered as draft (Critical/High/Medium/Low/Info)
Week 5:    Ring team responds to findings (fix / accept-risk / dispute)
Week 6:    Re-audit of fixes
Week 6+:   Final public report
```

### Parallel work during audit (do NOT idle)

| Track | Owner | Purpose |
|---|---|---|
| Gnosis Safe 3/5+ multisig deployment | CEO + 4 signers | Phase 4 prerequisite |
| Safe Module timelock (Zodiac Delay 24h) | CTO | Mandatory for RingUniBurner owner powers before meaningful volume |
| Sepolia testnet end-to-end dry run | engineer | Pre-deploy rehearsal |
| HookMiner CREATE2 salt mining | engineer | Hook address with `0x2888` suffix |
| Monitoring setup | CEO | 3 channels live |
| Incident runbook walkthrough | whole team | Confirm everyone knows the SOP |

### Code freeze discipline

- **Do not commit features during audit**. Only `audit-fix-*` commits accepted.
- All audit-fix PRs reviewed by 2 engineers before merge.

---

## Phase 4 — Pre-deploy preparation (parallel with audit, finalizes after audit)

### Multisig setup

1. Deploy Gnosis Safe 3/5+ on each target chain
2. Configure 5 signers — hardware wallets, geographically distributed, never the same as deploy keys
3. Add **Zodiac Delay** module with 24h timelock on the RingUniBurner owner's powers
   (the hook is ownerless — there is nothing to timelock on it):
   - `emergencyWithdraw` (on RingUniBurner)
   - `setFlushPaused` (on RingUniBurner)
   - `transferOwnership` start (you propose, 24h to act, then accept)
4. Test the timelock with a no-op transaction on each chain

### Monitoring setup

Production monitoring checklist:

1. **Tenderly** (Telegram real-time): red + yellow event subscriptions
2. **Etherscan Watch** (email backup)
3. **OpenZeppelin Defender Sentinels** (third channel + future automation)

All 3 fire test alerts in Sepolia rehearsal.

### CREATE2 salt mining

Hook permission flags require deployment address ending in `0x2888`:

```bash
# The hook is ownerless — no OWNER_ADDRESS.
FEE_RECIPIENT_ADDRESS=<safe> UNI_BURNER_ADDRESS=<uniburner> \
  forge script script/MineHookAddress.s.sol --via-ir
# Output: HOOK_SALT, EXPECTED_HOOK_ADDRESS
```

---

## Phase 5 — Mainnet deployment (D-Day)

Step-by-step on Ethereum mainnet (per [`README.md`](../README.md) Deploy section):

```sh
# 1. Deploy RingUniBurner (CREATE2, deterministic across chains).
#    OWNER_ADDRESS is the RingUniBurner owner — the ONLY privileged key (a multisig).
OWNER_ADDRESS=<safe>  forge script script/DeployUniBurner.s.sol  \
                       --rpc-url $ETH_RPC --broadcast --via-ir --verify

# 2. Mine hook CREATE2 salt (hook is ownerless — no OWNER_ADDRESS).
UNI_BURNER_ADDRESS=<above>  FEE_RECIPIENT_ADDRESS=<safe>  \
                            forge script script/MineHookAddress.s.sol --via-ir

# 3. Deploy hook (6 post-deploy state asserts run automatically; also initializes
#    the ETH/USDC pool unless SKIP_INIT_POOL=true). No OWNER_ADDRESS — hook is ownerless.
HOOK_SALT=<mined> EXPECTED_HOOK_ADDRESS=<mined> UNI_BURNER_ADDRESS=<above>  \
FEE_RECIPIENT_ADDRESS=<safe>                                               \
   forge script script/DeployMainnet.s.sol --rpc-url $ETH_RPC --broadcast --verify --via-ir

# 4. RingUniBurner owner is already the multisig from step 1 — no transfer needed.
#    The hook has no owner, so there is nothing to transfer.

# 5. Smoke swap (tiny ETH → USDC) to verify e2e
cast send <hook_addr> "..." ...
```

**Post-deploy 24h observation**: do nothing, just watch monitoring. Confirm no anomalies.

---

## Phase 6 — Submit PRs to Uniswap official

### 6a. `Uniswap/hooklist` (V4 hook registry)

Adds an entry to the canonical hook list. Required before routing-api PR.

```sh
# 1. Open issue on Uniswap/hooklist
gh issue create --repo Uniswap/hooklist --title "Submit Hook: Ring V4 Aggregator Hook" \
  --body "Chain: ethereum, Address: <hook addr>"
# 2. Their automation (Claude Code workflow) fetches Etherscan-verified source,
#    generates JSON, opens PR
# 3. Maintainer review + merge (1-2 weeks typical)
```

### 6b. Ring self-hosted routing-api allowlist (immediate, low-stakes)

```sh
# In Ring's internal ring-routing-api repo:
git checkout -b allowlist-aggregator-hook
# Edit allowlist file, add hook address
git commit && gh pr create
# Internal review + merge in 1 day → starts serving ring.exchange users
```

This gets Ring's own front-end traffic into the hook within a week — provides initial volume data that strengthens the upcoming Uniswap official PR.

### 6c. `Uniswap/routing-api` allowlist (the BIG one)

After 30 days of on-chain history, submit the **main flow-routing PR**:

```sh
# 1. Fork Uniswap/routing-api on GitHub
# 2. Clone your fork
git clone git@github.com:Few-Protocol/routing-api.git
cd routing-api
git checkout -b allowlist-ring-v4-aggregator-hook
# 3. Edit allowlist file (precedent: PR #1302)
# 4. Commit + push
git commit -m "feat: allowlist Ring V4 Aggregator Hook on mainnet"
git push origin allowlist-ring-v4-aggregator-hook
# 5. Open PR from your fork → Uniswap/routing-api main
```

**Required PR description content**:

- Hook address + Etherscan verified link
- Audit report PDF link (Cantina/Spearbit/...)
- Gas benchmarks for typical swap
- Test coverage: 88/88 passing
- Monitoring policy summary
- Slither baseline link (`SLITHER_TRIAGE.md`)
- Multisig address + Etherscan verified
- Initial volume data (from Phase 6b's 30 days)
- Deployment chain list

**Review cycle**: 3-6 weeks. Maintainers will ask about slippage protection, DoS risk, owner-key risk, upgrade path. Be ready with answers from `OWNER_KEY_COMPROMISE.md` + `RATIONALE.md`.

---

## Phase 7 — Hooks Marketplace application

When Foundation opens the Marketplace application (Q2 2026 per their roadmap):

1. Submit application via Foundation portal
2. Provide: audit report + on-chain metrics (30+ days) + hooklist registry merged
3. 4-8 week review
4. If accepted: allocated incentive pool share
5. Incentives distributed to FewV2 LPs → TVL flywheel begins

---

## Phase 8 — Live operations (ongoing)

| Cadence | Activity |
|---|---|
| 24/7 | Monitor alerts (Tenderly Telegram + Etherscan email + Defender) |
| Hourly | Keeper bot calls `RingUniBurner.flush()` (feat) — limits burner-side accumulation |
| Weekly | Review volume / fee / FewV2 LP earnings |
| Monthly | CEO/CTO report to board + investors |
| Quarterly | UNIfication metrics review (TokenJar forwarding + downstream Firepit burn impact) |
| Semi-annual | Consider V2 roadmap |

---

## Full timeline

```
T+0       this commit
          │
T+1w      Phase 1 done (this work)
          │
T+2w      Phase 2: 3 audit quotes received → contract signed
          │
T+8w      Phase 3: audit report delivered (Cantina lite = 6 weeks typical)
          │
T+10w     Phase 4-5: multisig live + mainnet deploy
          │  └─ Ring self-routing-api PR merged → ring.exchange users start using H
          │
T+14w     Phase 6a: Uniswap hooklist PR opened
          │
T+15w     Phase 6c: Uniswap routing-api PR opened (need 30 days mainnet data)
          │
T+18w     Phase 6a: hooklist PR merged
          │
T+20w     Phase 6c: routing-api PR merged → uniswap.org users start routing through H
          │
T+24w     Phase 7: Hooks Marketplace application submitted
          │
T+32w     Phase 7: Marketplace approval + incentives flow to FewV2 LPs
          │
T+52w     Phase 8: 12-month review + V2 planning
```

**Critical path total: 20 weeks = 5 months from now to uniswap.org main traffic.**

---

## Decision gates (CEO sign-off required)

| Gate | When | Decision |
|---|---|---|
| 1 | Phase 1 → 2 | (settled) single ownerless calldata-route build is the audit target |
| 2 | Phase 2 → 3 | Pick audit firm (Cantina / Spearbit / Code4rena) |
| 3 | Phase 3 → 4 | Approve audit-fix PRs |
| 4 | Phase 4 → 5 | Multisig signer list locked + tested |
| 5 | Phase 5 → 6 | Mainnet deploy go/no-go (Sepolia rehearsal complete + all monitoring live) |
| 6 | Phase 6c | Uniswap routing-api PR maintainer response — modify or escalate |

---

## Cost summary

| Phase | Cost (recommended path) |
|---|---|
| Phase 1-2 prep | engineering time (~$0 external) |
| **Phase 3 audit** | **~$30-50K** (Cantina lite) |
| Phase 4 multisig setup | $0 (Safe is free, hardware wallets one-time ~$1K) |
| Phase 5 deploy gas | $500-2K per chain (mainnet expensive, L2s cheap) |
| Phase 6 PR work | engineering time |
| Phase 7-8 ops | engineering time (24/7 monitoring rotation) |
| **Total external spend (5 months)** | **~$50K-$100K** |

Expected return (internal neutral-scenario projection):
- FewV2 LP income: $200-500K (6 months)
- Hooks Marketplace incentives: $200-500K
- **Net: $250K-$850K positive**

---

## Worst-case bailout (decision points)

| Scenario | Bailout |
|---|---|
| Audit finds Critical/High → 6+ week delay | Accept delay, fix, re-audit |
| Audit cost overruns | Renegotiate with firm or switch to Code4rena (cheaper) |
| Mainnet deploy revealed bug 24h-7d after | No pause (ownerless) — delist at the routing layer (ring.exchange + Uniswap routing-api), then redeploy V2 |
| Uniswap routing-api PR rejected | Stay with hooklist-only + Ring self-routing-api (lower flow but viable) |
| Hooks Marketplace not granted | Continue operations on FewV2 LP fees alone (still profitable per internal projections) |

All bailouts preserve the contract code itself — no scenario forces complete write-off.

---

## TL;DR

```
Now → audit firm contracted in 2 weeks
    → audit done in 8 weeks
    → mainnet deploy in 10 weeks
    → Ring traffic in 11 weeks
    → Uniswap official traffic in 20 weeks (5 months)
    → ~$50-100K external spend
    → expected $250-850K return in first 6 months post-deploy
```

Critical decision is **CEO picking the audit firm + branch** — everything else follows.
