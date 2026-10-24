// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOldEnoughVerifier} from "./interfaces/IOldEnoughVerifier.sol";

/// @title Old Enough - late-night festival pass
/// @notice Verifies a locally generated Noir/UltraHonk proof that the caller is
///         at least 18 on the current UTC date, binds the proof to the caller's
///         address, and issues exactly one pass per account.
///
/// @dev Policy is contract-controlled:
///      * MINIMUM_AGE is a fixed constant passed to the verifier as a public
///        input; the prover cannot choose a different threshold.
///      * The reference date is derived from block.timestamp as a UTC Gregorian
///        calendar date; the claim function accepts no caller-supplied date.
///      * FESTIVAL_ID is a fixed constant passed as the domain public input.
///
///      Public input order (must match src/main.nr):
///        0 account_hi  uint32  top 32 bits of uint160(msg.sender)
///        1 account_lo  uint128 low 128 bits of uint160(msg.sender)
///        2 claim_year  uint32  UTC year derived from block.timestamp
///        3 claim_month uint8   UTC month derived from block.timestamp
///        4 claim_day   uint8   UTC day derived from block.timestamp
///        5 minimum_age uint8   MINIMUM_AGE (18)
///        6 domain      Field   FESTIVAL_ID
///        7 nullifier   Field   Poseidon2(account, date, minimum_age, domain, secret)
///
///      The birth date is never accepted by this contract and never appears in
///      calldata, storage, or events.
///
///      There is no owner, pause, mint, or administrative bypass. The verifier
///      is immutable. The only external call is a view call to the verifier, so
///      it executes as STATICCALL and cannot reenter state-changing functions.
contract LateNightPass {
    // ---------------------------------------------------------------------
    // Policy constants (contract-controlled; never caller-controlled)
    // ---------------------------------------------------------------------

    /// @notice Minimum age in whole years. Mirrored by the circuit's public
    ///         `minimum_age` input; the proof is verified against this value.
    uint256 public constant MINIMUM_AGE = 18;

    /// @notice ASCII "OLDENOUGH_V1" as a 96-bit field element. Mirrors the
    ///         circuit domain constant and binds proofs to this festival.
    uint256 public constant FESTIVAL_ID = 0x4f4c44454e4f5547485f5631;

    /// @notice Number of public inputs expected by the circuit/verifier.
    uint256 public constant PUBLIC_INPUT_COUNT = 8;

    /// @notice BN254 scalar field modulus. Public field elements must be
    ///         canonical; the generated verifier also checks this.
    uint256 public constant BN254_SCALAR_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // ---------------------------------------------------------------------
    // Immutable verifier
    // ---------------------------------------------------------------------

    IOldEnoughVerifier public immutable verifier;

    // ---------------------------------------------------------------------
    // Claim state
    // ---------------------------------------------------------------------

    /// @notice Whether an account has already claimed its one pass.
    mapping(address account => bool claimed) public hasClaimed;

    /// @notice Consumed nullifiers. Complementary to the per-account flag.
    mapping(bytes32 nullifier => bool used) public consumedNullifiers;

    // ---------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------

    /// @notice Emitted only after proof verification succeeds. Contains no
    ///         birth date or exact age.
    event PassClaimed(
        address indexed account,
        bytes32 indexed nullifier,
        uint256 claimYear,
        uint256 claimMonth,
        uint256 claimDay
    );

    error InvalidVerifier();
    error AlreadyClaimed();
    error NullifierAlreadyUsed();
    error InvalidNullifier();
    error EmptyProof();
    error InvalidProof();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param _verifier The Barretenberg-generated UltraHonk verifier. This must
    ///        be the verifier generated from the exact circuit in src/main.nr.
    constructor(IOldEnoughVerifier _verifier) {
        if (address(_verifier).code.length == 0) revert InvalidVerifier();
        verifier = _verifier;
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

    /// @notice Claim the one late-night pass for msg.sender.
    /// @dev The proof must be generated for:
    ///      * msg.sender encoded as account_hi (top 32 bits) and account_lo
    ///        (low 128 bits);
    ///      * the current UTC date derived from block.timestamp;
    ///      * MINIMUM_AGE;
    ///      * FESTIVAL_ID;
    ///      * the supplied nullifier.
    ///      A proof generated for another account, date, age policy, domain, or
    ///      nullifier will fail verification.
    /// @param proof UltraHonk proof bytes generated locally by the buyer.
    /// @param nullifier The circuit-bound nullifier public input.
    function claim(bytes calldata proof, bytes32 nullifier) external {
        // Checks: replay defenses first, before any external call.
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (nullifier == bytes32(0)) revert InvalidNullifier();
        if (uint256(nullifier) >= BN254_SCALAR_MODULUS) revert InvalidNullifier();
        if (consumedNullifiers[nullifier]) revert NullifierAlreadyUsed();
        if (proof.length == 0) revert EmptyProof();

        // Contract-derived policy context. No caller-supplied date is accepted.
        (uint256 claimYear, uint256 claimMonth, uint256 claimDay) = _utcDate(block.timestamp);
        bytes32[] memory publicInputs = _expectedPublicInputs(msg.sender, claimYear, claimMonth, claimDay, nullifier);

        // Interaction: a view call, compiled as STATICCALL. A reverting or
        // returning-false verifier prevents all state changes below.
        if (!verifier.verify(proof, publicInputs)) revert InvalidProof();

        // Effects after successful verification.
        hasClaimed[msg.sender] = true;
        consumedNullifiers[nullifier] = true;

        emit PassClaimed(msg.sender, nullifier, claimYear, claimMonth, claimDay);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice True if the account has a claimed late-night pass.
    function hasPass(address account) external view returns (bool) {
        return hasClaimed[account];
    }

    /// @notice The UTC Gregorian claim date the contract would use right now.
    /// @dev Clients use this to generate a proof for the current claim context.
    ///      A proof for a different date will fail verification.
    function currentClaimDate() external view returns (uint256 year, uint256 month, uint256 day) {
        return _utcDate(block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Internal policy encoding
    // ---------------------------------------------------------------------

    /// @dev Builds exactly the public input array the circuit expects.
    function _expectedPublicInputs(
        address account,
        uint256 claimYear,
        uint256 claimMonth,
        uint256 claimDay,
        bytes32 nullifier
    ) internal pure returns (bytes32[] memory publicInputs) {
        uint160 encodedAccount = uint160(account);
        publicInputs = new bytes32[](PUBLIC_INPUT_COUNT);
        // Full 160-bit account: top 32 bits and low 128 bits. No truncation.
        publicInputs[0] = bytes32(uint256(uint32(encodedAccount >> 128)));
        publicInputs[1] = bytes32(uint256(uint128(encodedAccount)));
        publicInputs[2] = bytes32(claimYear);
        publicInputs[3] = bytes32(claimMonth);
        publicInputs[4] = bytes32(claimDay);
        publicInputs[5] = bytes32(MINIMUM_AGE);
        publicInputs[6] = bytes32(FESTIVAL_ID);
        publicInputs[7] = nullifier;
    }

    /// @dev Converts a Unix timestamp (seconds) to a UTC Gregorian date using
    ///      Howard Hinnant's civil-from-days algorithm. The epoch is
    ///      1970-01-01T00:00:00Z; days are floor(timestamp / 86400).
    ///
    ///      Leap years follow the Gregorian rule: every 4 years, except
    ///      centuries, except every 400 years. There is no local timezone.
    function _utcDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 dayOfEra = z - era * 146097; // [0, 146096]
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365; // [0, 399]
        uint256 y = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100); // [0, 365]
        uint256 monthPrime = (5 * dayOfYear + 2) / 153; // [0, 11]
        day = dayOfYear - (153 * monthPrime + 2) / 5 + 1; // [1, 31]
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9; // [1, 12]
        year = month <= 2 ? y + 1 : y;
    }
}
