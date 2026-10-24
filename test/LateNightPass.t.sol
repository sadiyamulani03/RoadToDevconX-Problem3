// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixtureTest} from "./FixtureTest.sol";
import {HonkVerifier} from "../contracts/verifiers/OldEnoughVerifier.sol";
import {LateNightPass} from "../contracts/LateNightPass.sol";
import {IOldEnoughVerifier} from "../contracts/interfaces/IOldEnoughVerifier.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {ReentrantVerifier} from "./mocks/ReentrantVerifier.sol";

contract LateNightPassTest is FixtureTest {
    event PassClaimed(
        address indexed account,
        bytes32 indexed nullifier,
        uint256 claimYear,
        uint256 claimMonth,
        uint256 claimDay
    );

    HonkVerifier internal verifier;
    LateNightPass internal pass;
    address internal alice;
    address internal bob;
    address internal carol;

    uint256 internal constant CLAIM_NOON = 1792843200;
    uint256 internal constant CLAIM_START = 1792800000;
    uint256 internal constant CLAIM_END = 1792886399;
    uint256 internal constant NEXT_MIDNIGHT = 1792886400;
    uint256 internal constant PREVIOUS_DAY_NOON = 1792756800;
    uint256 internal constant NEXT_DAY_NOON = 1792929600;
    uint256 internal constant LEAP_DAY_NOON = 1772366400;
    uint256 internal constant FEB_28_NOON = 1772280000;

    function setUp() public {
        verifier = new HonkVerifier();
        pass = new LateNightPass(IOldEnoughVerifier(address(verifier)));
        alice = _load("adult_alice").account;
        bob = _load("adult_bob").account;
        carol = _load("leap_carol").account;
        vm.warp(CLAIM_NOON);
    }

    function _claim(Fixture memory fixture, address account) internal {
        vm.prank(account);
        pass.claim(fixture.proof, fixture.nullifier);
    }

    function test_metadata() public view {
        assertEq(pass.MINIMUM_AGE(), 18);
        assertEq(pass.FESTIVAL_ID(), 0x4f4c44454e4f5547485f5631);
        assertEq(pass.PUBLIC_INPUT_COUNT(), 8);
    }

    function test_hasPassFalseInitially() public view {
        assertFalse(pass.hasPass(alice));
    }

    function test_adultCanClaim() public {
        Fixture memory fixture = _load("adult_alice");
        assertEq(fixture.account, alice);
        vm.expectEmit(true, true, false, true, address(pass));
        emit PassClaimed(alice, fixture.nullifier, fixture.year, fixture.month, fixture.day);
        _claim(fixture, alice);
        assertTrue(pass.hasPass(alice));
        assertTrue(pass.hasClaimed(alice));
        assertTrue(pass.consumedNullifiers(fixture.nullifier));
    }

    function test_contractPassesExactCircuitPublicInputs() public {
        Fixture memory fixture = _load("adult_alice");
        vm.expectCall(address(verifier), abi.encodeCall(IOldEnoughVerifier.verify, (fixture.proof, fixture.publicInputs)));
        _claim(fixture, alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_bobCanClaim() public {
        Fixture memory fixture = _load("adult_bob");
        assertEq(fixture.account, bob);
        _claim(fixture, bob);
        assertTrue(pass.hasPass(bob));
    }

    function test_secondClaimReverts() public {
        Fixture memory fixture = _load("adult_alice");
        _claim(fixture, alice);
        vm.prank(alice);
        vm.expectRevert(LateNightPass.AlreadyClaimed.selector);
        pass.claim(fixture.proof, fixture.nullifier);
    }

    function test_copiedProofRejectedForDifferentAccount() public {
        Fixture memory fixture = _load("adult_alice");
        vm.prank(bob);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(bob));
        assertFalse(pass.consumedNullifiers(fixture.nullifier));
    }

    function test_staleProofAcceptedOnOriginalDate() public {
        vm.warp(PREVIOUS_DAY_NOON);
        Fixture memory fixture = _load("stale_alice");
        assertEq(fixture.account, alice);
        _claim(fixture, alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_staleProofRejectedNextDay() public {
        Fixture memory fixture = _load("stale_alice");
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
        assertFalse(pass.consumedNullifiers(fixture.nullifier));
    }

    function test_futureProofRejectedCurrently() public {
        Fixture memory fixture = _load("future_alice");
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
    }

    function test_futureProofAcceptedOnItsDate() public {
        vm.warp(NEXT_DAY_NOON);
        Fixture memory fixture = _load("future_alice");
        _claim(fixture, alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_dayBefore18thBirthdayContextRejected() public {
        vm.warp(PREVIOUS_DAY_NOON);
        Fixture memory fixture = _load("adult_alice");
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
        assertFalse(pass.consumedNullifiers(fixture.nullifier));
    }

    function test_wrongMinimumAgeProofRejected() public {
        Fixture memory fixture = _load("wrong_min_age_alice");
        assertEq(fixture.minimumAge, 21);
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
    }

    function test_leapDayProofAcceptedOnMarch1() public {
        vm.warp(LEAP_DAY_NOON);
        Fixture memory fixture = _load("leap_carol");
        assertEq(fixture.account, carol);
        _claim(fixture, carol);
        assertTrue(pass.hasPass(carol));
    }

    function test_leapDayProofRejectedOnFeb28() public {
        vm.warp(FEB_28_NOON);
        Fixture memory fixture = _load("leap_carol");
        vm.prank(carol);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(carol));
    }

    function test_claimAtStartOfDay() public {
        vm.warp(CLAIM_START);
        _claim(_load("adult_alice"), alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_claimAtEndOfDay() public {
        vm.warp(CLAIM_END);
        _claim(_load("adult_alice"), alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_claimAtNextMidnightRejected() public {
        vm.warp(NEXT_MIDNIGHT);
        Fixture memory fixture = _load("adult_alice");
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(fixture.proof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
    }

    function test_failedProofDoesNotConsumeNullifier() public {
        Fixture memory fixture = _load("adult_alice");
        bytes memory badProof = new bytes(16);
        vm.prank(alice);
        vm.expectRevert();
        pass.claim(badProof, fixture.nullifier);
        assertFalse(pass.hasPass(alice));
        assertFalse(pass.consumedNullifiers(fixture.nullifier));
        _claim(fixture, alice);
        assertTrue(pass.hasPass(alice));
    }

    function test_emptyProofRejected() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        vm.prank(alice);
        vm.expectRevert(LateNightPass.EmptyProof.selector);
        mockPass.claim("", bytes32(uint256(1)));
    }

    function test_zeroNullifierRejected() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        vm.prank(alice);
        vm.expectRevert(LateNightPass.InvalidNullifier.selector);
        mockPass.claim(hex"01", bytes32(0));
    }

    function test_nonCanonicalNullifierRejected() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        bytes32 nonCanonical = bytes32(mockPass.BN254_SCALAR_MODULUS());
        vm.prank(alice);
        vm.expectRevert(LateNightPass.InvalidNullifier.selector);
        mockPass.claim(hex"01", nonCanonical);
    }

    function test_nullifierReplayAcrossAccountsRejected() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        bytes32 nullifierOne = bytes32(uint256(0x1111));
        bytes32 nullifierTwo = bytes32(uint256(0x2222));
        vm.prank(alice);
        mockPass.claim(hex"01", nullifierOne);
        vm.prank(bob);
        vm.expectRevert(LateNightPass.NullifierAlreadyUsed.selector);
        mockPass.claim(hex"01", nullifierOne);
        vm.prank(bob);
        mockPass.claim(hex"01", nullifierTwo);
        assertTrue(mockPass.hasPass(alice));
        assertTrue(mockPass.hasPass(bob));
        assertTrue(mockPass.consumedNullifiers(nullifierOne));
        assertTrue(mockPass.consumedNullifiers(nullifierTwo));
    }

    function test_verifierFalseRejectsAndPreservesState() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        mock.setResult(false);
        bytes32 nullifier = bytes32(uint256(0x3333));
        vm.prank(alice);
        vm.expectRevert(LateNightPass.InvalidProof.selector);
        mockPass.claim(hex"01", nullifier);
        assertFalse(mockPass.hasPass(alice));
        assertFalse(mockPass.consumedNullifiers(nullifier));
    }

    function test_revertingVerifierRejectsAndPreservesState() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        mock.setShouldRevert(true);
        bytes32 nullifier = bytes32(uint256(0x4444));
        vm.prank(alice);
        vm.expectRevert("mock verifier reverted");
        mockPass.claim(hex"01", nullifier);
        assertFalse(mockPass.hasPass(alice));
        assertFalse(mockPass.consumedNullifiers(nullifier));
    }

    function test_reentrantVerifierBlocked() public {
        ReentrantVerifier reentrant = new ReentrantVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(reentrant)));
        bytes memory payload = abi.encodeCall(LateNightPass.claim, (bytes("inner"), bytes32(uint256(0x5555))));
        reentrant.configure(address(mockPass), payload);
        vm.prank(alice);
        vm.expectRevert(ReentrantVerifier.ReentryBlocked.selector);
        mockPass.claim(bytes("outer"), bytes32(uint256(0x6666)));
        assertFalse(mockPass.hasPass(alice));
        assertFalse(mockPass.consumedNullifiers(bytes32(uint256(0x5555))));
        assertFalse(mockPass.consumedNullifiers(bytes32(uint256(0x6666))));
    }

    function test_constructorRejectsEOA() public {
        vm.expectRevert(LateNightPass.InvalidVerifier.selector);
        new LateNightPass(IOldEnoughVerifier(address(0xBEEF)));
    }

    function test_full160BitAccountIsEncoded() public {
        MockVerifier mock = new MockVerifier();
        LateNightPass mockPass = new LateNightPass(IOldEnoughVerifier(address(mock)));
        address highAccount = 0x1234567890AbcdEF1234567890aBcdef12345678;
        bytes32 nullifier = bytes32(uint256(0x7777));
        bytes32[] memory expected = new bytes32[](8);
        expected[0] = bytes32(uint256(uint32(uint160(highAccount) >> 128)));
        expected[1] = bytes32(uint256(uint128(uint160(highAccount))));
        expected[2] = bytes32(uint256(2026));
        expected[3] = bytes32(uint256(10));
        expected[4] = bytes32(uint256(24));
        expected[5] = bytes32(uint256(18));
        expected[6] = bytes32(mockPass.FESTIVAL_ID());
        expected[7] = nullifier;
        assertTrue(expected[0] != bytes32(0));
        vm.expectCall(address(mock), abi.encodeCall(IOldEnoughVerifier.verify, (hex"01", expected)));
        vm.prank(highAccount);
        mockPass.claim(hex"01", nullifier);
        assertTrue(mockPass.hasPass(highAccount));
    }

    function test_noCallerSuppliedDateSelector() public {
        (bool ok,) = address(pass).call(
            abi.encodeWithSignature(
                "claim(bytes,uint256,uint256,uint256,bytes32)",
                bytes("x"),
                uint256(2026),
                uint256(10),
                uint256(24),
                bytes32(uint256(1))
            )
        );
        assertFalse(ok);
    }
}
