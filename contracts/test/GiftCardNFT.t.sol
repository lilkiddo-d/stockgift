// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {GiftVault} from "../src/GiftVault.sol";
import {GiftCardNFT} from "../src/GiftCardNFT.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract GiftCardNFTTest is BaseTest {
    function _cardParams(uint8 design, string memory message) internal view returns (IGiftVault.CreateParams memory p) {
        p = _params(25e6);
        p.card = true;
        p.cardRecipient = bob;
        p.design = design;
        p.message = message;
    }

    function test_cardGift_mintsAndRedeems() public {
        uint256 id = _create(_cardParams(1, "Happy 18th <3 & enjoy \"stocks\""));
        assertEq(nft.ownerOf(id), bob);
        assertEq(vault.getGift(id).claimKey, address(nft));
        assertTrue(vault.getGift(id).isCard);
        assertEq(nft.card(id).design, 1);

        IGiftVault.ClaimParams memory c = _claimParams(bob, address(tsla));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, id));
        nft.redeem(id, c);

        vm.prank(bob);
        uint256 out = nft.redeem(id, c);
        assertEq(out, (_net(25e6) * 1e12) / 250);
        assertEq(tsla.balanceOf(bob), out);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
    }

    function test_cardGift_transferThenRedeemByNewHolder() public {
        uint256 id = _create(_cardParams(0, "gm"));
        address carol = makeAddr("carol");
        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        IGiftVault.ClaimParams memory c = _claimParams(carol, address(usdg));
        vm.prank(carol);
        nft.redeem(id, c);
        assertEq(usdg.balanceOf(carol), _net(25e6));
    }

    function test_cardGift_cannotUseLinkClaimOrCancel() public {
        uint256 id = _create(_cardParams(0, "gm"));
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.claim(id, c, "");
        vm.prank(bob);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.claimDirect(id, c);
        vm.prank(alice);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.cancel(id);
        vm.prank(alice);
        vm.expectRevert(GiftVault.Unauthorized.selector);
        vault.rekey(id, bob);
    }

    function test_cardGift_refundedCardCannotRedeem() public {
        uint256 id = _create(_cardParams(2, "gm"));
        vm.warp(block.timestamp + 31 days);
        vault.refund(id);
        string memory uri = nft.tokenURI(id);
        assertGt(bytes(uri).length, 100);
        IGiftVault.ClaimParams memory c = _claimParams(bob, address(usdg));
        c.deadline = block.timestamp + 1;
        vm.prank(bob);
        vm.expectRevert(GiftVault.NotOpen.selector);
        nft.redeem(id, c);
    }

    function test_premiumDesign_requiresTier() public {
        IGiftVault.CreateParams memory p = _cardParams(4, "gold");
        vm.prank(alice);
        vm.expectRevert(GiftVault.PremiumRequired.selector);
        vault.createGift(p);

        // wire $GIFT (mock, tests only), stake above premium tier, wait min age
        vm.prank(admin);
        hooks.setProjectToken(address(giftToken));
        giftToken.mint(alice, 2_000e18);
        vm.startPrank(alice);
        giftToken.approve(address(feeCollector), type(uint256).max);
        feeCollector.stake(1_500e18);
        vm.expectRevert(GiftVault.PremiumRequired.selector);
        vault.createGift(p); // stake too fresh
        vm.warp(block.timestamp + 1 days);
        uint256 id = vault.createGift(p);
        vm.stopPrank();
        assertEq(nft.card(id).design, 4);
    }

    function test_card_validation() public {
        IGiftVault.CreateParams memory p = _cardParams(8, "x");
        vm.prank(alice);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        vault.createGift(p);
        p = _cardParams(0, "x");
        p.cardRecipient = address(0);
        vm.prank(alice);
        vm.expectRevert(GiftVault.InvalidParams.selector);
        vault.createGift(p);
    }

    function test_mintCard_onlyVault() public {
        vm.expectRevert(GiftCardNFT.OnlyVault.selector);
        nft.mintCard(bob, 1, 0, "x");
        vm.expectRevert(GiftCardNFT.ZeroAddress.selector);
        new GiftCardNFT(address(0), address(forwarder));
    }

    function test_tokenURI_rendersAllDesignsAndEscapes() public {
        for (uint8 d; d < 4; ++d) {
            uint256 id = _create(_cardParams(d, unicode"Joyeux anniversaire 🎉 <b>&'\" — long message to wrap across several lines on the card face"));
            string memory uri = nft.tokenURI(id);
            assertTrue(_startsWith(uri, "data:application/json;base64,"));
        }
        string memory svg = nft.renderSVG(7, 6, "1.0000 USDG", "TSLA", "<script>&", "Open");
        assertTrue(_contains(svg, "&lt;script&gt;&amp;"));
        assertFalse(_contains(svg, "<script>"));
        for (uint8 d = 4; d < 8; ++d) {
            assertGt(bytes(nft.renderSVG(1, d, "a", "b", "c", "Open")).length, 300);
        }
    }

    function test_tokenURI_stockGiftAmountFormatting() public {
        IGiftVault.CreateParams memory p = _cardParams(0, "shares");
        p.token = address(tsla);
        p.targetToken = address(0);
        p.amount = 1.5e18;
        uint256 id = _create(p);
        string memory json = string(Base64Decode.decode(_after(nft.tokenURI(id), 29)));
        assertTrue(_contains(json, "Stockgift Card #"));
    }

    function test_tokenURI_metadataFallbacks() public {
        NoMetadataToken bad = new NoMetadataToken();
        LongSymbolToken longSym = new LongSymbolToken();
        vm.startPrank(admin);
        vault.setDepositToken(address(bad), true);
        vault.setDepositToken(address(longSym), true);
        vm.stopPrank();
        bad.mint(alice, 1e18);
        longSym.mint(alice, 1e18);
        vm.startPrank(alice);
        bad.approve(address(vault), type(uint256).max);
        longSym.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        IGiftVault.CreateParams memory p = _cardParams(0, "fallback");
        p.token = address(bad);
        p.targetToken = address(0);
        p.amount = 1e18;
        uint256 id = _create(p);
        string memory json = string(Base64Decode.decode(_after(nft.tokenURI(id), 29)));
        assertTrue(_contains(json, "Stockgift Card"));

        p.token = address(longSym);
        id = _create(p);
        assertGt(bytes(nft.tokenURI(id)).length, 0);
    }

    function test_msgData_viaHarness() public {
        NFTHarness h = new NFTHarness(address(vault), address(forwarder));
        assertEq(h.exposedMsgData().length, 4);
        VaultHarness v = new VaultHarness(admin, guardian, address(forwarder));
        assertEq(v.exposedMsgData().length, 4);
    }

    // ---------------------------------------------------------------- utils

    function _startsWith(string memory s, string memory pre) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(pre);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _contains(string memory s, string memory sub) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(sub);
        if (b.length > a.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool ok = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _after(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory a = bytes(s);
        bytes memory out = new bytes(a.length - n);
        for (uint256 i; i < out.length; ++i) {
            out[i] = a[i + n];
        }
        return string(out);
    }
}

