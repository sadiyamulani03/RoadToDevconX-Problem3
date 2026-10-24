// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

abstract contract FixtureTest is Test {
    struct Fixture {
        address account;
        bytes proof;
        bytes32[] publicInputs;
        bytes32 nullifier;
        uint256 year;
        uint256 month;
        uint256 day;
        uint256 minimumAge;
    }

    function _load(string memory name) internal view returns (Fixture memory fixture) {
        string memory json = vm.readFile(string.concat("test/fixtures/", name, ".json"));
        fixture.account = vm.parseJsonAddress(json, ".context.account");
        fixture.proof = vm.parseJsonBytes(json, ".proof");
        fixture.publicInputs = vm.parseJsonBytes32Array(json, ".publicInputs");
        fixture.nullifier = vm.parseJsonBytes32(json, ".nullifier");
        fixture.year = vm.parseJsonUint(json, ".context.claimDate.year");
        fixture.month = vm.parseJsonUint(json, ".context.claimDate.month");
        fixture.day = vm.parseJsonUint(json, ".context.claimDate.day");
        fixture.minimumAge = vm.parseJsonUint(json, ".context.minimumAge");
    }
}
