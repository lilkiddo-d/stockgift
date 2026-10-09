// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeCollector, IProjectTokenHooks} from "./interfaces/IStockgift.sol";

/// @title FeeCollector
/// @notice Receives protocol fees. A configurable share of fees in "reward tokens" is streamed to
///         $GIFT stakers (MasterChef-style accumulator); the rest accrues to the treasury, which only
///         the Timelock can withdraw. Staking is disabled until the project token is set in
///         ProjectTokenHooks; until then 100% of fees go to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard, Pausable, IFeeCollector {
    using SafeERC20 for IERC20;

    bytes32 public constant NOTIFIER_ROLE = keccak256("NOTIFIER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant MAX_REWARD_TOKENS = 10;
    uint256 internal constant ACC = 1e30;
    uint256 internal constant BPS = 10_000;

    IProjectTokenHooks public immutable hooks;
    uint16 public stakerShareBps = 5_000;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakedSince;

    mapping(address => uint256) public accRewardPerShare; // token => acc (scaled by ACC)
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => token => debt
    mapping(address => mapping(address => uint256)) public pendingRewards; // user => token => owed
    mapping(address => uint256) public treasuryBalance; // token => withdrawable by treasury

    event FeeNotified(address indexed token, uint256 amount, uint256 toStakers, uint256 toTreasury);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, address indexed token, uint256 amount);
    event RewardTokenAdded(address indexed token);
    event StakerShareSet(uint16 bps);
    event TreasuryWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSet();
    error TooManyRewardTokens();
    error InvalidToken();
    error InvalidShare();
    error InsufficientStake();
    error InsufficientTreasury();

    constructor(address admin, address guardian, address hooks_) {
        if (admin == address(0) || guardian == address(0) || hooks_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        hooks = IProjectTokenHooks(hooks_);
    }

    // ------------------------------------------------------------------ admin

    function addRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || isRewardToken[token] || token == hooks.projectToken()) revert InvalidToken();
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        isRewardToken[token] = true;
        rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    function setStakerShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS) revert InvalidShare();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    function withdrawTreasury(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount > treasuryBalance[token]) revert InsufficientTreasury();
        treasuryBalance[token] -= amount;
        emit TreasuryWithdrawn(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ fees

    /// @inheritdoc IFeeCollector
    function notifyFee(address token, uint256 amount) external onlyRole(NOTIFIER_ROLE) {
        uint256 toStakers = 0;
        uint256 staked = totalStaked;
        if (isRewardToken[token] && staked != 0) {
            // Accrue from the floored staker amount so cumulative payouts can never exceed it.
            toStakers = Math.mulDiv(amount, stakerShareBps, BPS);
            accRewardPerShare[token] += Math.mulDiv(toStakers, ACC, staked);
        }
        treasuryBalance[token] += amount - toStakers;
        emit FeeNotified(token, amount, toStakers, amount - toStakers);
    }

    // --------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        address token = hooks.projectToken();
        if (token == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        uint256 newBal = stakedBalance[msg.sender] + amount;
        stakedBalance[msg.sender] = newBal;
        totalStaked += amount;
        stakedSince[msg.sender] = block.timestamp;
        _resetDebt(msg.sender, newBal);
        emit Staked(msg.sender, amount);

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert InvalidToken();
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = stakedBalance[msg.sender];
        if (amount > bal) revert InsufficientStake();
        _settle(msg.sender);
        uint256 newBal = bal - amount;
        stakedBalance[msg.sender] = newBal;
        totalStaked -= amount;
        if (newBal == 0) stakedSince[msg.sender] = 0;
        _resetDebt(msg.sender, newBal);
        emit Unstaked(msg.sender, amount);
        IERC20(hooks.projectToken()).safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        _settle(msg.sender);
        _resetDebt(msg.sender, stakedBalance[msg.sender]);
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            uint256 owed = pendingRewards[msg.sender][t];
            if (owed != 0) {
                pendingRewards[msg.sender][t] = 0;
                emit RewardPaid(msg.sender, t, owed);
                IERC20(t).safeTransfer(msg.sender, owed);
            }
        }
    }

    function earned(address account, address token) external view returns (uint256) {
        return pendingRewards[account][token]
            + (stakedBalance[account] * accRewardPerShare[token]) / ACC - rewardDebt[account][token];
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    /// @dev Loops are bounded by MAX_REWARD_TOKENS.
    function _settle(address account) internal {
        uint256 bal = stakedBalance[account];
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            uint256 accrued = (bal * accRewardPerShare[t]) / ACC;
            pendingRewards[account][t] += accrued - rewardDebt[account][t];
        }
    }

    function _resetDebt(address account, uint256 bal) internal {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            rewardDebt[account][t] = (bal * accRewardPerShare[t]) / ACC;
        }
    }
}
