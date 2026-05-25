// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RingUniBurner} from "../src/RingUniBurner.sol";

/// @notice Deploy `RingUniBurner` via the canonical CREATE2 proxy so the
///         address is deterministic across every EVM chain Ring targets.
///
///         Run BEFORE `MineHookAddress.s.sol` — the hook constructor takes
///         the burner address, so the burner must exist first.
///
///         Required env:
///             OWNER_ADDRESS=0x...              (multisig that controls the burner)
///             RPC_URL=https://...
///             PRIVATE_KEY=0x...                (deploy signer; pays gas only)
///
///         Optional env (defaults pre-filled for Ethereum mainnet):
///             TOKEN_JAR_ADDRESS=0x...          (Uniswap canonical TokenJar)
///             FEW_FACTORY=0x...
///             UNI_BURNER_SALT=0x...            (CREATE2 salt; default is keccak256("RingUniBurner.V1"))
///
///         Run:
///             forge script script/DeployUniBurner.s.sol \
///                 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --via-ir
///
/// @dev    TokenJar is Uniswap's official per-chain fee collector
///         (https://github.com/Uniswap/protocol-fees). Sending ERC20 to it
///         "pushes" the assets into Uniswap's UNI burn pipeline — Firepit
///         (Uniswap-governed) then burns UNI in exchange for the accumulated
///         assets. We are a "push source" the same way Uniswap V2 is.
///
///         Canonical TokenJar deployments:
///             Ethereum mainnet: 0xf38521f130fcCF29dB1961597bc5d2B60F995f85
///             Arbitrum / Base / OP / Unichain / World / Celo / Zora / Soneium / X Layer
///         See https://github.com/Uniswap/protocol-fees for per-chain addresses.
contract DeployUniBurner is Script {
    /// @notice Canonical CREATE2 deployer proxy — same address on every EVM chain.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Mainnet defaults.
    address constant TOKEN_JAR_DEFAULT = 0xf38521f130fcCF29dB1961597bc5d2B60F995f85;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;

    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address tokenJar = vm.envOr("TOKEN_JAR_ADDRESS", TOKEN_JAR_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        bytes32 salt = vm.envOr("UNI_BURNER_SALT", keccak256("RingUniBurner.V1"));

        console2.log("=== Pre-flight ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Owner:           ", owner);
        console2.log("TokenJar:        ", tokenJar);
        console2.log("FewFactory:      ", fewFactory);
        console2.logBytes32(salt);

        // Build CREATE2 init code.
        bytes memory creationCode = type(RingUniBurner).creationCode;
        bytes memory ctorArgs = abi.encode(tokenJar, fewFactory, owner);
        bytes memory initCode = abi.encodePacked(creationCode, ctorArgs);

        // Predict the deployed address.
        address predicted = _computeCreate2Address(salt, keccak256(initCode));
        console2.log("Predicted address:", predicted);

        // Skip if already deployed (idempotency — supports multi-chain replays).
        if (predicted.code.length > 0) {
            console2.log("=== Already deployed at predicted address; skipping ===");
            _assertState(RingUniBurner(predicted), tokenJar, fewFactory, owner);
            return;
        }

        // Broadcast.
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "CREATE2 deployer call failed");

        address deployed;
        if (ret.length == 32) {
            deployed = address(uint160(uint256(bytes32(ret))));
        } else if (ret.length >= 20) {
            deployed = address(bytes20(ret));
        } else {
            deployed = predicted;
        }
        require(deployed == predicted, "deployed address != predicted");
        require(deployed.code.length > 0, "burner bytecode missing");

        // Post-deploy state asserts (M2 audit fix style — verify deployment
        // actually picked up the right immutable / initial state).
        _assertState(RingUniBurner(deployed), tokenJar, fewFactory, owner);

        vm.stopBroadcast();

        console2.log("=== RingUniBurner deployed ===");
        console2.log("Address:", deployed);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Set UNI_BURNER_ADDRESS=", deployed);
        console2.log("  2. Run script/MineHookAddress.s.sol to compute hook salt");
        console2.log("  3. Run script/DeployMainnet.s.sol to deploy the hook");
        console2.log("  4. Multi-chain: re-run this script with identical env on each chain");
    }

    function _assertState(RingUniBurner burner, address tokenJar, address fewFactory, address owner) internal view {
        require(burner.tokenJar() == tokenJar, "burner.tokenJar mismatch");
        require(address(burner.fewFactory()) == fewFactory, "burner.fewFactory mismatch");
        require(burner.owner() == owner, "burner.owner mismatch");
        require(!burner.flushPaused(), "burner must start unpaused");
        console2.log("State asserts: all passed");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 raw = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash));
        return address(uint160(uint256(raw)));
    }
}
