// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "./interfaces/IStockgift.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist. Disabled by default (everyone allowed). When enabled, protocol
///         contracts gate gift creation, claims, contributions and schedule releases on it.
///         Remember to allowlist protocol contracts that act as senders (GroupPot).
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address => bool) public allowed;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);

    error BatchTooLarge();
    error ZeroAddress();

    constructor(address admin, address complianceOperator) {
        if (admin == address(0) || complianceOperator == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, complianceOperator);
    }

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setAllowed(address[] calldata accounts, bool isAllowed_) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]] = isAllowed_;
            emit AllowedSet(accounts[i], isAllowed_);
        }
    }

    /// @inheritdoc IComplianceRegistry
    function isAllowed(address account) external view returns (bool) {
        return !enabled || allowed[account];
    }
}
