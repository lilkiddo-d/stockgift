// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolBase} from "./base/ProtocolBase.sol";
import {GiftVault} from "./GiftVault.sol";
import {IGiftVault} from "./interfaces/IStockgift.sol";

/// @title GroupPot
/// @notice Many people chip into one gift (birthday, wedding). The organizer creates the pot with the
///         claim-link key up front, shares a contribution link, and finally `finalize` moves the whole
///         pot into the GiftVault as a single link gift (one claim link for the recipient).
///         If the pot is cancelled before finalizing, or the resulting gift expires unclaimed / is
///         cancelled, every contributor withdraws their pro-rata share themselves (pull, no loops).
contract GroupPot is ProtocolBase {
    using SafeERC20 for IERC20;

    enum PotStatus {
        None,
        Open,
        Finalized,
        Cancelled,
        Refunded
    }

    struct Pot {
        address organizer;
        uint64 closesAt;
        uint64 claimWindow;
        uint16 maxSlippageBps;
        PotStatus status;
        bool recipientChooses;
        address token;
        address claimKey;
        address targetToken;
        uint256 total;
        uint256 giftId;
        uint256 refundPool;
    }

    uint64 public constant MAX_OPEN_DURATION = 365 days;
    uint64 public constant MIN_CLAIM_WINDOW = 1 days;
    uint64 public constant MAX_CLAIM_WINDOW = 3650 days;

    GiftVault public immutable vault;
    uint256 public nextPotId = 1;
    mapping(uint256 => Pot) internal _pots;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => string) public potTitle;

    event PotCreated(
        uint256 indexed potId,
        address indexed organizer,
        address indexed token,
        address targetToken,
        bool recipientChooses,
        uint64 closesAt,
        string title
    );
    event Contributed(uint256 indexed potId, address indexed contributor, uint256 amount, string message);
    event PotFinalized(uint256 indexed potId, uint256 indexed giftId, uint256 total);
    event PotCancelled(uint256 indexed potId);
    event PotRefunded(uint256 indexed potId, uint256 refundPool);
    event Withdrawn(uint256 indexed potId, address indexed contributor, uint256 amount);

    error InvalidParams();
    error NotOpen();
    error Unauthorized();
    error NothingToWithdraw();
    error NotRefundable();

    constructor(address admin, address guardian, address vault_) ProtocolBase(admin, guardian) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = GiftVault(vault_);
    }

    function createPot(
        address token,
        address claimKey,
        address targetToken,
        bool recipientChooses,
        uint16 maxSlippageBps,
        uint64 closesAt,
        uint64 claimWindow,
        string calldata title
    ) external nonReentrant whenNotPaused returns (uint256 potId) {
        _checkAllowed(msg.sender);
        if (!vault.isDepositToken(token) || claimKey == address(0)) revert InvalidParams();
        if (targetToken != address(0) && (!vault.isCurated(targetToken) || targetToken == token)) {
            revert InvalidParams();
        }
        if (maxSlippageBps > vault.MAX_SLIPPAGE_BPS()) revert InvalidParams();
        if (closesAt <= block.timestamp || closesAt > block.timestamp + MAX_OPEN_DURATION) revert InvalidParams();
        if (claimWindow < MIN_CLAIM_WINDOW || claimWindow > MAX_CLAIM_WINDOW) revert InvalidParams();
        if (bytes(title).length > 280) revert InvalidParams();

        potId = nextPotId++;
        _pots[potId] = Pot({
            organizer: msg.sender,
            closesAt: closesAt,
            claimWindow: claimWindow,
            maxSlippageBps: maxSlippageBps,
            status: PotStatus.Open,
            recipientChooses: recipientChooses,
            token: token,
            claimKey: claimKey,
            targetToken: targetToken,
            total: 0,
            giftId: 0,
            refundPool: 0
        });
        potTitle[potId] = title;
        emit PotCreated(potId, msg.sender, token, targetToken, recipientChooses, closesAt, title);
    }

    function contribute(uint256 potId, uint256 amount, string calldata message) external nonReentrant whenNotPaused {
        Pot storage p = _pots[potId];
        if (p.status != PotStatus.Open || block.timestamp >= p.closesAt) revert NotOpen();
        if (amount == 0 || bytes(message).length > 280) revert InvalidParams();
        _checkAllowed(msg.sender);

        contributions[potId][msg.sender] += amount;
        p.total += amount;
        emit Contributed(potId, msg.sender, amount, message);

        IERC20 t = IERC20(p.token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - before != amount) revert InvalidParams();
    }

    /// @notice Move the pot into the GiftVault as one link gift. Organizer any time; anyone after close.
    function finalize(uint256 potId) external nonReentrant whenNotPaused returns (uint256 giftId) {
        Pot storage p = _pots[potId];
        if (p.status != PotStatus.Open) revert NotOpen();
        if (msg.sender != p.organizer && block.timestamp < p.closesAt) revert Unauthorized();
        uint256 total = p.total;
        if (total == 0) revert InvalidParams();

        p.status = PotStatus.Finalized;
        uint256 expectedId = vault.nextGiftId();
        p.giftId = expectedId;
        emit PotFinalized(potId, expectedId, total);

        IERC20(p.token).forceApprove(address(vault), total);
        giftId = vault.createGift(
            IGiftVault.CreateParams({
                token: p.token,
                amount: total,
                claimKey: p.claimKey,
                expiry: uint64(block.timestamp) + p.claimWindow,
                targetToken: p.targetToken,
                recipientChooses: p.recipientChooses,
                maxSlippageBps: p.maxSlippageBps,
                card: false,
                cardRecipient: address(0),
                design: 0,
                message: potTitle[potId]
            })
        );
        if (giftId != expectedId) revert InvalidParams();
    }

    /// @notice Organizer cancels an open pot; contributors then withdraw in full.
    function cancelPot(uint256 potId) external nonReentrant whenNotPaused {
        Pot storage p = _pots[potId];
        if (msg.sender != p.organizer) revert Unauthorized();
        if (p.status != PotStatus.Open) revert NotOpen();
        p.status = PotStatus.Cancelled;
        p.refundPool = p.total;
        emit PotCancelled(potId);
    }

    /// @notice Organizer cancels the finalized (unclaimed) gift, e.g. the link leaked.
    function cancelGift(uint256 potId) external nonReentrant whenNotPaused {
        Pot storage p = _pots[potId];
        if (msg.sender != p.organizer) revert Unauthorized();
        if (p.status != PotStatus.Finalized) revert NotOpen();
        uint256 giftId = p.giftId;
        _markRefunded(potId, p);
        vault.cancel(giftId); // refunds exactly the recorded amount to this contract
    }

    /// @notice Organizer rotates the claim key (before or after finalizing).
    function rekey(uint256 potId, address newClaimKey) external nonReentrant whenNotPaused {
        Pot storage p = _pots[potId];
        if (msg.sender != p.organizer) revert Unauthorized();
        if (newClaimKey == address(0)) revert ZeroAddress();
        if (p.status == PotStatus.Open) {
            p.claimKey = newClaimKey;
        } else if (p.status == PotStatus.Finalized) {
            p.claimKey = newClaimKey;
            vault.rekey(p.giftId, newClaimKey);
        } else {
            revert NotOpen();
        }
    }

    /// @notice Record that the vault refunded this pot's gift (after expiry). Callable by anyone.
    function syncRefund(uint256 potId) external nonReentrant {
        Pot storage p = _pots[potId];
        if (p.status != PotStatus.Finalized || vault.giftStatus(p.giftId) != IGiftVault.Status.Refunded) {
            revert NotRefundable();
        }
        _markRefunded(potId, p);
    }

    /// @notice Contributor pulls their pro-rata share of a cancelled or refunded pot.
    function withdraw(uint256 potId) external nonReentrant {
        Pot storage p = _pots[potId];
        if (p.status != PotStatus.Cancelled && p.status != PotStatus.Refunded) revert NotRefundable();
        uint256 contributed = contributions[potId][msg.sender];
        if (contributed == 0) revert NothingToWithdraw();
        contributions[potId][msg.sender] = 0;
        uint256 amount = (contributed * p.refundPool) / p.total;
        emit Withdrawn(potId, msg.sender, amount);
        IERC20(p.token).safeTransfer(msg.sender, amount);
    }

    function _markRefunded(uint256 potId, Pot storage p) internal {
        uint256 refunded = vault.giftInfo(p.giftId).amount;
        p.status = PotStatus.Refunded;
        p.refundPool = refunded;
        emit PotRefunded(potId, refunded);
    }

    function getPot(uint256 potId) external view returns (Pot memory) {
        return _pots[potId];
    }
}
