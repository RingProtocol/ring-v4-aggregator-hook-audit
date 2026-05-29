# Residual Key & Owner-Compromise Threat Model

> **Premise**: the hook (`RingAggregatorHook`) is **ownerless** — no owner, no pause, no admin
> routes, no uniBurner rotation, and immutable direct-pair wiring. The classic
> "owner key stolen" threat does **not apply to the hook at all**, because there is no hook owner
> key to steal.
>
> **The only privileged key in the entire system is `RingUniBurner.owner`** — a separate
> contract that custodies *accrued protocol fees* (skimmed fwTokens awaiting flush), never user
> funds and never the hook. This document inventories the full blast radius of that one key.
>
> **Threat model**: attacker holds the stolen `RingUniBurner.owner` key, behaves rationally,
> maximises stolen value, uses any owner power. Does NOT have other Ring keys / fewFactory /
> FewV2 admin.
>
> Operational incident playbooks for non-key incidents are maintained outside this audit branch.

---

## 0. What "ownerless" eliminated

The hook used to be `Ownable2Step` with pause + admin routes + uniBurner rotation. All of it is
gone. Every attack vector below that a compromised **hook** owner could have run is now
**structurally impossible** (the function doesn't exist):

| Eliminated owner power | Old attack it enabled | Status now |
|---|---|---|
| `setSwapsPaused` | Griefing: pause all swaps, hold protocol hostage | ❌ removed — no pause exists |
| `proposeRoute` / `executeProposedRoute` | Register a route through an attacker-thin pair (bounded by slippage, but a nuisance) | ❌ removed — there is no route registry; each pool uses the direct factory-derived FewV2 pair |
| `proposeUniBurner` / `executeProposedUniBurner` | Rotate the fee sink to an attacker address | ❌ removed — `uniBurner` is immutable |
| `transferOwnership` (of the hook) | Take over all of the above | ❌ removed — hook has no owner |
| owner-set `_approvedIntermediate` | Select hidden route assets after deployment | ❌ removed — there are no hidden intermediates in the hook |

There is no hook owner, no hook pause, no hook upgrade path. The hook's pricing and routing are
fully determined by immutable wiring and direct on-chain FewV2 pair state. No key can change routing after deployment.

---

## I. The one residual key: `RingUniBurner.owner`

`RingUniBurner` is `Ownable2Step`. Owner powers:

| Function | Effect |
|---|---|
| `emergencyWithdraw(token, to)` | Transfer the burner's balance of `token` to an arbitrary `to`. No contract-native timelock; production must route this through a Safe-module timelock. |
| `setFlushPaused(bool)` | Pause/unpause the permissionless `flush()` (the unwrap→TokenJar push). |
| `transferOwnership` / `acceptOwnership` | 2-step ownership handover. |

`flush(fewToken)` itself is **permissionless** (anyone can push accrued fees to the immutable
`tokenJar`); `tokenJar` and `fewFactory` are immutable.

### Risk #1 — `emergencyWithdraw` drains accrued fees ⚠ **MEDIUM**

```solidity
RingUniBurner.emergencyWithdraw(fwUSDC, attacker)
RingUniBurner.emergencyWithdraw(fwWETH, attacker)
// ... repeat per fewToken with a balance
```

- **Latency**: instant only if the owner is misconfigured as an EOA or plain Safe. Production requires a Gnosis Safe + 24h module timelock before any owner transaction can execute.
- **Value at risk**: only protocol-fee accumulation **since the last `flush()`** —
  - $10M daily volume × 5 bps × 1 day backlog ≈ **$5,000/day**
  - keeper broken for a month (worst case) ≈ **$50K+**
- **Never at risk**: user funds (never custodied) and the hook's balance (held only transiently
  mid-swap; `sweep` is permissionless to the immutable `feeRecipient`, so the key cannot touch it).
- **Recoverability**: zero once withdrawn to the attacker EOA.
- **Detection**: `EmergencyWithdrawn` event (post-mortem).

### Risk #2 — `setFlushPaused(true)` griefs the burn pipeline + enlarges Risk #1 — **LOW**

A compromised owner can pause `flush()` so fees pile up in the burner, then `emergencyWithdraw`
a larger pile. The fees are **not lost while paused** (they sit in the burner); the only marginal
harm is enabling a bigger Risk #1 drain and stalling TokenJar forwarding / downstream Firepit burns.

- **Recoverable**: real owner (multisig) `setFlushPaused(false)` or `transferOwnership`.

### Risk #3 — `transferOwnership` lockout — **LOW**

`Ownable2Step` requires the new owner to `acceptOwnership`, so a fat-finger can't brick it. A
compromised owner could transfer to themselves, but that is no worse than the already-compromised
state. The renounce path is hardened (see contract).

---

## II. What is NOT at risk (by construction)

| Asset | Why it's safe |
|---|---|
| **User swap funds** | Never custodied. Each swap is atomic: `take → wrap → fewV2 swap → unwrap → settle`, with `WrapMismatch` / `UnwrapMismatch` / slippage guards. A revert rolls back the whole tx. |
| **Hook balance** | ~0 between txs. `sweep(token)` is permissionless and hard-wired to the immutable `feeRecipient` — no key can redirect it. |
| **Routing / pricing** | Direct pair is derived from immutable factories. No owner can change factories, fees, pair derivation, or pause swaps. |
| **TokenJar destination** | Immutable in `RingUniBurner`; the key cannot redirect the TokenJar destination, only withdraw pre-flush balances. |

---

## III. Required trust model & mitigations

1. **`RingUniBurner.owner` = Gnosis Safe multisig + timelock** (not a single EOA and not a plain Safe). This is the *only* key
   that needs ceremony — and it guards accrued fees, not user funds. Configure a 24h Safe-module timelock for `emergencyWithdraw`, `setFlushPaused`, and ownership-transfer initiation before meaningful volume.
2. **Frequent keeper `flush()`** → keeps the burner's balance near zero → directly caps Risk #1's
   value-at-risk. A flush-every-hour keeper bounds worst case to ~1 hour of fee accrual.
3. **Monitoring**: alert on `EmergencyWithdrawn`, `FlushPaused`, and `OwnershipTransferStarted`.

### V2 option: remove the owner entirely

If Ring wants the fee adapter to be as pure as the hook, a future V2 can remove `setFlushPaused`
and `emergencyWithdraw`, leaving only immutable TokenJar forwarding plus permissionless `flush`.
That eliminates the residual fee-custody key, but it also means a TokenJar migration, chain-specific
pause, or wrapper-specific failure can strand accrued fees with no recovery path. V1 keeps the
escape hatch and constrains it with Safe + timelock + frequent flushes.

---

## IV. Bottom line

By going ownerless, the hook removed its **entire** owner-compromise attack surface. The only
residual key (`RingUniBurner.owner`) cannot touch user funds, the hook, the routing, or the burn
destination — its worst case is draining a small, keeper-bounded pile of already-accrued protocol
fees. This is the smallest governance attack surface a fee-skimming hook can have short of also
making the fee non-custodial.
