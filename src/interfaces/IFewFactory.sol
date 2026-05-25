// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Ring's FewFactory — maps original ERC20 addresses to their deployed fewToken counterparts.
/// @dev Verified-equivalent of `contracts/few-periphery/contracts/interfaces/IFewFactory.sol`,
///      copied locally so this project stays self-contained.
interface IFewFactory {
    event WrappedTokenCreated(address indexed originalToken, address wrappedToken, uint256);

    /// @notice Returns the fewToken for `originalToken`, or address(0) if none deployed.
    function getWrappedToken(address originalToken) external view returns (address wrappedToken);

    function allWrappedTokens(uint256) external view returns (address wrappedToken);
    function allWrappedTokensLength() external view returns (uint256);
    function paused() external view returns (bool);

    /// @dev Permissioned in production; not used by the hook at runtime.
    function createToken(address originalToken) external returns (address wrappedToken);
}
