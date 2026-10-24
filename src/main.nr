// Old Enough - late-night festival pass eligibility.
//
// The circuit proves, in zero knowledge:
//   * the private birth date is a valid Gregorian calendar date;
//   * the claimant has reached `minimum_age` on the public claim date,
//     using the rule "the Nth birthday has occurred on or before the claim date";
//   * the public claim context is complete and internally consistent;
//   * `nullifier` is the Poseidon2 hash of the claim context and a private secret.
//
// The birth date is never public and is never returned from main().
//
// Public input ABI order (this order is used by the Solidity claim contract and
// by the generated Barretenberg verifier):
//   0 account_hi  (top 32 bits of the 160-bit address)
//   1 account_lo  (low 128 bits of the 160-bit address)
//   2 claim_year
//   3 claim_month
//   4 claim_day
//   5 minimum_age
//   6 domain
//   7 nullifier
//
// Private inputs:
//   birth_year, birth_month, birth_day, nullifier_secret

// ASCII "OLDENOUGH_V1", a 96-bit value well below the BN254 scalar modulus.
global DOMAIN: Field = 0x4f4c44454e4f5547485f5631;

// Bounds the public minimum-age input. The festival contract always supplies 18.
global MINIMUM_AGE_LOWER_BOUND: u8 = 1;
global MINIMUM_AGE_UPPER_BOUND: u8 = 150;

fn is_leap_year(year: u32) -> bool {
    ((year % 4 == 0) & (year % 100 != 0)) | (year % 400 == 0)
}

fn days_in_month(year: u32, month: u32) -> u32 {
    if month == 2 {
        if is_leap_year(year) { 29 } else { 28 }
    } else if (month == 4) | (month == 6) | (month == 9) | (month == 11) {
        30
    } else {
        31
    }
}

// Enforces a real Gregorian date. February 29 is accepted only in leap years.
fn assert_valid_date(year: u32, month: u32, day: u32) {
    assert((year >= 1) & (year <= 9999), "year outside supported range");
    assert((month >= 1) & (month <= 12), "month outside supported range");
    assert(day >= 1, "day outside supported range");
    assert(day <= days_in_month(year, month), "day does not exist in this month");
}

// Poseidon2 sponge with rate 3 / capacity 1 (matching the standard library's
// Poseidon2Hasher for the 4-field BN254 state). Fixed eight-field absorption:
// two full rate-3 blocks, one tail block of two elements, length in the capacity.
fn poseidon2_hash8(input: [Field; 8]) -> Field {
    let mut state: [Field; 4] = [0; 4];
    // Domain-separating input-length initialisation vector: length << 64.
    state[3] = (8 as Field) * 18446744073709551616;
    state[0] += input[0];
    state[1] += input[1];
    state[2] += input[2];
    state = std::hash::poseidon2_permutation(state);

    state[0] += input[3];
    state[1] += input[4];
    state[2] += input[5];
    state = std::hash::poseidon2_permutation(state);

    state[0] += input[6];
    state[1] += input[7];
    std::hash::poseidon2_permutation(state)[0]
}

fn compute_nullifier(
    account_hi: u32,
    account_lo: u128,
    claim_year: u32,
    claim_month: u8,
    claim_day: u8,
    minimum_age: u8,
    domain: Field,
    nullifier_secret: Field,
) -> Field {
    poseidon2_hash8([
        account_hi as Field,
        account_lo as Field,
        claim_year as Field,
        claim_month as Field,
        claim_day as Field,
        minimum_age as Field,
        domain,
        nullifier_secret,
    ])
}

// The single constrained statement used by main() and by the Noir tests.
fn verify_claim(
    account_hi: u32,
    account_lo: u128,
    claim_year: u32,
    claim_month: u8,
    claim_day: u8,
    minimum_age: u8,
    domain: Field,
    nullifier: Field,
    birth_year: u32,
    birth_month: u8,
    birth_day: u8,
    nullifier_secret: Field,
) {
    assert(domain == DOMAIN, "wrong festival domain");
    assert(
        (minimum_age >= MINIMUM_AGE_LOWER_BOUND) & (minimum_age <= MINIMUM_AGE_UPPER_BOUND),
        "minimum age outside supported range",
    );
    assert(nullifier != 0, "nullifier must be non-zero");

    assert_valid_date(claim_year, claim_month as u32, claim_day as u32);
    assert_valid_date(birth_year, birth_month as u32, birth_day as u32);

    // Calendar-age rule: the (minimum_age)-th birthday has occurred on or
    // before the claim date. This is a full (year, month, day) comparison, not
    // a year-only comparison. For a February 29 birth date, the birthday is
    // treated as March 1 in years where February 29 does not exist (which is
    // always the case 18 years later, since 18 is not a multiple of 4).
    let birthday_year: u32 = birth_year + (minimum_age as u32);
    let later_year: bool = claim_year > birthday_year;
    let same_year: bool = claim_year == birthday_year;
    let later_month: bool = (claim_month as u32) > (birth_month as u32);
    let same_month: bool = claim_month == birth_month;
    let day_reached: bool = (claim_day as u32) >= (birth_day as u32);
    let birthday_reached: bool = later_month | (same_month & day_reached);
    assert(
        later_year | (same_year & birthday_reached),
        "claimant has not reached the required age",
    );

    let expected_nullifier = compute_nullifier(
        account_hi,
        account_lo,
        claim_year,
        claim_month,
        claim_day,
        minimum_age,
        domain,
        nullifier_secret,
    );
    assert(nullifier == expected_nullifier, "nullifier does not match claim context");
}

