// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal read-only interface for door-partner and venue integrations.
/// @dev A door partner should call `hasPass` after the claim transaction is
///      finalized, or index `PassClaimed`. The pass deliberately contains no
///      birth date, exact age, or other personal data.
interface ILateNightPass {
    /// @notice Emitted after a successful claim. Indexed fields are the account
    ///         and the circuit nullifier; the date is the contract's UTC claim
    ///         date, not a birth date.
    event PassClaimed(
        address indexed account,
        bytes32 indexed nullifier,
        uint256 claimYear,
        uint256 claimMonth,
        uint256 claimDay
    );

    /// @notice True if `account` has already claimed its one pass.
    function hasPass(address account) external view returns (bool);

    /// @notice The UTC Gregorian date the contract would use for a claim now.
    function currentClaimDate() external view returns (uint256 year, uint256 month, uint256 day);

    /// @notice Contract-controlled minimum age, fixed at 18.
    function MINIMUM_AGE() external view returns (uint256);

    /// @notice Contract-controlled proof domain.
    function FESTIVAL_ID() external view returns (uint256);
}
