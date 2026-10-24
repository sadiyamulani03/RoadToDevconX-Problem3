// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HonkVerifier} from "../contracts/verifiers/OldEnoughVerifier.sol";

contract VerifierSmokeTest is Test {
    function test_generatedVerifierAcceptsRealProof() public {
        HonkVerifier verifier = new HonkVerifier();
        bytes memory proof = vm.parseJsonBytes(vm.readFile("test/fixtures/smoke.json"), ".proof");
        bytes32[] memory publicInputs = vm.parseJsonBytes32Array(vm.readFile("test/fixtures/smoke.json"), ".publicInputs");
        assertEq(publicInputs.length, 8);
        assertTrue(verifier.verify(proof, publicInputs));
    }
}
