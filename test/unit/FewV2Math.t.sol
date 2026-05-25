// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FewV2Math} from "../../src/lib/FewV2Math.sol";

/// @notice Hermetic math sanity checks. The same getAmountOut formula is in Phase E's
///         FewV2Library — this test set proves the new getAmountIn satisfies the V2
///         safety invariant `getAmountOut(getAmountIn(y)) >= y` and behaves correctly
///         for multi-hop walks.
contract FewV2MathTest is Test {
    // External wrapper — needed so vm.expectRevert sees the revert at a lower call depth.
    // Library functions inline into the caller, foiling the cheatcode if called directly.
    FewV2MathExternal external_;

    function setUp() public {
        external_ = new FewV2MathExternal();
    }

    // ──────────── getAmountOut sanity ────────────

    function test_getAmountOut_matchesV2() public pure {
        // Reserves: 5000 fwETH / 10_000_000 fwUSDC -> spot ~$2000/ETH.
        // 1 ETH in -> ~1994 USDC out (0.3% fee + spread).
        uint256 out = FewV2Math.getAmountOut(1 ether, 5000 ether, 10_000_000e6);
        assertGt(out, 1990e6);
        assertLt(out, 2000e6);
    }

    // ──────────── Safety invariant: getAmountIn over-supplies ────────────

    /// @dev The V2 +1 round-up guarantees getAmountOut(getAmountIn(y)) >= y.
    ///      This is the property our hook actually depends on for exact-output safety.
    function test_safetyInvariant_getAmountIn_oversupplies() public pure {
        uint256 reserveIn = 5000 ether;
        uint256 reserveOut = 10_000_000e6;

        for (uint256 desiredOut = 1e6; desiredOut <= 1_000_000e6; desiredOut *= 5) {
            uint256 inRequired = FewV2Math.getAmountIn(desiredOut, reserveIn, reserveOut);
            uint256 actualOut = FewV2Math.getAmountOut(inRequired, reserveIn, reserveOut);
            assertGe(actualOut, desiredOut, "getAmountIn must over-supply");
        }
    }

    /// @dev The reverse direction (getAmountIn(getAmountOut(x))) typically returns x or x-1,
    ///      because getAmountOut floors. We do NOT depend on this property; we just document it.
    function test_floorBehavior_in_to_out_to_in() public pure {
        uint256 reserveIn = 5000 ether;
        uint256 reserveOut = 10_000_000e6;

        for (uint256 amountIn = 1e16; amountIn <= 100 ether; amountIn *= 5) {
            uint256 out = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
            uint256 inRequired = FewV2Math.getAmountIn(out, reserveIn, reserveOut);
            // inRequired must NOT exceed amountIn by more than the +1 ceil convention.
            assertLe(inRequired, amountIn + 1, "ceil over-estimate should be at most +1 wei");
            // It may be slightly less due to flooring slack — that's expected.
        }
    }

    // ──────────── Reverts (via external wrapper) ────────────

    function test_getAmountOut_revertsOnZeroIn() public {
        vm.expectRevert(FewV2Math.InsufficientAmount.selector);
        external_.getAmountOut(0, 1e18, 1e18);
    }

    function test_getAmountOut_revertsOnEmptyReserves() public {
        vm.expectRevert(FewV2Math.InsufficientLiquidity.selector);
        external_.getAmountOut(1, 0, 1e18);
    }

    function test_getAmountIn_revertsOnUnderwater() public {
        vm.expectRevert(FewV2Math.InsufficientLiquidity.selector);
        external_.getAmountIn(1e18, 1e18, 1e18);
    }

    function test_getAmountsOut_revertsOnOddReserves() public {
        uint256[] memory reserves = new uint256[](3);
        reserves[0] = 1e18;
        reserves[1] = 1e18;
        reserves[2] = 1e18;
        vm.expectRevert(FewV2Math.InsufficientLiquidity.selector);
        external_.getAmountsOut(1, reserves);
    }

    // ──────────── Multi-hop ────────────

    function test_getAmountsOut_singleHop() public pure {
        uint256[] memory reserves = new uint256[](2);
        reserves[0] = 5000 ether;
        reserves[1] = 10_000_000e6;
        uint256[] memory amounts = FewV2Math.getAmountsOut(1 ether, reserves);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 1 ether);
        assertGt(amounts[1], 1990e6);
        assertLt(amounts[1], 2000e6);
    }

    function test_getAmountsOut_twoHop() public pure {
        // ETH -> USDC -> UNI (2 hops)
        uint256[] memory reserves = new uint256[](4);
        reserves[0] = 5000 ether; // hop1 fwETH
        reserves[1] = 10_000_000e6; // hop1 fwUSDC
        reserves[2] = 20_000_000e6; // hop2 fwUSDC reserve
        reserves[3] = 100_000 ether; // hop2 fwUNI reserve
        uint256[] memory amounts = FewV2Math.getAmountsOut(1 ether, reserves);
        assertEq(amounts.length, 3);
        assertEq(amounts[0], 1 ether);
        assertGt(amounts[1], 1990e6);
        assertLt(amounts[1], 2000e6);
        assertGt(amounts[2], 9 ether); // ~9.93 UNI for 1 ETH at $200/UNI implied
        assertLt(amounts[2], 11 ether);
    }

    function test_safetyInvariant_multiHop() public pure {
        // Multi-hop must also over-supply.
        uint256[] memory reserves = new uint256[](4);
        reserves[0] = 5000 ether;
        reserves[1] = 10_000_000e6;
        reserves[2] = 20_000_000e6;
        reserves[3] = 100_000 ether;

        uint256 desiredFinal = 5 ether; // want 5 UNI out
        uint256[] memory ins = FewV2Math.getAmountsIn(desiredFinal, reserves);
        // forward-walk ins[0] through reserves and check final >= desiredFinal
        uint256[] memory outs = FewV2Math.getAmountsOut(ins[0], reserves);
        assertGe(outs[2], desiredFinal, "multi-hop getAmountsIn must over-supply");
    }
}

contract FewV2MathExternal {
    function getAmountOut(uint256 a, uint256 r0, uint256 r1) external pure returns (uint256) {
        return FewV2Math.getAmountOut(a, r0, r1);
    }

    function getAmountIn(uint256 a, uint256 r0, uint256 r1) external pure returns (uint256) {
        return FewV2Math.getAmountIn(a, r0, r1);
    }

    function getAmountsOut(uint256 a, uint256[] calldata r) external pure returns (uint256[] memory) {
        return FewV2Math.getAmountsOut(a, r);
    }

    function getAmountsIn(uint256 a, uint256[] calldata r) external pure returns (uint256[] memory) {
        return FewV2Math.getAmountsIn(a, r);
    }
}
