# Known Issues & Accepted Residual Risks

> **Purpose**: tell external auditors what we already found and how we disposed of it, so audit hours go to net-new analysis. **This is not a claim that these are the only issues** — it is a disclosure of our internal pre-audit review (CTO-level) and Slither triage. We explicitly invite the firm to challenge every disposition here.
>
> **Build**: ownerless calldata-route hook + 5 bps TokenJar fee pipeline. The hook has no owner, no pause, no admin routes, immutable wiring, empty-hookData default auto-routing over direct + fixed connectors, and bounded calldata routes. The hook does not burn UNI itself; it pushes fees to Uniswap's TokenJar, with downstream UNI burn handled by Firepit. Audit commit frozen at kickoff.

---

## Severity legend

| | |
|---|---|
| **Mitigated** | Defence in code; residual risk documented + accepted by Ring. |
| **Resolved by design** | A class of risk eliminated by an architectural choice (e.g. immutability). |
| **Accepted** | Operational/economic risk; no code change; bounded by process. |
| **False positive** | Tool/analysis flagged; not a real issue (reasoning given). |

---

## Medium

### M1 — `uniBurner` reverting transfer would halt the protocol — *Mitigated*

**Issue**: `_skimUniBurnFee` does `IERC20(fewToken).safeTransfer(uniBurner, fee)` on every swap. If `uniBurner` were a contract whose token receipt reverts, **every swap would revert** — protocol-wide DoS.

**Mitigations in code**:
- `uniBurner` is **immutable** — set once at construction to the audited `RingUniBurner` and never changeable. The "malicious rotation" vector (a compromised owner repointing it to a hostile contract) **does not exist**: the hook has no owner and no setter.
- `RingUniBurner` is a minimal push-source adapter: standard ERC20 balances, no reverting `receive`/`fallback`, no external calls in the receive path. Ring fewTokens are plain ERC20 wrappers (no transfer hooks), so a `safeTransfer` into the burner always succeeds.
- The constructor rejects a zero `uniBurner` (`ZeroAddress`), so the fee path can never deploy mis-wired to an unset address.

**Residual risk**: negligible. With no rotation path and a known-good immutable burner, there is no owner-reachable way to turn the fee transfer into a DoS. (The earlier admin build bounded this with a 24h rotation timelock + emergency pause; **immutability removes the vector outright**, which is strictly stronger.)

**Auditor ask**: confirm there is no path — owner or otherwise — by which the per-swap `safeTransfer(uniBurner, fee)` can be made to revert.

---

### M2 — `RingUniBurner.emergencyWithdraw` is an owner backdoor — *Mitigated/Accepted*

**Issue**: `emergencyWithdraw(token, to)` lets the **RingUniBurner owner** move any token held by the burner to an arbitrary address. A compromised owner could redirect accumulated, not-yet-flushed protocol fees away from the TokenJar/Firepit path.

> Note: this is the **RingUniBurner's** owner — a *separate* contract from the ownerless hook. The hook itself has no owner. This is the only privileged key in the system.

**Mitigations**:
- The burner holds at most the fee accumulated since the last permissionless `flush()`. `flush()` is callable by **anyone** (keeper bot runs it frequently), so the at-risk balance is small and time-bounded.
- RingUniBurner owner -> Gnosis Safe 3/5+ with a 24h Safe-module timelock on `emergencyWithdraw` and `setFlushPaused` (deployment requirement, `docs/OWNER_KEY_COMPROMISE.md`).
- All `emergencyWithdraw` calls emit an event and must be monitored by the production alerting stack.

**Residual risk accepted**: a fully-compromised burner multisig could still drain the small in-flight fee balance. This is an inherent property of having any emergency-recovery function; removing it creates a worse failure mode (stuck fees if the TokenJar address ever changes). Net: accepted, bounded to "fees since last flush" — never user funds.

**Auditor ask**: confirm `emergencyWithdraw` cannot reach *user swap funds* or *settled pool funds* — only the burner's own transient balance.

---

### M3 — uniBurner mutability eliminated — *Resolved by design*

**Was**: earlier admin revisions exposed `setUniBurner(address)` (immediate) and later a `proposeUniBurner` / `executeProposedUniBurner` rotation timelock. Either way, uniBurner mutability created an owner-compromise rotation surface that amplified M1.

