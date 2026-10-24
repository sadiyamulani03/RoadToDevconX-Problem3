// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LateNightPass} from "../contracts/LateNightPass.sol";
import {IOldEnoughVerifier} from "../contracts/interfaces/IOldEnoughVerifier.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

contract DatePolicyTest is Test {
    LateNightPass internal pass;

    function setUp() public {
        pass = new LateNightPass(IOldEnoughVerifier(address(new MockVerifier())));
    }

    function _assertDate(uint256 timestamp, uint256 expectedYear, uint256 expectedMonth, uint256 expectedDay) internal {
        vm.warp(timestamp);
        (uint256 year, uint256 month, uint256 day) = pass.currentClaimDate();
        assertEq(year, expectedYear);
        assertEq(month, expectedMonth);
        assertEq(day, expectedDay);
    }

    function test_epoch() public {
        _assertDate(0, 1970, 1, 1);
        _assertDate(86399, 1970, 1, 1);
        _assertDate(86400, 1970, 1, 2);
    }

    function test_leapYear2000() public {
        _assertDate(951696000, 2000, 2, 28);
        _assertDate(951782400, 2000, 2, 29);
        _assertDate(951868800, 2000, 3, 1);
    }

    function test_nonLeapYear2100() public {
        _assertDate(4107456000, 2100, 2, 28);
        _assertDate(4107542400, 2100, 3, 1);
    }

    function test_leapDay2024() public {
        _assertDate(1709164800, 2024, 2, 29);
        _assertDate(1709251200, 2024, 3, 1);
    }

    function test_februaryBoundary2026() public {
        _assertDate(1772323199, 2026, 2, 28);
        _assertDate(1772323200, 2026, 3, 1);
    }

    function test_claimDayBoundary2026() public {
        _assertDate(1792800000, 2026, 10, 24);
        _assertDate(1792843200, 2026, 10, 24);
        _assertDate(1792886399, 2026, 10, 24);
        _assertDate(1792886400, 2026, 10, 25);
    }

    function test_yearBoundary2099() public {
        _assertDate(4102444799, 2099, 12, 31);
        _assertDate(4102444800, 2100, 1, 1);
    }

    function test_leapDayCarolsClaimDate() public {
        _assertDate(1772280000, 2026, 2, 28);
        _assertDate(1772323200, 2026, 3, 1);
        _assertDate(1772366400, 2026, 3, 1);
    }
}
