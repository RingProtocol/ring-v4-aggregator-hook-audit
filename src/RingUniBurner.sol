// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";

/// @title  RingUniBurner — Push-source adapter to Uniswap's TokenJar
/// @notice Receives the 5 bps protocol fee (denominated in fewTokens) from
///         `RingAggregatorHook`, unwraps fewToken → underlying ERC20, and
///         forwards the underlying to Uniswap's canonical `TokenJar` fee
///         collector. From there, Uniswap's governance-controlled `Firepit`
///         contract handles the actual UNI buyback + burn (sending UNI to
///         `0x000...dEaD`).
///
/// @dev    Architecture rationale: align with Uniswap's official protocol-fees
///         pipeline rather than rolling our own UNI swap/burn logic. The
///         TokenJar + Firepit pattern is documented in the UNIfication
///         governance proposal (passed Dec 2025) and implemented in
///         https://github.com/Uniswap/protocol-fees. By matching the
///         "push source" model that Uniswap V2 uses to deliver fees to
///         TokenJar, Ring slots cleanly into the same review/audit framework
///         the Foundation applies to its own protocol versions.
///
/// @dev    Canonical TokenJar deployments:
///           Ethereum mainnet: 0xf38521f130fcCF29dB1961597bc5d2B60F995f85
///           Also live on:     Arbitrum One, Base, OP Mainnet, Polygon,
///                             Unichain, World Chain, Celo, Zora, Soneium,
///                             X Layer.
///         Pass the chain-appropriate address as `_tokenJar` at construction.
///
/// @dev    Design principles:
///         1. NO REVERTING RECEIVE — passive ERC20 receive, no fallback. The
///            hook's `safeTransfer(thisContract, fee)` always succeeds.
///         2. PERMISSIONLESS FLUSH — `flush(fewToken)` is callable by anyone.
///            No slippage, no oracle dependency: we just unwrap (1:1) and
///            push the underlying to TokenJar. Keeper bots can run it on
///            a cron without worrying about MEV.
///         3. NO SWAPS, NO UNI HANDLING — this contract never holds UNI,
///            never swaps. All UNI logic lives in Uniswap's Firepit on the
///            other side of TokenJar.
///         4. EMERGENCY ESCAPE — owner can `emergencyWithdraw` accumulated
///            fewTokens if TokenJar is somehow paused or moved. Withdrawn
///            tokens are expected to be manually forwarded via an alternate
///            path. This is an operational rescue, not a fee diversion.
///
/// @dev    Source reference: https://github.com/Uniswap/protocol-fees
contract RingUniBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Immutable ============

    /// @notice Uniswap's canonical fee collector on this chain.
    /// @dev    Address per chain published at:
    ///         https://github.com/Uniswap/protocol-fees (deployments table).
    address public immutable tokenJar;

    IFewFactory public immutable fewFactory;

    // ============ Mutable (owner-controlled) ============

    /// @notice Pause flag. Owner can disable flush entirely if TokenJar is
    ///         temporarily paused (e.g., during a Foundation migration).
    bool public flushPaused;

    // ============ Errors ============

    error ZeroAddress();
    error UnknownFewToken(address fewToken);
    error UnwrapMismatch(uint256 expected, uint256 actual);
    error FlushPaused();

    // ============ Events ============

    event Flushed(address indexed fewToken, address indexed underlying, uint256 amount, address indexed caller);
    event FlushPausedSet(bool paused);
    event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);

    // ============ Constructor ============

    constructor(address _tokenJar, address _fewFactory, address _owner) Ownable(_owner) {
        if (_tokenJar == address(0)) revert ZeroAddress();
        if (_fewFactory == address(0)) revert ZeroAddress();
        tokenJar = _tokenJar;
        fewFactory = IFewFactory(_fewFactory);
    }

    // ============ Main entry ============

    /// @notice Unwrap accumulated `fewToken` balance to its underlying ERC20
    ///         and push the underlying to `tokenJar`. Anyone can call.
    /// @param  fewToken  The fewToken sitting in this contract (transferred
    ///                   in by `RingAggregatorHook` on each swap).
    /// @return amount    Amount of underlying forwarded to TokenJar.
    function flush(address fewToken) external nonReentrant returns (uint256 amount) {
        if (flushPaused) revert FlushPaused();

        uint256 fewBalance = IERC20(fewToken).balanceOf(address(this));
        if (fewBalance == 0) return 0;

        // Validate fewToken via fewFactory (defends against caller forwarding
        // a non-Few ERC20 with a malicious unwrap implementation).
        address underlying = IFewWrappedToken(fewToken).token();
        if (fewFactory.getWrappedToken(underlying) != fewToken) {
            revert UnknownFewToken(fewToken);
        }

        // Unwrap fewToken → underlying (1:1 by Few protocol invariant).
        uint256 unwrapped = IFewWrappedToken(fewToken).unwrap(fewBalance);
        if (unwrapped != fewBalance) revert UnwrapMismatch(fewBalance, unwrapped);

        // Push underlying to Uniswap's TokenJar. From here, Firepit (governed
        // by Uniswap DAO) accumulates and periodically burns UNI against the
        // collected assets.
        IERC20(underlying).safeTransfer(tokenJar, unwrapped);

        emit Flushed(fewToken, underlying, unwrapped, msg.sender);
        return unwrapped;
    }

    // ============ Owner functions ============

    /// @notice Pause/unpause `flush`. Used if Uniswap's TokenJar is migrated
    ///         or temporarily unsafe to forward into. Owner-only.
    /// @param  _paused True to halt flushing (fees accumulate in this contract
    ///         until unpaused), false to resume.
    function setFlushPaused(bool _paused) external onlyOwner {
        flushPaused = _paused;
        emit FlushPausedSet(_paused);
    }

    /// @notice Emergency withdraw of any ERC20 stuck in this contract.
    /// @dev    Use case: TokenJar address changes (Foundation migration) and
    ///         this contract is no longer addressable, OR a particular
    ///         fewToken's `unwrap` is broken. Owner rescues the asset and
    ///         routes it via an alternative path. **Not** intended for fee
    ///         diversion — owners are expected to honour the public commitment
    ///         that all skimmed fees ultimately reach Uniswap.
    function emergencyWithdraw(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawn(token, to, amount);
    }

    // ============ Ownable hardening ============

    /// @dev Renouncing would permanently lock pause/emergency tools.
    function renounceOwnership() public pure override {
        revert ZeroAddress();
    }
}
