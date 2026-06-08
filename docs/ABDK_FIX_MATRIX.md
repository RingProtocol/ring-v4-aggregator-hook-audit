# ABDK Draft Report Fix Matrix

This matrix responds to ABDK draft report v0.1 for Ring Protocol's Aggregator Hook.

Patch branch: `abdk-report-fixes`

Verification:

- `forge test` passed: 76 tests, 0 failures, 0 skipped.
- Full suite includes unit tests, invariants, mainnet fork tests, and V4Quoter exact-in / exact-out fork tests.

## Patch Scope

The patch intentionally keeps the product behavior unchanged:

- direct-only FewV2 route per v4 pool;
- no in-hook connector engine;
- no admin / pause / upgrade path in `RingAggregatorHook`;
- unchanged 5 bps protocol fee path to `RingUniBurner`;
- unchanged wrap -> FewV2 swap -> unwrap -> PoolManager settlement flow.

We fixed findings that could affect safety, audit outcome, or important operational correctness. Pure readability / typing / naming suggestions were acknowledged but mostly not changed to keep the review diff narrow and avoid re-opening the already reviewed business logic.

## Fixed / Addressed

| ID | Status | Response |
| --- | --- | --- |
| CVF-1 | Fixed | Replaced `uint256(-params.amountSpecified)` with checked conversion through `_exactInputAmount`. The helper first bounds the value to an int128-compatible v4 delta, then uses OpenZeppelin `SafeCast.toUint256`. Added regression test for `type(int256).min` and unrepresentable exact-input deltas. |
| CVF-4 | Addressed | Kept the Uniswap V2 exact-output `+1` convention, but reworded the comment so it no longer claims that `+1` is mathematically identical to generic ceil rounding. |
| CVF-8 | Addressed | Added a comment before the native ETH forwarding call in `sweep`, clarifying that native ETH can only be swept to the immutable `feeRecipient`. |
| CVF-9 | Addressed | Removed the hard-coded "5 bps" value from the `RingUniBurner` notice and described it as the protocol fee received from `RingAggregatorHook`. |
| CVF-10 | Addressed | Replaced hard-coded TokenJar deployment details in `RingUniBurner` comments with a reference to Uniswap's `protocol-fees` repository and the constructor-supplied `_tokenJar`. |
| CVF-11 | Addressed | Reworded the flush comment to state that `flush(fewToken)` is permissionless only while `flushPaused` is false. |
| CVF-12 | Fixed | `RingUniBurner.emergencyWithdraw(address(0), to)` now rescues native ETH, including ETH force-sent via `selfdestruct`. Added owner-only native ETH withdrawal test. |
| CVF-13 | Fixed | Added `nonReentrant` to `RingUniBurner.emergencyWithdraw`, matching `flush`. |
| CVF-15 | Fixed | Added named `FEE_NUMERATOR` and `FEE_DENOMINATOR` constants in `FewV2Math`; replaced raw `997` / `1000` math literals. |
| CVF-16 | Fixed | Reworded FewV2 math comments to refer to `FEE_NUMERATOR` / `FEE_DENOMINATOR` instead of repeating raw constants. |
| CVF-17 | Fixed | Made `FewV2Math` use the same `pragma solidity 0.8.26` as the rest of the audited contracts. |
| CVF-30 | Addressed | Moved the `payer` inline comment next to the unnamed `address` parameter in `_pay`. |
| CVF-35 | Fixed | Added `USER_FEE_BPS` as a constant and rewrote exact-output fee gross-up to use the precomputed constant expression. |
| CVF-36 | Fixed | Same as CVF-35. |
| CVF-44 | Addressed | Added an explanatory comment inside the empty native ETH `receive` block. |

Additional defensive fix:

| Item | Status | Response |
| --- | --- | --- |
| Zero-output exact-input edge | Fixed | `FewV2Math.getAmountOut` now reverts if the V2 formula floors to zero output. This avoids reaching `pair.swap(0, 0, ...)` on tiny exact-input swaps against very small reserves. Added a unit test. |

## Acknowledged / By Design

