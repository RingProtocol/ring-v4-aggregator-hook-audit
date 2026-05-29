# Ring V4 Aggregator Hook — Ownerless Rationale

> Last updated: 2026-05-25
> Audience: auditor, reviewer, protocol engineer
> Companion docs: `DESIGN.md`, `AUDIT_SCOPE.md`, `KNOWN_ISSUES.md`, `OWNER_KEY_COMPROMISE.md`

> Branch note: this rationale describes the helper-externalized ownerless calldata-route audit
> package: no admin model, empty-hookData default auto-routing, and bounded
> calldata routes. Read `CALLDATA_ROUTE_SECURITY.md` for the route-specific
> validation and red-team pass.

---

## 1. TL;DR

The ownerless build intentionally removes every hook-level governance lever:

- No owner
- No pause
- No custom route registry
- No route timelock
- No burner rotation
- No fee setter
- No sweep recipient setter
- No upgrade path

The result is a smaller and easier-to-audit adapter:

```text
input token -> FewToken.wrap -> direct or fixed-connector FewV2 route -> skim 5 bps -> FewToken.unwrap -> output token
```

The main design decision is philosophical as much as technical: if a feature requires a powerful key, the feature is not in V1. Redeploying a new hook is preferred over shipping dormant admin power.

---

## 2. Why Ownerless

The earlier branch kept a minimal owner for operational convenience. That still left reviewers with the wrong core question:

> "What can the owner do if compromised?"

The ownerless branch changes the premise:

> "What can the hook do after deployment?"

For `RingAggregatorHook`, the answer is fixed by bytecode, constructor arguments, and live FewV2 pair state. There is no human key that can change routing, pause swaps, redirect fees, upgrade logic, or rewrite parameters.

This is especially important for a Uniswap routing-api integration. A router allowlist should not need to trust Ring to keep an admin key safe for the swap path. It should only need to review the deployed bytecode and immutable wiring.

---

## 3. Why Bounded Default Routing

A fully open multi-hop aggregator inside `beforeSwap` sounds useful, but it creates unnecessary risk:

- More external calls inside a v4 hook
- More rounding surfaces
- Larger gas and revert surface
- More complex exact-output quoting
- A need to choose intermediate assets
- Pressure to add an admin route registry

The calldata-route branch keeps the useful part and removes the dangerous part:

```text
No admin route registry.
No user-supplied pair addresses.
No arbitrary hidden intermediate assets.
Only direct + six immutable, canonical FewToken connectors by default.
```

This specifically serves the Uniswap classic-router goal: with `hookData == ""`, the official V4Quoter can ask the hook for a price without any Ring-specific calldata and still receive the best direct-or-connector quote. Advanced integrators can pass `hookData`, but intermediates stay inside the same connector set and amount limits are enforced in the hook.

---

## 4. Why No Pause

A pause function is often described as safety equipment. In this hook it would mostly be a governance attack surface.

The hook does not custody LP inventory and has no mutable route book. If a FewV2 pair, connector route, or FewToken is unhealthy, the likely response is:

1. The swap reverts through existing checks (`DegeneratePair`, `TokenMismatch`, wrapper mismatch, or user slippage), or
2. The router/hooklist delists the affected hook/pool, or
3. A new hook is deployed after remediation.

A hook pause key would introduce a new censorship/DoS primitive without solving the underlying asset problem. For V1, delisting and redeployment are the cleaner emergency controls.

---

## 5. Why Immutable Factories

`fewFactory` and `fewV2Factory` are core Ring infrastructure. Making them mutable would add a high-impact pointer that can redirect the hook's entire liquidity source.

Immutable factories give auditors a stable statement:

```text
All wrapped tokens and pairs are derived from these exact deployed factories.
```

If Ring ever migrates FewV2 factories, the correct path is:

1. Mine a new hook address
2. Deploy the new hook with the new immutable factory
3. Initialize pools that have valid direct pairs
4. Re-submit to routing infrastructure

This is slower than a setter, but it is public, reviewable, and does not give a key the ability to silently repoint swap execution.

---

## 6. Why 5 bps Is Constant

`PROTOCOL_FEE_BPS = 5` is fixed at compile time.

