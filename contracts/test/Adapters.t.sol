// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Timelock} from "../src/Timelock.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";
import {MockAggregator} from "./mocks/Mocks.sol";

contract OracleAdapterTest is BaseTest {
    function test_getPrice_scalesTo1e18() public view {
        assertEq(oracle.getPrice(address(tsla)), 250e18);
        assertEq(oracle.getPrice(address(usdg)), 1e18);
        assertTrue(oracle.hasFeed(address(tsla)));
        assertFalse(oracle.hasFeed(address(0xBEEF)));
    }

    function test_quote_handlesDecimals() public view {
        assertEq(oracle.quote(address(usdg), address(tsla), 500e6), 2e18);
        assertEq(oracle.quote(address(tsla), address(usdg), 2e18), 500e6);
        assertEq(oracle.quote(address(tsla), address(aapl), 4e18), 5e18);
    }

    function test_revert_noFeed() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(0xBEEF)));
        oracle.getPrice(address(0xBEEF));
    }

    function test_revert_nonPositive() public {
        tslaFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tsla)));
        oracle.getPrice(address(tsla));
        tslaFeed.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tsla)));
        oracle.getPrice(address(tsla));
    }

    function test_revert_stale_future_zero() public {
        uint256 t = block.timestamp;
        vm.warp(t + 3 days + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(tsla), t));
        oracle.getPrice(address(tsla));
        tslaFeed.set(250e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(tsla), block.timestamp + 1));
        oracle.getPrice(address(tsla));
        tslaFeed.set(250e8, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(tsla), 0));
        oracle.getPrice(address(tsla));
    }

    function test_bounds() public {
        vm.startPrank(admin);
        oracle.setFeed(address(usdg), address(usdgFeed), 1 days, 0.98e18, 1.02e18);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(usdg), address(usdgFeed), 1 days, 2e18, 1e18);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(usdg), address(usdgFeed), 0, 0, 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(0), address(usdgFeed), 1, 0, 0);
        vm.stopPrank();
        assertEq(oracle.getPrice(address(usdg)), 1e18);
        usdgFeed.set(0.95e8, block.timestamp); // depeg
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceOutOfBounds.selector, address(usdg), 0.95e18));
        oracle.getPrice(address(usdg));
        usdgFeed.set(1.05e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceOutOfBounds.selector, address(usdg), 1.05e18));
        oracle.getPrice(address(usdg));
    }

    function test_badDecimals() public {
        MockAggregator weird = new MockAggregator(19, 1);
        vm.prank(admin);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(usdg), address(weird), 1 days, 0, 0);
    }

    function test_sequencerUptime() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.prank(admin);
        oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector); // within grace period
        oracle.getPrice(address(tsla));
        vm.warp(block.timestamp + 2 hours);
        tslaFeed.set(250e8, block.timestamp);
        assertEq(oracle.getPrice(address(tsla)), 250e18);
        seq.set(1, block.timestamp); // down
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(tsla));
        seq.set(0, block.timestamp);
        seq.setStartedAt(0);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(tsla));
    }

    function test_removeFeed_andAdmin() public {
        vm.prank(admin);
        oracle.removeFeed(address(tsla));
        assertFalse(oracle.hasFeed(address(tsla)));
        vm.expectRevert();
        oracle.removeFeed(address(usdg));
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        new OracleAdapter(address(0));
    }
}