fn main(
    account_hi: pub u32,
    account_lo: pub u128,
    claim_year: pub u32,
    claim_month: pub u8,
    claim_day: pub u8,
    minimum_age: pub u8,
    domain: pub Field,
    nullifier: pub Field,
    birth_year: u32,
    birth_month: u8,
    birth_day: u8,
    nullifier_secret: Field,
) {
    verify_claim(
        account_hi,
        account_lo,
        claim_year,
        claim_month,
        claim_day,
        minimum_age,
        domain,
        nullifier,
        birth_year,
        birth_month,
        birth_day,
        nullifier_secret,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

global TEST_ACCOUNT_HI: u32 = 0x12345678;
global TEST_ACCOUNT_LO: u128 = 0x0fedcba987654321;
global TEST_SECRET: Field = 0x2a3b4c5d6e7f8091a2b3c4d5e6f70819;

fn test_nullifier(
    account_hi: u32,
    account_lo: u128,
    claim_year: u32,
    claim_month: u8,
    claim_day: u8,
    minimum_age: u8,
) -> Field {
    compute_nullifier(
        account_hi,
        account_lo,
        claim_year,
        claim_month,
        claim_day,
        minimum_age,
        DOMAIN,
        TEST_SECRET,
    )
}

#[test]
fn accepts_adult_on_exact_18th_birthday() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test]
fn accepts_adult_after_18th_birthday() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 25, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        25,
        18,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "claimant has not reached the required age")]
fn rejects_one_day_before_18th_birthday() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2008,
        10,
        25,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "claimant has not reached the required age")]
fn rejects_underage_claimant() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2010,
        1,
        1,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "claimant has not reached the required age")]
fn rejects_birth_date_after_claim_date() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2027,
        1,
        1,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "day does not exist in this month")]
fn rejects_impossible_birth_date_feb_29_non_leap() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2007,
        2,
        29,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "day does not exist in this month")]
fn rejects_impossible_claim_date_feb_29_non_leap() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 2, 29, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        2,
        29,
        18,
        DOMAIN,
        n,
        2000,
        1,
        1,
        TEST_SECRET,
    );
}

#[test]
fn accepts_leap_day_birth_on_march_1() {
    // Born 2004-02-29. Eighteen years later (2022) has no February 29, so the
    // documented rule treats the birthday as March 1.
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2022, 3, 1, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2022,
        3,
        1,
        18,
        DOMAIN,
        n,
        2004,
        2,
        29,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "claimant has not reached the required age")]
fn rejects_leap_day_birth_on_feb_28() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2022, 2, 28, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2022,
        2,
        28,
        18,
        DOMAIN,
        n,
        2004,
        2,
        29,
        TEST_SECRET,
    );
}

#[test]
fn accepts_leap_day_birth_on_later_feb_29() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2024, 2, 29, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2024,
        2,
        29,
        18,
        DOMAIN,
        n,
        2004,
        2,
        29,
        TEST_SECRET,
    );
}

#[test]
fn accepts_century_leap_day_2000() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2018, 3, 1, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2018,
        3,
        1,
        18,
        DOMAIN,
        n,
        2000,
        2,
        29,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "day does not exist in this month")]
fn rejects_non_leap_century_feb_29() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2018, 3, 1, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2018,
        3,
        1,
        18,
        DOMAIN,
        n,
        1900,
        2,
        29,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "day does not exist in this month")]
fn rejects_invalid_day_for_april() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2000,
        4,
        31,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "wrong festival domain")]
fn rejects_wrong_domain() {
    let wrong_domain = DOMAIN + 1;
    let n = compute_nullifier(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        wrong_domain,
        TEST_SECRET,
    );
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        wrong_domain,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "nullifier does not match claim context")]
fn rejects_tampered_nullifier() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n + 1,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "nullifier must be non-zero")]
fn rejects_zero_nullifier() {
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        0,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "nullifier does not match claim context")]
fn rejects_nullifier_bound_to_other_account() {
    let other_account_hi = TEST_ACCOUNT_HI + 1;
    let n = test_nullifier(other_account_hi, TEST_ACCOUNT_LO, 2026, 10, 24, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "nullifier does not match claim context")]
fn rejects_nullifier_bound_to_other_date() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 25, 18);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        18,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "minimum age outside supported range")]
fn rejects_minimum_age_zero() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 0);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        0,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "minimum age outside supported range")]
fn rejects_minimum_age_above_supported_range() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 151);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        151,
        DOMAIN,
        n,
        2008,
        10,
        24,
        TEST_SECRET,
    );
}

#[test]
fn accepts_21_policy_for_21_year_old() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 21);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        21,
        DOMAIN,
        n,
        2005,
        10,
        24,
        TEST_SECRET,
    );
}

#[test(should_fail_with = "claimant has not reached the required age")]
fn rejects_21_policy_for_20_year_old() {
    let n = test_nullifier(TEST_ACCOUNT_HI, TEST_ACCOUNT_LO, 2026, 10, 24, 21);
    verify_claim(
        TEST_ACCOUNT_HI,
        TEST_ACCOUNT_LO,
        2026,
        10,
        24,
        21,
        DOMAIN,
        n,
        2006,
        10,
        24,
        TEST_SECRET,
    );
}
