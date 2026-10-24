# Acceptance Matrix

All commands run from the repository root. `./scripts/test_all.sh` runs the Noir,
Foundry, client, local-verification, underage, and security checks below (except
the Anvil end-to-end run). `./scripts/e2e_local.sh` runs the full local claim.

Observed results on the current tree:

- `nargo test`: **22 passed**
- `forge test`: **47 passed** (29 contract behavior, 8 date policy, 9 verifier binding, 1 real-proof smoke)
- `cd client && npm test`: **9 passed**
- `node scripts/test_underage.mjs`: **underage witness rejected; no proof produced**
- `./scripts/security_audit.sh`: **passed; no private-witness fields in fixtures; `npm audit` 0 vulnerabilities**
- `./scripts/e2e_local.sh`: **claim succeeded; `PassClaimed` emitted; replay rejected**

| # | Requirement | How it is checked | Result |
|---|-------------|-------------------|--------|
| 1 | A valid adult proof can claim and emits the event | `forge test --match-test test_adultCanClaim`; `forge test --match-test test_contractPassesExactCircuitPublicInputs`; `./scripts/e2e_local.sh` | Pass |
| 2 | An underage claimant cannot produce a proof | `nargo test rejects_underage_claimant`; `node scripts/test_underage.mjs`; `forge test --match-test test_dayBefore18thBirthdayContextRejected` | Pass: witness generation fails; no proof is written |
| 3 | Exactly the 18th birthday is accepted; one day before is rejected | `nargo test accepts_adult_on_exact_18th_birthday`; `nargo test rejects_one_day_before_18th_birthday` | Pass |
| 4 | Leap-day policy is correct | `nargo test accepts_leap_day_birth_on_march_1`; `nargo test rejects_leap_day_birth_on_feb_28`; `forge test --match-test test_leapDay`; `forge test --match-test test_leapDayCarolsClaimDate` | Pass |
| 5 | One pass per account; a proof/nullifier cannot be replayed | `forge test --match-test "test_secondClaimReverts|test_copiedProofRejectedForDifferentAccount|test_nullifierReplayAcrossAccountsRejected"`; replay step in `./scripts/e2e_local.sh` | Pass |
| 6 | Stale and future proofs are rejected outside their claim date | `forge test --match-test "test_staleProof|test_futureProof"` | Pass |
| 7 | Wrong domain or wrong minimum-age public input is rejected | `nargo test rejects_wrong_domain`; `forge test --match-test "test_wrongMinimumAgeProofRejected|test_wrongMinimumAgePublicInputRejected"`; `forge test --match-test test_eachPublicInputIsBound` | Pass |
| 8 | Tampered, empty, truncated, or malformed proofs are rejected without state changes | `forge test --match-test "test_tamperedProofRejected|test_truncatedProofRejected|test_emptyProofRejected|test_wrongPublicInputCountRejected|test_verifierFalseRejectsAndPreservesState|test_revertingVerifierRejectsAndPreservesState"` | Pass |
| 9 | The account is bound over all 160 bits; the caller cannot choose the claim date | `forge test --match-test test_full160BitAccountIsEncoded`; `forge test --match-test test_copiedProofRejectedForDifferentAccount`; `forge test --match-test test_noCallerSuppliedDateSelector`; `forge test --match-test test_contractPassesExactCircuitPublicInputs` | Pass |
| 10 | The birth date and nullifier secret do not appear on chain or in the proof file | `cd client && npm test` (fixture contains public data only; `readProofFile` agrees with metadata); `node client/claim.mjs verify --proof test/fixtures/adult_alice.json`; `./scripts/security_audit.sh`; privacy grep in `./scripts/e2e_local.sh` | Pass |

## Explicit non-goal: issuer authenticity

The checks above prove that *the birth date in the witness* is internally
consistent and satisfies the age/domain/date/account policy. They do **not**
prove that the birth date is true or issued by a government or trusted issuer.
A user can generate a proof with any birth date they choose. This is a
fundamental trust-boundary limitation of the current self-declaration design,
not a failure of the ZK binding. A production identity deployment requires an
issuer attestation layer; see [INTEGRATION.md](INTEGRATION.md).
