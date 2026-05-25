# Calldata Route Security Notes

> Branch: `ownerless-calldata-route`
> Last updated: 2026-05-25
> Scope: ownerless default auto-routing plus bounded multi-hop path support via `beforeSwap` `hookData`

---

## 1. Security Claim

This branch keeps the important ownerless claim:

> Default auto-routing and calldata routes do not introduce admin or governance fund risk. User fund risk is limited to the caller's own transaction, the route selected by immutable code from immutable factories, and the caller-signed slippage bound.

What changed is the execution surface:

- Empty `hookData` now runs the built-in default router: direct FewV2 route plus a fixed deploy-time connector set.
- Non-empty `hookData` enables a per-swap path, but hidden intermediates must be members of the same fixed connector set.
- The caller supplies FewToken path intent, not pair addresses.
- The hook derives every pair from immutable `fewV2Factory`.
- The hook validates every path token against immutable `fewFactory`.
- The deploy-time connector set is canonical-validated and duplicate-rejected in the constructor.

No owner can change routes globally because there is still no owner, no route registry, no pause, no fee setter, and no burner setter.

---

## 2. ABI

### Empty `hookData`

Empty `hookData` is the Uniswap-facing default path. The hook compares:

```text
fewInput -> fewOutput
fewInput -> fixedConnector[i] -> fewOutput
```

for `i in [0, 5]`, using the immutable default connector set:

```text
fwWETH, fwWBTC, fwUSDC, fwUSDT, fwDAI, fwUSDR
```

Exact-input chooses the candidate with the highest gross FewToken output. Exact-output chooses the candidate with the lowest required input for the grossed-up target. Direct is evaluated first and wins ties.

Empty-hookData swaps intentionally do **not** add a hook-level `amountLimit`: Uniswap Universal Router / classic router integrations enforce the user's `amountOutMinimum` or `amountInMaximum` around the v4 swap. A direct `PoolManager` caller with no router slippage is using a low-level interface and accepts that risk, similar to calling Uniswap core directly.

### Non-empty `hookData`

Non-empty `hookData` is:

```solidity
abi.encode(address[] fewPath, uint256 amountLimit)
```

`fewPath` is in execution order:

```text
fewInput -> fewIntermediate... -> fewOutput
```

`amountLimit` meaning depends on swap mode:

| Swap mode | Meaning |
|---|---|
| Exact input (`amountSpecified < 0`) | Minimum underlying output after the 5 bps fee skim |
| Exact output (`amountSpecified > 0`) | Maximum underlying input the hook may take |

`amountLimit == 0` is rejected for calldata routes.

---

## 3. On-Chain Validation

For every calldata route, the hook enforces:

| Check | Reason |
|---|---|
| Path length >= 2 | At least one FewV2 hop is required |
| First FewToken matches PoolKey input | Caller cannot swap a different asset than the v4 pool side |
| Last FewToken matches PoolKey output | Caller cannot redirect output to another asset |
| Every path token is canonical | `IFewWrappedToken(few).token()` must map back through `fewFactory.getWrappedToken(underlying) == few` |
| Intermediate token is a default connector | Hidden hops cannot be arbitrary user-selected assets |
| No duplicate FewToken | Prevent cycles and repeated-state reasoning |
| Pair derived on-chain | `fewV2Factory.getPair(path[i], path[i+1])`, never user supplied |
| No duplicate pair | Defensive guard against repeated pair state assumptions |
| Pair token shape checked per hop | `token0/token1` must match the hop direction |
| Reserve sentinel checked per hop | Drained pairs revert with `DegeneratePair` |
| Exact-in minOut checked | Reverts with `SlippageExceeded(actual, limit)` |
| Exact-out maxIn checked | Reverts with `SlippageExceeded(actual, limit)` |

The path length is implicitly bounded: with 6 allowed connectors and duplicate tokens rejected, a calldata path can only contain the two endpoints plus at most the fixed connector set.

---

## 4. Exact-Output Flow

Exact-output routes are quoted backward:

1. Gross up the final requested output so the user still receives the exact target after 5 bps skim.
2. Walk the route backward with V2 `getAmountIn`.
3. Reject if required input exceeds `amountLimit`.
4. Execute the route forward.
5. Skim 5 bps from final FewToken output.
6. Unwrap and require `actualOut >= target`.

