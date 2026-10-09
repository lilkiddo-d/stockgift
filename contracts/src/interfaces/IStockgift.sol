// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Price source abstraction. Prices are USD per 1 whole token, scaled to 1e18.
interface IOracleAdapter {
    function getPrice(address token) external view returns (uint256 priceE18);
    function hasFeed(address token) external view returns (bool);
    /// @notice Oracle-implied output amount for swapping `amountIn` of `tokenIn` into `tokenOut`.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}

/// @notice Swap venue abstraction. Implementations must pull `amountIn` from msg.sender,
///         deliver at least `minAmountOut` of `tokenOut` to `recipient`, and revert after `deadline`.
interface IDexAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool);
}

/// @notice Optional allowlist hook. When the registry is disabled every account is allowed.
interface IComplianceRegistry {
    function isAllowed(address account) external view returns (bool);
}

/// @notice Fee sink. `notifyFee` must be called right after the fee tokens were transferred in.
interface IFeeCollector {
    function notifyFee(address token, uint256 amount) external;
    function stakedBalance(address account) external view returns (uint256);
    function stakedSince(address account) external view returns (uint256);
}

/// @notice Project-token ($GIFT) feature gates. All return false until the token is set.
interface IProjectTokenHooks {
    function projectToken() external view returns (address);
    function isFeeExempt(address account) external view returns (bool);
    function hasPremium(address account) external view returns (bool);
}

/// @notice Subset of GiftVault used by GiftCardNFT and GroupPot.
interface IGiftVault {
    enum Status {
        None,
        Open,
        Claimed,
        Refunded
    }

    struct CreateParams {
        address token; // deposit token (stablecoin or stock token)
        uint256 amount; // gross amount pulled from the sender (fee is taken from it)
        address claimKey; // link key address, recipient wallet, or ignored for cards
        uint64 expiry; // unix time after which the gift can be refunded
        address targetToken; // stock to convert into at claim time (0 = no conversion)
        bool recipientChooses; // recipient may pick any curated token at claim time
        uint16 maxSlippageBps; // max deviation from oracle price accepted at claim time
        bool card; // mint a GiftCardNFT that holds the claim right
        address cardRecipient; // receiver of the card NFT (card gifts only)
        uint8 design; // card design id
        string message; // short message (emitted, and stored on the card)
    }

    struct ClaimParams {
        address recipient;
        address tokenOut;
        uint256 minAmountOut;
        address relayer;
        uint256 relayerFee; // paid in the deposit token
        uint256 deadline;
    }

    function createGift(CreateParams calldata p) external returns (uint256 giftId);
    function claimDirect(uint256 giftId, ClaimParams calldata c) external returns (uint256 amountOut);
    function giftStatus(uint256 giftId) external view returns (Status);
    struct GiftInfo {
        address sender;
        address token;
        uint256 amount;
        address targetToken;
        Status status;
        uint64 expiry;
    }

    function giftInfo(uint256 giftId) external view returns (GiftInfo memory);
}

interface IGiftCardNFT {
    function mintCard(address to, uint256 giftId, uint8 design, string calldata message) external;
}
