// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GiftVault} from "../src/GiftVault.sol";
import {GiftCardNFT} from "../src/GiftCardNFT.sol";
import {ScheduledGifts} from "../src/ScheduledGifts.sol";
import {GroupPot} from "../src/GroupPot.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {TrustedForwarder} from "../src/TrustedForwarder.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";
import {MockERC20, MockAggregator, MockSwapRouter} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice"); // sender
    address internal bob = makeAddr("bob"); // recipient
    address internal relayer = makeAddr("relayer");

    uint256 internal linkPk = 0xA11CE5EC2E7; // ephemeral claim-link key (test value)
    address internal linkKey;

    MockERC20 internal usdg;
    MockERC20 internal tsla;
    MockERC20 internal aapl;
    MockERC20 internal giftToken; // mock $GIFT, tests only
    MockAggregator internal usdgFeed;
    MockAggregator internal tslaFeed;
    MockAggregator internal aaplFeed;
    MockSwapRouter internal router;

    TrustedForwarder internal forwarder;
    OracleAdapter internal oracle;
    DexAdapter internal dex;
    ProjectTokenHooks internal hooks;
    FeeCollector internal feeCollector;
    ComplianceRegistry internal registry;
    GiftVault internal vault;
    GiftCardNFT internal nft;
    ScheduledGifts internal sched;
    GroupPot internal pot;

    uint16 internal constant FEE_BPS = 50;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        linkKey = vm.addr(linkPk);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        tsla = new MockERC20("Tesla", "TSLA", 18);
        aapl = new MockERC20("Apple", "AAPL", 18);
        giftToken = new MockERC20("Gift", "GIFT", 18);
        usdgFeed = new MockAggregator(8, 1e8);
        tslaFeed = new MockAggregator(8, 250e8);
        aaplFeed = new MockAggregator(8, 200e8);

        vm.startPrank(admin);
        forwarder = new TrustedForwarder();
        oracle = new OracleAdapter(admin);
        oracle.setFeed(address(usdg), address(usdgFeed), 1 days, 0, 0);
        oracle.setFeed(address(tsla), address(tslaFeed), 3 days, 0, 0);
        oracle.setFeed(address(aapl), address(aaplFeed), 3 days, 0, 0);
        router = new MockSwapRouter(address(oracle));
        dex = new DexAdapter(admin, address(router));
        dex.setRoute(address(usdg), address(tsla), abi.encodePacked(address(usdg), uint24(3000), address(tsla)));
        dex.setRoute(address(usdg), address(aapl), abi.encodePacked(address(usdg), uint24(500), address(aapl)));
        dex.setRoute(address(tsla), address(aapl), abi.encodePacked(address(tsla), uint24(3000), address(usdg), uint24(500), address(aapl)));

        hooks = new ProjectTokenHooks(admin, 1_000e18, 10_000e18);
        feeCollector = new FeeCollector(admin, guardian, address(hooks));
        hooks.setFeeCollector(address(feeCollector));
        feeCollector.addRewardToken(address(usdg));
        registry = new ComplianceRegistry(admin, admin);

        vault = new GiftVault(admin, guardian, address(forwarder));
        nft = new GiftCardNFT(address(vault), address(forwarder));
        sched = new ScheduledGifts(admin, guardian);
        pot = new GroupPot(admin, guardian, address(vault));

        _wireConversion(address(vault));
        _wireConversion(address(sched));
        vault.setCardNFT(address(nft));
        vault.setCompliance(address(registry));
        sched.setCompliance(address(registry));
        pot.setCompliance(address(registry));
        vm.stopPrank();

        usdg.mint(alice, 1_000_000e6);
        tsla.mint(alice, 1_000e18);
        vm.startPrank(alice);
        usdg.approve(address(vault), type(uint256).max);
        tsla.approve(address(vault), type(uint256).max);
        usdg.approve(address(sched), type(uint256).max);
        usdg.approve(address(pot), type(uint256).max);
        vm.stopPrank();
    }

    function _wireConversion(address c) internal {
        GiftVault v = GiftVault(c); // same admin ABI as ScheduledGifts (ConversionBase)
        v.setOracle(address(oracle));
        v.setDex(address(dex));
        v.setFeeConfig(address(feeCollector), address(hooks), FEE_BPS);
        v.setDepositToken(address(usdg), true);
        v.setDepositToken(address(tsla), true);
        v.setCurated(address(tsla), true);
        v.setCurated(address(aapl), true);
        feeCollector.grantRole(feeCollector.NOTIFIER_ROLE(), c);
    }

    // ---------------------------------------------------------------- helpers

    function _params(uint256 amount) internal view returns (IGiftVault.CreateParams memory p) {
        p.token = address(usdg);
        p.amount = amount;
        p.claimKey = linkKey;
        p.expiry = uint64(block.timestamp + 30 days);
        p.targetToken = address(tsla);
        p.maxSlippageBps = 300;
        p.message = "Happy birthday!";
    }

    function _create(IGiftVault.CreateParams memory p) internal returns (uint256 id) {
        vm.prank(alice);
        id = vault.createGift(p);
    }

    function _claimParams(address recipient, address tokenOut) internal view returns (IGiftVault.ClaimParams memory c) {
        c.recipient = recipient;
        c.tokenOut = tokenOut;
        c.deadline = block.timestamp + 1 hours;
    }

    function _sign(uint256 pk, uint256 giftId, IGiftVault.ClaimParams memory c) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, vault.hashClaim(giftId, c));
        return abi.encodePacked(r, s, v);
    }

    function _net(uint256 gross) internal pure returns (uint256) {
        return gross - (gross * FEE_BPS) / 10_000;
    }
}
