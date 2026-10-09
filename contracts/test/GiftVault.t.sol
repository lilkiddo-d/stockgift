// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {GiftVault} from "../src/GiftVault.sol";
import {ConversionBase} from "../src/base/ConversionBase.sol";
import {ProtocolBase} from "../src/base/ProtocolBase.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";
import {FeeOnTransferERC20} from "./mocks/Mocks.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract GiftVaultTest is BaseTest {
    // ------------------------------------------------------------- creation

    function test_createGift_storesNetAndChargesFee() public {
        uint256 id = _create(_params(100e6));
        GiftVault.Gift memory g = vault.getGift(id);
        assertEq(id, 1);
        assertEq(g.sender, alice);
        assertEq(g.amount, _net(100e6));
        assertEq(uint8(g.status), uint8(IGiftVault.Status.Open));
        assertEq(g.claimKey, linkKey);
        assertEq(usdg.balanceOf(address(vault)), _net(100e6));
        assertEq(vault.totalOpen(address(usdg)), _net(100e6));
        assertEq(usdg.balanceOf(address(feeCollector)), 100e6 - _net(100e6));
        assertEq(feeCollector.treasuryBalance(address(usdg)), 100e6 - _net(100e6));
        assertEq(vault.nextGiftId(), 2);
    }

    function test_create_reverts_validation() public {
        IGiftVault.CreateParams memory p = _params(100e6);

        p.token = address(aapl); // not a deposit token
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(aapl)));
        _create(p);

        p = _params(0);
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(usdg)));
        _create(p);

        p = _params(100e6);
        p.targetToken = address(usdg); // same as deposit
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(usdg)));
        _create(p);

        p = _params(100e6);
        p.targetToken = address(0xBEEF); // not curated
        vm.expectRevert(abi.encodeWithSelector(ConversionBase.TokenNotAllowed.selector, address(0xBEEF)));
        _create(p);

        p = _params(100e6);
        p.maxSlippageBps = 1001;
        vm.expectRevert(ConversionBase.SlippageTooHigh.selector);
        _create(p);

        p = _params(100e6);
        p.expiry = uint64(block.timestamp + 10 minutes);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        _create(p);

        p.expiry = uint64(block.timestamp + 3651 days);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        _create(p);

        p = _params(100e6);
        p.message = string(new bytes(281));
        vm.expectRevert(GiftVault.InvalidParams.selector);
        _create(p);

        p = _params(100e6);
        p.claimKey = address(0);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        _create(p);

        p = _params(1); // fee rounds to 0, net 1 is fine
        _create(p);
    }

    function test_create_rejectsFeeOnTransfer() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        vm.prank(admin);
        vault.setDepositToken(address(fot), true);
        fot.mint(alice, 100e18);
        vm.prank(alice);
        fot.approve(address(vault), type(uint256).max);
        IGiftVault.CreateParams memory p = _params(100e18);
        p.token = address(fot);
        p.targetToken = address(0);
        vm.expectRevert(ConversionBase.FeeOnTransferUnsupported.selector);
        _create(p);
    }

    function test_create_noFeeWhenFeeBpsZero() public {
        vm.prank(admin);
        vault.setFeeConfig(address(0), address(0), 0);
        uint256 id = _create(_params(100e6));
        assertEq(vault.getGift(id).amount, 100e6);
    }

    // ---------------------------------------------------------------- claims

    function test_claim_link_convertsToTarget() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        bytes memory sig = _sign(linkPk, id, c);

        vm.prank(relayer); // anyone can submit
        uint256 out = vault.claim(id, c, sig);

        uint256 expected = (_net(100e6) * 1e12) / 250; // $99.5 / $250 per share
        assertEq(out, expected);
        assertEq(tsla.balanceOf(bob), expected);
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(vault.totalOpen(address(usdg)), 0);
        assertEq(uint8(vault.giftStatus(id)), uint8(IGiftVault.Status.Claimed));
    }

    function test_claim_cashFallback_andStockGift() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        vault.claim(id, c, _sign(linkPk, id, c));
        assertEq(usdg.balanceOf(bob), _net(100e6));

        // stock-denominated gift, no conversion
        IGiftVault.CreateParams memory p = _params(2e18);
        p.token = address(tsla);
        p.targetToken = address(0);
        id = _create(p);
        c = _claimParams(bob, address(tsla));
        vault.claim(id, c, _sign(linkPk, id, c));
        assertEq(tsla.balanceOf(bob), _net(2e18));
    }

    function test_claim_recipientChooses() public {
        IGiftVault.CreateParams memory p = _params(100e6);
        p.targetToken = address(0);
        p.recipientChooses = true;
        uint256 id = _create(p);

        IGiftVault.ClaimParams memory c = _claimParams(bob, address(0xBEEF));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.TokenOutNotAllowed.selector);
        vault.claim(id, c, sig);

        c = _claimParams(bob, address(aapl));
        vault.claim(id, c, _sign(linkPk, id, c));
        assertEq(aapl.balanceOf(bob), (_net(100e6) * 1e12) / 200);
    }

    function test_claim_fixedTarget_rejectsOtherCurated() public {
        uint256 id = _create(_params(100e6)); // target TSLA, recipientChooses false
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(aapl));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.TokenOutNotAllowed.selector);
        vault.claim(id, c, sig);
    }

    function test_claim_oracleFloorBlocksBadExecution() public {
        uint256 id = _create(_params(100e6)); // 3% max slippage
        router.setHaircutBps(400); // pool 4% worse than oracle
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert("Too little received");
        vault.claim(id, c, sig);

        router.setHaircutBps(200); // within tolerance
        uint256 out = vault.claim(id, c, sig);
        assertEq(out, ((_net(100e6) * 1e12) / 250) * 9800 / 10_000);
    }

    function test_claim_recipientMinOutRespected() public {
        uint256 id = _create(_params(100e6));
        router.setHaircutBps(100);
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        c.minAmountOut = (_net(100e6) * 1e12) / 250; // demands oracle price exactly
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert("Too little received");
        vault.claim(id, c, sig);
    }

    function test_claim_staleOracleBlocksConversionButCashWorks() public {
        uint256 id = _create(_params(100e6));
        vm.warp(block.timestamp + 4 days); // tsla feed max staleness is 3 days
        usdgFeed.set(1e8, block.timestamp);
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert();
        vault.claim(id, c, sig);

        c = _claimParams(bob, address(usdg));
        vault.claim(id, c, _sign(linkPk, id, c));
        assertEq(usdg.balanceOf(bob), _net(100e6));
    }

    // ------------------------------------------------- front-running / replay

    function test_frontrun_cannotRedirect() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);

        address mallory = makeAddr("mallory");
        IGiftVault.ClaimParams memory evil = _copy(c);
        evil.recipient = mallory;
        vm.prank(mallory);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, evil, sig);

        // mallory may only "front-run" by executing the honest claim, which still pays bob
        vm.prank(mallory);
        vault.claim(id, c, sig);
        assertEq(usdg.balanceOf(bob), _net(100e6));
        assertEq(usdg.balanceOf(mallory), 0);
    }

    function test_frontrun_cannotChangeAnySignedField() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        c.relayer = relayer;
        c.relayerFee = 1e6;
        bytes memory sig = _sign(linkPk, id, c);

        IGiftVault.ClaimParams memory m = _copy(c);
        m.relayer = address(0xBAD);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, m, sig);
        m = _copy(c);
        m.relayerFee = 2e6;
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, m, sig);
        m = _copy(c);
        m.tokenOut = address(tsla);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, m, sig);
        m = _copy(c);
        m.minAmountOut = 0 + 1;
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, m, sig);
        m = _copy(c);
        m.deadline = c.deadline + 1;
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, m, sig);
    }

    function test_replay_sameGift() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        vault.claim(id, c, sig);
        vm.expectRevert(GiftVault.NotOpen.selector);
        vault.claim(id, c, sig);
    }

    function test_replay_otherGiftSameKey() public {
        uint256 id1 = _create(_params(100e6));
        uint256 id2 = _create(_params(100e6)); // careless reuse of the same link key
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id1, c);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id2, c, sig);
    }

    function test_replay_otherVaultDomain() public {
        vm.prank(admin);
        GiftVault other = new GiftVault(admin, guardian, address(forwarder));
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes32 otherDigest = other.hashClaim(id, c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPk, otherDigest);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, c, abi.encodePacked(r, s, v));
        assertTrue(other.domainSeparator() != vault.domainSeparator());
    }

    function test_claim_wrongKey() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(0xBADBAD, id, c);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, c, sig);
    }

    function test_claim_malformedSignature() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, c, hex"1234");
    }

    function test_claim_nonexistentGift() public {
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, 99, c);
        vm.expectRevert(GiftVault.InvalidSignature.selector); // claimKey == 0
        vault.claim(99, c, sig);
    }

    function test_claim_expiryAndDeadline() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        c.deadline = block.timestamp + 60 days;
        bytes memory sig = _sign(linkPk, id, c);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(ConversionBase.Expired.selector);
        vault.claim(id, c, sig);

        uint256 id2 = _create(_params(100e6));
        c = _claimParams(bob, address(usdg));
        sig = _sign(linkPk, id2, c);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(ConversionBase.Expired.selector);
        vault.claim(id2, c, sig);
    }

    function test_claim_badRecipient() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(address(vault), address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(ConversionBase.BadRecipient.selector);
        vault.claim(id, c, sig);
    }

    // --------------------------------------------------------------- relayer

    function test_relayerFee_paidFromGift() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        c.relayer = relayer;
        c.relayerFee = 0.5e6;
        vm.prank(relayer);
        vault.claim(id, c, _sign(linkPk, id, c));
        assertEq(usdg.balanceOf(relayer), 0.5e6);
        assertEq(usdg.balanceOf(bob), _net(100e6) - 0.5e6);
    }

    function test_relayerFee_capped() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        c.relayer = relayer;
        c.relayerFee = (_net(100e6) * 300) / 10_000 + 1;
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.RelayerFeeTooHigh.selector);
        vault.claim(id, c, sig);

        c.relayer = address(0);
        c.relayerFee = 1;
        sig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        vault.claim(id, c, sig);
    }

    function test_setMaxRelayerFee() public {
        vm.prank(admin);
        vault.setMaxRelayerFeeBps(1000);
        assertEq(vault.maxRelayerFeeBps(), 1000);
        vm.prank(admin);
        vm.expectRevert(GiftVault.RelayerFeeTooHigh.selector);
        vault.setMaxRelayerFeeBps(1001);
    }

    // ----------------------------------------------------- wallet / forwarder

    function test_claimDirect_walletGift() public {
        IGiftVault.CreateParams memory p = _params(100e6);
        p.claimKey = bob;
        uint256 id = _create(p);
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));

        vm.prank(alice);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.claimDirect(id, c);

        vm.prank(bob);
        vault.claimDirect(id, c);
        assertEq(usdg.balanceOf(bob), _net(100e6));
    }

    function test_claimDirect_viaTrustedForwarder_gasless() public {
        uint256 bobPk = 0xB0B;
        address bobW = vm.addr(bobPk);
        IGiftVault.CreateParams memory p = _params(100e6);
        p.claimKey = bobW;
        uint256 id = _create(p);

        IGiftVault.ClaimParams memory c = _claimParams(bobW, address(tsla));
        c.relayer = relayer;
        c.relayerFee = 0.2e6;
        bytes memory data = abi.encodeCall(GiftVault.claimDirect, (id, c));

        ERC2771Forwarder.ForwardRequestData memory req = ERC2771Forwarder.ForwardRequestData({
            from: bobW,
            to: address(vault),
            value: 0,
            gas: 500_000,
            deadline: uint48(block.timestamp + 1 hours),
            data: data,
            signature: ""
        });
        req.signature = _signForward(bobPk, req);

        assertTrue(forwarder.verify(req));
        vm.prank(relayer);
        forwarder.execute(req);
        assertEq(usdg.balanceOf(relayer), 0.2e6);
        assertGt(tsla.balanceOf(bobW), 0);
        // replay of the forward request fails (nonce consumed)
        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(req);
    }

    function _signForward(uint256 pk, ERC2771Forwarder.ForwardRequestData memory req)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = keccak256(
            "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typehash, req.from, req.to, req.value, req.gas, forwarder.nonces(req.from), req.deadline, keccak256(req.data)
            )
        );
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = forwarder.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------- refund / cancel

    function test_refund_afterExpiry() public {
        uint256 id = _create(_params(100e6));
        uint256 before = usdg.balanceOf(alice);
        vm.expectRevert(GiftVault.NotRefundable.selector);
        vault.refund(id);

        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(makeAddr("keeper"));
        vault.refund(id);
        assertEq(usdg.balanceOf(alice), before + _net(100e6));
        assertEq(uint8(vault.giftStatus(id)), uint8(IGiftVault.Status.Refunded));

        vm.expectRevert(GiftVault.NotRefundable.selector);
        vault.refund(id);

        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.NotOpen.selector);
        vault.claim(id, c, sig);
    }

    function test_cancel_bySenderOnly() public {
        uint256 id = _create(_params(100e6));
        vm.prank(bob);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.cancel(id);

        vm.prank(alice);
        vault.cancel(id);
        assertEq(uint8(vault.giftStatus(id)), uint8(IGiftVault.Status.Refunded));
        vm.prank(alice);
        vm.expectRevert(GiftVault.NotRefundable.selector);
        vault.cancel(id);
    }

    function test_rekey_leakedLink() public {
        uint256 id = _create(_params(100e6));
        uint256 newPk = 0x5EC0D;
        vm.prank(bob);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.rekey(id, vm.addr(newPk));
        vm.prank(alice);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.rekey(id, address(0));

        vm.prank(alice);
        vault.rekey(id, vm.addr(newPk));

        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory oldSig = _sign(linkPk, id, c);
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, c, oldSig);
        vault.claim(id, c, _sign(newPk, id, c));

        vm.prank(alice);
        vm.expectRevert(GiftVault.NotOpen.selector);
        vault.rekey(id, vm.addr(newPk));
    }

    // ------------------------------------------------- admin / pause / gates

    function test_pause_blocksEverything() public {
        uint256 id = _create(_params(100e6));
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        vm.prank(alice);
        vm.expectRevert(IAccessControlUnauthorized(alice, guardianRole));
        vault.pause();

        vm.prank(guardian);
        vault.pause();
        IGiftVault.CreateParams memory p = _params(100e6);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.createGift(p);
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(id, c, sig);

        vm.prank(guardian);
        vault.unpause();
        vault.claim(id, c, sig);
    }

    function test_compliance_gatesSenderAndRecipient() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.startPrank(admin);
        registry.setEnabled(true);
        registry.setAllowed(list, true);
        vm.stopPrank();

        uint256 id = _create(_params(100e6)); // alice allowed
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        vm.expectRevert(abi.encodeWithSelector(ProtocolBase.NotAllowed.selector, bob));
        vault.claim(id, c, sig);

        IGiftVault.CreateParams memory p = _params(100e6);
        usdg.mint(bob, 100e6);
        vm.startPrank(bob);
        usdg.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ProtocolBase.NotAllowed.selector, bob));
        vault.createGift(p);
        vm.stopPrank();

        vm.prank(admin);
        vault.setCompliance(address(0));
        vault.claim(id, c, sig);
    }

    function test_adminSetters_accessControlAndValidation() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(alice);
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setOracle(address(1));
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setDex(address(1));
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setFeeConfig(address(1), address(1), 1);
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setDepositToken(address(1), true);
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setCurated(address(1), true);
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setCardNFT(address(1));
        vm.expectRevert(IAccessControlUnauthorized(alice, role));
        vault.setCompliance(address(1));
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setOracle(address(0));
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setDex(address(0));
        vm.expectRevert(ConversionBase.FeeTooHigh.selector);
        vault.setFeeConfig(address(feeCollector), address(hooks), 201);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setFeeConfig(address(0), address(hooks), 10);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setDepositToken(address(0), true);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setCurated(address(0), true);
        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        vault.setCardNFT(address(0));
        vm.stopPrank();

        vm.expectRevert(ProtocolBase.ZeroAddress.selector);
        new GiftVault(address(0), guardian, address(forwarder));
    }

    function test_giftInfo_view() public {
        uint256 id = _create(_params(100e6));
        IGiftVault.GiftInfo memory info = vault.giftInfo(id);
        assertEq(info.sender, alice);
        assertEq(info.token, address(usdg));
        assertEq(info.amount, _net(100e6));
        assertEq(info.targetToken, address(tsla));
        assertEq(uint8(info.status), 1);
        assertEq(info.expiry, block.timestamp + 30 days);
    }

    function test_trustedForwarderSender() public view {
        assertTrue(vault.isTrustedForwarder(address(forwarder)));
        assertEq(vault.trustedForwarder(), address(forwarder));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_createClaim(uint96 amount, address recipient, bool convert) public {
        amount = uint96(bound(amount, 1, 1_000_000e6));
        vm.assume(recipient != address(0) && recipient != address(vault) && recipient != address(feeCollector));
        vm.assume(recipient != alice);
        uint256 id = _create(_params(amount));
        uint256 net = _net(amount);
        IGiftVault.ClaimParams memory c = _claimParams(recipient, convert ? address(tsla) : address(usdg));
        if (convert && (net * 1e12) / 250 == 0) {
            bytes memory s0 = _sign(linkPk, id, c);
            vm.expectRevert();
            vault.claim(id, c, s0);
            return;
        }
        uint256 out = vault.claim(id, c, _sign(linkPk, id, c));
        if (convert) assertEq(out, (net * 1e12) / 250);
        else assertEq(usdg.balanceOf(recipient), net);
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    function testFuzz_signatureBoundToRecipient(address recipient, address attacker) public {
        vm.assume(recipient != attacker && recipient != address(0) && attacker != address(0));
        vm.assume(recipient != address(vault));
        uint256 id = _create(_params(100e6));
        IGiftVault.ClaimParams memory c = _claimParams(recipient, address(usdg));
        bytes memory sig = _sign(linkPk, id, c);
        c.recipient = attacker;
        vm.expectRevert(GiftVault.InvalidSignature.selector);
        vault.claim(id, c, sig);
    }

    function testFuzz_feeMath(uint128 amount, uint16 bps) public {
        bps = uint16(bound(bps, 0, 200));
        amount = uint128(bound(amount, 1, 1e30));
        vm.prank(admin);
        vault.setFeeConfig(address(feeCollector), address(hooks), bps);
        usdg.mint(alice, amount);
        uint256 fee = (uint256(amount) * bps) / 10_000;
        if (amount - fee == 0) return;
        uint256 id = _create(_params(amount));
        assertEq(vault.getGift(id).amount + fee, amount);
    }

    function _copy(IGiftVault.ClaimParams memory c) internal pure returns (IGiftVault.ClaimParams memory) {
        return abi.decode(abi.encode(c), (IGiftVault.ClaimParams));
    }

    function IAccessControlUnauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }
}
