// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RingUniBurner} from "../../src/RingUniBurner.sol";

// ────────────────────────────────────────────────────────────────────
// Mocks
// ────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFewToken is ERC20 {
    address public immutable token; // underlying ERC20

    constructor(address _underlying) ERC20("FewToken", "fwTKN") {
        token = _underlying;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function unwrap(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        MockERC20(token).mint(msg.sender, amount); // 1:1 mint underlying
        return amount;
    }
}

/// @dev MockFewToken variant where unwrap returns the wrong amount, simulating
///      a malicious / buggy fewToken.
contract MockFewTokenBadUnwrap is ERC20 {
    address public immutable token;
    uint256 public unwrapReturnOverride;

    constructor(address _underlying) ERC20("BadFew", "bfwTKN") {
        token = _underlying;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReturnOverride(uint256 v) external {
        unwrapReturnOverride = v;
    }

    function unwrap(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        MockERC20(token).mint(msg.sender, amount);
        return unwrapReturnOverride;
    }
}

contract MockFewFactory {
    mapping(address => address) public getWrappedToken;

    function setWrap(address underlying, address fewToken) external {
        getWrappedToken[underlying] = fewToken;
    }
}

// ────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────

contract RingUniBurnerTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockFewToken fwWeth;
    MockFewToken fwUsdc;
    MockFewFactory fewFactory;
    RingUniBurner burner;

    address TOKEN_JAR = address(0xf38521f130fcCF29dB1961597bc5d2B60F995f85); // mainnet TokenJar
    address OWNER = address(0xABCD);
    address KEEPER = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");

        fwWeth = new MockFewToken(address(weth));
        fwUsdc = new MockFewToken(address(usdc));

        fewFactory = new MockFewFactory();
        fewFactory.setWrap(address(weth), address(fwWeth));
        fewFactory.setWrap(address(usdc), address(fwUsdc));

        burner = new RingUniBurner(TOKEN_JAR, address(fewFactory), OWNER);
    }

    // ─── Constructor ───────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(burner.tokenJar(), TOKEN_JAR);
        assertEq(address(burner.fewFactory()), address(fewFactory));
        assertEq(burner.owner(), OWNER);
        assertFalse(burner.flushPaused());
    }

    function test_constructor_zeroTokenJar_reverts() public {
        vm.expectRevert(RingUniBurner.ZeroAddress.selector);
        new RingUniBurner(address(0), address(fewFactory), OWNER);
    }

    function test_constructor_zeroFewFactory_reverts() public {
        vm.expectRevert(RingUniBurner.ZeroAddress.selector);
        new RingUniBurner(TOKEN_JAR, address(0), OWNER);
    }

    // ─── flush() main path ─────────────────────────────────────────

    function test_flush_zeroBalance_returnsZero() public {
        uint256 forwarded = burner.flush(address(fwWeth));
        assertEq(forwarded, 0);
        assertEq(weth.balanceOf(TOKEN_JAR), 0);
    }

    function test_flush_unwrapsAndForwardsToTokenJar_weth() public {
        fwWeth.mint(address(burner), 5 ether);
        uint256 tjBefore = weth.balanceOf(TOKEN_JAR);

        uint256 forwarded = burner.flush(address(fwWeth));

        assertEq(forwarded, 5 ether);
        assertEq(weth.balanceOf(TOKEN_JAR) - tjBefore, 5 ether, "5 WETH delivered to TokenJar");
        assertEq(weth.balanceOf(address(burner)), 0, "no underlying retained");
        assertEq(fwWeth.balanceOf(address(burner)), 0, "no fewToken retained");
    }

    function test_flush_unwrapsAndForwardsToTokenJar_usdc() public {
        fwUsdc.mint(address(burner), 1000e6);
        uint256 tjBefore = usdc.balanceOf(TOKEN_JAR);

        uint256 forwarded = burner.flush(address(fwUsdc));

        assertEq(forwarded, 1000e6);
        assertEq(usdc.balanceOf(TOKEN_JAR) - tjBefore, 1000e6);
    }

    function test_flush_caller_is_permissionless() public {
        fwWeth.mint(address(burner), 3 ether);

        vm.prank(KEEPER); // arbitrary EOA, not owner
        burner.flush(address(fwWeth));

        assertEq(weth.balanceOf(TOKEN_JAR), 3 ether);
    }

    function test_flush_emitsFlushedEvent() public {
        fwWeth.mint(address(burner), 2 ether);

        vm.expectEmit(true, true, true, true, address(burner));
        emit RingUniBurner.Flushed(address(fwWeth), address(weth), 2 ether, address(this));

        burner.flush(address(fwWeth));
    }

    // ─── flush() rejections ────────────────────────────────────────

    function test_flush_unknownFewToken_reverts() public {
        MockERC20 fake = new MockERC20("Fake", "FAKE");
        MockFewToken fakeFew = new MockFewToken(address(fake));
        fakeFew.mint(address(burner), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(RingUniBurner.UnknownFewToken.selector, address(fakeFew)));
        burner.flush(address(fakeFew));
    }

    function test_flush_unwrapMismatch_reverts() public {
        // Register a bad fewToken with the factory.
        MockFewTokenBadUnwrap bad = new MockFewTokenBadUnwrap(address(weth));
        fewFactory.setWrap(address(weth), address(bad)); // remap WETH → bad
        bad.mint(address(burner), 10 ether);
        bad.setReturnOverride(9 ether); // returns less than burned

        vm.expectRevert(abi.encodeWithSelector(RingUniBurner.UnwrapMismatch.selector, 10 ether, 9 ether));
        burner.flush(address(bad));
    }

    function test_flush_whenPaused_reverts() public {
        vm.prank(OWNER);
        burner.setFlushPaused(true);

        fwWeth.mint(address(burner), 1 ether);

        vm.expectRevert(RingUniBurner.FlushPaused.selector);
        burner.flush(address(fwWeth));
    }

    // ─── Owner setters ─────────────────────────────────────────────

    function test_setFlushPaused_ownerOnly() public {
        vm.prank(KEEPER);
        vm.expectRevert();
        burner.setFlushPaused(true);

        vm.prank(OWNER);
        burner.setFlushPaused(true);
        assertTrue(burner.flushPaused());
    }

    // ─── Emergency withdraw ────────────────────────────────────────

    function test_emergencyWithdraw_ownerOnly_transfersBalance() public {
        weth.mint(address(burner), 5 ether);

        vm.prank(KEEPER);
        vm.expectRevert();
        burner.emergencyWithdraw(address(weth), OWNER);

        vm.prank(OWNER);
        burner.emergencyWithdraw(address(weth), OWNER);
        assertEq(weth.balanceOf(OWNER), 5 ether);
        assertEq(weth.balanceOf(address(burner)), 0);
    }

    function test_emergencyWithdraw_zeroRecipient_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(RingUniBurner.ZeroAddress.selector);
        burner.emergencyWithdraw(address(weth), address(0));
    }

    function test_emergencyWithdraw_nativeEth_ownerOnly_transfersBalance() public {
        vm.deal(address(burner), 1 ether);
        uint256 ownerBefore = OWNER.balance;

        vm.prank(KEEPER);
        vm.expectRevert();
        burner.emergencyWithdraw(address(0), OWNER);

        vm.prank(OWNER);
        burner.emergencyWithdraw(address(0), OWNER);
        assertEq(OWNER.balance - ownerBefore, 1 ether);
        assertEq(address(burner).balance, 0);
    }

    // ─── Ownable hardening ─────────────────────────────────────────

    function test_renounceOwnership_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(RingUniBurner.ZeroAddress.selector);
        burner.renounceOwnership();
    }
}
