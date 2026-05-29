# Slither Triage Report

> **Tool**: Slither 0.11.5 (Trail of Bits, pip release)
> **Date**: 2026-05-29
> **Scope**: `src/RingAggregatorHook.sol` + `src/RingUniBurner.sol` + `src/lib/FewV2Math.sol`. Uniswap `BaseHook` / `DeltaResolver` are inherited from pinned `lib/v4-periphery` and excluded as third-party dependency code.
> **Build**: the **ownerless calldata-route** hook + 5 bps TokenJar fee pipeline
> **Result**: **22 detector hits, 0 real findings**. All triaged below with reasoning.
> **Run summary**: `42 contracts analyzed (98 detectors), 22 results found`.

This document is **intended to be submitted as part of the package to external audit firms** (Spearbit / Cantina / Code4rena / OpenZeppelin). It shows the team has run the standard static analyzer and explained every output — saving auditor time.

> **Change vs the frozen direct-route ownerless build**: this branch intentionally reintroduces route loops, but without admin state. Empty `hookData` loops over exactly 6 immutable default connectors; non-empty calldata routes are implicitly bounded to endpoints plus those same 6 connectors because intermediates must be fixed connectors and duplicate tokens are rejected. The `timestamp` category remains gone because the hook has no route / uniBurner rotation timelocks.

---

## I. How to Reproduce

```bash
# Prereqs
pip3 install --user slither-analyzer solc-select
solc-select install 0.8.26
solc-select use 0.8.26
export PATH="$HOME/Library/Python/3.9/bin:$PATH"

# Run (from repo root)
slither . \
  --filter-paths "lib/|test/|script/" \
  --exclude naming-convention,solc-version,pragma
```

**Excluded detectors** (and why):

| Detector | Reason for exclusion |
|---|---|
| `naming-convention` | Style; OpenZeppelin uses same patterns. |
| `solc-version` | Pinned to `0.8.26` intentionally for `via_ir` + Cancun. |
| `pragma` | Pinned for reproducibility. |

---

## II. Findings (22) — all false-positive or by-design

| Detector | Count | Locations / reason | Verdict |
|---|---:|---|---|
| `calls-loop` | 13 | Constructor default-connector canonical checks; default-route quote search over 6 connectors; calldata path validation/pair derivation; route quote/execution hop loops | By design, bounded |
| `unused-return` | 2 | Ignored V2 `blockTimestampLast` from `getReserves()` in hop-state helpers | By design |
| `reentrancy-events` | 2 | Event emitted after transfer in `_skimUniBurnFee` and `RingUniBurner.emergencyWithdraw` | False positive |
| `incorrect-equality` | 1 | `RingUniBurner.flush` — `fewBalance == 0` no-op guard | By design |
| `reentrancy-no-eth` | 1 | `_ensureApproval` writes approval cache after `forceApprove` | False positive |
| `reentrancy-balance` | 1 | `RingUniBurner.flush` compares unwrap output against the pre-read fewToken balance | False positive |
| `cyclomatic-complexity` | 1 | `_calldataRoute` groups endpoint/canonical/intermediate/duplicate/pair checks | By design |
| `low-level-calls` | 1 | `RingAggregatorHook.sweep` native ETH `call` | By design |

### `calls-loop`: bounded route loops

The loop findings are the expected static-analysis cost of making the hook route-aware again:

- Empty `hookData` checks direct plus exactly 6 immutable default connectors.
- The constructor canonical-validates those same 6 default connectors and rejects duplicates.
- Non-empty `hookData` validates a caller-supplied path, but intermediate tokens must be default connectors and duplicate tokens are rejected.
- Execution and exact-output backward quoting iterate over the route's derived pairs.

There is no admin-triggered loop and no stored route state. A bad or long calldata path can only revert or waste the caller's own gas; it cannot affect another user, alter global state, or redirect funds. Because intermediates are limited to 6 fixed connectors and duplicates are rejected, calldata paths are implicitly bounded to endpoints plus the connector set. **No fix.**