/// @dev Minimal base64 decoder for assertions.
library Base64Decode {
    function decode(string memory data) internal pure returns (bytes memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory d = bytes(data);
        uint256 pad = d.length > 1 && d[d.length - 1] == "=" ? (d[d.length - 2] == "=" ? 2 : 1) : 0;
        bytes memory out = new bytes((d.length / 4) * 3 - pad);
        uint256 o;
        for (uint256 i; i < d.length; i += 4) {
            uint256 n;
            for (uint256 j; j < 4; ++j) {
                uint256 v;
                if (d[i + j] != "=") {
                    for (uint256 k; k < 64; ++k) {
                        if (table[k] == d[i + j]) {
                            v = k;
                            break;
                        }
                    }
                }
                n = (n << 6) | v;
            }
            for (uint256 j; j < 3 && o < out.length; ++j) {
                out[o++] = bytes1(uint8(n >> (16 - 8 * j)));
            }
        }
        return out;
    }
}

contract NoMetadataToken is MockERC20 {
    constructor() MockERC20("", "", 18) {}

    function symbol() public pure override returns (string memory) {
        revert();
    }

    function decimals() public pure override returns (uint8) {
        revert();
    }
}

contract LongSymbolToken is MockERC20 {
    constructor() MockERC20("Long", "AVERYVERYLONGSYMBOLNAME", 6) {}
}

contract NFTHarness is GiftCardNFT {
    constructor(address v, address f) GiftCardNFT(v, f) {}

    function exposedMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}

contract VaultHarness is GiftVault {
    constructor(address a, address g, address f) GiftVault(a, g, f) {}

    function exposedMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}