Reasons:

- It avoids fee-governance risk.
- It gives exact-output math one permanent denominator.
- It aligns with the UNIfication-style 1/6 protocol-fee ratio for a 30 bps V2-style pair.
- It keeps audit review focused on code correctness, not future fee governance.

Ring does not take a treasury cut in this build. The entire skim goes to `RingUniBurner`, then into Uniswap's TokenJar path. Ring does not perform the UNI buyback or burn; Uniswap's Firepit/releaser layer handles that downstream.

---

## 7. Why `RingUniBurner` Is Separate

The hook should not know how to perform UNI buybacks or burns. It should only send the fee to a small adapter that pushes assets into Uniswap's official protocol-fee pipeline.

`RingUniBurner` exists to:

1. Receive FewToken fees from the hook
2. Validate the FewToken against `fewFactory`
3. Unwrap 1:1 into the underlying token
4. Push the underlying to Uniswap's TokenJar

The adapter has an owner because operational reality may require pausing flushes or rescuing accrued fees if TokenJar migrates or a wrapper breaks. That role is outside the swap path and bounded to accrued fee balances.

This split keeps the hook ownerless while still giving Ring a narrow operational escape hatch for the fee adapter.

Production requires this owner to be a Gnosis Safe with a timelock before meaningful volume. A future V2 can remove `emergencyWithdraw` and make the burner closer to fully ownerless, but that deliberately gives up recovery if TokenJar migrates or a wrapper-specific failure strands accrued fees.

---

## 8. Accepted Tradeoffs

| Decision | What we gain | What we give up |
|---|---|---|
| Ownerless hook | No governance attack surface in swap path | No hot patching |
| Empty-hookData default auto-route | Uniswap router can discover direct or fixed-connector FewV2 price without custom calldata | Larger audit surface than direct-only |
| Calldata route with fixed connectors | Ring/router integrations can choose explicit paths without arbitrary intermediates | Integrators must encode `hookData` correctly |
| Immutable burner | No fee-sink rotation attack | Burner migration requires hook redeploy |
| Constant 5 bps fee | Simple math and social commitment | No fee tuning |
| Owner-managed V1 burner | Recovery path for TokenJar/wrapper exceptions | Residual key over accrued fees until flushed |
| Permissionless sweep to immutable recipient | No stuck dust, no caller trust | Cannot choose custom recipient per sweep |
| No v4 liquidity | Uses existing FewV2 liquidity | Pool UI must explain that LPing happens in FewV2 |

These are product constraints, not hidden limitations.

---

## 9. Risk Register

| Risk | Status | Rationale |
|---|---|---|
| Wrong `BeforeSwapDelta` sign | Tested | Exact-input, exact-output, and fork e2e tests cover settlement signs |
| Empty-hookData chooses wrong route | Tested | Fork tests compare actual swap to local best-route quote and V4Quoter exact-in/exact-out |
| Exact-output underfill after fee skim | Mitigated | Gross-up before quoting; `ExactOutputUnderfilled` guard |
| Arbitrary calldata intermediate | Mitigated | Intermediates must be fixed default connectors |
| Calldata path cycle / pair reuse | Mitigated | Duplicate tokens and duplicate pairs rejected |
| FewToken wrapper not 1:1 | Mitigated | `WrapMismatch` / `UnwrapMismatch` fail closed |
| Pair returns wrong token layout | Mitigated | `TokenMismatch` checks actual pair tokens |
| Drained pair produces bad quotes | Mitigated | `DegeneratePair` reserve sentinel |
| Reentrancy through token/pair calls | Mitigated | `nonReentrant`; known trusted FewV2/FewToken surface; tests include sweep reentrancy |
| Direct hook calls | Mitigated | `BaseHook` `onlyPoolManager` path tested |
| Forced ETH or accidental tokens | Mitigated | Permissionless sweep to immutable recipient |
| Fee recipient compromise | Low | Hook sweep destination is immutable; compromise affects receiving wallet, not hook behavior |
| Burner owner compromise | Accepted | Bounded to accrued fees in `RingUniBurner`; documented in `OWNER_KEY_COMPROMISE.md` |
| TokenJar migration | Accepted | Burner can pause/withdraw accrued fees; hook redeploy for permanent new adapter |
| Factory migration | Accepted | Hook redeploy; no mutable factory pointer |
| Router delisting needed | Operational | Handled off-chain by routing-api/hooklist, not by hook pause |