| ID | Status | Response |
| --- | --- | --- |
| CVF-2 | Acknowledged | We did not expand the full custom-error parameter surface in this patch. Errors that already carry security-critical context remain parameterized. Keeping the existing error interface avoids a larger ABI-level diff for a low-severity documentation issue. |
| CVF-3 | By design | Zero input and zero requested output remain invalid for this hook. A zero amount has no useful swap semantics and can hide caller mistakes. The patch further rejects exact-input quotes that floor to zero output. |
| CVF-5 | Acknowledged | `PROTOCOL_FEE_BPS` remains public for external introspection; `FEE_DENOM` remains an internal implementation constant. We added `USER_FEE_BPS` to make exact-output fee math clearer without changing the public surface. |
| CVF-6 | Acknowledged | `_defaultFewPair` remains simple and explicit. Changing it would be readability-only and would not alter safety. |
| CVF-7 | Acknowledged | `_wrap` / `_unwrap` branch duplication is intentional and keeps ETH and ERC20 flows easy to audit locally. We avoided refactoring settlement-adjacent code for a readability-only item. |
| CVF-14 | Acknowledged | Redundant arithmetic parentheses were left mostly unchanged where they improve local readability. No safety impact. |
| CVF-18 | By design | Exact compiler pinning is intentional for reproducible audit and deployment builds. The project compiles and deploys with `solc 0.8.26`, `via-ir`, Cancun. |
| CVF-19 | Acknowledged | The imported Few interfaces are ABI references to existing Ring systems, not new production logic in this review surface. |
| CVF-20 | Acknowledged | `UseFewTokenHookForWrapPairs` remains unchanged to avoid ABI churn. The current name is explicit enough: wrap pairs should use the FewToken hook, not this aggregator hook. |
| CVF-21 | Acknowledged | Pair addresses in custom errors remain `address` because Solidity custom errors and indexed explorer displays are clearer with raw addresses. |
| CVF-22 | Acknowledged | `PROTOCOL_FEE_BPS` remains `uint24`; this is a small public constant and changing it would be ABI/style churn without safety benefit. |
| CVF-23 | Acknowledged | `_approved` stays keyed by raw addresses because it is an internal approval cache used with both ERC20 underlyings and fewToken spender addresses. |
| CVF-24 | Acknowledged | `DirectRoute.pair` stays as `address` to keep the struct compact and avoid wider typing churn across helper calls. Every use is validated through `fewV2Factory.getPair` and `_hopState`. |
| CVF-25 | Acknowledged | `fewIn` / `fewOut` stay as `address` in the route struct. Canonical validation comes from `fewFactory` and pair derivation, not from the static type alone. |
| CVF-26 | Acknowledged | The `router` event field remains `address` because the hook can be called by multiple router/executor contracts, not one specific interface. |
| CVF-27 | Acknowledged | Event token fields remain `address` for explorer readability and compatibility with native ETH represented as `address(0)`. |
| CVF-28 | Acknowledged | `UniFeeAccrued` keeps the fee token as `address` for indexed event filtering and explorer compatibility. |
| CVF-29 | By design | Constructor zero-address checks are intentionally retained. They catch deployment misconfiguration early and do not weaken security. |
| CVF-31 | Acknowledged | `_isFewTokenOf` is unchanged. The duplicated zero-address guard is readability-only and does not affect behavior. |
| CVF-32 | Acknowledged | No change. The current direct returns are concise and behaviorally clear. |
| CVF-33 | Acknowledged | Same as CVF-32. |
| CVF-34 | Acknowledged | The two `zeroForOne` ternaries remain explicit for local readability. No safety impact. |
| CVF-37 | Acknowledged | `fewToken` parameters remain addresses to avoid refactoring the routing/wrap/unwrap helpers. Runtime checks against `fewFactory`, wrap/unwrap mismatch checks, and pair derivation provide the actual safety boundary. |
| CVF-38 | Acknowledged | No else-block refactor. The early-return style is intentional and avoids touching wrap/unwrap flow structure. |
| CVF-39 | Acknowledged | `token` parameters remain addresses because `address(0)` is used for native ETH in `sweep` and `emergencyWithdraw`. |
| CVF-40 | Acknowledged | Pair helper parameters remain addresses to keep the diff narrow. Pair identity is still verified by `fewV2Factory.getPair`, `token0/token1`, and reserves. |
| CVF-41 | Acknowledged | Token helper parameters remain addresses for consistency with `Currency.unwrap`, native ETH handling, and existing pair calls. |
| CVF-42 | Acknowledged | `defaultRouteFor` intentionally returns addresses for ABI/explorer usability. |
| CVF-43 | Acknowledged | Same as CVF-42. Returning a raw pair address is easier for integrators and explorers. |
| CVF-45 | Acknowledged | `RingUniBurner` event and error fields remain addresses for indexed event filtering and explorer readability. |
| CVF-46 | Acknowledged | Same as CVF-45. |
| CVF-47 | Acknowledged | The constructor keeps `_fewFactory` as `address` to keep the deployment interface simple and consistent with script inputs; it is immediately cast to `IFewFactory` after zero-address validation. |

## Notes for ABDK Recheck

The main security-relevant fixes are CVF-1, CVF-12, and CVF-13. The patch also closes several documentation/math clarity items without changing the hook's routing behavior.

We intentionally did not implement broad typing, naming, or readability refactors because they would expand the recheck diff while providing little security value. Where we retained the original code, the decision is either defensive by design, ABI/explorer compatibility, or diff minimization for an already reviewed direct-only hook.
