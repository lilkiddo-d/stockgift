// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {GiftVault} from "../../src/GiftVault.sol";
import {GiftCardNFT} from "../../src/GiftCardNFT.sol";
import {ScheduledGifts} from "../../src/ScheduledGifts.sol";
import {GroupPot} from "../../src/GroupPot.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {DexAdapter} from "../../src/DexAdapter.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {Timelock} from "../../src/Timelock.sol";
import {IGiftVault} from "../../src/interfaces/IStockgift.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Fork tests against Robinhood Chain mainnet (chain 4663) with the real USDG, stock tokens,
///         Chainlink feeds and Uniswap v3 pools. Runs the production Deploy script.
///         Skipped unless ROBINHOOD_RPC_URL is set:
///           ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
contract ForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    bool internal enabled;
    Deploy.Deployment internal d;
    GiftVault internal vault;
    address internal alice = makeAddr("fork-alice");
    address internal bob = makeAddr("fork-bob");
    uint256 internal linkPk = 0xF0F0F0F0;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        enabled = true;
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        vm.setEnv("WRITE_FRONTEND", "false");
        vm.setEnv("WRITE_DEPLOYMENT", "false");
        d = new Deploy().run();
        vault = GiftVault(d.vault);
        deal(USDG, alice, 10_000e6);
        vm.prank(alice);
        IERC20(USDG).approve(d.vault, type(uint256).max);
    }

    modifier onlyFork() {
        if (!enabled) {
            vm.skip(true);
        }
        _;
    }

    function test_fork_wiringAndHandOff() public onlyFork {
        assertTrue(vault.hasRole(0x00, d.timelock));
        assertEq(Timelock(payable(d.timelock)).getMinDelay(), 48 hours);
        assertTrue(vault.isCurated(TSLA));
        assertTrue(vault.isDepositToken(USDG));
        assertTrue(DexAdapter(d.dex).hasRoute(USDG, TSLA));
        assertTrue(DexAdapter(d.dex).hasRoute(NVDA, USDG));
        uint256 p = OracleAdapter(d.oracle).getPrice(TSLA);
        console2.log("TSLA/USD (1e18):", p);
        assertGt(p, 1e18);
        assertApproxEqRel(OracleAdapter(d.oracle).getPrice(USDG), 1e18, 0.03e18);
        assertEq(address(vault.cardNFT()), d.cardNFT);
        assertEq(ProjectTokenHooks(d.hooks).projectToken(), address(0));
    }

    function test_fork_linkGift_claimConvertsViaUniswap() public onlyFork {
        IGiftVault.CreateParams memory p;
        p.token = USDG;
        p.amount = 100e6;
        p.claimKey = vm.addr(linkPk);
        p.expiry = uint64(block.timestamp + 30 days);
        p.targetToken = TSLA;
        p.maxSlippageBps = 300;
        p.message = "fork gift";
        vm.prank(alice);
        uint256 id = vault.createGift(p);

        IGiftVault.ClaimParams memory c;
        c.recipient = bob;
        c.tokenOut = TSLA;
        c.deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPk, vault.hashClaim(id, c));
        uint256 quote = OracleAdapter(d.oracle).quote(USDG, TSLA, vault.getGift(id).amount);
        uint256 out = vault.claim(id, c, abi.encodePacked(r, s, v));
        console2.log("oracle quote TSLA:", quote);
        console2.log("received TSLA:", out);
        assertEq(IERC20(TSLA).balanceOf(bob), out);
        assertGe(out, (quote * 9700) / 10_000);
        assertEq(IERC20(USDG).balanceOf(d.vault), 0);
    }

    function test_fork_recipientPicksStock_andCashFallback() public onlyFork {
        IGiftVault.CreateParams memory p;
        p.token = USDG;
        p.amount = 50e6;
        p.claimKey = vm.addr(linkPk);
        p.expiry = uint64(block.timestamp + 30 days);
        p.recipientChooses = true;
        p.maxSlippageBps = 300;
        vm.startPrank(alice);
        uint256 id1 = vault.createGift(p);
        uint256 id2 = vault.createGift(p);
        vm.stopPrank();

        IGiftVault.ClaimParams memory c;
        c.recipient = bob;
        c.tokenOut = NVDA;
        c.deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPk, vault.hashClaim(id1, c));
        assertGt(vault.claim(id1, c, abi.encodePacked(r, s, v)), 0);

        c.tokenOut = USDG;
        (v, r, s) = vm.sign(linkPk, vault.hashClaim(id2, c));
        vault.claim(id2, c, abi.encodePacked(r, s, v));
        assertEq(IERC20(USDG).balanceOf(bob), vault.getGift(id2).amount);
    }

    function test_fork_cardGift_redeem() public onlyFork {
        IGiftVault.CreateParams memory p;
        p.token = USDG;
        p.amount = 25e6;
        p.expiry = uint64(block.timestamp + 30 days);
        p.targetToken = AAPL;
        p.maxSlippageBps = 300;
        p.card = true;
        p.cardRecipient = bob;
        p.design = 1;
        p.message = "Happy birthday";
        vm.prank(alice);
        uint256 id = vault.createGift(p);
        assertGt(bytes(GiftCardNFT(d.cardNFT).tokenURI(id)).length, 500);

        IGiftVault.ClaimParams memory c;
        c.recipient = bob;
        c.tokenOut = AAPL;
        c.deadline = block.timestamp + 1 hours;
        vm.prank(bob);
        assertGt(GiftCardNFT(d.cardNFT).redeem(id, c), 0);
    }

    function test_fork_scheduledAllowance() public onlyFork {
        ScheduledGifts sched = ScheduledGifts(d.scheduled);
        vm.prank(alice);
        IERC20(USDG).approve(d.scheduled, type(uint256).max);
        ScheduledGifts.CreateScheduleParams memory p;
        p.recipient = bob;
        p.token = USDG;
        p.targetToken = TSLA;
        p.amountPerRelease = 20e6;
        p.releases = 12;
        p.interval = 30 days;
        p.firstReleaseAt = uint64(block.timestamp);
        p.maxSlippageBps = 300;
        vm.prank(alice);
        uint256 id = sched.createSchedule(p);
        sched.release(id, 0, block.timestamp + 10 minutes);
        assertGt(IERC20(TSLA).balanceOf(bob), 0);
        assertEq(IERC20(USDG).balanceOf(d.scheduled), 220e6);
    }

    function test_fork_groupPot() public onlyFork {
        GroupPot pot = GroupPot(d.groupPot);
        vm.startPrank(alice);
        IERC20(USDG).approve(d.groupPot, type(uint256).max);
        uint256 potId = pot.createPot(
            USDG, vm.addr(linkPk), TSLA, false, 300, uint64(block.timestamp + 1 days), 30 days, "Wedding"
        );
        pot.contribute(potId, 40e6, "congrats");
        uint256 giftId = pot.finalize(potId);
        vm.stopPrank();
        assertEq(vault.getGift(giftId).sender, d.groupPot);
    }

    function test_fork_setProjectTokenThroughTimelock() public onlyFork {
        MockERC20 gift = new MockERC20("Gift", "GIFT", 18); // test-only stand-in for the launchpad token
        Timelock tl = Timelock(payable(d.timelock));
        address proposer = vm.envOr("TIMELOCK_PROPOSER", tx.origin);
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(gift)));
        // the deploy script's broadcaster is the proposer when TIMELOCK_PROPOSER is unset
        vm.startPrank(_proposer(tl, proposer));
        tl.schedule(d.hooks, 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        tl.execute(d.hooks, 0, data, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(ProjectTokenHooks(d.hooks).projectToken(), address(gift));

        // staking now live
        gift.mint(alice, 200_000e18);
        vm.startPrank(alice);
        gift.approve(d.feeCollector, type(uint256).max);
        FeeCollector(d.feeCollector).stake(150_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertTrue(ProjectTokenHooks(d.hooks).isFeeExempt(alice));
    }

    function _proposer(Timelock tl, address hint) internal view returns (address) {
        if (tl.hasRole(tl.PROPOSER_ROLE(), hint)) return hint;
        // Deploy defaults the proposer to the broadcasting sender
        address def = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
        require(tl.hasRole(tl.PROPOSER_ROLE(), def), "proposer unknown");
        return def;
    }
}
