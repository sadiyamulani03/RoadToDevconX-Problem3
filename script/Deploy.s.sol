// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HonkVerifier} from "../contracts/verifiers/OldEnoughVerifier.sol";
import {LateNightPass} from "../contracts/LateNightPass.sol";
import {IOldEnoughVerifier} from "../contracts/interfaces/IOldEnoughVerifier.sol";

contract Deploy is Script {
    function run() external returns (HonkVerifier verifier, LateNightPass pass) {
        vm.startBroadcast();
        verifier = new HonkVerifier();
        pass = new LateNightPass(IOldEnoughVerifier(address(verifier)));
        vm.stopBroadcast();

        console2.log("verifier", address(verifier));
        console2.log("lateNightPass", address(pass));

        string memory objectKey = "deployment";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "verifier", address(verifier));
        string memory json = vm.serializeAddress(objectKey, "pass", address(pass));
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
