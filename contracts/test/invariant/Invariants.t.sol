// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {GiftVault} from "../../src/GiftVault.sol";
import {GiftCardNFT} from "../../src/GiftCardNFT.sol";
import {ScheduledGifts} from "../../src/ScheduledGifts.sol";
import {IGiftVault} from "../../src/interfaces/IStockgift.sol";
import {MockERC20, MockAggregator, MockSwapRouter} from "../mocks/Mocks.sol";

contract VaultHandler is Test {
    GiftVault internal vault;
    GiftCardNFT internal nft;
    ScheduledGifts internal sched;
    MockERC20 internal usdg;
    MockERC20 internal tsla;
    MockAggregator[] internal feeds;
    MockSwapRouter internal router;

    address[3] internal senders;
    address[3] internal recipients;
    uint256[3] internal keyPks = [uint256(0x1111), 0x2222, 0x3333];

    uint256[] public giftIds;
    mapping(uint256 => uint256) public keyIndexOf;
    mapping(uint256 => uint256) public claimCount;
    mapping(uint256 => uint256) public refundCount;
    uint256[] public scheduleIds;
    uint256 public totalClaims;
    uint256 public totalRefunds;

    constructor(
        GiftVault v,
        GiftCardNFT n,
        ScheduledGifts s,
        MockERC20 u,
        MockERC20 t,
        MockAggregator[] memory f,
        MockSwapRouter r
    ) {
        vault = v;
        nft = n;
        sched = s;
        usdg = u;
        tsla = t;
        feeds = f;
        router = r;
        for (uint256 i; i < 3; ++i) {
            senders[i] = makeAddr(string.concat("sender", vm.toString(i)));
            recipients[i] = makeAddr(string.concat("recipient", vm.toString(i)));
            usdg.mint(senders[i], 1e15);
            tsla.mint(senders[i], 1e24);
            vm.startPrank(senders[i]);
            usdg.approve(address(vault), type(uint256).max);
            tsla.approve(address(vault), type(uint256).max);
            usdg.approve(address(sched), type(uint256).max);
            vm.stopPrank();
        }
    }

    function giftCount() external view returns (uint256) {
        return giftIds.length;
    }

    function scheduleCount() external view returns (uint256) {
        return scheduleIds.length;
    }

    function _refreshFeeds() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
    }

    // ------------------------------------------------------------- actions

    function create(uint256 seed, uint96 amount, bool stock, bool card) external {
        address sender = senders[seed % 3];
        uint256 k = (seed / 3) % 3;
        IGiftVault.CreateParams memory p;
        p.token = stock ? address(tsla) : address(usdg);
        p.amount = stock ? bound(amount, 1e12, 1e21) : bound(amount, 1e3, 1e12);
        p.claimKey = vm.addr(keyPks[k]);
        p.expiry = uint64(block.timestamp + 1 days + (seed % 30 days));
        p.targetToken = stock ? address(0) : address(tsla);
        p.maxSlippageBps = 500;
        p.card = card;
        p.cardRecipient = recipients[seed % 3];
        p.message = "inv";
        vm.prank(sender);
        uint256 id = vault.createGift(p);
        giftIds.push(id);
        keyIndexOf[id] = k;
    }

    function claim(uint256 idSeed, uint256 rSeed, bool convert, uint16 relayerFeeBps) external {
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idSeed % giftIds.length];
        GiftVault.Gift memory g = vault.getGift(id);
        _refreshFeeds();
        IGiftVault.ClaimParams memory c;
        c.recipient = recipients[rSeed % 3];
        c.tokenOut = convert && g.targetToken != address(0) ? g.targetToken : g.token;
        c.deadline = block.timestamp + 1 hours;
        c.relayer = address(0xFEE);
        c.relayerFee = (g.amount * bound(relayerFeeBps, 0, 300)) / 10_000;
        bool ok;
        if (g.isCard) {
            if (g.status != IGiftVault.Status.Open) return;
            address holder = nft.ownerOf(id);
            c.recipient = holder;
            vm.prank(holder);
            try nft.redeem(id, c) {
                ok = true;
            } catch {}
        } else {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyPks[keyIndexOf[id]], vault.hashClaim(id, c));
            try vault.claim(id, c, abi.encodePacked(r, s, v)) {
                ok = true;
            } catch {}
        }
        if (ok) {
            claimCount[id]++;
            totalClaims++;
        }
    }

    function replayClaim(uint256 idSeed) external {
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idSeed % giftIds.length];
        GiftVault.Gift memory g = vault.getGift(id);
        if (g.isCard || g.status == IGiftVault.Status.Open) return;
        IGiftVault.ClaimParams memory c;
        c.recipient = recipients[0];
        c.tokenOut = g.token;
        c.deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyPks[keyIndexOf[id]], vault.hashClaim(id, c));
        try vault.claim(id, c, abi.encodePacked(r, s, v)) {
            claimCount[id]++; // would break the invariant
        } catch {}
    }

    function refund(uint256 idSeed) external {
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idSeed % giftIds.length];
        try vault.refund(id) {
            refundCount[id]++;
            totalRefunds++;
        } catch {}
    }

    function cancel(uint256 idSeed) external {
        if (giftIds.length == 0) return;
        uint256 id = giftIds[idSeed % giftIds.length];
        GiftVault.Gift memory g = vault.getGift(id);
        vm.prank(g.sender);
        try vault.cancel(id) {
            refundCount[id]++;
            totalRefunds++;
        } catch {}
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function createSchedule(uint256 seed, uint64 amount, uint16 releases) external {
        ScheduledGifts.CreateScheduleParams memory p;
        p.recipient = recipients[seed % 3];
        p.token = address(usdg);
        p.targetToken = seed % 2 == 0 ? address(0) : address(tsla);
        p.amountPerRelease = uint128(bound(amount, 1e3, 1e9));
        p.releases = uint16(bound(releases, 1, 24));
        p.interval = 1 days;
        p.firstReleaseAt = uint64(block.timestamp);
        p.maxSlippageBps = 500;
        vm.prank(senders[seed % 3]);
        scheduleIds.push(sched.createSchedule(p));
    }

    function releaseSchedule(uint256 seed) external {
        if (scheduleIds.length == 0) return;
        _refreshFeeds();
        try sched.release(scheduleIds[seed % scheduleIds.length], 0, block.timestamp) {} catch {}
    }

    function cancelSchedule(uint256 seed) external {
        if (scheduleIds.length == 0) return;
        uint256 id = scheduleIds[seed % scheduleIds.length];
        vm.prank(sched.getSchedule(id).sender);
        try sched.cancelSchedule(id) {} catch {}
    }
}

