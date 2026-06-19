# ring-v4-aggregator-hook-audit

Clean-history public audit mirror for Ring's Uniswap v4 aggregator hook.

This hook exposes Ring's existing FewV2 liquidity as Uniswap v4 swapable pools. A Uniswap swap such as `ETH -> USDC` can be settled by the hook through the matching `fwETH/fwUSDC` FewV2 pair, while the user only sees the underlying tokens.

> **Status**: `audit-router-compat-aggregator-interface` branch. Direct-only ownerless hook with UniRoute aggregator-hook compatibility, 83/83 tests passing, V4Quoter and aggregator `quote` fork tests passing, Slither triaged at 8 findings / 0 real issues.

---

## Architecture

```text
V4 swap (tokenA -> tokenB)
  -> Hook.beforeSwap
  -> wrap tokenA to fewA
  -> direct FewV2 pair swap (fewA -> fewB)
  -> skim 5 bps fewB fee to RingUniBurner
  -> unwrap fewB to tokenB
  -> settle through PoolManager
```

The v4 pool holds zero liquidity. All liquidity comes from the direct FewV2 pair for the two pool endpoints.

Multi-hop price improvement is intentionally left to Uniswap routing. If `A -> X -> B` is better than `A -> B`, the router can compose two v4 pools and call the hook twice: once for `A -> X`, then once for `X -> B`. This keeps the hook small and removes the in-hook connector search / calldata path surface.

For Uniswap Labs / UniRoute discovery, this branch adds a narrow aggregator-hook compatibility layer: `AggregatorPoolRegistered`, `HookSwap`, `quote`, and `pseudoTotalValueLocked`. The core swap path remains direct-only.

---

## Permission Model

`RingAggregatorHook` is ownerless:

- no owner
- no admin functions
- no pause
- no upgrade path
- no admin route registry
- no connector whitelist
- no user-supplied pair addresses

Routing is fixed by immutable constructor wiring and live FewV2 pair state. Each v4 pool maps to one direct FewV2 pair derived from `fewV2Factory`.

| Concern | Design |
|---|---|
| Routing | Direct FewV2 pair only. `hookData` is ignored for routing so default router / quoter integrations do not need Ring-specific calldata. |
| UniRoute compatibility | Registers one canonical v4 shell pool per FewV2 pair and exposes `quote` / `pseudoTotalValueLocked` for external-liquidity routing. |
| Liquidity source | `fewFactory` and `fewV2Factory` are immutable. FewTokens and pairs are derived on-chain. |
| Protocol fee | `PROTOCOL_FEE_BPS = 5`. Gross output fee is sent to immutable `uniBurner`. |
| Fee pipeline | Ring pushes fees into Uniswap's TokenJar via `RingUniBurner`; Uniswap's Firepit handles the downstream UNI burn. |
| Emergency | The hook has no pause. Failure response is per-swap revert, routing-layer delist, or redeploy. |
| Sweep | `sweep(token)` is permissionless and always sends to immutable `feeRecipient`. |

The only privileged key is `RingUniBurner.owner`, on a separate fee adapter. Its scope is limited to accrued protocol fees held by the burner, never user swap funds. See [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md).

---

## Audit Scope

The Ring-written production review surface is intentionally small:

| Contract | nSLOC | Role |
|---|---:|---|
| `src/RingAggregatorHook.sol` | 406 | Direct-only ownerless v4 hook plus UniRoute aggregator compatibility |
| `src/RingUniBurner.sol` | 64 | TokenJar push-source adapter |
| `src/lib/FewV2Math.sol` | 32 | V2 `getAmountOut` / `getAmountIn` math |
| **Total** | **502** | |

Interfaces, tests, scripts, docs, and pinned third-party dependencies are out of production scope. See [`AUDIT_SCOPE.md`](AUDIT_SCOPE.md).

---

## Documentation Map

| File | Purpose |
|---|---|
| [`AUDIT_SCOPE.md`](AUDIT_SCOPE.md) | External-audit package: in scope, out of scope, nSLOC, questions |
| [`docs/ABDK_Ring_Aggregator_Hook_Audit_Report_v1.1.pdf`](docs/ABDK_Ring_Aggregator_Hook_Audit_Report_v1.1.pdf) | ABDK public audit report for the core hook review |
| [`docs/DIRECT_ONLY_ROUTING.md`](docs/DIRECT_ONLY_ROUTING.md) | Direct-only routing model and why SOR composes multi-hop paths |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Architecture reference |
| [`docs/RATIONALE.md`](docs/RATIONALE.md) | Design decisions and rejected alternatives |
| [`docs/SLITHER_TRIAGE.md`](docs/SLITHER_TRIAGE.md) | 7 Slither findings triaged, 0 real issues |
| [`docs/TEST_COVERAGE.md`](docs/TEST_COVERAGE.md) | Coverage and test matrix |
| [`docs/OWNER_KEY_COMPROMISE.md`](docs/OWNER_KEY_COMPROMISE.md) | Residual key analysis for `RingUniBurner.owner` |
| [`docs/UNI_BURN_NOTES.md`](docs/UNI_BURN_NOTES.md) | 5 bps TokenJar / Firepit fee path |
| [`docs/GO_LIVE_MECHANICS.md`](docs/GO_LIVE_MECHANICS.md) | How swaps reach the hook after listing / routing integration |
| [`docs/DEPLOYMENT_FLOW.md`](docs/DEPLOYMENT_FLOW.md) | Audit-to-deploy roadmap |
| [`docs/INDEX.md`](docs/INDEX.md) | One-page documentation guide |

