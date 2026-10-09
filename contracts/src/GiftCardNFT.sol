// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IGiftVault, IGiftCardNFT} from "./interfaces/IStockgift.sol";

/// @title GiftCardNFT
/// @notice Optional ERC-721 gift card. Token id == gift id. The card holds the claim right of its gift:
///         the vault records this contract as the gift's claim key, and burning the card (`redeem`)
///         claims the gift to an address of the holder's choice. Artwork is a fully on-chain SVG.
contract GiftCardNFT is ERC721, ERC2771Context, IGiftCardNFT {
    using Strings for uint256;

    struct Card {
        uint8 design;
        string message;
    }

    IGiftVault public immutable vault;
    mapping(uint256 => Card) internal _cards;

    event CardMinted(uint256 indexed giftId, address indexed to, uint8 design);
    event CardRedeemed(uint256 indexed giftId, address indexed holder, address indexed recipient, uint256 amountOut);

    error OnlyVault();
    error ZeroAddress();

    constructor(address vault_, address trustedForwarder) ERC721("Stockgift Card", "SGCARD") ERC2771Context(trustedForwarder) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = IGiftVault(vault_);
    }

    /// @inheritdoc IGiftCardNFT
    function mintCard(address to, uint256 giftId, uint8 design, string calldata message) external {
        if (msg.sender != address(vault)) revert OnlyVault();
        _cards[giftId] = Card({design: design, message: message});
        emit CardMinted(giftId, to, design);
        // _mint (not _safeMint): no receiver callback while the vault is mid-transaction.
        _mint(to, giftId);
    }

    /// @notice Burn the card and claim its gift. Holder (or approved operator) only; gasless via forwarder.
    function redeem(uint256 giftId, IGiftVault.ClaimParams calldata c) external returns (uint256 amountOut) {
        address holder = _msgSender();
        _checkAuthorized(_ownerOf(giftId), holder, giftId);
        _burn(giftId);
        amountOut = vault.claimDirect(giftId, c);
        emit CardRedeemed(giftId, holder, c.recipient, amountOut);
    }

    function card(uint256 giftId) external view returns (Card memory) {
        return _cards[giftId];
    }

    // ----------------------------------------------------------------- render

    function tokenURI(uint256 giftId) public view override returns (string memory) {
        _requireOwned(giftId);
        IGiftVault.GiftInfo memory info = vault.giftInfo(giftId);
        string memory ticker = info.targetToken == address(0) ? _symbol(info.token) : _symbol(info.targetToken);
        string memory amountStr =
            string.concat(_formatAmount(info.amount, _decimals(info.token)), " ", _symbol(info.token));
        string memory statusStr = info.status == IGiftVault.Status.Open
            ? "Open"
            : (info.status == IGiftVault.Status.Claimed ? "Claimed" : "Refunded");
        Card storage c = _cards[giftId];

        string memory svg = renderSVG(giftId, c.design, amountStr, ticker, c.message, statusStr);
        bytes memory json = abi.encodePacked(
            '{"name":"Stockgift Card #',
            giftId.toString(),
            '","description":"A Stockgift card. Burn it in the Stockgift app to claim the gift.",',
            '"attributes":[{"trait_type":"Design","value":',
            uint256(c.design).toString(),
            '},{"trait_type":"Status","value":"',
            statusStr,
            '"}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function renderSVG(
        uint256 giftId,
        uint8 design,
        string memory amountStr,
        string memory ticker,
        string memory message,
        string memory statusStr
    ) public pure returns (string memory) {
        (string memory bg1, string memory bg2, string memory fg) = _palette(design);
        string memory head = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 250" font-family="Helvetica,Arial,sans-serif">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="',
            bg1,
            '"/><stop offset="1" stop-color="',
            bg2,
            '"/></linearGradient></defs><rect width="400" height="250" rx="18" fill="url(#g)"/>',
            '<text x="24" y="40" font-size="16" font-weight="700" fill="',
            fg,
            '">STOCKGIFT</text><text x="376" y="40" font-size="12" text-anchor="end" fill="',
            fg,
            '">#',
            giftId.toString(),
            "</text>"
        );
        string memory body = string.concat(
            '<text x="24" y="92" font-size="30" font-weight="700" fill="',
            fg,
            '">',
            _escape(bytes(ticker), 0, bytes(ticker).length),
            '</text><text x="24" y="118" font-size="14" fill="',
            fg,
            '">',
            _escape(bytes(amountStr), 0, bytes(amountStr).length),
            "</text>",
            _messageLines(message, fg),
            '<text x="376" y="232" font-size="11" text-anchor="end" fill="',
            fg,
            '">',
            statusStr,
            "</text></svg>"
        );
        return string.concat(head, body);
    }

    // ---------------------------------------------------------------- helpers

    function _palette(uint8 design) internal pure returns (string memory, string memory, string memory) {
        if (design == 0) return ("#0f5132", "#1fa463", "#ffffff"); // evergreen
        if (design == 1) return ("#ff7a59", "#ffcf56", "#1b1b1b"); // birthday
        if (design == 2) return ("#2b2d42", "#8d99ae", "#ffffff"); // classic
        if (design == 3) return ("#3a0ca3", "#4cc9f0", "#ffffff"); // celebration
        if (design == 4) return ("#111111", "#b8860b", "#f5e6b3"); // premium: gold
        if (design == 5) return ("#0b0c10", "#45a29e", "#c5c6c7"); // premium: onyx
        if (design == 6) return ("#e0e0e0", "#ffffff", "#222222"); // premium: platinum
        return ("#590d22", "#c9184a", "#fff0f3"); // premium: ruby
    }

    /// @dev Up to 5 lines of ~34 bytes, never splitting a UTF-8 code point.
    function _messageLines(string memory message, string memory fg) internal pure returns (string memory out) {
        bytes memory m = bytes(message);
        uint256 start = 0;
        for (uint256 line = 0; line < 5 && start < m.length; ++line) {
            uint256 end = start + 34;
            if (end >= m.length) {
                end = m.length;
            } else {
                while (end > start && (uint8(m[end]) & 0xC0) == 0x80) --end;
            }
            out = string.concat(
                out,
                '<text x="24" y="',
                (150 + line * 18).toString(),
                '" font-size="13" fill="',
                fg,
                '">',
                _escape(m, start, end),
                "</text>"
            );
            start = end;
        }
    }

    /// @dev XML-escapes m[start:end]. Bounded by the vault's 280-byte message cap.
    function _escape(bytes memory m, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory buf = new bytes((end - start) * 6);
        uint256 n;
        for (uint256 i = start; i < end; ++i) {
            bytes1 ch = m[i];
            bytes memory rep;
            if (ch == "&") rep = "&amp;";
            else if (ch == "<") rep = "&lt;";
            else if (ch == ">") rep = "&gt;";
            else if (ch == '"') rep = "&quot;";
            else if (ch == "'") rep = "&#39;";
            if (rep.length == 0) {
                buf[n++] = ch;
            } else {
                for (uint256 j; j < rep.length; ++j) {
                    buf[n++] = rep[j];
                }
            }
        }
        assembly {
            mstore(buf, n)
        }
        return string(buf);
    }

    function _symbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return bytes(s).length > 16 ? "TOKEN" : s;
        } catch {
            return "TOKEN";
        }
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    /// @dev Formats with up to 4 fractional digits (truncated).
    function _formatAmount(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 whole = amount / unit;
        uint256 frac = decimals >= 4 ? (amount % unit) / 10 ** (decimals - 4) : (amount % unit) * 10 ** (4 - decimals);
        bytes memory f = bytes(frac.toString());
        bytes memory padded = new bytes(4);
        for (uint256 i; i < 4; ++i) {
            padded[i] = i < 4 - f.length ? bytes1("0") : f[i - (4 - f.length)];
        }
        return string.concat(whole.toString(), ".", string(padded));
    }

    // ------------------------------------------------------- ERC-2771 plumbing

    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
