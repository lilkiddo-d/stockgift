// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ConversionBase} from "./base/ConversionBase.sol";
import {ClaimVerifier} from "./ClaimVerifier.sol";
import {IGiftVault, IGiftCardNFT} from "./interfaces/IStockgift.sol";

/// @title GiftVault
/// @notice Escrow for Stockgift gifts. A sender deposits a stablecoin or stock token; the gift is
///         claimable by whoever controls `claimKey`:
///           - link gifts:    claimKey = address of an ephemeral key carried in the link fragment
///           - wallet gifts:  claimKey = recipient wallet (EOA signature or direct call)
///           - card gifts:    claimKey = GiftCardNFT; burning the card claims the gift
///         On claim, the deposit can be converted into a stock token via the DexAdapter, bounded by an
///         oracle-derived floor. Unclaimed gifts are refundable to the sender after expiry.
/// @dev Invariant: for every token, balanceOf(this) == totalOpen[token] (absent unsolicited transfers).
contract GiftVault is ConversionBase, ClaimVerifier, ERC2771Context, IGiftVault {
    using SafeERC20 for IERC20;

    struct Gift {
        address sender;
        uint64 expiry;
        uint16 maxSlippageBps;
        Status status;
        bool recipientChooses;
        bool isCard;
        address token;
        address claimKey;
        address targetToken;
        uint256 amount;
    }

    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 3650 days;
    uint256 public constant MAX_MESSAGE_LENGTH = 280;
    uint8 public constant MAX_DESIGN = 7;
    /// @notice Designs >= this id require the $GIFT premium tier.
    uint8 public constant FIRST_PREMIUM_DESIGN = 4;
    /// @notice Hard cap on the relayer fee a claim may pay (10% of the gift).
    uint16 public constant MAX_RELAYER_FEE_CAP_BPS = 1_000;

    uint16 public maxRelayerFeeBps = 300;
    uint256 public nextGiftId = 1;
    IGiftCardNFT public cardNFT;

    mapping(uint256 => Gift) internal _gifts;
    /// @notice Sum of open gift amounts per token.
    mapping(address => uint256) public totalOpen;

    event GiftCreated(
        uint256 indexed giftId,
        address indexed sender,
        address indexed token,
        uint256 amount,
        address claimKey,
        address targetToken,
        bool recipientChooses,
        uint64 expiry,
        bool card,
        string message
    );
    event GiftClaimed(
        uint256 indexed giftId,
        address indexed recipient,
        address indexed tokenOut,
        uint256 amountOut,
        address relayer,
        uint256 relayerFee
    );
    event GiftRefunded(uint256 indexed giftId, address indexed sender, uint256 amount, bool cancelled);
    event GiftRekeyed(uint256 indexed giftId, address newClaimKey);
    event CardNFTSet(address indexed cardNFT);
    event MaxRelayerFeeSet(uint16 bps);

    error InvalidParams();
    error NotOpen();
    error NotClaimable();
    error NotRefundable();
    error Unauthorized();
    error InvalidSignature();
    error PremiumRequired();
    error RelayerFeeTooHigh();
    error TokenOutNotAllowed();

    constructor(address admin, address guardian, address trustedForwarder)
        ConversionBase(admin, guardian)
        ERC2771Context(trustedForwarder)
    {}

    // ------------------------------------------------------------------ admin

    function setCardNFT(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert ZeroAddress();
        cardNFT = IGiftCardNFT(nft);
        emit CardNFTSet(nft);
    }

    function setMaxRelayerFeeBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_RELAYER_FEE_CAP_BPS) revert RelayerFeeTooHigh();
        maxRelayerFeeBps = bps;
        emit MaxRelayerFeeSet(bps);
    }

    // ----------------------------------------------------------------- create

    /// @inheritdoc IGiftVault
    function createGift(CreateParams calldata p) external nonReentrant whenNotPaused returns (uint256 giftId) {
        address sender = _msgSender();
        _checkAllowed(sender);
        _validateCreate(p, sender);

        address claimKey = p.card ? address(cardNFT) : p.claimKey;
        uint256 fee = _quoteFee(sender, p.amount);
        uint256 net = p.amount - fee;
        if (net == 0) revert InvalidParams();

        giftId = nextGiftId++;
        _gifts[giftId] = Gift({
            sender: sender,
            expiry: p.expiry,
            maxSlippageBps: p.maxSlippageBps,
            status: Status.Open,
            recipientChooses: p.recipientChooses,
            isCard: p.card,
            token: p.token,
            claimKey: claimKey,
            targetToken: p.targetToken,
            amount: net
        });
        totalOpen[p.token] += net;

        emit GiftCreated(
            giftId,
            sender,
            p.token,
            net,
            claimKey,
            p.targetToken,
            p.recipientChooses,
            p.expiry,
            p.card,
            p.message
        );

        _collect(p.token, sender, p.amount, fee);
        if (p.card) cardNFT.mintCard(p.cardRecipient, giftId, p.design, p.message);
    }

    function _validateCreate(CreateParams calldata p, address sender) internal view {
        if (!isDepositToken[p.token] || p.amount == 0) revert TokenNotAllowed(p.token);
        if (p.targetToken != address(0) && (!isCurated[p.targetToken] || p.targetToken == p.token)) {
            revert TokenNotAllowed(p.targetToken);
        }
        if (p.maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        if (p.expiry < block.timestamp + MIN_DURATION || p.expiry > block.timestamp + MAX_DURATION) {
            revert InvalidParams();
        }
        if (bytes(p.message).length > MAX_MESSAGE_LENGTH) revert InvalidParams();
        if (p.card) {
            if (address(cardNFT) == address(0) || p.cardRecipient == address(0) || p.design > MAX_DESIGN) {
                revert InvalidParams();
            }
            if (p.design >= FIRST_PREMIUM_DESIGN) {
                if (address(tokenHooks) == address(0) || !tokenHooks.hasPremium(sender)) revert PremiumRequired();
            }
        } else if (p.claimKey == address(0)) {
            revert InvalidParams();
        }
    }

    // ------------------------------------------------------------------ claim

    /// @notice Claim with an EIP-712 signature from the gift's claim key. Callable by anyone
    ///         (e.g. a gasless relayer); funds always go to the signed `c.recipient`.
    function claim(uint256 giftId, ClaimParams calldata c, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        Gift storage g = _gifts[giftId];
        if (g.isCard) revert Unauthorized();
        if (!_isValidClaimSignature(g.claimKey, hashClaim(giftId, c), signature)) revert InvalidSignature();
        return _claim(giftId, g, c);
    }

    /// @inheritdoc IGiftVault
    /// @dev Caller must be the claim key itself (wallet gifts, smart accounts, the card NFT).
    ///      Works through the trusted forwarder for gasless calls.
    function claimDirect(uint256 giftId, ClaimParams calldata c)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        Gift storage g = _gifts[giftId];
        if (_msgSender() != g.claimKey) revert Unauthorized();
        return _claim(giftId, g, c);
    }

    function _claim(uint256 giftId, Gift storage g, ClaimParams calldata c) internal returns (uint256 amountOut) {
        if (g.status != Status.Open) revert NotOpen();
        if (block.timestamp > g.expiry || block.timestamp > c.deadline) revert Expired();
        _checkAllowed(c.recipient);

        address token = g.token;
        uint256 amount = g.amount;
        if (c.tokenOut != token && c.tokenOut != g.targetToken && !(g.recipientChooses && isCurated[c.tokenOut])) {
            revert TokenOutNotAllowed();
        }
        if (c.relayerFee > (amount * maxRelayerFeeBps) / BPS) revert RelayerFeeTooHigh();
        if (c.relayerFee != 0 && c.relayer == address(0)) revert InvalidParams();

        // effects
        g.status = Status.Claimed;
        totalOpen[token] -= amount;

        // interactions
        if (c.relayerFee != 0) IERC20(token).safeTransfer(c.relayer, c.relayerFee);
        amountOut =
            _deliver(token, amount - c.relayerFee, c.tokenOut, c.minAmountOut, c.deadline, g.maxSlippageBps, c.recipient);
        emit GiftClaimed(giftId, c.recipient, c.tokenOut, amountOut, c.relayer, c.relayerFee);
    }

    // ----------------------------------------------------------------- refund

    /// @notice Return an expired, unclaimed gift to its sender. Callable by anyone (keepers).
    function refund(uint256 giftId) external nonReentrant whenNotPaused {
        Gift storage g = _gifts[giftId];
        if (g.status != Status.Open || block.timestamp <= g.expiry) revert NotRefundable();
        _refund(giftId, g, false);
    }

    /// @notice Sender reclaims an unclaimed link/wallet gift early (e.g. the link leaked).
    ///         Card gifts cannot be cancelled: the card holder owns the claim right.
    function cancel(uint256 giftId) external nonReentrant whenNotPaused {
        Gift storage g = _gifts[giftId];
        if (_msgSender() != g.sender || g.isCard) revert Unauthorized();
        if (g.status != Status.Open) revert NotRefundable();
        _refund(giftId, g, true);
    }

    /// @notice Sender rotates the claim key of an open link gift (e.g. re-issue a leaked link).
    function rekey(uint256 giftId, address newClaimKey) external whenNotPaused {
        Gift storage g = _gifts[giftId];
        if (_msgSender() != g.sender || g.isCard) revert Unauthorized();
        if (g.status != Status.Open) revert NotOpen();
        if (newClaimKey == address(0)) revert ZeroAddress();
        g.claimKey = newClaimKey;
        emit GiftRekeyed(giftId, newClaimKey);
    }

    function _refund(uint256 giftId, Gift storage g, bool cancelled) internal {
        uint256 amount = g.amount;
        address token = g.token;
        g.status = Status.Refunded;
        totalOpen[token] -= amount;
        emit GiftRefunded(giftId, g.sender, amount, cancelled);
        IERC20(token).safeTransfer(g.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function getGift(uint256 giftId) external view returns (Gift memory) {
        return _gifts[giftId];
    }

    /// @inheritdoc IGiftVault
    function giftStatus(uint256 giftId) external view returns (Status) {
        return _gifts[giftId].status;
    }

    /// @inheritdoc IGiftVault
    function giftInfo(uint256 giftId) external view returns (GiftInfo memory) {
        Gift storage g = _gifts[giftId];
        return GiftInfo(g.sender, g.token, g.amount, g.targetToken, g.status, g.expiry);
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
