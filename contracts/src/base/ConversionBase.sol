// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolBase} from "./ProtocolBase.sol";
import {IOracleAdapter, IDexAdapter, IFeeCollector, IProjectTokenHooks} from "../interfaces/IStockgift.sol";

/// @title ConversionBase
/// @notice Token registry, fee charging and oracle-guarded "convert at delivery" logic shared by
///         GiftVault and ScheduledGifts.
abstract contract ConversionBase is ProtocolBase {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @notice Hard cap on any slippage tolerance a sender can choose (10%).
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;
    /// @notice Hard cap on the protocol fee (2%).
    uint16 public constant MAX_FEE_BPS = 200;

    IOracleAdapter public oracle;
    IDexAdapter public dex;
    IFeeCollector public feeCollector;
    IProjectTokenHooks public tokenHooks;
    uint16 public feeBps;

    /// @notice Tokens that may be deposited into gifts (stablecoins + curated stocks).
    mapping(address => bool) public isDepositToken;
    /// @notice Curated stock tokens a gift may convert into.
    mapping(address => bool) public isCurated;

    event OracleUpdated(address indexed oracle);
    event DexUpdated(address indexed dex);
    event FeeConfigUpdated(address indexed feeCollector, address indexed tokenHooks, uint16 feeBps);
    event DepositTokenSet(address indexed token, bool allowed);
    event CuratedTokenSet(address indexed token, bool allowed);
    event FeeCharged(address indexed payer, address indexed token, uint256 fee);
    event Converted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error TokenNotAllowed(address token);
    error SlippageTooHigh();
    error FeeTooHigh();
    error Expired();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error BadRecipient();
    error FeeOnTransferUnsupported();

    constructor(address admin, address guardian) ProtocolBase(admin, guardian) {}

    // ------------------------------------------------------------------ admin

    function setOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IOracleAdapter(oracle_);
        emit OracleUpdated(oracle_);
    }

    function setDex(address dex_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (dex_ == address(0)) revert ZeroAddress();
        dex = IDexAdapter(dex_);
        emit DexUpdated(dex_);
    }

    function setFeeConfig(address feeCollector_, address tokenHooks_, uint16 feeBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeBps_ != 0 && feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = IFeeCollector(feeCollector_);
        tokenHooks = IProjectTokenHooks(tokenHooks_);
        feeBps = feeBps_;
        emit FeeConfigUpdated(feeCollector_, tokenHooks_, feeBps_);
    }

    function setDepositToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isDepositToken[token] = allowed;
        emit DepositTokenSet(token, allowed);
    }

    function setCurated(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isCurated[token] = allowed;
        emit CuratedTokenSet(token, allowed);
    }

    // --------------------------------------------------------------- internal

    /// @dev Protocol fee owed by `payer` on `gross`. Zero for $GIFT tier holders.
    function _quoteFee(address payer, uint256 gross) internal view returns (uint256 fee) {
        if (feeBps != 0 && !_feeExempt(payer)) {
            fee = (gross * feeBps) / BPS;
        }
    }

    /// @dev Interactions half of a deposit (call after state is written): pulls `gross` from `from`,
    ///      rejects fee-on-transfer tokens and forwards `fee` to the FeeCollector.
    function _collect(address token, address from, uint256 gross, uint256 fee) internal {
        IERC20 t = IERC20(token);
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), gross);
        if (t.balanceOf(address(this)) - balBefore != gross) revert FeeOnTransferUnsupported();
        if (fee != 0) {
            IFeeCollector fc = feeCollector;
            t.safeTransfer(address(fc), fee);
            fc.notifyFee(token, fee);
            emit FeeCharged(from, token, fee);
        }
    }

    function _feeExempt(address account) internal view returns (bool) {
        IProjectTokenHooks h = tokenHooks;
        return address(h) != address(0) && h.isFeeExempt(account);
    }

    // Slither "reentrancy-balance" is a false positive here: the before/after delta IS the defence
    // against a lying adapter, and every caller of _deliver is nonReentrant.
    // slither-disable-start reentrancy-balance
    /// @dev Sends `amountIn` of `tokenIn` to `recipient`, converting into `tokenOut` when they differ.
    ///      The effective minimum output is max(caller min, oracle quote - maxSlippageBps).
    function _deliver(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline,
        uint16 maxSlippageBps,
        address recipient
    ) internal returns (uint256 amountOut) {
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        if (amountIn == 0) return 0;
        if (tokenOut == tokenIn) {
            IERC20(tokenIn).safeTransfer(recipient, amountIn);
            return amountIn;
        }

        uint256 floor = (oracle.quote(tokenIn, tokenOut, amountIn) * (BPS - maxSlippageBps)) / BPS;
        if (minAmountOut < floor) minAmountOut = floor;
        if (minAmountOut == 0) revert InsufficientOutput(0, 0);

        IDexAdapter d = dex;
        IERC20 out = IERC20(tokenOut);
        uint256 before = out.balanceOf(recipient);
        IERC20(tokenIn).forceApprove(address(d), amountIn);
        uint256 reported = d.swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut, deadline, recipient);
        IERC20(tokenIn).forceApprove(address(d), 0);
        // Trust the recipient's balance delta, not the adapter. All entrypoints are nonReentrant, so
        // the balance cannot be manipulated through re-entry between the two reads.
        amountOut = out.balanceOf(recipient) - before;
        if (amountOut < minAmountOut || amountOut < reported) revert InsufficientOutput(amountOut, minAmountOut);
        emit Converted(tokenIn, tokenOut, amountIn, amountOut);
    }
    // slither-disable-end reentrancy-balance
}