contract DexAdapterTest is BaseTest {
    function test_setRoute_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(address(usdg), address(tsla), hex"00");
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(address(usdg), address(tsla), abi.encodePacked(address(tsla), uint24(3000), address(usdg)));
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(
            address(usdg), address(tsla), abi.encodePacked(address(usdg), uint24(3000), address(tsla), uint8(1))
        );
        dex.setRoute(address(usdg), address(tsla), "");
        vm.stopPrank();
        assertFalse(dex.hasRoute(address(usdg), address(tsla)));
        assertEq(dex.getRoute(address(usdg), address(tsla)).length, 0);
        assertTrue(dex.hasRoute(address(usdg), address(aapl)));
    }

    function test_swap_directAndErrors() public {
        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(dex), type(uint256).max);
        uint256 out = dex.swapExactIn(address(usdg), address(aapl), 200e6, 1e18, block.timestamp, bob);
        assertEq(out, 1e18);
        assertEq(aapl.balanceOf(bob), 1e18);
        assertEq(usdg.balanceOf(address(dex)), 0);

        vm.expectRevert(DexAdapter.DeadlinePassed.selector);
        dex.swapExactIn(address(usdg), address(aapl), 1e6, 0, block.timestamp - 1, bob);
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.NoRoute.selector, address(aapl), address(usdg)));
        dex.swapExactIn(address(aapl), address(usdg), 1e6, 0, block.timestamp, bob);
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        dex.swapExactIn(address(usdg), address(aapl), 1e6, 0, block.timestamp, address(0));
        vm.expectRevert("Too little received");
        dex.swapExactIn(address(usdg), address(aapl), 200e6, 2e18, block.timestamp, bob);
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        new DexAdapter(address(0), address(router));
    }

    function test_hubRouting() public {
        // no direct AAPL->TSLA route; compose through USDG once the hub is set
        vm.startPrank(admin);
        dex.setRoute(address(aapl), address(usdg), abi.encodePacked(address(aapl), uint24(500), address(usdg)));
        assertFalse(dex.hasRoute(address(aapl), address(tsla)));
        dex.setHub(address(usdg));
        vm.stopPrank();
        assertTrue(dex.hasRoute(address(aapl), address(tsla)));
        assertEq(
            dex.getRoute(address(aapl), address(tsla)),
            abi.encodePacked(address(aapl), uint24(500), address(usdg), uint24(3000), address(tsla))
        );
        assertFalse(dex.hasRoute(address(usdg), address(0xBEEF)));
        assertFalse(dex.hasRoute(address(tsla), address(0xBEEF)));
        aapl.mint(address(this), 5e18);
        aapl.approve(address(dex), type(uint256).max);
        assertEq(dex.swapExactIn(address(aapl), address(tsla), 5e18, 0, block.timestamp, bob), 4e18);
    }

    function test_swap_multihopPath() public {
        tsla.mint(address(this), 4e18);
        tsla.approve(address(dex), type(uint256).max);
        uint256 out = dex.swapExactIn(address(tsla), address(aapl), 4e18, 0, block.timestamp, bob);
        assertEq(out, 5e18);
    }
}

/// @dev Router that takes nothing, delivers nothing and returns 0.
contract LyingRouter {
    fallback() external payable {
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}

contract DexAdapterLyingRouterTest is BaseTest {
    function test_revertsWhenRouterUnderdelivers() public {
        LyingRouter lr = new LyingRouter();
        DexAdapter d = new DexAdapter(admin, address(lr));
        vm.prank(admin);
        d.setRoute(address(usdg), address(tsla), abi.encodePacked(address(usdg), uint24(3000), address(tsla)));
        usdg.mint(address(this), 1e6);
        usdg.approve(address(d), 1e6);
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.InsufficientOutput.selector, 0, 1));
        d.swapExactIn(address(usdg), address(tsla), 1e6, 1, block.timestamp, bob);
    }

    /// @dev A malicious/buggy adapter that reports success without paying is caught by the vault's
    ///      recipient balance-delta check.
    function test_vaultCatchesUnderdeliveringAdapter() public {
        FakeAdapter fake = new FakeAdapter();
        vm.prank(admin);
        vault.setDex(address(fake));
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert();
        vault.claim(id, c, sig);
    }
}

contract FakeAdapter {
    function swapExactIn(address, address, uint256, uint256 minOut, uint256, address) external pure returns (uint256) {
        return minOut;
    }
}

contract ComplianceAndTimelockTest is BaseTest {
    function test_registry() public {
        assertTrue(registry.isAllowed(bob));
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        vm.startPrank(admin);
        registry.setEnabled(true);
        assertFalse(registry.isAllowed(bob));
        registry.setAllowed(list, true);
        assertTrue(registry.isAllowed(bob));
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        registry.setAllowed(new address[](201), true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        registry.setEnabled(false);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0), admin);
    }

    function test_timelock_48h_and_setProjectToken() public {
        address[] memory ops = new address[](1);
        ops[0] = admin;
        vm.expectRevert(Timelock.DelayTooShort.selector);
        new Timelock(47 hours, ops, ops);

        Timelock tl = new Timelock(48 hours, ops, ops);
        vm.startPrank(admin);
        hooks.grantRole(0x00, address(tl));
        hooks.renounceRole(0x00, admin);
        vm.stopPrank();

        bytes memory data = abi.encodeCall(hooks.setProjectToken, (address(giftToken)));
        vm.prank(admin);
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.prank(admin);
        vm.expectRevert();
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        assertEq(hooks.projectToken(), address(giftToken));

        // admin no longer has direct access
        vm.prank(admin);
        vm.expectRevert();
        hooks.setTiers(0, 0, 0, false);
        vm.prank(alice);
        vm.expectRevert();
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32(uint256(1)), 48 hours);
    }
}