Duplicate tokens/pairs are rejected so backward quote assumptions are not invalidated by reusing the same pair later in the same route.

---

## 5. Red-Team Coverage

New fork tests cover:

| Test | Purpose |
|---|---|
| `test_fork_calldataRoute_ETH_to_USDC_viaUSDT_exactInput` | Real mainnet `fwETH -> fwUSDT -> fwUSDC` exact-input execution |
| `test_fork_calldataRoute_ETH_to_USDC_viaUSDT_exactOutput` | Real mainnet backward quote + exact-output gross-up |
| `test_fork_defaultConnectorsConfigured` | Mainnet connector immutables configured and canonical, including `USDR -> fwUSDR` |
| `test_fork_emptyHookData_autoRoute_matchesBestDefaultQuote_exactInput` | Empty-hookData swap matches the best direct-or-connector local quote |
| `test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactInput` | Official V4Quoter can quote empty-hookData exact-input swaps |
| `test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactOutput` | Official V4Quoter can quote empty-hookData exact-output swaps |
| `test_fork_initAllowsFewFactorySupportedPoolWithoutDirectPair` | Pool initialization no longer requires direct FewV2 pair when endpoints have FewTokens |
| `test_attack_calldataRoute_exactInput_minOutReverts` | Min-output protection |
| `test_attack_calldataRoute_exactOutput_maxInReverts` | Max-input protection |
| `test_attack_calldataRoute_zeroLimitReverts` | Rejects calldata routes without slippage limit |
| `test_attack_calldataRoute_endpointMismatchReverts` | First/last token binding to PoolKey |
| `test_attack_calldataRoute_nonDefaultIntermediateReverts` | Rejects arbitrary hidden intermediates outside the fixed connector set |
| `test_attack_calldataRoute_nonCanonicalFewTokenReverts` | Rejects fake/EOA FewToken path entries |
| `test_attack_calldataRoute_duplicateTokenReverts` | Rejects cycles |
| `test_attack_calldataRoute_missingPairReverts` | Rejects unsupported adjacent hops |
| `test_attack_constructor_nonCanonicalDefaultConnector_reverts` | Rejects bad default connector wiring |
| `test_attack_constructor_duplicateDefaultConnector_reverts` | Rejects duplicate default connector wiring |

Current result on this branch: 88/88 tests passing.

---

## 6. Slither Triage

Slither reports 27 results on this branch. The material new class is `calls-loop`:

- default auto-route quote loops over exactly 6 fixed connectors
- constructor canonical FewToken validation over exactly 6 fixed connectors
- canonical FewToken validation inside a bounded calldata path loop
- pair derivation inside a bounded calldata path loop
- per-hop reserve/token checks inside execution/quote loops
- per-hop pair swaps inside execution loops

This is expected for default auto-routing and calldata routes. The loops are not admin-triggered and do not create global protocol state. Empty-hookData loops are fixed at 6 connector candidates; calldata path length is bounded by the same 6-connector set plus endpoints. A malicious caller can make their own transaction revert or run out of gas; they cannot change another user's route or redirect protocol funds.

Other repeated findings remain unchanged from the ownerless build:

- `RingUniBurner.flush` strict zero-balance equality: by design no-op branch
- approval-cache reentrancy warning: guarded by `nonReentrant`; state is an approval cache only
- event-after-transfer warnings: telemetry ordering, no state-invariant dependency
- `_calldataRoute` cyclomatic-complexity warning: expected from one function grouping all path validation checks
- BaseHook dead-code/unimplemented warning: Slither override-resolution quirk
- native ETH sweep low-level call: required to forward ETH to immutable `feeRecipient`

No admin/governance risk is introduced by this branch.

---

## 7. Residual Review Questions

Before this branch is considered audit-ready, reviewers should focus on:

1. Whether SDK/router integration should use a typed helper to avoid bad ABI encoding.
2. Whether route telemetry should emit path hash or connector id for easier monitoring.
3. Whether exact-output surplus dust behavior should remain sweep-based or explicitly refund surplus.
4. Whether the fixed connector set should remain six immutables or be reduced for the first audited deployment.

The current implementation is larger than the frozen `ownerless` direct-route branch, but it is bounded and ready for external audit: no admin state, no user-supplied pairs, no arbitrary hidden intermediates, and V4Quoter-level empty-hookData coverage.
