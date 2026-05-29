# ring-v4-aggregator-hook-audit

Clean-history public audit mirror for Ring's Uniswap V4 aggregator hook.

A Uniswap V4 **aggregator hook** that exposes Ring's FewV2 AMM liquidity (~$130M TVL across 7 chains) as native V4 pools. The Universal Router and V4 Quoter discover and use it as primitive `(tokenA, tokenB)` pools — under the hood every swap is routed through Ring's existing fewV2 AMM.

> **Naming**: follows the Uniswap V4 ecosystem convention `<protocol>-v4-<purpose>-hook` (sibling to Ring's `ring-v4-periphery`).
> **Status**: audit helper-externalized branch, based on `audit-ownerless-calldata-route-2026-05-25-r3` · 88/88 tests passing · V4Quoter empty-hookData fork tests passing · calldata-route red-team pass complete.

---

## Architecture (one line)

```
V4 swap (tokenA → tokenB)  →  Hook.beforeSwap  →  wrap A  →  fewV2.swap(fewA → fewB)  →  unwrap B  →  settle
```

The V4 pool holds **zero liquidity**. All liquidity comes from FewV2 pairs. The hook is purely a routing translation layer that `beforeSwapReturnDelta`-absorbs the swap before the V4 AMM loop runs.

This is the same pattern as:
- Uniswap Labs' Tempo aggregator hook (first production deployment, March 2026)
- Aligned with the [UNIfication governance proposal](https://blog.uniswap.org/unification) (passed Dec 2025)

---

## Permission model — the hook is ownerless

The hook has **no owner, no admin functions, no pause, no upgrade path**. Once deployed, its behaviour is fully determined by immutable constructor wiring (`fewFactory`, `fewV2Factory`, `weth`, `feeRecipient`, `uniBurner`) and the on-chain state of the FewV2 pairs it routes through. This is the Universal-Router philosophy: a thin, immutable, permissionless routing layer.

| Concern | Design |
|---|---|
| Routing | Empty `hookData`: built-in default router compares direct FewV2 route plus a fixed deploy-time connector set (`fwWETH`, `fwWBTC`, `fwUSDC`, `fwUSDT`, `fwDAI`, `fwUSDR`) and chooses the best quote. Non-empty `hookData`: per-swap FewToken path, but intermediates are restricted to the same fixed connector set and retain hook-level slippage bounds. No admin-registered routes. |
| Liquidity source | `fewV2Factory` is **immutable** — multi-year-stable core infra; a migration is handled by redeploying the hook, not a setter (see the contract NatSpec for the full rationale). |
| Protocol fee | `PROTOCOL_FEE_BPS = 5` constant. 5 bps of gross fewToken output -> immutable `uniBurner` -> Uniswap TokenJar. Firepit, governed by Uniswap, handles the downstream UNI burn. |
| Emergency | No pause. Defence is layered: per-swap reverts (`DegeneratePair` / `WrapMismatch` / caller slippage) + routing-layer delist. |
| Sweep | `sweep(token)` is permissionless; destination locked to the immutable `feeRecipient`. |

The only privileged key in the system is the **RingUniBurner owner** — a *separate* fee adapter that receives the 5 bps before `flush()` pushes it to TokenJar. Its worst-case power is diverting *already-accrued protocol fees* (never user funds, never routing). Production owner must be a Gnosis Safe with a timelock before meaningful volume. See [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md).

For this audit build's calldata-route ABI, validation model, red-team tests, and Slither triage, see [`docs/CALLDATA_ROUTE_SECURITY.md`](docs/CALLDATA_ROUTE_SECURITY.md). The historical `ownerless` branch remains the smaller direct-route package, while the pre-ownerless `main` branch is archived as `archive/pre-ownerless-main-2026-05-25`.

For the 3-anchor (mathematical / political / economic) rationale of the 5 bps choice, see [`docs/UNI_BURN_NOTES.md`](docs/UNI_BURN_NOTES.md). For how a Uniswap user's swap actually reaches FewV2 (shell pool, `initialize` ≠ add liquidity, hooklist vs allowlist), see [`docs/GO_LIVE_MECHANICS.md`](docs/GO_LIVE_MECHANICS.md).

---

## Documentation map

> First-time reader / CEO / CTO: start here.

| File | Audience | Read time |
|---|---|---|
| `README.md` (this file) | Everyone | 5 min |
| [`docs/GO_LIVE_MECHANICS.md`](docs/GO_LIVE_MECHANICS.md) | Everyone | 10 min — how a user's swap reaches FewV2: shell pool, `initialize` ≠ add liquidity, hooklist vs allowlist |
| [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md) | CEO / Auditor | 15 min — the hook has no owner; this inventories the one residual privileged key (the RingUniBurner owner) and its bounded blast radius |
| [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md) | Auditor | 20 min — every Slither finding triaged, 0 real issues |
| [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) | Auditor | 10 min — per-file coverage report |
| [`docs/UNI_BURN_NOTES.md`](docs/UNI_BURN_NOTES.md) | Auditor / Engineer | 25 min — 3-anchor 5 bps rationale + TokenJar/Firepit architecture |

Technical deep-dives (all in-repo, self-contained):
- [`docs/DESIGN.md`](docs/DESIGN.md) — full architecture spec
- [`docs/RATIONALE.md`](docs/RATIONALE.md) — why every design decision
- [`docs/CALLDATA_ROUTE_SECURITY.md`](docs/CALLDATA_ROUTE_SECURITY.md) — calldata-route ABI, validation, and red-team coverage
- [`docs/DEPLOYMENT_FLOW.md`](docs/DEPLOYMENT_FLOW.md) — audit-to-deploy roadmap
- [`docs/INDEX.md`](docs/INDEX.md) — one-page map of every doc by audience

---

## Layout

```
src/
├── RingAggregatorHook.sol        # main hook contract (~772 LOC, ownerless)
├── RingUniBurner.sol             # TokenJar push-source adapter (~157 LOC, owner-managed)
├── interfaces/
│   └── external/                 # ABI-only references, not Ring production logic
│       ├── IFewWrappedToken.sol  # Ring fewToken wrap/unwrap
│       ├── IFewFactory.sol       # token → fewToken lookup
│       └── IFewV2.sol            # ISwapV2Pair / ISwapV2Factory
└── lib/
    └── FewV2Math.sol             # V2 getAmountOut + getAmountIn (30 bps fee)

lib/
└── v4-periphery/                 # pinned Uniswap v4-periphery v1.0.2 submodule
    ├── src/utils/BaseHook.sol     # official hook callback base
    ├── src/base/DeltaResolver.sol # official take/settle helper
    ├── src/utils/HookMiner.sol    # official hook address miner used by scripts/tests
    └── src/interfaces/external/IWETH9.sol # official WETH interface

test/
├── unit/                         # 25 hermetic unit tests (10 FewV2Math + 15 RingUniBurner)
├── invariant/                    # 5 property-fuzz invariants (fee math, gross-up, sentinel)
└── fork/                         # 58 mainnet-fork e2e + adversarial tests

script/
├── DeployUniBurner.s.sol         # deploy RingUniBurner via CREATE2
├── MineHookAddress.s.sol         # CREATE2 salt search for permission flags 0x2888
└── DeployMainnet.s.sol           # deploy hook + init ETH/USDC pool

docs/
├── INDEX.md                      # one-page guide to every doc by audience
├── DESIGN.md                     # full architecture spec
├── RATIONALE.md                  # why every design decision
├── GO_LIVE_MECHANICS.md          # how a user's swap reaches FewV2
├── UNI_BURN_NOTES.md             # 5 bps + TokenJar/Firepit architecture
├── CALLDATA_ROUTE_SECURITY.md    # calldata-route ABI, validation, red-team coverage
├── SLITHER_TRIAGE.md             # static analysis triage (0 real findings)
├── TEST_COVERAGE.md              # per-file forge coverage report
├── OWNER_KEY_COMPROMISE.md       # residual-key (RingUniBurner owner) threat model
├── DEPLOYMENT_FLOW.md            # current-state → routing-api roadmap
└── MECHANISM_PROVENANCE.md       # every mechanism traced to a battle-tested precedent

# Audit-submission package (repo root):
#   AUDIT_SCOPE.md  KNOWN_ISSUES.md  SECURITY.md
```

---

## Build & test

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` `cast` `anvil`)
- An archive Ethereum mainnet RPC URL (Alchemy / Infura / your own node) — only needed for fork tests

### Initial setup
```sh
git clone --recurse-submodules git@github.com:RingProtocol/ring-v4-aggregator-hook-audit.git
cd ring-v4-aggregator-hook-audit
git submodule update --init --recursive
forge install
```

### Build
```sh
forge build
```

Compiles with Solidity `0.8.26`, `via_ir = true`, optimizer 200 runs, EVM Cancun. See [`foundry.toml`](foundry.toml).

### Run tests

```sh
# unit tests only (25 tests, hermetic, fast)
forge test --match-path "test/unit/*"

# all tests including mainnet fork (88 total: 25 unit + 5 invariant + 58 fork)
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY  forge test
```

Fork tests auto-skip when `ETH_RPC_URL` is unset (so CI without an RPC stays green).

### Static analysis

Slither + solc-select setup:
```sh
pip3 install --user slither-analyzer solc-select
solc-select install 0.8.26
solc-select use 0.8.26
export PATH="$HOME/Library/Python/3.9/bin:$PATH"

slither . --filter-paths "lib/|test/|script/" \
          --exclude naming-convention,solc-version,pragma
```

See [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md) — all detector hits triaged (0 real findings).

---

## Deploy

Three-script flow:

```sh
# 1. Deploy RingUniBurner (CREATE2, same address across chains).
#    OWNER_ADDRESS is the BURNER's owner (the hook itself is ownerless) — use a multisig.
OWNER_ADDRESS=0x...   forge script script/DeployUniBurner.s.sol  \
                                  --rpc-url $RPC --broadcast --via-ir

# 2. Mine hook CREATE2 salt (hook takes NO owner arg)
UNI_BURNER_ADDRESS=0x... FEE_RECIPIENT_ADDRESS=0x...  \
                       forge script script/MineHookAddress.s.sol --via-ir

# 3. Deploy hook + initialize ETH/USDC pool (hook takes NO owner arg)
HOOK_SALT=0x... EXPECTED_HOOK_ADDRESS=0x... UNI_BURNER_ADDRESS=0x...        \
FEE_RECIPIENT_ADDRESS=0x...                                                \
                       forge script script/DeployMainnet.s.sol             \
                                    --rpc-url $RPC --broadcast --via-ir
```

The deploy script runs post-deploy state assertions for all immutables (`feeRecipient`, `uniBurner`, `fewFactory`, `fewV2Factory`, `weth`, `PROTOCOL_FEE_BPS == 5`, and all 6 default connectors) before exiting. Failure on any assertion aborts.

**The hook is ownerless** — there is nothing to transfer after deploy. The only key to secure is the **RingUniBurner owner**: transfer it to a Gnosis Safe 3/5+ multisig before any meaningful volume flows. See [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md).

---

## Status

| Item | State |
|---|---|
| Code complete | ✅ |
| Slither static analysis | ✅ 22 hits reviewed on this branch; fixed-connector auto-routing and bounded calldata `calls-loop` findings are expected/by-design ([branch notes](docs/CALLDATA_ROUTE_SECURITY.md)) |
| Tests | ✅ 88/88 (25 unit + 5 invariant + 58 fork) |
| Adversarial tests | ✅ included in the fork suite (Cork-style direct-call, Bunni-style lying fewToken, force-fed ETH, reentrant sweep, degenerate pair, default-connector constructor checks, V4Quoter empty-hookData exact-in/out, calldata-route endpoint/fake-token/duplicate/missing-pair/slippage cases, etc.) |
| Known-issues triage | ✅ [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) |
| Residual-key risk doc | ✅ [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md) |
| External professional audit | ⬜ pending (Cantina lite / Spearbit / Code4rena) |
| Multisig for RingUniBurner owner | ⬜ pending — Gnosis Safe 3/5+ with timelock before mainnet |
| Monitoring live | ⬜ pending before mainnet |
| Mainnet deployment | ⬜ pending audit + multisig |
| Submit to Uniswap hooklist | ⬜ pending deployment |
| Submit to Uniswap routing-api | ⬜ pending hooklist + 30d on-chain history |
| Hooks Marketplace application | ⬜ pending routing-api merge + Marketplace open |

---

## Pre-deploy blockers (non-negotiable)

1. **External audit** — at least 1 professional firm (Cantina / Spearbit / Code4rena) signs off with a public report. All Critical/High/Medium findings fixed.
2. **Multisig + timelock for the RingUniBurner owner** — the hook is ownerless, but the burner (which temporarily custodies accrued 5 bps fees) is owner-managed. Its owner must be a Gnosis Safe 3/5+ with a timelock before any meaningful volume.
3. **Monitoring live** — all 3 channels (Tenderly / Etherscan / OpenZeppelin Defender) running before deploy day.

---

## References

| Topic | Link |
|---|---|
| UNIfication governance proposal | https://blog.uniswap.org/unification |
| Uniswap official hooklist registry | https://github.com/Uniswap/hooklist |
| Uniswap protocol-fees (TokenJar + Firepit) | https://github.com/Uniswap/protocol-fees |
| Ring's prior Uniswap routing-api PR | https://github.com/Uniswap/routing-api/pull/1302 |
| V4 hook flag specification | https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol |

---

## License

GPL-2.0-or-later (matches Uniswap V4 core).
