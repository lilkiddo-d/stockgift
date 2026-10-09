// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Timelock} from "../src/Timelock.sol";
import {TrustedForwarder} from "../src/TrustedForwarder.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {GiftVault} from "../src/GiftVault.sol";
import {GiftCardNFT} from "../src/GiftCardNFT.sol";
import {ScheduledGifts} from "../src/ScheduledGifts.sol";
import {GroupPot} from "../src/GroupPot.sol";
import {ConversionBase} from "../src/base/ConversionBase.sol";

/// @title Deploy
/// @notice Deploys and wires the whole Stockgift protocol, hands every admin role to the 48h
///         Timelock, renounces the deployer's roles, and writes deployments/<chainId>.json plus the
///         frontend config. Signs only through the Foundry keystore account passed on the CLI
///         (`--account stockgift-deployer`); it never reads a private key.
///
///         Optional env vars (all default to the deployer address / sane values):
///           GUARDIAN            pause/unpause + compliance operator (use a monitoring multisig)
///           TIMELOCK_PROPOSER   proposer + executor of the Timelock (use a multisig)
///           TIMELOCK_DELAY      seconds, >= 172800 (48h)
///           FEE_BPS             protocol fee in bps (default 50 = 0.5%, max 200)
///           PREMIUM_THRESHOLD   $GIFT (wei) staked for premium cards  (default 10_000e18)
///           FEE_FREE_THRESHOLD  $GIFT (wei) staked for zero fees       (default 100_000e18)
///           WRITE_FRONTEND      "false" to skip writing app config (default true)
///           WRITE_DEPLOYMENT    "false" to skip writing deployments/<name>.json (fork tests)
///           DEPLOYMENT_NAME     file name under deployments/ (default <chainId>, e.g. "4663-fork")
contract Deploy is Script {
    using stdJson for string;

    struct StockConfig {
        // alphabetical order: required by vm.parseJson struct decoding
        uint256 fee;
        address feed;
        uint256 maxStaleness;
        string symbol;
        address token;
    }

    struct Deployment {
        address timelock;
        address forwarder;
        address compliance;
        address oracle;
        address dex;
        address hooks;
        address feeCollector;
        address vault;
        address cardNFT;
        address scheduled;
        address groupPot;
    }

    address internal deployer;
    address internal guardian;
    address internal proposer;

    function run() external returns (Deployment memory d) {
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/config/", vm.toString(block.chainid), ".json"));
        address usdg = cfg.readAddress(".usdg");
        StockConfig[] memory stocks = abi.decode(vm.parseJson(cfg, ".stocks"), (StockConfig[]));

        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        guardian = vm.envOr("GUARDIAN", deployer);
        proposer = vm.envOr("TIMELOCK_PROPOSER", deployer);

        d = _deployCore(cfg);
        _configureMarkets(d, cfg, usdg, stocks);
        _handOff(d);
        vm.stopBroadcast();

        _verifyHandOff(d);
        _write(d, cfg, usdg, stocks);
    }

    function _deployCore(string memory cfg) internal returns (Deployment memory d) {
        address[] memory ops = new address[](1);
        ops[0] = proposer;
        d.timelock = address(new Timelock(vm.envOr("TIMELOCK_DELAY", uint256(48 hours)), ops, ops));
        d.forwarder = address(new TrustedForwarder());
        d.compliance = address(new ComplianceRegistry(deployer, guardian));
        d.oracle = address(new OracleAdapter(deployer));
        d.dex = address(new DexAdapter(deployer, cfg.readAddress(".swapRouter02")));
        d.hooks = address(
            new ProjectTokenHooks(
                deployer,
                vm.envOr("PREMIUM_THRESHOLD", uint256(10_000e18)),
                vm.envOr("FEE_FREE_THRESHOLD", uint256(100_000e18))
            )
        );
        d.feeCollector = address(new FeeCollector(deployer, guardian, d.hooks));
        d.vault = address(new GiftVault(deployer, guardian, d.forwarder));
        d.cardNFT = address(new GiftCardNFT(d.vault, d.forwarder));
        d.scheduled = address(new ScheduledGifts(deployer, guardian));
        d.groupPot = address(new GroupPot(deployer, guardian, d.vault));
    }

    function _configureMarkets(Deployment memory d, string memory cfg, address usdg, StockConfig[] memory stocks)
        internal
    {
        OracleAdapter oracle = OracleAdapter(d.oracle);
        DexAdapter dex = DexAdapter(d.dex);
        FeeCollector fc = FeeCollector(d.feeCollector);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(50)));

        // USDG with a depeg guard: conversions halt outside [0.97, 1.03]
        oracle.setFeed(usdg, cfg.readAddress(".usdgFeed"), uint32(cfg.readUint(".usdgMaxStaleness")), 0.97e18, 1.03e18);
        address seqFeed = cfg.readAddress(".sequencerUptimeFeed");
        if (seqFeed != address(0)) oracle.setSequencerUptimeFeed(seqFeed, 1 hours);

        ProjectTokenHooks(d.hooks).setFeeCollector(d.feeCollector);
        fc.addRewardToken(usdg);
        fc.grantRole(fc.NOTIFIER_ROLE(), d.vault);
        fc.grantRole(fc.NOTIFIER_ROLE(), d.scheduled);

        address[2] memory conv = [d.vault, d.scheduled];
        for (uint256 c; c < 2; ++c) {
            ConversionBase cb = ConversionBase(conv[c]);
            cb.setOracle(d.oracle);
            cb.setDex(d.dex);
            cb.setFeeConfig(d.feeCollector, d.hooks, feeBps);
            cb.setDepositToken(usdg, true);
            cb.setCompliance(d.compliance);
        }
        GiftVault(d.vault).setCardNFT(d.cardNFT);
        GroupPot(d.groupPot).setCompliance(d.compliance);

        dex.setHub(usdg); // stock -> stock conversions route through USDG
        for (uint256 i; i < stocks.length; ++i) {
            StockConfig memory s = stocks[i];
            oracle.setFeed(s.token, s.feed, uint32(s.maxStaleness), 0, 0);
            dex.setRoute(usdg, s.token, abi.encodePacked(usdg, uint24(s.fee), s.token));
            dex.setRoute(s.token, usdg, abi.encodePacked(s.token, uint24(s.fee), usdg));
            for (uint256 c; c < 2; ++c) {
                ConversionBase(conv[c]).setCurated(s.token, true);
                ConversionBase(conv[c]).setDepositToken(s.token, true);
            }
        }
    }

    /// @dev Grant DEFAULT_ADMIN_ROLE to the Timelock and renounce every deployer role.
    function _handOff(Deployment memory d) internal {
        address[8] memory acl =
            [d.compliance, d.oracle, d.dex, d.hooks, d.feeCollector, d.vault, d.scheduled, d.groupPot];
        for (uint256 i; i < 8; ++i) {
            AccessControl a = AccessControl(acl[i]);
            a.grantRole(0x00, d.timelock);
            if (deployer != d.timelock) a.renounceRole(0x00, deployer);
        }
    }

    function _verifyHandOff(Deployment memory d) internal view {
        address[8] memory acl =
            [d.compliance, d.oracle, d.dex, d.hooks, d.feeCollector, d.vault, d.scheduled, d.groupPot];
        for (uint256 i; i < 8; ++i) {
            require(AccessControl(acl[i]).hasRole(0x00, d.timelock), "timelock not admin");
            require(!AccessControl(acl[i]).hasRole(0x00, deployer), "deployer still admin");
        }
        require(Timelock(payable(d.timelock)).getMinDelay() >= 48 hours, "delay");
    }

    function _l2BlockNumber() internal returns (uint256 n) {
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory r) {
            for (uint256 i; i < r.length; ++i) {
                n = (n << 8) | uint8(r[i]);
            }
        } catch {
            n = block.number;
        }
    }

    function _write(Deployment memory d, string memory cfg, address usdg, StockConfig[] memory stocks) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        // Robinhood Chain is an Arbitrum Orbit chain: block.number is the L1 estimate, so record the
        // L2 height from the RPC (what eth_getLogs ranges use).
        vm.serializeUint(k, "deployedAtBlock", _l2BlockNumber());
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "guardian", guardian);
        vm.serializeAddress(k, "timelockProposer", proposer);
        vm.serializeAddress(k, "Timelock", d.timelock);
        vm.serializeAddress(k, "TrustedForwarder", d.forwarder);
        vm.serializeAddress(k, "ComplianceRegistry", d.compliance);
        vm.serializeAddress(k, "OracleAdapter", d.oracle);
        vm.serializeAddress(k, "DexAdapter", d.dex);
        vm.serializeAddress(k, "ProjectTokenHooks", d.hooks);
        vm.serializeAddress(k, "FeeCollector", d.feeCollector);
        vm.serializeAddress(k, "GiftVault", d.vault);
        vm.serializeAddress(k, "GiftCardNFT", d.cardNFT);
        vm.serializeAddress(k, "ScheduledGifts", d.scheduled);
        vm.serializeAddress(k, "GroupPot", d.groupPot);
        vm.serializeAddress(k, "usdg", usdg);
        vm.serializeAddress(k, "quoterV2", cfg.readAddress(".quoterV2"));

        string[] memory symbols = new string[](stocks.length);
        address[] memory tokens = new address[](stocks.length);
        uint256[] memory fees = new uint256[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            symbols[i] = stocks[i].symbol;
            tokens[i] = stocks[i].token;
            fees[i] = stocks[i].fee;
        }
        vm.serializeString(k, "stockSymbols", symbols);
        vm.serializeUint(k, "stockPoolFees", fees);
        string memory out = vm.serializeAddress(k, "stockTokens", tokens);

        string memory name = vm.envOr("DEPLOYMENT_NAME", vm.toString(block.chainid));
        if (vm.envOr("WRITE_DEPLOYMENT", true)) {
            vm.writeJson(out, string.concat(vm.projectRoot(), "/deployments/", name, ".json"));
        }
        if (vm.envOr("WRITE_FRONTEND", true)) {
            vm.writeJson(out, string.concat(vm.projectRoot(), "/../app/src/config/generated/deployment.json"));
        }
        console2.log("GiftVault:", d.vault);
        console2.log("Timelock:", d.timelock);
        console2.log("ProjectTokenHooks (setProjectToken target):", d.hooks);
    }
}