---

## Layout

```text
src/
├── RingAggregatorHook.sol        # main direct-only hook, ownerless
├── RingUniBurner.sol             # TokenJar push-source adapter, owner-managed
├── interfaces/external/          # ABI-only references
└── lib/FewV2Math.sol             # V2 quote math

test/
├── unit/                         # 21 unit tests
├── invariant/                    # 5 property-fuzz tests
└── fork/                         # 47 mainnet-fork integration/adversarial tests

script/
├── DeployUniBurner.s.sol
├── MineHookAddress.s.sol
├── DeployMainnet.s.sol
├── InitializeEthUsdcPool.s.sol
├── InitializeRecommendedPools.s.sol
└── SmokeSwapEthUsdc.s.sol

docs/
├── DIRECT_ONLY_ROUTING.md
├── DESIGN.md
├── RATIONALE.md
├── SLITHER_TRIAGE.md
├── TEST_COVERAGE.md
├── OWNER_KEY_COMPROMISE.md
├── UNI_BURN_NOTES.md
├── GO_LIVE_MECHANICS.md
├── DEPLOYMENT_FLOW.md
├── MECHANISM_PROVENANCE.md
└── INDEX.md
```

---

## Build And Test

Prerequisites:

- Foundry
- An Ethereum mainnet RPC URL for fork tests

```sh
git clone --recurse-submodules git@github.com:RingProtocol/ring-v4-aggregator-hook-audit.git
cd ring-v4-aggregator-hook-audit
git checkout audit-router-compat-aggregator-interface
git submodule update --init --recursive
forge build
```

Hermetic tests:

```sh
forge test --offline --no-match-path "test/fork/*"
```

Full suite:

```sh
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY forge test
```

Static analysis:

```sh
uvx --from slither-analyzer slither . \
  --filter-paths "lib/|test/|script/" \
  --exclude naming-convention,solc-version,pragma
```

---

## Deploy

```sh
# 1. Deploy RingUniBurner. OWNER_ADDRESS is the burner owner, not the hook owner.
OWNER_ADDRESS=0x... forge script script/DeployUniBurner.s.sol \
  --rpc-url $RPC --broadcast --via-ir

# 2. Mine a hook CREATE2 salt.
UNI_BURNER_ADDRESS=0x... FEE_RECIPIENT_ADDRESS=0x... \
  forge script script/MineHookAddress.s.sol --via-ir

# 3. Deploy hook. Leave SKIP_INIT_POOL unset to initialize ETH/USDC in the same tx,
#    or set SKIP_INIT_POOL=true and run the init script separately.
HOOK_SALT=0x... EXPECTED_HOOK_ADDRESS=0x... \
UNI_BURNER_ADDRESS=0x... FEE_RECIPIENT_ADDRESS=0x... \
  forge script script/DeployMainnet.s.sol --rpc-url $RPC --broadcast --via-ir

# 4. Initialize recommended v4 shell pools for existing direct FewV2 pairs.
HOOK_ADDRESS=0x... \
  forge script script/InitializeRecommendedPools.s.sol --rpc-url $RPC --broadcast --via-ir

# 5. Run a tiny ETH -> USDC smoke swap through PoolManager + hook.
HOOK_ADDRESS=0x... \
  forge script script/SmokeSwapEthUsdc.s.sol --tc SmokeSwapEthUsdc \
  --rpc-url $RPC --broadcast --via-ir
```

The hook has no owner to transfer after deployment. The burner owner must be transferred to a Gnosis Safe with a timelock before meaningful volume.

---

## Status

| Item | State |
|---|---|
| Code complete | Yes |
| Tests | 83/83 passing |
| V4Quoter / aggregator quote fork coverage | Exact-input and exact-output direct route tests passing |
| Slither | 8 findings triaged, 0 real issues |
| Hook admin surface | None |
| External audit | ABDK public report v1.1 included; router-compat delta is narrow and tested |
| Multisig for `RingUniBurner.owner` | Required before meaningful volume |
| Uniswap hooklist / Labs routing allowlist | Re-submit after deploying this router-compatible hook address |

---

## References

| Topic | Link |
|---|---|
| Uniswap official hooklist registry | https://github.com/Uniswap/hooklist |
| Uniswap protocol-fees (TokenJar + Firepit) | https://github.com/Uniswap/protocol-fees |
| Uniswap Labs hook routing allowlist | https://developers.uniswap.org/hook-allowlist |
| UniRoute public reference | https://github.com/Uniswap/uniroute-public |
| V4 hook flags | https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol |

---

## License

GPL-2.0-or-later.
