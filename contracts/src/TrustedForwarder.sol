// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/// @title TrustedForwarder
/// @notice ERC-2771 forwarder used by the gasless-claim relayer. Users sign an EIP-712
///         ForwardRequest (with nonce + deadline); the relayer submits it and is repaid from the
///         gift via the `relayerFee` field the user signed inside the forwarded call.
/// @dev OpenZeppelin's implementation: per-signer nonces (replay protection), deadlines,
///      target must trust this forwarder, and `value` must match.
contract TrustedForwarder is ERC2771Forwarder {
    constructor() ERC2771Forwarder("Stockgift Forwarder") {}
}
