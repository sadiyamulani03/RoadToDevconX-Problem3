// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOldEnoughVerifier} from "../../contracts/interfaces/IOldEnoughVerifier.sol";

contract MockVerifier is IOldEnoughVerifier {
    bool public result = true;
    bool public shouldRevert;

    function setResult(bool value) external {
        result = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        if (shouldRevert) revert("mock verifier reverted");
        return result;
    }
}
