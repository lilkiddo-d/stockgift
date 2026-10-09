// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracleAdapter} from "./interfaces/IStockgift.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title OracleAdapter
/// @notice Chainlink-backed implementation of IOracleAdapter. Swappable: the vault and
///         ScheduledGifts reference IOracleAdapter and the Timelock can point them elsewhere.
/// @dev Checks per read: answer > 0, updatedAt set and not in the future, age <= per-feed
///      maxStaleness, optional L2 sequencer-uptime feed (+ grace period), and optional per-feed
///      [minPrice, maxPrice] sanity bounds. The price-vs-execution deviation check lives in
///      ConversionBase (swap output must be within maxSlippageBps of `quote`).
contract OracleAdapter is AccessControl, IOracleAdapter {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        uint128 minPriceE18; // 0 = unbounded
        uint128 maxPriceE18; // 0 = unbounded
    }

    mapping(address => FeedConfig) public feeds;
    AggregatorV3Interface public sequencerUptimeFeed; // address(0) = not available on this chain
    uint32 public sequencerGracePeriod = 1 hours;

    event FeedSet(address indexed token, address indexed feed, uint32 maxStaleness, uint128 minPriceE18, uint128 maxPriceE18);
    event SequencerFeedSet(address indexed feed, uint32 gracePeriod);

    error NoFeed(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error PriceOutOfBounds(address token, uint256 price);
    error SequencerDown();
    error InvalidConfig();

    constructor(address admin) {
        if (admin == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address token, address feed, uint32 maxStaleness, uint128 minPriceE18, uint128 maxPriceE18)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0) || feed == address(0) || maxStaleness == 0) revert InvalidConfig();
        if (maxPriceE18 != 0 && maxPriceE18 <= minPriceE18) revert InvalidConfig();
        uint8 fd = AggregatorV3Interface(feed).decimals();
        uint8 td = IERC20Metadata(token).decimals();
        if (fd > 18 || td > 36) revert InvalidConfig();
        feeds[token] = FeedConfig(AggregatorV3Interface(feed), maxStaleness, fd, td, minPriceE18, maxPriceE18);
        emit FeedSet(token, feed, maxStaleness, minPriceE18, maxPriceE18);
    }

    function removeFeed(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete feeds[token];
        emit FeedSet(token, address(0), 0, 0, 0);
    }

    function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = AggregatorV3Interface(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    /// @inheritdoc IOracleAdapter
    function hasFeed(address token) external view returns (bool) {
        return address(feeds[token].feed) != address(0);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice(address token) public view returns (uint256 priceE18) {
        FeedConfig memory cfg = feeds[token];
        if (address(cfg.feed) == address(0)) revert NoFeed(token);
        _checkSequencer();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            cfg.feed.latestRoundData();
        if (answer <= 0 || roundId == 0 || startedAt == 0 || answeredInRound < roundId) revert InvalidPrice(token);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.maxStaleness) {
            revert StalePrice(token, updatedAt);
        }
        priceE18 = uint256(answer) * 10 ** (18 - cfg.feedDecimals);
        if ((cfg.minPriceE18 != 0 && priceE18 < cfg.minPriceE18) || (cfg.maxPriceE18 != 0 && priceE18 > cfg.maxPriceE18))
        {
            revert PriceOutOfBounds(token, priceE18);
        }
    }

    /// @inheritdoc IOracleAdapter
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        uint256 pIn = getPrice(tokenIn);
        uint256 pOut = getPrice(tokenOut);
        // usdE18 = amountIn * pIn / 10^decIn ; amountOut = usdE18 * 10^decOut / pOut
        uint256 usdE18 = Math.mulDiv(amountIn, pIn, 10 ** feeds[tokenIn].tokenDecimals);
        amountOut = Math.mulDiv(usdE18, 10 ** feeds[tokenOut].tokenDecimals, pOut);
    }

    function _checkSequencer() internal view {
        AggregatorV3Interface s = sequencerUptimeFeed;
        if (address(s) == address(0)) return;
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            s.latestRoundData();
        // answer == 0: sequencer up; 1: down. startedAt == 0 means the round is invalid.
        if (
            answer != 0 || startedAt == 0 || updatedAt == 0 || answeredInRound < roundId
                || block.timestamp - startedAt <= sequencerGracePeriod
        ) revert SequencerDown();
    }
}
