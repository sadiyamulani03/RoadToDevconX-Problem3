// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface implemented by the Barretenberg-generated UltraHonk verifier.
/// @dev The production claim contract is constructed with the generated
///      `HonkVerifier` (contracts/verifiers/OldEnoughVerifier.sol).
interface IOldEnoughVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