---

## 10. What Was Removed From Earlier Designs

The ownerless branch removes a whole class of mechanisms:

| Removed mechanism | Why it was removed |
|---|---|
| Hook ownership | No key should control the swap path |
| Swap pause | Delisting/redeploy is safer than an on-chain DoS key |
| Custom route registry | Route selection should not be governable inside `beforeSwap` |
| Admin-controlled multi-hop intermediates | Path finding may be per-transaction, but no owner can register global routes |
| Route timelock | No route registry means no timelock needed |
| Fee setter | 5 bps is a public constant |
| Fee recipient setter | Sweep destination is immutable |
| Burner rotation | Fee sink is immutable; migration means redeploy |
| Renounce override in hook | No hook owner exists to renounce |

This is why the governance risk profile improved: stale classes of findings around route timestamps and privileged controls disappeared with the code. The calldata-route branch reintroduces `calls-loop` findings, but they are bounded by the immutable connector set and per-transaction calldata.

---

## 11. Test Strategy Rationale

The test suite is intentionally split by risk:

| Suite | Purpose |
|---|---|
| `FewV2Math.t.sol` | Verify V2 quote math, rounding, and sentinel behavior |
| `RingUniBurner.t.sol` | Validate flush, owner-only emergency paths, pause, and unknown FewToken rejection |
| `RingAggregatorHookInvariants.t.sol` | Fuzz fee accounting and exact-output gross-up properties |
| `RingAggregatorHookFork.t.sol` | Exercise real mainnet factories, real FewTokens, real FewV2 pair, real TokenJar |

The fork tests are critical because this hook is an adapter over deployed Ring infrastructure. Hermetic mocks are useful, but they are not enough to prove the real `fewFactory -> FewToken -> FewV2Pair -> TokenJar` path.

Current result: 88/88 tests passing.

---

## 12. Coverage Interpretation

Coverage is strongest on the two audit-critical contracts:

| File | Line coverage | Function coverage |
|---|---:|---:|
| `src/RingAggregatorHook.sol` | 303/312 = 97.12% | 37/37 = 100.00% |
| `src/RingUniBurner.sol` | 26/27 = 96.30% | 5/5 = 100.00% |
| `src/lib/FewV2Math.sol` | 29/34 = 85.29% | 4/5 = 80.00% |

Repo-wide coverage is lower because scripts and tests are included in LCOV. The audit focus should be per-file behavior on the hook, burner, and math library; Uniswap `BaseHook` / `DeltaResolver` are inherited from pinned `lib/v4-periphery` rather than local Ring source.

---

## 13. Auditor Questions We Want Answered

1. Is the `BeforeSwapDelta` accounting correct for both swap directions and exact modes?
2. Can empty-hookData default routing ever select a stale, degenerate, or worse route than intended?
3. Can any FewToken/FewV2 edge case break the 1:1 wrap/unwrap or pair-token assumptions?
4. Is exact-output fee gross-up correct under all rounding boundaries?
5. Does permissionless sweep create any griefing or accounting issue?
6. Does `RingUniBurner` conform to Uniswap's fee-adapter / push-source model, without self-rolled UNI swaps or burns?
7. Is the `RingUniBurner.owner` emergency scope correctly bounded and documented?
8. Are there any integration assumptions with Universal Router or routing-api that need extra tests?

The preferred audit outcome is not just "no critical bugs"; it is a sharper statement of the integration invariants Ring must preserve at deployment and monitoring time.

---

## 14. Final Position

This version is ready for audit because it is bounded:

- One immutable default connector set
- No admin route book
- One immutable fee
- One immutable fee sink
- One immutable sweep destination
- One external operational owner, isolated to the burner

The remaining uncertainty is exactly what an audit should examine: swap accounting, external-call assumptions, and deployment wiring. The core governance attack surface has been removed rather than mitigated with process.
