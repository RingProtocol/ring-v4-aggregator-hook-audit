# TokenJar Fee Pipeline — Design Notes

> Build: single canonical **ownerless** contract (5 bps fee pushed to Uniswap TokenJar, immutable wiring)
> Scope: canonical ownerless audit build. There is no 0 bps fallback variant in scope.
> Naming discipline: Ring does **not** swap for UNI and does **not** burn UNI itself. Ring pushes the 5 bps fee into Uniswap's canonical TokenJar; Uniswap's Firepit/releaser layer handles downstream UNI burn.

## 1. Why 5 bps? — three anchors must agree

5 bps is the **intersection** of three independent constraints. Any one alone
would be insufficient; together they make 5 the only defensible choice.

### Anchor 1 — Mathematical (UNIfication's 1/6 ratio)

UNIfication (Uniswap governance proposal, passed Dec 2025) activates protocol
fees on Uniswap V3 / V4 pools. The fee ratio is explicit in the proposal:

- 0.01% / 0.05% LP-fee tiers → protocol fee = 1/4 of LP fee
- **0.30% / 1% LP-fee tiers → protocol fee = 1/6 of LP fee**

FewV2 charges 30 bps LP fee (matches V2 fork canon). Apply the 1/6 ratio:
30 / 6 = **5 bps**. Not 3, not 8. This is the canonical Uniswap-governance number
for the tier Ring sits in.