contract InvariantsTest is BaseTest {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockAggregator[] memory f = new MockAggregator[](3);
        f[0] = usdgFeed;
        f[1] = tslaFeed;
        f[2] = aaplFeed;
        handler = new VaultHandler(vault, nft, sched, usdg, tsla, f, router);
        targetContract(address(handler));
    }

    /// @notice Vault balance always equals the sum of open gifts (per token).
    function invariant_vaultBalanceEqualsOpenGifts() public view {
        uint256 openUsdg;
        uint256 openTsla;
        uint256 n = handler.giftCount();
        for (uint256 i; i < n; ++i) {
            GiftVault.Gift memory g = vault.getGift(handler.giftIds(i));
            if (g.status == IGiftVault.Status.Open) {
                if (g.token == address(usdg)) openUsdg += g.amount;
                else openTsla += g.amount;
            }
        }
        assertEq(usdg.balanceOf(address(vault)), openUsdg);
        assertEq(tsla.balanceOf(address(vault)), openTsla);
        assertEq(vault.totalOpen(address(usdg)), openUsdg);
        assertEq(vault.totalOpen(address(tsla)), openTsla);
    }

    /// @notice Each gift is claimed or refunded exactly once (never both, never twice), and the
    ///         recorded status matches what happened.
    function invariant_claimedOrRefundedExactlyOnce() public view {
        uint256 n = handler.giftCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.giftIds(i);
            uint256 cl = handler.claimCount(id);
            uint256 rf = handler.refundCount(id);
            assertLe(cl + rf, 1);
            IGiftVault.Status st = vault.giftStatus(id);
            if (st == IGiftVault.Status.Open) assertEq(cl + rf, 0);
            if (st == IGiftVault.Status.Claimed) assertEq(cl, 1);
            if (st == IGiftVault.Status.Refunded) assertEq(rf, 1);
        }
    }

    /// @notice ScheduledGifts holds exactly the unreleased installments.
    function invariant_scheduledBalanceEqualsCommitted() public view {
        uint256 committed;
        uint256 n = handler.scheduleCount();
        for (uint256 i; i < n; ++i) {
            ScheduledGifts.Schedule memory s = sched.getSchedule(handler.scheduleIds(i));
            committed += uint256(s.amountPerRelease) * s.releasesLeft;
        }
        assertEq(usdg.balanceOf(address(sched)), committed);
        assertEq(sched.totalCommitted(address(usdg)), committed);
    }

    function afterInvariant() external view {
        console2.log("gifts", handler.giftCount(), "claims", handler.totalClaims());
        console2.log("refunds", handler.totalRefunds());
    }

    /// @notice Gift ids are sequential and never reused.
    function invariant_nextIdMonotonic() public view {
        assertEq(vault.nextGiftId(), handler.giftCount() + 1);
    }
}
