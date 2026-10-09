// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ConversionBase} from "./base/ConversionBase.sol";

/// @title ScheduledGifts
/// @notice Pre-funded recurring gifts ("$20 of a stock every month for 12 months"). The sender funds
///         all installments up front (plus the protocol fee on top). Each due installment is released
///         by a keeper (or anyone, or the recipient) and optionally converted into the target stock
///         with the same oracle-floored swap protection as claims.
/// @dev One installment per call (no unbounded loops); a late schedule catches up one call at a time.
///      Invariant: balanceOf(this, token) == totalCommitted[token].
contract ScheduledGifts is ConversionBase {
    using SafeERC20 for IERC20;

    struct Schedule {
        address sender;
        uint64 interval;
        uint64 nextReleaseAt;
        uint16 maxSlippageBps;
        uint16 releasesLeft;
        bool active;
        address recipient;
        address token;
        address targetToken;
        uint128 amountPerRelease;
    }

    uint64 public constant MIN_INTERVAL = 1 days;
    uint64 public constant MAX_INTERVAL = 366 days;
    uint16 public constant MAX_RELEASES = 520;

    uint256 public nextScheduleId = 1;
    mapping(uint256 => Schedule) internal _schedules;
    mapping(address => uint256) public totalCommitted;

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed sender,
        address indexed recipient,
        address token,
        address targetToken,
        uint256 amountPerRelease,
        uint16 releases,
        uint64 interval,
        uint64 firstReleaseAt,
        string message
    );
    event InstallmentReleased(
        uint256 indexed scheduleId, address indexed recipient, address tokenOut, uint256 amountIn, uint256 amountOut, uint16 releasesLeft
    );
    event ScheduleCancelled(uint256 indexed scheduleId, uint256 refunded);

    error InvalidParams();
    error NotActive();
    error NotDue();
    error Unauthorized();

    constructor(address admin, address guardian) ConversionBase(admin, guardian) {}

    struct CreateScheduleParams {
        address recipient;
        address token; // deposit token
        address targetToken; // stock to buy at each release (0 = deliver deposit token)
        uint128 amountPerRelease;
        uint16 releases;
        uint64 interval; // seconds (7 days = weekly, 30 days = monthly)
        uint64 firstReleaseAt;
        uint16 maxSlippageBps;
        string message;
    }

    function createSchedule(CreateScheduleParams calldata p) external nonReentrant whenNotPaused returns (uint256 id) {
        address sender = msg.sender;
        _checkAllowed(sender);
        _validate(p);

        uint256 committed = uint256(p.amountPerRelease) * p.releases;
        uint256 fee = _quoteFee(sender, committed);

        id = nextScheduleId++;
        _schedules[id] = Schedule({
            sender: sender,
            interval: p.interval,
            nextReleaseAt: p.firstReleaseAt,
            maxSlippageBps: p.maxSlippageBps,
            releasesLeft: p.releases,
            active: true,
            recipient: p.recipient,
            token: p.token,
            targetToken: p.targetToken,
            amountPerRelease: p.amountPerRelease
        });
        totalCommitted[p.token] += committed;
        emit ScheduleCreated(
            id,
            sender,
            p.recipient,
            p.token,
            p.targetToken,
            p.amountPerRelease,
            p.releases,
            p.interval,
            p.firstReleaseAt,
            p.message
        );

        // fee is charged on top of the committed amount
        _collect(p.token, sender, committed + fee, fee);
    }

    function _validate(CreateScheduleParams calldata p) internal view {
        if (p.recipient == address(0) || p.recipient == address(this)) revert BadRecipient();
        if (!isDepositToken[p.token]) revert TokenNotAllowed(p.token);
        if (p.targetToken != address(0) && (!isCurated[p.targetToken] || p.targetToken == p.token)) {
            revert TokenNotAllowed(p.targetToken);
        }
        if (p.amountPerRelease == 0 || p.releases == 0 || p.releases > MAX_RELEASES) revert InvalidParams();
        if (p.interval < MIN_INTERVAL || p.interval > MAX_INTERVAL) revert InvalidParams();
        if (p.firstReleaseAt < block.timestamp || p.firstReleaseAt > block.timestamp + MAX_INTERVAL) {
            revert InvalidParams();
        }
        if (p.maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        if (bytes(p.message).length > 280) revert InvalidParams();
    }

    /// @notice Release the next due installment, converting into the target stock if configured.
    ///         Permissionless (keepers); `minAmountOut` is floored by the oracle quote.
    function release(uint256 id, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        Schedule storage s = _schedules[id];
        address tokenOut = s.targetToken == address(0) ? s.token : s.targetToken;
        return _release(id, s, tokenOut, minAmountOut, deadline);
    }

    /// @notice Recipient takes the due installment in the deposited token (e.g. markets closed,
    ///         oracle stale, or no liquidity).
    function releaseAsDeposit(uint256 id) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        Schedule storage s = _schedules[id];
        if (msg.sender != s.recipient) revert Unauthorized();
        return _release(id, s, s.token, 0, block.timestamp);
    }

    function _release(uint256 id, Schedule storage s, address tokenOut, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256 amountOut)
    {
        if (!s.active) revert NotActive();
        if (block.timestamp < s.nextReleaseAt) revert NotDue();
        if (block.timestamp > deadline) revert Expired();
        address recipient = s.recipient;
        _checkAllowed(recipient);

        uint256 amount = s.amountPerRelease;
        uint16 left = s.releasesLeft - 1;
        s.releasesLeft = left;
        s.nextReleaseAt += s.interval;
        if (left == 0) s.active = false;
        totalCommitted[s.token] -= amount;

        amountOut = _deliver(s.token, amount, tokenOut, minAmountOut, deadline, s.maxSlippageBps, recipient);
        emit InstallmentReleased(id, recipient, tokenOut, amount, amountOut, left);
    }

    /// @notice Sender stops the schedule and takes back all unreleased installments.
    function cancelSchedule(uint256 id) external nonReentrant whenNotPaused {
        Schedule storage s = _schedules[id];
        if (msg.sender != s.sender) revert Unauthorized();
        if (!s.active) revert NotActive();
        uint256 remaining = uint256(s.amountPerRelease) * s.releasesLeft;
        s.active = false;
        s.releasesLeft = 0;
        totalCommitted[s.token] -= remaining;
        emit ScheduleCancelled(id, remaining);
        IERC20(s.token).safeTransfer(s.sender, remaining);
    }

    function getSchedule(uint256 id) external view returns (Schedule memory) {
        return _schedules[id];
    }

    function isDue(uint256 id) external view returns (bool) {
        Schedule storage s = _schedules[id];
        return s.active && block.timestamp >= s.nextReleaseAt;
    }
}
