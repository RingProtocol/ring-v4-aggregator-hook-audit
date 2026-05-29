// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {RingAggregatorHook} from "../src/RingAggregatorHook.sol";
import {IFewFactory} from "../src/interfaces/IFewFactory.sol";
import {ISwapV2Factory} from "../src/interfaces/IFewV2.sol";

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
    address constant FW_WETH_DEFAULT = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_WBTC_DEFAULT = 0x2078f336Fdd260f708BEc4a20c82b063274E1b23;
    address constant FW_USDC_DEFAULT = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant FW_USDT_DEFAULT = 0xef87f4608e601E8564800265AeE1c1FfaDF73283;
    address constant FW_DAI_DEFAULT = 0x8A6fe57C08C84e0f4eE97aAe68a62e820a37d259;
    address constant FW_USDR_DEFAULT = 0x29A294F8FE285Dfb259705213e375eCb7Fcf9d9b;

    function run() external view {
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", RING_FACTORY_DEFAULT);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address uniBurner = vm.envAddress("UNI_BURNER_ADDRESS");
        address[6] memory defaultConnectors = _defaultConnectors();

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
            uniBurner,
            defaultConnectors
        );

        console2.log("=== Mining hook address ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Pool manager:    ", poolManager);
        console2.log("Few factory:     ", fewFactory);
        console2.log("FewV2 factory:   ", fewV2Factory);
        console2.log("WETH:            ", weth);
        console2.log("Fee recipient:   ", feeRecipient);
        console2.log("UNI burner:      ", uniBurner);
        console2.log("Default connectors:");
        for (uint256 i = 0; i < defaultConnectors.length; ++i) {
            console2.log("  connector:", defaultConnectors[i]);
        }
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

    function _defaultConnectors() internal view returns (address[6] memory connectors) {
        connectors[0] = vm.envOr("FW_WETH", FW_WETH_DEFAULT);
        connectors[1] = vm.envOr("FW_WBTC", FW_WBTC_DEFAULT);
        connectors[2] = vm.envOr("FW_USDC", FW_USDC_DEFAULT);
        connectors[3] = vm.envOr("FW_USDT", FW_USDT_DEFAULT);
        connectors[4] = vm.envOr("FW_DAI", FW_DAI_DEFAULT);
        connectors[5] = vm.envOr("FW_USDR", FW_USDR_DEFAULT);
    }
}
