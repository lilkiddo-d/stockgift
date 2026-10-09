// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IComplianceRegistry} from "../interfaces/IStockgift.sol";

/// @title ProtocolBase
/// @notice Shared admin surface: AccessControl (admin = Timelock), guardian pause, compliance hook.
abstract contract ProtocolBase is AccessControl, Pausable, ReentrancyGuard {
    /// @notice Can pause/unpause instantly. Intended for a monitoring multisig.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Optional allowlist hook; address(0) = no gating.
    IComplianceRegistry public compliance;

    event ComplianceUpdated(address indexed registry);

    error ZeroAddress();
    error NotAllowed(address account);

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice Set or clear (address(0)) the compliance registry.
    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceUpdated(registry);
    }

    function _checkAllowed(address account) internal view {
        IComplianceRegistry c = compliance;
        if (address(c) != address(0) && !c.isAllowed(account)) revert NotAllowed(account);
    }
}
