// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {ScheduledGifts} from "../src/ScheduledGifts.sol";
import {ConversionBase} from "../src/base/ConversionBase.sol";
import {ProtocolBase} from "../src/base/ProtocolBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract ScheduledGiftsTest is BaseTest {
    function _p() internal view returns (ScheduledGifts.CreateScheduleParams memory p) {
        p.recipient = bob;
        p.token = address(usdg);
        p.targetToken = address(tsla);
        p.amountPerRelease = 20e6;
        p.releases = 12;
        p.interval = 30 days;
        p.firstReleaseAt = uint64(block.timestamp);
        p.maxSlippageBps = 300;
        p.message = "Monthly TSLA allowance";
    }

    function _create(ScheduledGifts.CreateScheduleParams memory p) internal returns (uint256 id) {
        vm.prank(alice);
        id = sched.createSchedule(p);
    }

    function test_create_fundsAllPlusFeeOnTop() public {
        uint256 before = usdg.balanceOf(alice);
        uint256 id = _create(_p());
        assertEq(usdg.balanceOf(address(sched)), 240e6);
        assertEq(sched.totalCommitted(address(usdg)), 240e6);
        assertEq(before - usdg.balanceOf(alice), 240e6 + 1.2e6);
        ScheduledGifts.Schedule memory s = sched.getSchedule(id);
        assertEq(s.releasesLeft, 12);
        assertTrue(s.active);
        assertTrue(sched.isDue(id));
    }

    function test_release_monthlyFor12Months() public {
        uint256 id = _create(_p());
        address keeper = makeAddr("keeper");
        for (uint256 i; i < 12; ++i) {
            tslaFeed.set(250e8, block.timestamp);
            usdgFeed.set(1e8, block.timestamp);
            vm.prank(keeper);
            sched.release(id, 0, block.timestamp + 10 minutes);
            if (i < 11) {
                vm.expectRevert(ScheduledGifts.NotDue.selector);
                sched.release(id, 0, block.timestamp);
                vm.warp(block.timestamp + 30 days);
            }
        }
        assertEq(tsla.balanceOf(bob), 12 * ((20e6 * 1e12) / 250));
        assertEq(usdg.balanceOf(address(sched)), 0);
        assertFalse(sched.getSchedule(id).active);
        vm.expectRevert(ScheduledGifts.NotActive.selector);
        sched.release(id, 0, block.timestamp);
    }

    function test_release_catchUpOnePerCall() public {
        uint256 id = _create(_p());
        vm.warp(block.timestamp + 65 days);
        tslaFeed.set(250e8, block.timestamp);
        usdgFeed.set(1e8, block.timestamp);
        sched.release(id, 0, block.timestamp);
        sched.release(id, 0, block.timestamp);
        sched.release(id, 0, block.timestamp);
        vm.expectRevert(ScheduledGifts.NotDue.selector);
        sched.release(id, 0, block.timestamp);
        assertEq(sched.getSchedule(id).releasesLeft, 9);
    }

    function test_release_noTarget_and_deadline() public {
        ScheduledGifts.CreateScheduleParams memory p = _p();
        p.targetToken = address(0);
        uint256 id = _create(p);
        vm.expectRevert(ConversionBase.Expired.selector);
        sched.release(id, 0, block.timestamp - 1);
        sched.release(id, 0, block.timestamp);
        assertEq(usdg.balanceOf(bob), 20e6);
    }

    function test_releaseAsDeposit_recipientOnly() public {
        uint256 id = _create(_p());
        vm.expectRevert(ScheduledGifts.Unauthorized.selector);
        sched.releaseAsDeposit(id);
        vm.warp(block.timestamp + 4 days); // stock oracle stale: conversion impossible
        vm.expectRevert();
        sched.release(id, 0, block.timestamp);
        vm.prank(bob);
        sched.releaseAsDeposit(id);
        assertEq(usdg.balanceOf(bob), 20e6);
    }

    function test_release_oracleFloor() public {
        uint256 id = _create(_p());
        router.setHaircutBps(500);
        vm.expectRevert("Too little received");
        sched.release(id, 0, block.timestamp);
    }

    function test_cancel_refundsRemaining() public {
        uint256 id = _create(_p());
        sched.release(id, 0, block.timestamp);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(bob);
        vm.expectRevert(ScheduledGifts.Unauthorized.selector);
        sched.cancelSchedule(id);
        vm.prank(alice);
        sched.cancelSchedule(id);
        assertEq(usdg.balanceOf(alice) - before, 220e6);
        assertEq(usdg.balanceOf(address(sched)), 0);
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.NotActive.selector);
        sched.cancelSchedule(id);
    }

    function test_create_validation() public {
        ScheduledGifts.CreateScheduleParams memory p = _p();
        p.recipient = address(0);
        vm.prank(alice);
        vm.expectRevert(ConversionBase.BadRecipient.selector);
        sched.createSchedule(p);

        p = _p();
        p.token = address(aapl);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(aapl)));
        sched.createSchedule(p);

        p = _p();
        p.targetToken = address(usdg);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(usdg)));
        sched.createSchedule(p);

        p = _p();
        p.releases = 0;
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.InvalidParams.selector);
        sched.createSchedule(p);
        p.releases = 521;
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.InvalidParams.selector);
        sched.createSchedule(p);

        p = _p();
        p.interval = 1 hours;
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.InvalidParams.selector);
        sched.createSchedule(p);

        p = _p();
        p.firstReleaseAt = uint64(block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.InvalidParams.selector);
        sched.createSchedule(p);

        p = _p();
        p.maxSlippageBps = 2000;
        vm.prank(alice);
        vm.expectRevert(ConversionBase.SlippageTooHigh.selector);
        sched.createSchedule(p);

        p = _p();
        p.message = string(new bytes(281));
        vm.prank(alice);
        vm.expectRevert(ScheduledGifts.InvalidParams.selector);
        sched.createSchedule(p);
    }

    function test_pause_and_compliance() public {
        uint256 id = _create(_p());
        vm.prank(guardian);
        sched.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sched.release(id, 0, block.timestamp);
        vm.prank(guardian);
        sched.unpause();

        vm.prank(admin);
        registry.setEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(ProtocolBase.NotAllowed.selector, bob));
        sched.release(id, 0, block.timestamp);
    }

    function testFuzz_schedule(uint64 amount, uint16 releases, uint64 interval) public {
        amount = uint64(bound(amount, 1, 10_000e6));
        releases = uint16(bound(releases, 1, 52));
        interval = uint64(bound(interval, 1 days, 366 days));
        ScheduledGifts.CreateScheduleParams memory p = _p();
        p.amountPerRelease = amount;
        p.releases = releases;
        p.interval = interval;
        p.targetToken = address(0);
        uint256 id = _create(p);
        assertEq(usdg.balanceOf(address(sched)), uint256(amount) * releases);
        for (uint256 i; i < releases; ++i) {
            sched.release(id, 0, block.timestamp);
            vm.warp(block.timestamp + interval);
            assertEq(usdg.balanceOf(address(sched)), sched.totalCommitted(address(usdg)));
        }
        assertEq(usdg.balanceOf(bob), uint256(amount) * releases);
    }
}
