// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {RingAggregatorHook} from "../src/RingAggregatorHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "../src/interfaces/external/IFewV2.sol";

/// @notice Deploy RingAggregatorHook through the canonical CREATE2 proxy and
///         initialize the first ETH/USDC pool.
///
///         FULL DEPLOYMENT ORDER (per chain):
///             1. script/DeployUniBurner.s.sol     -> get RingUniBurner address
///             2. script/MineHookAddress.s.sol     -> compute HOOK_SALT + EXPECTED_HOOK_ADDRESS
///             3. script/DeployMainnet.s.sol       -> this script (deploys hook + inits pool)
///
///         Run AFTER MineHookAddress.s.sol, with the salt + predicted address
///         baked into your env:
///
///             HOOK_SALT=0x...                   (from mining step)
///             EXPECTED_HOOK_ADDRESS=0x...       (from mining step, for verification)
///             FEE_RECIPIENT_ADDRESS=0x...       (must match mining; dust sweep destination)
///             UNI_BURNER_ADDRESS=0x...          (from DeployUniBurner.s.sol output; must match mining)
///             RPC_URL=https://...
///             PRIVATE_KEY=0x...                 (deploy signer; pays gas only)
///             forge script script/DeployMainnet.s.sol \
///                 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --via-ir
///
/// @dev    Uses the canonical CREATE2 proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`)
///         so the same salt produces the same hook address on every EVM chain Ring deploys to.
///         Multi-chain replication: re-run this script with the same env on each chain.
contract DeployMainnet is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_DEFAULT = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;
    address constant FW_WETH_DEFAULT = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_WBTC_DEFAULT = 0x2078f336Fdd260f708BEc4a20c82b063274E1b23;
    address constant FW_USDC_DEFAULT = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant FW_USDT_DEFAULT = 0xef87f4608e601E8564800265AeE1c1FfaDF73283;
    address constant FW_DAI_DEFAULT = 0x8A6fe57C08C84e0f4eE97aAe68a62e820a37d259;
    address constant FW_USDR_DEFAULT = 0x29A294F8FE285Dfb259705213e375eCb7Fcf9d9b;

    /// @dev sqrtPriceX96 ≈ 1.0. Routing-api never reads this for hooks with
    ///      beforeSwapReturnDelta=true — it's only required so PoolManager.initialize doesn't reject.
    uint160 constant INIT_PRICE = 79228162514264337593543950336;

    /// @dev 30 bps pool fee — see AGGREGATOR_HOOK_DESIGN.md §6.4 / §10.2 for justification.
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function run() external {
        bytes32 salt = vm.envBytes32("HOOK_SALT");
        address expectedAddr = vm.envAddress("EXPECTED_HOOK_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address uniBurner = vm.envAddress("UNI_BURNER_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        address usdc = vm.envOr("USDC", USDC_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", RING_FACTORY_DEFAULT);
        address[6] memory defaultConnectors = _defaultConnectors();
        bool skipInitPool = vm.envOr("SKIP_INIT_POOL", false);

        console2.log("=== Pre-flight ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Expected hook:   ", expectedAddr);
        console2.log("Pool manager:    ", poolManager);
        console2.log("Fee recipient:   ", feeRecipient);
        console2.log("UNI burner:      ", uniBurner);

        // Build creation code with constructor args appended (CREATE2 input format).
        bytes memory creationCode = type(RingAggregatorHook).creationCode;
        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager),
            IFewFactory(fewFactory),
            ISwapV2Factory(fewV2Factory),
            IWETH9(weth),
            feeRecipient,
            uniBurner,
            defaultConnectors
        );

        // CREATE2 proxy ABI: data = abi.encodePacked(salt, init_code)
        // It performs CREATE2(0, init_code, salt) and returns the deployed address.
        bytes memory deployData = abi.encodePacked(salt, creationCode, ctorArgs);

        // ─── Broadcast ───
        vm.startBroadcast();

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(deployData);
        require(ok, "CREATE2 deployer call failed");

        // CREATE2 proxy returns the new contract address (left-padded to 32 bytes).
        address hookAddr;
        if (ret.length == 32) {
            hookAddr = address(uint160(uint256(bytes32(ret))));
        } else if (ret.length >= 20) {
            hookAddr = address(bytes20(ret));
        } else {
            // Some proxy variants return nothing — recompute predicted address.
            hookAddr = expectedAddr;
        }

        require(hookAddr == expectedAddr, "Hook address mismatch - re-mine salt");
        require(hookAddr.code.length > 0, "Hook bytecode missing");

        // ─── Post-deploy state assertions ───
        // Verify the deployed contract actually committed our expected immutable state.
        // If env vars or CREATE2 init code drifts silently, these asserts catch it before we
        // push to routing-api allowlist.
        RingAggregatorHook deployed = RingAggregatorHook(payable(hookAddr));
        require(deployed.feeRecipient() == feeRecipient, "feeRecipient mismatch in deployed hook");
        require(deployed.uniBurner() == uniBurner, "uniBurner mismatch in deployed hook");
        require(address(deployed.fewFactory()) == fewFactory, "fewFactory mismatch in deployed hook");
        require(address(deployed.fewV2Factory()) == fewV2Factory, "fewV2Factory mismatch in deployed hook");
        require(address(deployed.weth()) == weth, "weth mismatch in deployed hook");
        require(deployed.PROTOCOL_FEE_BPS() == 5, "PROTOCOL_FEE_BPS must be 5");
        for (uint256 i = 0; i < defaultConnectors.length; ++i) {
            require(deployed.defaultConnector(i) == defaultConnectors[i], "default connector mismatch");
        }

        console2.log("=== Hook deployed ===");
        console2.log("Address:", hookAddr);
        console2.log("State asserts: all passed");

        if (!skipInitPool) {
            // Initialize ETH/USDC pool (currency0 = address(0) since 0 < USDC)
            PoolKey memory ethUsdcKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(usdc),
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hookAddr)
            });

            IPoolManager(poolManager).initialize(ethUsdcKey, INIT_PRICE);

            console2.log("=== ETH/USDC pool initialized ===");
            console2.log("currency0:    address(0) (native ETH)");
            console2.log("currency1:    USDC", usdc);
            console2.log("fee:          3000 (30bps)");
            console2.log("tickSpacing:  60");
            console2.log("hooks:        ", hookAddr);
        } else {
            console2.log("(SKIP_INIT_POOL=true; pool initialization skipped)");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify on Etherscan:");
        console2.log("     forge verify-contract ", hookAddr, "RingAggregatorHook");
        console2.log("  2. Submit hook to canonical Uniswap hooklist registry");
        console2.log("  3. PR to ring-routing-api allowlist");
        console2.log("  4. Run smoke swap (small ETH -> USDC) to confirm e2e");
    }

    function _defaultConnectors() internal view returns (address[6] memory connectors) {
        connectors[0] = vm.envOr("FW_WETH", FW_WETH_DEFAULT);
        connectors[1] = vm.envOr("FW_WBTC", FW_WBTC_DEFAULT);
        connectors[2] = vm.envOr("FW_USDC", FW_USDC_DEFAULT);
        connectors[3] = vm.envOr("FW_USDT", FW_USDT_DEFAULT);
        connectors[4] = vm.envOr("FW_DAI", FW_DAI_DEFAULT);
        connectors[5] = vm.envOr("FW_USDR", FW_USDR_DEFAULT);
    }
}
