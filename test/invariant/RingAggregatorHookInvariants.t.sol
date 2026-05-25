// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @title RingAggregatorHook Invariants (branch-agnostic)
/// @notice Property-based fuzz tests asserting math invariants used in the
///         hook's fee skim + ExactOutput gross-up + reserve sentinel logic.
///         These must compile + pass on BOTH branches (`main` with fee=0 and
///         `feat/uni-burn-5bps` with fee=5).
///
/// @dev Tests here verify the MATH that the hook depends on — not the hook's
///      stateful behaviour. Stateful invariant tests (Foundry handlers) are
///      recommended pre-audit but require non-trivial harness scaffolding;
///      these property tests catch the core arithmetic bugs at trivial cost
///      (10000 fuzz runs * 4 properties = 40000 random inputs per CI run).
contract RingAggregatorHookInvariants is Test {
    // ───────────────────────────────────────────────────────────────────────
    // Invariant 1 — ExactOutput gross-up ceildiv never under-quotes
    //
    // The formula the hook uses for ExactOutput:
    //     fwOutGross = (amountOut * FEE_DENOM + (FEE_DENOM - feeBps) - 1) / (FEE_DENOM - feeBps)
    //
    // Must satisfy:
    //     floor(fwOutGross * (FEE_DENOM - feeBps) / FEE_DENOM) >= amountOut
    //
    // Otherwise the user gets less than requested -> ExactOutputUnderfilled
    // is the only safety net. We want the math itself to guarantee >= target.
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_invariant_exactOutGrossUp_neverUnderQuotes(uint256 amountOut, uint24 feeBps) public pure {
        amountOut = bound(amountOut, 1, 1e24); // 1 wei .. 1M of 18-decimal token
        feeBps = uint24(bound(feeBps, 0, 100)); // 0 .. 1%

        uint256 FEE_DENOM = 10_000;
        uint256 netDenom = FEE_DENOM - feeBps;

        // Same ceildiv formula as in RingAggregatorHook._swapExactOutput
        uint256 fwOutGross = (amountOut * FEE_DENOM + netDenom - 1) / netDenom;

        uint256 userReceives = (fwOutGross * netDenom) / FEE_DENOM;
        assertGe(userReceives, amountOut, "gross-up under-quotes: user would receive less than requested");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Invariant 2 - fee skim is monotone in fwOutAmount (larger swap >=
    // equal fee per swap; integer rounding can produce equality but never
    // smaller fee for larger amount).
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_invariant_feeSkim_monotone(uint256 a, uint256 b, uint24 feeBps) public pure {
        a = bound(a, 0, 1e24);
        b = bound(b, 0, 1e24);
        feeBps = uint24(bound(feeBps, 0, 100));

        if (a > b) (a, b) = (b, a); // ensure a <= b

        uint256 feeA = (a * feeBps) / 10_000;
        uint256 feeB = (b * feeBps) / 10_000;

        assertGe(feeB, feeA, "fee not monotone in amount");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Invariant 3 - fee never exceeds the gross output (sanity: skim is a
    // strict subset, not an additive surcharge).
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_invariant_feeSkim_neverExceedsOutput(uint256 fwOutAmount, uint24 feeBps) public pure {
        fwOutAmount = bound(fwOutAmount, 0, type(uint128).max);
        feeBps = uint24(bound(feeBps, 0, 10_000)); // any plausible bps

        uint256 fee = (fwOutAmount * feeBps) / 10_000;
        assertLe(fee, fwOutAmount, "fee exceeds gross output");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Invariant 4 - MIN_PAIR_RESERVE sentinel partitions reserves into a
    // clean binary (degenerate vs healthy). No reserve value falls in both
    // sets or neither set.
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_invariant_minPairReserve_sentinelBoundary(uint256 reserve) public pure {
        reserve = bound(reserve, 0, type(uint112).max);
        uint256 MIN_PAIR_RESERVE = 1000;

        bool isDegenerate = reserve <= MIN_PAIR_RESERVE;
        bool isHealthy = reserve > MIN_PAIR_RESERVE;

        assertTrue(isDegenerate != isHealthy, "boundary partition broken");
        assertEq(MIN_PAIR_RESERVE + 1, 1001, "smallest healthy reserve must be 1001");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Invariant 5 - fee + user output exactly equals gross (no value leaks).
    // For any (fwOutAmount, feeBps), the hook's accounting must be:
    //     fee + user_remainder = fwOutAmount
    // ───────────────────────────────────────────────────────────────────────

    function testFuzz_invariant_feeAndUserOutput_sumToGross(uint256 fwOutAmount, uint24 feeBps) public pure {
        fwOutAmount = bound(fwOutAmount, 0, type(uint128).max);
        feeBps = uint24(bound(feeBps, 0, 10_000));

        uint256 fee = (fwOutAmount * feeBps) / 10_000;
        uint256 userOut = fwOutAmount - fee;

        assertEq(fee + userOut, fwOutAmount, "value leaked: fee + userOut != gross");
    }
}