**Now**: `uniBurner` is **immutable** — no setter, no propose/execute, no timelock to mis-implement. The entire rotation attack surface is removed at the language level. Changing the burner requires deploying a new hook.

No residual — listed so auditors don't look for a rotation mechanism that no longer exists.

---

## Low (internal pre-audit findings — disposition stated, all invited for challenge)

| ID | Issue | Disposition |
|---|---|---|
| L1 | `_approved[token][spender]` caches `type(uint256).max` approval | Accepted — spender is always a fewToken (from the immutable `fewFactory`) or the resolved fewV2 pair; the hook holds no idle balance between txs (atomic swap). |
| L2 | `tx.origin` used in `SwapAggregated` event | Accepted — analytics only, never an auth check. |
| L3 | Cross-chain fork tests only run vs Ethereum mainnet | Open — per-chain fork suites to be added before each non-mainnet deployment. Not a mainnet-launch blocker. |
| L4 | `_pay` ignores `payer` param, always pays from `address(this)` | Accepted — correct by construction; hook always custodies the token before settle. |
| L5 | `lpFeeOverride` return is hardcoded `0` | Accepted — moot; AMM loop is fully absorbed by `beforeSwapReturnDelta`, the fee override is never consulted. Documented. |

**Removed from the prior admin build** (so auditors don't re-report findings against deleted code): hook ownership, pause, admin route registry, mutable route/fee/burner controls, and `block.timestamp` timelock comparisons. This branch intentionally reintroduces route loops, but only as immutable-code default routing over 6 fixed connectors or caller-supplied calldata paths whose intermediates are restricted to that same connector set.

---

## Static analysis (Slither)

**Re-run on the ownerless calldata-route build: 27 detector hits, 0 real** (full triage in `docs/SLITHER_TRIAGE.md`). The admin build had 28; `timestamp` disappeared with the deleted timelocks, while `calls-loop` returned by design because this branch performs bounded route quoting/execution over fixed connectors and calldata paths.

The remaining 27 are all false-positive / by-design: bounded `calls-loop` findings, `unused-return` tuple/return discards, BaseHook abstract stubs, event-after-transfer warnings, `_calldataRoute` complexity from grouped validation, one approval-cache write warning, one native ETH transfer warning, one strict zero-balance equality, and one Slither override-chain quirk. No code change.

---

## Non-issues frequently raised (pre-empting noise)

1. **"The V4 pool shows $0 TVL on Etherscan/DexScreener/DeFiLlama."** Cosmetic. The pool intentionally holds zero liquidity; all liquidity is in FewV2 and the hook absorbs the swap in `beforeSwap`. Real economic depth is the FewV2 pair (~$25M on fwETH/fwUSDC). Not a vulnerability.
2. **"routing-api won't find a 0-liquidity pool."** Correct, and expected. Off-chain routing-api filters by subgraph liquidity; the hook must be added to the routing-api **allowlist** (PR, post-deploy — see `docs/DEPLOYMENT_FLOW.md` Phase 6c, precedent PR #1302). On-chain `V4Quoter` *does* quote it natively because it executes `beforeSwap`; this branch now has explicit V4Quoter empty-hookData exact-in/exact-out fork tests. This is an operational integration step, not a contract defect.
3. **"`key.fee = 3000` but no V4 fee is collected."** Intentional. The fee field is a routing-api ranking label only; the AMM loop never runs (full delta absorption), so `key.fee` is never charged. The real 30 bps is the FewV2 LP fee inside `pair.swap()`. Documented in `docs/DESIGN.md` §6.4.

---

## Summary for the auditor

- **0 Critical, 0 High** found internally. We expect the firm to either confirm or break this.
- **2 Medium**: M1 (per-swap fee-transfer DoS vector — removed by making `uniBurner` immutable) and M2 (burner `emergencyWithdraw`, bounded to in-flight fees, never user funds). M3 resolved by design.
- **5 Low**: accepted with reasoning, 1 open (L3, non-blocking).
- **Slither**: 27/27 triaged on the ownerless calldata-route build, 0 real (bounded `calls-loop` findings are expected; `timestamp` is gone).
- The highest-value place to spend audit hours: the `BeforeSwapDelta` sign matrix (all 4 directions), default-route exact-in/exact-out quote selection, calldata-route validation bounds, cross-contract reentrancy via `fewV2Pair.swap()`, and the burner-owner-compromise economic bounds in `docs/OWNER_KEY_COMPROMISE.md`.