### `incorrect-equality`: `fewBalance == 0` in `RingUniBurner.flush`

`flush()` early-returns a no-op when the burner holds no fewTokens. The strict `== 0` is intentional and safe: a zero balance is the exact "nothing to flush" condition. There is no rounding or token-balance manipulation that makes `== 0` unsafe here (it is a balance read of the burner's own holdings, used only to skip work). **No fix.**

### `reentrancy-no-eth`: `_approved` written after `forceApprove`

`_ensureApproval` calls `forceApprove(spender, max)` then sets `_approved[token][spender] = true` (an approval cache). The external call is to a Ring fewToken or fewV2 pair (derived from the immutable `fewFactory` / `fewV2Factory`), not arbitrary user code; and the swap entry point `_beforeSwap` is `nonReentrant`, closing any cross-function reentrancy. The cache write being "after" the call only risks a redundant future `forceApprove`, never a fund path. **No fix.**

### `unused-return`: `getReserves()` third field ignored

`(uint112 r0, uint112 r1, ) = ISwapV2Pair(pair).getReserves()` intentionally discards the third field (`blockTimestampLast`), which the hook does not use. Standard V2 idiom. **No fix.**

### `reentrancy-balance`: `RingUniBurner.flush` balance read before unwrap

`flush()` reads the burner's fewToken balance, unwraps exactly that amount, then checks `unwrapped == fewBalance`. The fewToken address is canonical-validated through `fewFactory`, and the function is `nonReentrant`. The pre-read balance is intentionally the accounting target for the unwrap mismatch check; a mismatch reverts and does not create a fund-drain path. **No fix.**

### `reentrancy-events`: event emitted after `safeTransfer`

- `_skimUniBurnFee` emits `UniFeeAccrued` after `safeTransfer(uniBurner, fee)`. The transfer target is the immutable, audited `RingUniBurner` (a plain ERC20 recipient, no hostile callback), and `_beforeSwap` is `nonReentrant`. Event ordering is cosmetic.
- `RingUniBurner.emergencyWithdraw` emits `EmergencyWithdrawn` after `safeTransfer`; the function is `onlyOwner` + `nonReentrant`. 

Neither is a real reentrancy. **No fix.**

### `cyclomatic-complexity`: `_calldataRoute`

`_calldataRoute` intentionally keeps the route-admission checks in one function: endpoint binding, canonical FewToken validation, default-connector intermediate restriction, duplicate-token rejection, pair derivation, and duplicate-pair rejection. Splitting this into many tiny functions would reduce the metric but make the security review less local. **No fix.**

### `low-level-calls`: native ETH transfer in `sweep`

`sweep` sends native ETH to the immutable `feeRecipient` via `address(feeRecipient).call{value: amount}("")` — the correct, recommended way to transfer ETH (vs `transfer`/`send` gas-stipend pitfalls). The destination is immutable and the function is `nonReentrant`. **No fix.**

---

## III. Summary

| Category | Count | Disposition |
|---|---:|---|
| `calls-loop` | 13 | Bounded default connector / calldata route loops |
| `unused-return` | 2 | Intentional tuple discards |
| `reentrancy-events` | 2 | Event-after-transfer; `nonReentrant` + trusted recipients |
| `incorrect-equality` | 1 | `== 0` no-op guard |
| `reentrancy-no-eth` | 1 | Approval-cache write; trusted token + `nonReentrant` |
| `reentrancy-balance` | 1 | Balance snapshot used for unwrap mismatch check |
| `cyclomatic-complexity` | 1 | Localized route-validation function |
| `low-level-calls` | 1 | Native ETH transfer (recommended pattern) |
| **Total** | **22** | **0 require a code change** |

All 22 are false-positive or by-design. One real Slither catch (`uninitialized-local` in `_defaultRoute`) was fixed before this final run by explicitly initializing best-route locals. No remaining finding requires a code change.
