// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IGiftVault} from "./interfaces/IStockgift.sol";

/// @title ClaimVerifier
/// @notice EIP-712 claim authorisation for link gifts.
/// @dev A claim link carries a one-time secret: an ephemeral secp256k1 key generated in the
///      sender's browser. The vault stores only the key's address (the keccak hash of its public key),
///      never the secret. To claim, the recipient's browser signs a `Claim` that binds the gift id, the
///      recipient address, the output token, minimum output, relayer and relayer fee and a deadline.
///      Because the recipient is inside the signed payload, a mempool observer who copies the
///      signature cannot redirect the funds; because the gift id and this contract's domain
///      (chainId + address) are signed, the signature cannot be replayed on another gift or chain; and
///      because a gift transitions to Claimed exactly once, it cannot be replayed on the same gift.
abstract contract ClaimVerifier is EIP712 {
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 giftId,address recipient,address tokenOut,uint256 minAmountOut,address relayer,uint256 relayerFee,uint256 deadline)"
    );

    constructor() EIP712("Stockgift", "1") {}

    /// @notice EIP-712 digest a claim key must sign.
    function hashClaim(uint256 giftId, IGiftVault.ClaimParams calldata c) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CLAIM_TYPEHASH,
                    giftId,
                    c.recipient,
                    c.tokenOut,
                    c.minAmountOut,
                    c.relayer,
                    c.relayerFee,
                    c.deadline
                )
            )
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Supports EOAs (ECDSA, low-s enforced by OZ) and ERC-1271 smart accounts.
    function _isValidClaimSignature(address claimKey, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        return SignatureChecker.isValidSignatureNow(claimKey, digest, signature);
    }
}
