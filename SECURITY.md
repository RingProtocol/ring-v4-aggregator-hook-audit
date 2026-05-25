# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

| Channel | Detail |
|---|---|
| Email | `contact@ring.exchange` (monitored by the Ring core team) |
| Encrypted | PGP key fingerprint to be published at `ring.exchange/.well-known/security.txt` |
| Backup | Direct message to a Ring core team member through the internal security contact list |

Please include: affected contract + commit hash, a description, a proof-of-concept (Foundry test preferred), and the impact you believe it has.

We aim to acknowledge within **24 hours** and provide an initial assessment within **72 hours**.

---

## Scope

### In scope
- `src/RingAggregatorHook.sol`
- `src/RingUniBurner.sol`
- `src/lib/FewV2Math.sol`
- `src/base/DeltaResolver.sol`, `src/utils/BaseHook.sol`
- Any deployed instance of the above on a chain where Ring has announced an official deployment (see `DEPLOYMENTS.md` once populated).

### Out of scope
- `lib/` dependencies (Uniswap v4-core, OpenZeppelin, permit2, solmate, forge-std) — report upstream.
- Ring Few Protocol / FewV2 contracts — separate codebases with their own disclosure process.
- Uniswap TokenJar / Firepit — report to Uniswap.
- Findings that require the one trusted role — the **RingUniBurner owner / multisig signer** — to act maliciously **and** are already documented in `KNOWN_ISSUES.md` as accepted residual risk. (Note: the hook itself is ownerless; the burner is the only privileged contract.) Novel burner-owner-compromise vectors *not* covered there are in scope.
- Gas optimizations without a security impact.
- Issues in test/script files that cannot affect deployed bytecode.

---

## Bug bounty

A formal bug bounty program (Immunefi) will be launched **after** the external
audit report is published and the contracts are deployed to mainnet behind a
multisig. Until then, this policy governs responsible disclosure. Good-faith
reports received before the bounty launches will be honoured retroactively at
the program's published rates for the corresponding severity.

Indicative severity → reward bands (finalized at Immunefi launch):

| Severity | Definition | Indicative band |
|---|---|---|
| Critical | Direct theft / permanent freezing of user or protocol funds | up to $X (set at launch) |
| High | Conditional fund loss, protocol insolvency, or theft requiring specific state | high band |
| Medium | Griefing, unbounded gas, or value-at-risk only under burner-owner compromise | medium band |
| Low | Best-practice deviation, no fund impact | low band / acknowledgement |

---

## Safe harbor

Ring will not pursue legal action against researchers who:
1. Make a good-faith effort to avoid privacy violations, data destruction, and service interruption.
2. Only interact with accounts they own or have explicit permission to test.
3. Do not exploit a finding beyond what is necessary to demonstrate it.
4. Report promptly and give Ring reasonable time to remediate before public disclosure (default: 90 days, or sooner by mutual agreement).

Testing against mainnet that risks third-party funds is **not** authorized — use a fork (`ETH_RPC_URL=… forge test`) or a local anvil instance.

---

## Disclosure timeline

1. Report received → acknowledged ≤24h.
2. Triage + severity assignment ≤72h.
3. Fix developed on a private branch; reporter kept informed.
4. Fix deployed (the hook is immutable → redeploy + routing-layer migration; RingUniBurner fixes go through its multisig + 24h Safe-module timelock).
5. Coordinated public disclosure + reporter credit (if desired) after fix is live.

---

## Hardening already in place (context for researchers)

Before reporting, check whether the vector is already mitigated:

- `onlyPoolManager` on every V4 callback (Cork-class).
- `nonReentrant` on `_beforeSwap` and `sweep`.
- `wrap`/`unwrap` return-value equality checks (Bunni-class lying token → fail closed).
- Empty-hookData default routing is bounded to direct + 6 immutable connectors; calldata-route intermediates are restricted to the same fixed connector set. No admin-registered routes and no user-supplied pair addresses.
- `uniBurner`, `fewFactory`, `fewV2Factory`, `weth`, `feeRecipient` are all **immutable** — no setters, no rotation surface.
- `DegeneratePair` reserve sentinel (MIN_PAIR_RESERVE).
- The hook is **ownerless** — no owner, no pause, no upgrade path. (RingUniBurner, a separate contract, uses `Ownable2Step` for its `emergencyWithdraw` / `setFlushPaused`.)
- Constructor zero-address checks on all immutables + 6 post-deploy state assertions.

Full inventory: `docs/OWNER_KEY_COMPROMISE.md`, `KNOWN_ISSUES.md`, `docs/SLITHER_TRIAGE.md`.
