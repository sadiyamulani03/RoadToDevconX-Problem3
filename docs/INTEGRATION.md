# Door-Partner and Issuer Integration

## Door partner (implemented interface)

`contracts/interfaces/ILateNightPass.sol` is the supported read-only interface:

- `hasPass(address)` — true after a successful claim.
- `currentClaimDate()` — the UTC Gregorian date the contract would use now.
- `MINIMUM_AGE()` — fixed at 18.
- `FESTIVAL_ID()` — the proof domain.
- `PassClaimed(account, nullifier, claimYear, claimMonth, claimDay)` — emitted
  only after verification.

Recommended flow:

1. Record the chain ID and the deployed pass address. Do not accept a pass
   address supplied by the attendee at the door.
2. On claim, index `PassClaimed`. Wait for the receipt/finality policy you use
   for other on-chain attendance credentials.
3. At the door, call `hasPass(account)` with a fresh `eth_call`, or read the
   finalized event. The pass is per account, not per person.
4. Show the claim date (from the event) if the venue needs to display it.
   Do not ask for or store a birth date; the contract never receives one.
5. The proof file is a public artifact and contains no birth date or secret.
   It is not needed at the door after the on-chain claim. If you verify it
   independently, verify it locally with:

   ```bash
   node client/claim.mjs verify --proof path/to/proof.json
   ```

   and check that the account/public inputs match your finality record. The
   on-chain verifier has already performed the authoritative verification.

### Sybil warning

A pass is unique per **address**, not per **person**. One person can create
multiple accounts and obtain multiple passes. If a venue needs one pass per
person, bind the pass to an external ticket/attendee credential at the door, or
add an issuer/attendee uniqueness layer. The ZK proof alone does not solve
personhood or ticket uniqueness.

## Issuer authenticity (not implemented)

The program is a privacy-preserving **age self-declaration** system. The circuit
proves that the private birth date in the witness is at least 18 years before
the claim date and is bound to the account, date, domain, and nullifier. It does
not prove that the birth date is authentic. A user can choose any date when
generating the witness.

A production identity deployment must add an issuer attestation, for example:

1. An issuer signs a credential over a commitment to the birth date (and,
   preferably, a holder key or address).
2. The circuit verifies the issuer signature/attestation and proves the
   birth date inside the signed payload.
3. The verifier key or a public input pins the trusted issuer key/root.
4. The credential is bound to the claimant's account or holder key so it cannot
   be transferred.
5. Revocation and credential expiry are defined.
6. The issuer does not learn or receive the claim transaction; the attestation
   is presented locally.

Adding an issuer registry or admin to `LateNightPass` would change the trust
model and is intentionally out of scope here. A fake or unverifiable issuer
interface would be worse than documenting the gap. Until a real attestation
layer exists, do not describe this system as government ID verification or use
it for regulated age-restricted sales.

## Contract properties relevant to integrators

- No owner, pause, mint, or administrative bypass.
- Verifier is immutable; the proof domain and minimum age are fixed.
- The claim date is derived from `block.timestamp` as UTC; the caller cannot
  choose it.
- The contract checks the account, date, minimum age, domain, and nullifier as
  public inputs; the proof is bound to all of them.
- A failed verification changes no state and consumes no nullifier.
- A successful claim sets `hasClaimed[account]` and
  `consumedNullifiers[nullifier]`; the event contains no personal data.
