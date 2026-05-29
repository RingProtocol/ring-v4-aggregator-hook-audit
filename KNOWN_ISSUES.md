# Known Issues & Accepted Residual Risks

> **Purpose**: tell external auditors what we already found and how we disposed of it, so audit hours go to net-new analysis. This is not a claim that these are the only issues.
>
> **Build**: `audit-r3-direct-only-sor`. Ownerless direct-only hook + 5 bps TokenJar fee pipeline. The hook has no owner, no pause, no admin routes, no connector router, no calldata path engine, and no user-supplied pair addresses.

---

## Severity Legend

| Label | Meaning |
|---|---|
| Mitigated | Defense exists in code; residual risk documented |
| Resolved by design | Risk class removed by architecture |
| Accepted | Operational/economic risk accepted with bounded impact |
| False positive | Tool/analysis flagged it; not a real issue |

---

## Medium

### M1 - `uniBurner` fee transfer reverting would halt swaps - Mitigated

**Issue**: `_skimUniBurnFee` transfers 5 bps of the gross output FewToken to immutable `uniBurner` on every swap. If that transfer were made to a reverting receiver, swaps would revert.

**Mitigations**:

- `uniBurner` is immutable and zero-address rejected.
- The hook has no owner and no setter, so there is no malicious rotation path.
- `RingUniBurner` is a small ERC20 balance receiver; it does not run code on receipt.
- Ring FewTokens are ERC20 wrappers without transfer hooks.

**Residual risk**: negligible if deployment wiring is correct. Auditor ask: confirm there is no path by which the per-swap fee transfer can be made to revert through hook state or owner action.

---

### M2 - `RingUniBurner.emergencyWithdraw` can move burner balances - Mitigated / Accepted

**Issue**: `RingUniBurner.owner` can call `emergencyWithdraw(token, to)` and move assets held by the burner. A compromised owner could redirect accrued, not-yet-flushed protocol fees away from TokenJar.

**Important boundary**: this is the burner's owner, not the hook. `RingAggregatorHook` itself has no owner.

**Mitigations**:

- The burner only receives accrued 5 bps fees after a swap has executed.
- User swap funds are never held by the burner.
- `flush(fewToken)` is permissionless, so keepers can frequently push balances to TokenJar.
- Production requirement: Gnosis Safe owner with a timelock for `emergencyWithdraw` and `setFlushPaused`.
- All emergency withdrawals emit events and must be monitored.

**Residual risk accepted**: a fully compromised burner Safe can drain in-flight fee balances before they are flushed. This does not affect user swap funds or PoolManager-settled funds.

---

### M3 - `uniBurner` mutability eliminated - Resolved by design

Earlier revisions had a mutable burner pointer. This branch uses an immutable `uniBurner`. Changing the fee adapter requires a new hook deployment.

---

## Low

| ID | Issue | Disposition |
|---|---|---|
| L1 | `_approved[token][spender]` caches max approval | Accepted. Spenders are canonical FewToken wrappers; hook holds no idle user balance between transactions. |
| L2 | `tx.origin` appears in `SwapAggregated` event | Accepted. Analytics only, never authorization. |
| L3 | Cross-chain fork tests only run against Ethereum mainnet today | Open. Add per-chain fork suites before non-mainnet deployments. |
| L4 | `_pay` ignores `payer` and always pays from `address(this)` | Accepted. The hook takes custody before settlement by construction. |
| L5 | `lpFeeOverride` return is hardcoded `0` | Accepted. The AMM loop is fully absorbed by `beforeSwapReturnDelta`. |

---

## Removed Risk Classes

The current branch removes:

- hook ownership
- hook pause
- admin route registry
- connector whitelist
- built-in connector search
- calldata path decoding
- hook-level route amount limits
- multi-hop route execution loops
- route timelocks
- fee setter
- fee recipient setter
- burner rotation

These are not mitigated by process; they are absent from the deployed hook.

---

## Static Analysis

Slither was re-run on the direct-only branch.

Result: **7 findings, 0 real issues**. Full triage is in [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md).

The prior `calls-loop` category disappeared because connector routing and calldata multi-hop execution were removed.

---

## Non-Issues Frequently Raised

1. **"The v4 pool shows $0 TVL."** Expected. The v4 pool is a shell; liquidity is in FewV2, and the hook absorbs the swap in `beforeSwap`.
2. **"routing-api may not find a zero-liquidity pool automatically."** Expected integration work. The hook needs hooklist / routing allowlist review. On-chain V4Quoter quotes it because it executes `beforeSwap`; fork tests cover exact-in and exact-out.
3. **"`key.fee = 3000` but no v4 fee is collected."** Intentional. The v4 AMM loop is bypassed by full delta absorption. The real LP fee is inside the FewV2 pair swap, and Ring's 5 bps protocol fee is skimmed in the hook.
4. **"A better `A -> X -> B` route is not searched inside the hook."** Intentional. This branch relies on Uniswap routing to compose multiple hook pools, keeping hook code small.

---

## Summary For Auditors

- Internal review found 0 Critical and 0 High.
- Two Medium risks are documented: immutable fee-transfer DoS assumptions and burner-owner fee custody.
- The hook itself has no privileged key.
- Slither baseline is 7 findings / 0 real issues.
- Highest-value audit areas: `BeforeSwapDelta` signs, exact-output gross-up, direct pair validation, wrapper/pair external-call assumptions, reentrancy, and `RingUniBurner` owner blast radius.
