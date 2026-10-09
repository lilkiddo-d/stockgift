// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Timelock
/// @notice Admin of every Stockgift contract. Enforces a minimum 48 hour delay on all admin actions.
///         Self-administered (no external admin): changing proposers/executors also goes through the delay.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY) revert DelayTooShort();
    }
}
