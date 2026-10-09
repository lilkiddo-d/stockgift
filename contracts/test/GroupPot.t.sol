// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {GroupPot} from "../src/GroupPot.sol";
import {GiftVault} from "../src/GiftVault.sol";
import {ProtocolBase} from "../src/base/ProtocolBase.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";

contract GroupPotTest is BaseTest {
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        address[2] memory people = [carol, dave];
        for (uint256 i; i < 2; ++i) {
            usdg.mint(people[i], 1_000e6);
            vm.prank(people[i]);
            usdg.approve(address(pot), type(uint256).max);
        }
    }

    function _createPot() internal returns (uint256 id) {
        vm.prank(alice);
        id = pot.createPot(
            address(usdg), linkKey, address(tsla), false, 300, uint64(block.timestamp + 7 days), 30 days, "Wedding gift"
        );
    }

    function _contribute(uint256 id, address who, uint256 amt) internal {
        vm.prank(who);
        pot.contribute(id, amt, "congrats!");
    }

    function test_fullFlow_contributeFinalizeClaim() public {
        uint256 id = _createPot();
        _contribute(id, carol, 30e6);
        _contribute(id, dave, 70e6);
        _contribute(id, carol, 100e6);
        assertEq(pot.getPot(id).total, 200e6);
        assertEq(pot.contributions(id, carol), 130e6);

        vm.prank(carol);
        vm.expectRevert(GroupPot.Unauthorized.selector);
        pot.finalize(id);

        vm.prank(alice);
        uint256 giftId = pot.finalize(id);
        assertEq(usdg.balanceOf(address(pot)), 0);
        assertEq(vault.getGift(giftId).sender, address(pot));
        assertEq(vault.getGift(giftId).amount, _net(200e6));

        // one claim link for the recipient
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        vault.claim(giftId, c, _sign(linkPk, giftId, c));
        assertEq(tsla.balanceOf(bob), (_net(200e6) * 1e12) / 250);

        vm.expectRevert(GroupPot.NotOpen.selector);
        _contribute(id, carol, 1e6);
        vm.expectRevert(GroupPot.NotOpen.selector);
        pot.finalize(id);
    }

    function test_anyoneFinalizesAfterClose() public {
        uint256 id = _createPot();
        _contribute(id, carol, 10e6);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(GroupPot.NotOpen.selector);
        _contribute(id, dave, 10e6);
        vm.prank(dave);
        pot.finalize(id);
        assertEq(uint8(pot.getPot(id).status), uint8(GroupPot.PotStatus.Finalized));
    }

    function test_finalizeEmptyReverts() public {
        uint256 id = _createPot();
        vm.prank(alice);
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.finalize(id);
    }

    function test_cancelPot_fullWithdraw() public {
        uint256 id = _createPot();
        _contribute(id, carol, 30e6);
        _contribute(id, dave, 70e6);
        vm.prank(carol);
        vm.expectRevert(GroupPot.NotRefundable.selector);
        pot.withdraw(id);
        vm.prank(carol);
        vm.expectRevert(GroupPot.Unauthorized.selector);
        pot.cancelPot(id);
        vm.prank(alice);
        pot.cancelPot(id);
        vm.prank(carol);
        pot.withdraw(id);
        vm.prank(dave);
        pot.withdraw(id);
        assertEq(usdg.balanceOf(carol), 1_000e6);
        assertEq(usdg.balanceOf(dave), 1_000e6);
        vm.prank(dave);
        vm.expectRevert(GroupPot.NothingToWithdraw.selector);
        pot.withdraw(id);
        vm.prank(alice);
        vm.expectRevert(GroupPot.NotOpen.selector);
        pot.cancelPot(id);
    }

    function test_expiredGift_proRataRefund() public {
        uint256 id = _createPot();
        _contribute(id, carol, 25e6);
        _contribute(id, dave, 75e6);
        vm.prank(alice);
        uint256 giftId = pot.finalize(id);

        vm.expectRevert(GroupPot.NotRefundable.selector);
        pot.syncRefund(id);
        vm.warp(block.timestamp + 31 days);
        vault.refund(giftId); // keeper refunds to the pot
        pot.syncRefund(id);
        assertEq(pot.getPot(id).refundPool, _net(100e6));

        vm.prank(carol);
        pot.withdraw(id);
        vm.prank(dave);
        pot.withdraw(id);
        assertEq(usdg.balanceOf(carol), 1_000e6 - 25e6 + (25e6 * _net(100e6)) / 100e6);
        assertEq(usdg.balanceOf(dave), 1_000e6 - 75e6 + (75e6 * _net(100e6)) / 100e6);
    }

    function test_cancelGift_and_rekey() public {
        uint256 id = _createPot();
        uint256 newPk = 0xC0FFEE;
        vm.prank(alice);
        pot.rekey(id, vm.addr(newPk)); // before finalize
        assertEq(pot.getPot(id).claimKey, vm.addr(newPk));
        _contribute(id, carol, 50e6);
        vm.prank(alice);
        uint256 giftId = pot.finalize(id);
        assertEq(vault.getGift(giftId).claimKey, vm.addr(newPk));

        vm.prank(alice);
        pot.rekey(id, linkKey); // after finalize: propagates to the vault
        assertEq(vault.getGift(giftId).claimKey, linkKey);

        vm.prank(carol);
        vm.expectRevert(GroupPot.Unauthorized.selector);
        pot.cancelGift(id);
        vm.prank(alice);
        pot.cancelGift(id);
        assertEq(uint8(vault.giftStatus(giftId)), uint8(IGiftVault.Status.Refunded));
        vm.prank(carol);
        pot.withdraw(id);
        assertEq(usdg.balanceOf(carol), 1_000e6 - 50e6 + _net(50e6));

        vm.prank(alice);
        vm.expectRevert(GroupPot.NotOpen.selector);
        pot.rekey(id, linkKey);
        vm.prank(alice);
        vm.expectRevert(GroupPot.NotOpen.selector);
        pot.cancelGift(id);
        vm.prank(carol);
        vm.expectRevert(GroupPot.Unauthorized.selector);
        pot.rekey(id, linkKey);
        vm.prank(alice);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        pot.rekey(id, address(0));
    }

    function test_createPot_validation() public {
        vm.startPrank(alice);
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(aapl), linkKey, address(0), false, 0, uint64(block.timestamp + 1 days), 30 days, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(usdg), address(0), address(0), false, 0, uint64(block.timestamp + 1 days), 30 days, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(usdg), linkKey, address(usdg), false, 0, uint64(block.timestamp + 1 days), 30 days, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(usdg), linkKey, address(0), false, 5000, uint64(block.timestamp + 1 days), 30 days, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(usdg), linkKey, address(0), false, 0, uint64(block.timestamp), 30 days, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(address(usdg), linkKey, address(0), false, 0, uint64(block.timestamp + 1 days), 1 hours, "");
        vm.expectRevert(GroupPot.InvalidParams.selector);
        pot.createPot(
            address(usdg), linkKey, address(0), false, 0, uint64(block.timestamp + 1 days), 30 days, string(new bytes(281))
        );
        vm.stopPrank();
        uint256 id = _createPot();
        vm.expectRevert(GroupPot.InvalidParams.selector);
        _contribute(id, carol, 0);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        new GroupPot(admin, guardian, address(0));
    }

    function testFuzz_proRataNeverExceedsPool(uint64 a, uint64 b, uint64 c) public {
        a = uint64(bound(a, 1, 1_000e6));
        b = uint64(bound(b, 1, 1_000e6));
        c = uint64(bound(c, 1, 1_000e6));
        address e = makeAddr("e");
        usdg.mint(e, 1_000e6);
        vm.prank(e);
        usdg.approve(address(pot), type(uint256).max);
        uint256 id = _createPot();
        _contribute(id, carol, a);
        _contribute(id, dave, b);
        _contribute(id, e, c);
        vm.prank(alice);
        uint256 giftId = pot.finalize(id);
        vm.warp(block.timestamp + 31 days);
        vault.refund(giftId);
        pot.syncRefund(id);
        vm.prank(carol);
        pot.withdraw(id);
        vm.prank(dave);
        pot.withdraw(id);
        vm.prank(e);
        pot.withdraw(id);
        assertLe(usdg.balanceOf(address(pot)), 3); // only rounding dust remains
    }
}