Source: UNIfication blog post (https://blog.uniswap.org/unification) on the V3 fee schedule.

### Anchor 2 — Political (signaling alignment)

The Hooks Marketplace ($500M liquidity incentive program launched Apr 2026)
is curated by the Uniswap Foundation. Their public framing of aggregator hooks:

> "Aggregator hooks source liquidity from other onchain protocols and
> add a programmatic UNI burn on top, turning Uniswap v4 itself into an
> aggregator that anyone can integrate."  — UNIfication blog

The phrase "**programmatic UNI burn on top**" is the entrance ticket. Hooks
that do not feed the official TokenJar/Firepit path read as freeloaders capturing
Uniswap routing flow without contributing to UNI value. The Marketplace review
committee can choose priorities; UNI alignment is the strongest discriminator
they have.

The political anchor sets a **minimum** of 5 bps (matching UNIfication ratio).
Anything below is "half-hearted alignment." Anything above is fine politically
but loses on the next anchor.

### Anchor 3 — Economic (cost competitiveness vs V3)

User cost comparison for the FewV2 route at 5 bps:

| Path | LP fee | Protocol fee | Total |
|---|---|---|---|
| V3 single-hop 30bps pool | 30 | 5 | 35 bps |
| V3 multi-hop 5bps × 2 | 10 | 2.5 (UNIfication) | 12.5 bps |
| V3 multi-hop 30bps × 2 | 60 | 10 | 70 bps |
| **Ring H @ 5 bps** | **30 (FewV2)** | **5 (Ring -> TokenJar -> Firepit)** | **35 bps** |

**Insight**: at 5 bps, Ring's total user cost equals V3's single 30bps tier
*exactly*. This is the price the user already pays for entering a V2-curve
30bps pool — no surcharge for going through Ring.

If Ring charged 8 bps: total 38 bps -> routing-api compares 38 vs 35 (V3 30bps
tier) and de-prioritizes Ring on price. Lost volume = less fee flow into the
TokenJar/Firepit pipeline.

If Ring charged 3 bps: total 33 bps -> wins on price vs V3, but misses
UNIfication anchor. Politically half-aligned + ~40% less TokenJar fee flow.

5 bps is the **tightest** rate that satisfies both political and price-parity
constraints simultaneously.

### Why the three anchors aren't redundant

- **Math alone** sets a tier-specific number but doesn't say WHY Ring should
  pay it (a 0-fee hook could exist legally; nothing forces tier matching).
- **Political alone** sets a direction ("some value into the UNI burn pipeline") but no level.
- **Economic alone** drives toward 0 bps (max price competitiveness).

Without all three converging on 5 bps, the choice would be arbitrary —
political folks would argue 10 bps, treasury folks 0 bps, marketers some
arbitrary "looks generous" number. Three independent constraints converging
gives the choice intellectual defensibility under audit pushback.

### Alternatives considered (full table)

| Rate | Math anchor | Political anchor | Economic anchor | Decision |
|---|---|---|---|---|
| 0 bps | ✗ ignores tier | ✗ freeloader | ✓ max competitive | Reject (no fallback build in audit scope) |
| 3 bps | ✗ off-ratio | ⚠ half-aligned | ✓ slightly better | Reject |
| **5 bps** | **✓ V3 30bps × 1/6** | **✓ matches UNIfication** | **✓ same as V3 30bps** | **Chosen** |
| 8 bps | ✗ off-ratio | ✓ generous | ✗ loses price compare | Reject |
| 10+ bps | ✗ off-ratio | ✓ very generous | ✗ uncompetitive | Reject |

## 1b. Why 100% to TokenJar/Firepit (no split with Ring treasury)?

V1 forwards the **entire 5 bps to uniBurner**. The natural counterproposal is
to split: e.g., 2.5 bps to TokenJar/Firepit + 2.5 bps to Ring treasury. We rejected this.

### Argument for splitting (rejected)

- Ring is doing engineering / audit / ops work; the protocol should capture
  some value for sustainability
- Half-split (2.5/2.5) is still a meaningful TokenJar/Firepit signal
- "Free money to Uniswap" optics for Ring stakeholders

### Why we still send 100% to TokenJar

1. **V1 is a signaling exercise.** Ring is asking Uniswap Foundation +
   Marketplace + routing-api maintainers to accept Ring as a peer. The
   strongest possible signal is "100% into Uniswap's TokenJar path, we keep nothing." Any
   split, no matter how favorable to Uniswap, opens the question "how much
   are they really aligned?"

2. **Ring captures value upstream.** Every swap through H increases FewV2
   pair volume → FewV2 LPs (which include Ring entities) earn 30 bps LP fee.
   The protocol fee is a marginal additional capture; the FewV2 LP fee is
   the actual revenue model. Ring isn't choosing between "5 bps to Uniswap"
   and "5 bps to nothing" — it's choosing between "5 bps to TokenJar/Firepit
   + full FewV2 LP fee" and "5 bps split + full FewV2 LP fee."

3. **Marketplace incentive math.** The Hooks Marketplace pays $500M of UNI
   to hooks. Burning UNI raises the per-UNI value of those incentives. Ring
   receives a share of incentives proportionate to its volume; that share
   is in UNI; burning UNI elsewhere raises the value of Ring's own incentive
   share. Indirect but real.

4. **V2 option preserved.** V2 can introduce a Ring treasury split AFTER
   establishing the "Uniswap citizen" reputation. Going 100% in V1 makes
   the V2 split look like a graduation, not a betrayal.

5. **Audit narrative.** "All protocol fees are pushed into Uniswap's official
   TokenJar; Firepit handles downstream UNI burn" reads cleanly in the audit /
   governance / press cycle. "Protocol fees split 50/50" invites a year of
   debate over the right ratio.

### Why this is safe to commit to

`PROTOCOL_FEE_BPS = 5` is a `constant` and `uniBurner` is `immutable`. Both the fee
size and its hook-level destination are fixed at deploy and cannot be changed by anyone —
there is no hook owner and no setter. The "100% of protocol fees to the TokenJar path"
commitment is therefore **enforced by the bytecode**, not by a policy promise: to change
the fee or the distribution, Ring must deploy a new hook and migrate routing to it (a
public, deliberate act — the old hook keeps doing exactly what it says).

This is a stronger narrative than a rotatable burner: there is no "stealth re-route the
fees" surface at all. What the interface says is what the code does, permanently.

## 2. Where the fee comes from

5 bps is taken from the **gross fewToken output** of the FewV2 swap,
i.e., the amount the hook receives back from FewV2 before unwrapping to the
user's token. This is the cleanest skim point:

- The hook already custodies the fewToken at this point (no extra approval needed)
- Fee can be transferred as fewToken (avoiding a per-swap UNI swap round-trip)
- Math is simple: `fee = floor(fwOut * 5 / 10_000)`

ExactOutput case requires grossing up the FewV2 quote so the user still receives
the exact target amount after the fee is skimmed:

```
fwOutGross = ceil(amountOut * FEE_DENOM / (FEE_DENOM - PROTOCOL_FEE_BPS))
fwInRequired = quoteAmountIn(fwOutGross)
```

The contract uses `ceildiv` integer math: `(amountOut * 10000 + 9994) / 9995`.

## 3. Downstream UNI burn — handled by Uniswap's TokenJar + Firepit

**This implementation aligns with Uniswap's official UNIfication pipeline**
(https://github.com/Uniswap/protocol-fees), not a self-rolled UNI swap.

External language should be precise: Ring pushes the 5 bps fee into TokenJar.
Firepit, governed by Uniswap, handles any subsequent UNI burn.

### Three contracts on Uniswap's side

1. **TokenJar** — per-chain canonical fee collector. Immutable ERC20 sink that
   any push source (V2, V3 adapter, V4 adapter, UniswapX, and now Ring) can
   transfer assets to. Only the governance-controlled `releaser` (Firepit)
   can withdraw.
2. **Firepit** — UNI burner. Accepts assets from TokenJar in exchange for
   burning UNI to `0x...dEaD` (mainnet) or bridging out for L2s.
3. **Adapters** — per-source helpers. V2 uses "push source" semantics (the
   source just transfers tokens to TokenJar). V3 uses a "pull adapter" that
   anyone can trigger.

### Ring's slot in this pipeline

Ring's `RingUniBurner` is a **push-source adapter** in the V2 style:

```
RingAggregatorHook            RingUniBurner               TokenJar
 ─────────────────             ────────────                ─────────
 take 5 bps of            ──→ unwrap fewToken         ──→ accumulate
 gross fewOutput              (1:1 to underlying)         underlying

                                                       Firepit (governed)
                                                       ─────────────────
                                                       burn UNI to 0xdEaD
```

### Why this beats our V1 self-rolled design

Earlier in this branch we considered a `RingUniBurner` that did its own V3 swap to
UNI and its own burn. That would have been a Ring-specific mechanism. Refactoring
to use TokenJar gives us:

- **Foundation-aligned**: Uniswap's audit / governance / monitoring already
  cover TokenJar + Firepit. Ring inherits all of it for free.
- **No MEV exposure in Ring code**: we don't swap on-chain; Firepit batches swaps under
  governance control (likely MEV-resistant solver auctions).
- **No oracle dependency** for callers: `flush(fewToken)` has no `minUniOut`
  parameter — there's no swap to slip.
- **Smaller audit surface**: ~80 LOC vs the ~210 LOC we had with V3-router
  integration.

### Canonical TokenJar addresses

| Chain | Address |
|---|---|
| Ethereum mainnet | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` |
| Arbitrum One | (see protocol-fees repo) |
| Base | (see protocol-fees repo) |
| OP Mainnet | (see protocol-fees repo) |
| Unichain, World Chain, Celo, Zora, Soneium, X Layer | (see protocol-fees repo) |

Source of truth: https://github.com/Uniswap/protocol-fees (deployments).

## 4. Permission model

### Hook (RingAggregatorHook) — uniBurner setting

| Action | Who | Constraint |
|---|---|---|
| Set | constructor only | `_uniBurner` must be non-zero — checked at construction |
| Change after deploy | **impossible** | `uniBurner` is `immutable` — no setter, no rotation, no timelock. To change it, redeploy the hook. |

The hook is ownerless, so there is **no rotation surface to attack**: no key can point the
fee skim at a malicious burner, because no key can change `uniBurner` at all. This trades
operational flexibility (rotation) for zero governance attack surface — see
[`RATIONALE.md`](RATIONALE.md) and [`OWNER_KEY_COMPROMISE.md`](OWNER_KEY_COMPROMISE.md).

### Burner (RingUniBurner) — operational controls

| Action | Who | Constraint |
|---|---|---|
| flush | anyone | callable by keeper bot, no slippage param |
| setFlushPaused | owner | emergency stop if TokenJar is migrated or temporarily unsafe; production owner is Safe + timelock |
| emergencyWithdraw | owner | rescue if TokenJar is removed; not for fee diversion; production owner is Safe + timelock |
| Renouncement | impossible | reverts |

Because the burner is just a forwarder (no swap, no UNI handling), `flush` is
intentionally permissionless: any keeper / community member can convert
accumulated fewTokens to underlying-in-TokenJar at any time, paying their
own gas.

### V2 ownerless-burner option

The V1 burner keeps `setFlushPaused` and `emergencyWithdraw` because TokenJar migrations,
chain-specific pauses, or wrapper-specific failures are operationally real. The production
control must therefore be a Gnosis Safe + timelock and must be monitored.

If Ring later wants the purest possible fee adapter, V2 can remove both owner functions and
leave only immutable TokenJar forwarding plus permissionless `flush`. That eliminates the
last privileged key, but it also means accrued fees may be permanently stranded if TokenJar
migrates or a particular unwrap path breaks.

## 5. Fail-closed semantics

The hook reverts if `uniBurner == address(0)` and `PROTOCOL_FEE_BPS > 0`. This
means:

- `uniBurner` is immutable and non-zero (checked at construction), so it can never
  become zero post-deploy. No silent zero-fee fallback.
- If the burner contract itself is broken (rejects transfers), swaps fail at the
  `SafeERC20.safeTransfer` call. Audit-friendly: failure modes are explicit.

This is by design. Silent fee skipping would be a route for value capture
to "leak" via degraded states.

## 6. Gas overhead

Per swap, the TokenJar fee path adds:

- 1 `IERC20.safeTransfer` to `uniBurner` (~25-30k gas, cold first-touch, warm after)
- 1 `emit UniFeeAccrued` (~1.5k gas)
- 1 `mul`/`div` for fee calc (~50 gas)
- ExactOutput only: 1 extra `mul`/`div` for `fwOutGross` (~50 gas)

Estimated ceiling: **~32k gas per swap**, dominated by the warm-vs-cold transfer.
Negligible vs a V4 swap baseline of ~150-200k gas.

## 7. Test coverage

In `test/fork/RingAggregatorHookFork.t.sol`:

| Test | What it verifies |
|---|---|
| `test_fork_uniBurn_exactInput_5bps_skim` | Burner receives exactly `floor(gross * 5/10000)`; user gets the remainder |
| `test_fork_uniBurn_exactOutput_userReceivesTarget` | User receives EXACTLY `amountOut`; burner gets ~5 bps of grossed-up route |
| `test_fork_uniBurn_noTokensLost_exactInput` | Hook retains no fewToken dust after exact-in swap |
| `test_fork_uniBurn_emitsUniFeeAccruedEvent` | Event emitted with poolId + fewToken + amount |
| `test_attack_constructor_zeroUniBurner_reverts` | Zero address rejected at construction |

All 88 tests pass (25 unit + 5 invariant + 58 fork).

## 8. Fee configuration

`PROTOCOL_FEE_BPS = 5` is a `constant` and `uniBurner` is `immutable`. There is no
0 bps fallback build and no in-place fee toggle: changing the fee or the burner means
deploying a new hook. This is deliberate — it removes fee-tuning and burner-rotation
as governance attack vectors for the audit (see [`RATIONALE.md`](RATIONALE.md)).

## 9. Audit language checklist

Use this wording in audit kickoff and external review:

- "Ring pushes 5 bps of gross FewToken output into Uniswap's canonical TokenJar."
- "Uniswap's Firepit/releaser layer handles downstream UNI burn."
- "`RingUniBurner` is a TokenJar push-source adapter, not a UNI swapper."
- "The audit should confirm `RingUniBurner` conforms to Uniswap's fee-adapter model."

Avoid saying "Ring burns UNI" or "we run the UNI burn." Those are shorthand and can be
misread as self-rolled buyback/burn logic, which this implementation deliberately avoids.
