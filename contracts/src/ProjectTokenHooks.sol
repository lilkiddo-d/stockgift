// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeCollector, IProjectTokenHooks} from "./interfaces/IStockgift.sol";

/// @title ProjectTokenHooks
/// @notice Feature gates for the project token ($GIFT). This protocol never deploys a token: the
///         token is launched separately and wired in once via `setProjectToken`, callable a single
///         time by the admin (the 48h Timelock). Until then every gate returns false and the protocol
///         runs without token features.
/// @dev Tier balance = $GIFT staked in the FeeCollector for at least `minStakeAge` (flash-loan
///      resistant). Optionally (`countWalletBalance`) the raw wallet balance is added too.
contract ProjectTokenHooks is AccessControl, IProjectTokenHooks {
    address public projectToken;
    IFeeCollector public feeCollector;

    uint256 public premiumThreshold;
    uint256 public feeFreeThreshold;
    uint32 public minStakeAge = 1 days;
    bool public countWalletBalance;

    event ProjectTokenSet(address indexed token);
    event FeeCollectorSet(address indexed feeCollector);
    event TiersSet(uint256 premiumThreshold, uint256 feeFreeThreshold, uint32 minStakeAge, bool countWalletBalance);

    error AlreadySet();
    error InvalidAddress();

    constructor(address admin, uint256 premiumThreshold_, uint256 feeFreeThreshold_) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        premiumThreshold = premiumThreshold_;
        feeFreeThreshold = feeFreeThreshold_;
        emit TiersSet(premiumThreshold_, feeFreeThreshold_, minStakeAge, false);
    }

    /// @notice One-time: wire the launchpad-deployed $GIFT token. Admin = Timelock.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (projectToken != address(0)) revert AlreadySet();
        if (token == address(0) || token.code.length == 0) revert InvalidAddress();
        projectToken = token;
        emit ProjectTokenSet(token);
    }

    /// @notice One-time: link the FeeCollector that holds stakes (done at deploy).
    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(feeCollector) != address(0)) revert AlreadySet();
        if (fc == address(0)) revert InvalidAddress();
        feeCollector = IFeeCollector(fc);
        emit FeeCollectorSet(fc);
    }

    function setTiers(uint256 premium, uint256 feeFree, uint32 minAge, bool countWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        premiumThreshold = premium;
        feeFreeThreshold = feeFree;
        minStakeAge = minAge;
        countWalletBalance = countWallet;
        emit TiersSet(premium, feeFree, minAge, countWallet);
    }

    /// @notice Balance that counts toward tiers. 0 while the token is unset.
    function tierBalance(address account) public view returns (uint256 bal) {
        address token = projectToken;
        IFeeCollector fc = feeCollector;
        if (token == address(0)) return 0;
        if (address(fc) != address(0)) {
            uint256 since = fc.stakedSince(account);
            if (since != 0 && block.timestamp >= since + minStakeAge) bal = fc.stakedBalance(account);
        }
        if (countWalletBalance) bal += IERC20(token).balanceOf(account);
    }

    /// @inheritdoc IProjectTokenHooks
    function isFeeExempt(address account) external view returns (bool) {
        return projectToken != address(0) && feeFreeThreshold != 0 && tierBalance(account) >= feeFreeThreshold;
    }

    /// @inheritdoc IProjectTokenHooks
    function hasPremium(address account) external view returns (bool) {
        return projectToken != address(0) && premiumThreshold != 0 && tierBalance(account) >= premiumThreshold;
    }
}
