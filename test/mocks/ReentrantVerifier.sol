// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LateNightPass} from "../../contracts/LateNightPass.sol";
import {IOldEnoughVerifier} from "../../contracts/interfaces/IOldEnoughVerifier.sol";

contract ReentrantVerifier is IOldEnoughVerifier {
    error ReentryBlocked();

    LateNightPass public target;
    bytes public payload;
    bool public configured;

    function configure(address target_, bytes calldata payload_) external {
        target = LateNightPass(target_);
        payload = payload_;
        configured = true;
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        if (!configured) return false;
        (bool ok,) = address(target).staticcall(payload);
        if (!ok) revert ReentryBlocked();
        return true;
    }
}
