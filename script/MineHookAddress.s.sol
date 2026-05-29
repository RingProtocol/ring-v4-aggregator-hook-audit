// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {RingAggregatorHook} from "../src/RingAggregatorHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "../src/interfaces/external/IFewV2.sol";

/// @notice Mine a CREATE2 salt for RingAggregatorHook so its address encodes the
///         beforeInitialize | beforeAddLiquidity | beforeSwap | beforeSwapReturnsDelta flags
///         (mask 0x2888) in the lowest 14 bits.
///
///         Run BEFORE deployment day:
///
///             FEE_RECIPIENT_ADDRESS=0x... \
///             UNI_BURNER_ADDRESS=0x... \
///             forge script script/MineHookAddress.s.sol --via-ir
///
///         Output the salt + predicted address into your .env, then run DeployMainnet.
///
/// @dev    The deployer used here is the canonical CREATE2 proxy
///         `0x4e59b44847b379578588920cA78FbF26c0B4956C` (same address on every EVM chain).
///         Mining + deploying through it gives the SAME hook address on all 7 Ring chains.
contract MineHookAddress is Script {
    /// @notice Canonical CREATE2 deployer proxy — same address on all EVM chains.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Mainnet defaults — override via env vars if needed for other chains.
    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;

    function run() external view {
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", RING_FACTORY_DEFAULT);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address uniBurner = vm.envAddress("UNI_BURNER_ADDRESS");

        // The four flags the contract subscribes to.
        // Bit positions (from v4-core/src/libraries/Hooks.sol):
        //   BEFORE_INITIALIZE_FLAG          = 1 << 13   = 0x2000
        //   BEFORE_ADD_LIQUIDITY_FLAG       = 1 << 11   = 0x0800
        //   BEFORE_SWAP_FLAG                = 1 <<  7   = 0x0080
        //   BEFORE_SWAP_RETURNS_DELTA_FLAG  = 1 <<  3   = 0x0008
        //   ─────────────────────────────────────────────────────
        //   Combined mask                                = 0x2888
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory creationCode = type(RingAggregatorHook).creationCode;
        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager),
            IFewFactory(fewFactory),
            ISwapV2Factory(fewV2Factory),
            IWETH9(weth),
            feeRecipient,
            uniBurner
        );

        console2.log("=== Mining hook address ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Pool manager:    ", poolManager);
        console2.log("Few factory:     ", fewFactory);
        console2.log("FewV2 factory:   ", fewV2Factory);
        console2.log("WETH:            ", weth);
        console2.log("Fee recipient:   ", feeRecipient);
        console2.log("UNI burner:      ", uniBurner);
        console2.log("Flags (uint160): ", flags);
        console2.log("");

        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, ctorArgs);

        console2.log("=== Mining complete ===");
        console2.log("Hook address:    ", mined);
        console2.log("Salt:");
        console2.logBytes32(salt);
        console2.log("");
        console2.log("Save the salt to .env as HOOK_SALT, then run DeployMainnet.s.sol.");
    }
}
