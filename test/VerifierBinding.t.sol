// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixtureTest} from "./FixtureTest.sol";
import {HonkVerifier} from "../contracts/verifiers/OldEnoughVerifier.sol";

contract VerifierBindingTest is FixtureTest {
    uint256 internal constant BN254_SCALAR_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    HonkVerifier internal verifier;

    function setUp() public {
        verifier = new HonkVerifier();
    }

    function _assertRejected(bytes memory proof, bytes32[] memory publicInputs) internal {
        try verifier.verify{gas: 10_000_000}(proof, publicInputs) returns (bool ok) {
            assertFalse(ok);
        } catch {}
    }

    function test_validProof() public {
        Fixture memory fixture = _load("adult_alice");
        assertEq(fixture.publicInputs.length, 8);
        assertEq(fixture.publicInputs[7], fixture.nullifier);
        assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
    }

    function test_allFixturesHaveValidProofs() public {
        string[6] memory names = [
            "adult_alice",
            "adult_bob",
            "stale_alice",
            "future_alice",
            "wrong_min_age_alice",
            "leap_carol"
        ];
        for (uint256 index = 0; index < names.length; index++) {
            Fixture memory fixture = _load(names[index]);
            assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
        }
    }

    function test_tamperedProofRejected() public {
        Fixture memory fixture = _load("adult_alice");
        bytes memory tampered = new bytes(fixture.proof.length);
        for (uint256 index = 0; index < tampered.length; index++) tampered[index] = fixture.proof[index];
        tampered[tampered.length - 1] ^= 0x01;
        _assertRejected(tampered, fixture.publicInputs);
        assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
    }

    function test_eachPublicInputIsBound() public {
        Fixture memory fixture = _load("adult_alice");
        for (uint256 index = 0; index < fixture.publicInputs.length; index++) {
            bytes32 original = fixture.publicInputs[index];
            fixture.publicInputs[index] = bytes32(uint256(original) + 1);
            _assertRejected(fixture.proof, fixture.publicInputs);
            fixture.publicInputs[index] = original;
        }
        assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
    }

    function test_wrongMinimumAgePublicInputRejected() public {
        Fixture memory fixture = _load("wrong_min_age_alice");
        bytes32 original = fixture.publicInputs[5];
        fixture.publicInputs[5] = bytes32(uint256(18));
        _assertRejected(fixture.proof, fixture.publicInputs);
        fixture.publicInputs[5] = original;
        assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
    }

    function test_wrongPublicInputCountRejected() public {
        Fixture memory fixture = _load("adult_alice");
        bytes32[] memory shortInputs = new bytes32[](7);
        for (uint256 index = 0; index < 7; index++) shortInputs[index] = fixture.publicInputs[index];
        _assertRejected(fixture.proof, shortInputs);
    }

    function test_nonCanonicalNullifierRejected() public {
        Fixture memory fixture = _load("adult_alice");
        bytes32 original = fixture.publicInputs[7];
        fixture.publicInputs[7] = bytes32(BN254_SCALAR_MODULUS);
        _assertRejected(fixture.proof, fixture.publicInputs);
        fixture.publicInputs[7] = original;
        assertTrue(verifier.verify(fixture.proof, fixture.publicInputs));
    }

    function test_emptyProofRejected() public {
        Fixture memory fixture = _load("adult_alice");
        _assertRejected(hex"", fixture.publicInputs);
    }

    function test_truncatedProofRejected() public {
        Fixture memory fixture = _load("adult_alice");
        bytes memory truncated = new bytes(fixture.proof.length - 1);
        for (uint256 index = 0; index < truncated.length; index++) truncated[index] = fixture.proof[index];
        _assertRejected(truncated, fixture.publicInputs);
    }
}
