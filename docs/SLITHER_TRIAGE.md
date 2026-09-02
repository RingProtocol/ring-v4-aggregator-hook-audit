# Slither Triage Report

> **Tool**: Slither 0.11.4
> **Date**: 2026-09-01
> **Branch**: `audit-router-compat-aggregator-interface`
> **Scope**: `src/RingAggregatorHook.sol`, `src/RingUniBurner.sol`, `src/lib/FewV2Math.sol`
> **Result**: 7 outputs, all triaged; no code change required
> **Run summary**: `42 contracts analyzed (97 detectors), 7 result(s) found`

---

## Reproduce

```bash
slither . \
  --filter-paths "lib/|test/|script/" \
  --exclude naming-convention,solc-version,pragma
```

Excluded detectors:

| Detector | Reason |
|---|---|
| `naming-convention` | Style noise |
| `solc-version` | Compiler is intentionally pinned to `0.8.26` |
| `pragma` | Pinned for reproducible builds |

---

## Findings

| Detector | Location | Verdict |
|---|---|---|
| `incorrect-equality` | `RingUniBurner.flush` zero-balance no-op | By design |
| `reentrancy-no-eth` | `RingAggregatorHook._ensureApproval` approval cache write | False positive |
| `unused-return` | `RingAggregatorHook._hopState` ignores V2 timestamp | By design |
| `unused-return` | `RingAggregatorHook.pseudoTotalValueLocked` ignores V2 timestamp | By design |
| `reentrancy-events` | `RingAggregatorHook._skimUniBurnFee` event after transfer | False positive |
| `low-level-calls` | `RingAggregatorHook.sweep` native ETH call | By design |
| `low-level-calls` | `RingUniBurner.emergencyWithdraw` native ETH call | By design |

The prior `calls-loop` category is gone in this branch because connector routing and calldata multi-hop execution were removed.

---

## Triage Notes

### `RingUniBurner.flush` balance checks

`flush(fewToken)` reads the burner's own FewToken balance, unwraps exactly that balance, checks the unwrap amount, and transfers the resulting underlying token to TokenJar. The function is `nonReentrant`, and the FewToken is canonical-validated through `fewFactory`. A mismatch reverts. The reported zero-balance equality is the exact no-op condition.

### `_ensureApproval`

`_ensureApproval` calls `forceApprove` and then writes an internal approval cache. The cache is only a gas optimization. The spender is a canonical FewToken wrapper for the underlying token, and `_beforeSwap` is `nonReentrant`. A failed or reentrant approval cannot redirect funds or change routing.

### Ignored V2 timestamp

`getReserves()` returns `(reserve0, reserve1, blockTimestampLast)`. The hook only needs reserves, so the timestamp is intentionally ignored.

The same applies to `pseudoTotalValueLocked`: UniRoute needs a reserve-backed external-liquidity proxy, not the pair timestamp.

### Event-after-transfer warnings

The events are emitted after the corresponding transfer. The functions are `nonReentrant`, and no security decision depends on event ordering.

### Native ETH sweep / rescue

The hook uses `call` to transfer ETH to the immutable `feeRecipient`, which is the standard way to avoid fixed-gas-stipend issues. `sweep` is `nonReentrant`, and the recipient cannot be changed.

`RingUniBurner.emergencyWithdraw` also uses `call` for native ETH rescue. It is owner-only, `nonReentrant`, and scoped to balances already held by the burner.

---

## Summary

All 7 current outputs are false-positive or by-design. No current Slither output requires a code change.
