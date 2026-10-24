# Old Enough — Late Night Pass

A privacy-preserving age check for a one-time late-night pass. The claimant
generates an UltraHonk zero-knowledge proof locally, proving that their birth
date makes them at least 18 on the contract's current UTC date, bound to their
Ethereum account and a one-time nullifier. The Solidity contract verifies the
proof and stores only a claimed flag and consumed nullifiers.

> **Security boundary — read this first.** This is age *self-declaration*, not
> government ID verification. The circuit proves that the private birth date in
> the witness is at least 18 years before the claim date. It does **not** prove
> that the birth date is true or issued by a trusted authority. A user can
> generate a proof with any birth date they choose. Do not describe this system
> as identity verification or use it for regulated age-restricted sales without
> an issuer attestation layer. See [docs/INTEGRATION.md](docs/INTEGRATION.md).

## What is proven

- The claimant knows a birth date and nullifier secret satisfying the circuit.
- The birth date is at least the contract-controlled minimum age (18) on the
  contract's current UTC date.
- The proof is bound to the claimant's full 160-bit account, the claim date, the
  policy, the festival domain, and the nullifier.
- A given account can claim once, and a nullifier cannot be reused by any
  account.
- The birth date and exact age are never accepted by the contract, stored, or
  emitted in an event.

## What is not proven

- That the birth date is authentic or government-issued.
- That the claimant is a unique person (one pass per address, not per person).
- That the claimant's device or key is uncompromised.

## Architecture

```text
birth date + secret
        │  local witness (never leaves the device)
        ▼
   Noir circuit  ──UltraHonk proof──►  LateNightPass.claim(proof, nullifier)
        │                                      │
        │ public inputs:                       ├─ generated HonkVerifier (immutable)
        │ account, UTC date, min age,          ├─ hasClaimed[account] = true
        │ domain, nullifier                    └─ consumedNullifiers[nullifier] = true
        ▼
  proof.json (public proof data only)
```

- `src/main.nr` — Noir circuit, Poseidon2 nullifier, date/age/leap-year policy.
- `contracts/LateNightPass.sol` — claim contract; policy constants, UTC date,
  replay defenses, reentrancy-safe verifier call.
- `contracts/verifiers/OldEnoughVerifier.sol` — Barretenberg-generated
  UltraHonk verifier (`HonkVerifier`).
- `client/` — local proving/verifying CLI built on `@noir-lang/noir_js` and
  `@aztec/bb.js`; viem is used only for chain reads/writes.
- `test/` — Noir/Fixture-based Foundry tests, date-policy tests, real-verifier
  binding tests, mocks.
- `scripts/` — circuit build, fixture generation, full test runner, security
  audit, local end-to-end run.

## Repository layout

```text
Nargo.toml
src/main.nr
contracts/LateNightPass.sol
contracts/interfaces/{IOldEnoughVerifier,ILateNightPass}.sol
contracts/verifiers/OldEnoughVerifier.sol
client/{claim.mjs,lib,test,package.json,package-lock.json}
script/Deploy.s.sol
scripts/{build_circuit,e2e_local,generate_fixtures,security_audit,test_all,test_underage}.{sh,mjs}
test/{LateNightPass,DatePolicy,VerifierBinding,VerifierSmoke,FixtureTest}.t.sol
test/fixtures/*.json
docs/{ACCEPTANCE_MATRIX,INTEGRATION}.md
```

## Requirements

- Node.js 22 and npm 10.
- `nargo 1.0.0-rc.5` and `bb 5.2.1` (the client pins the matching JS packages).
- Foundry 1.8.1 with Solidity 0.8.27.
- Bash, Python 3, and a local Anvil for the end-to-end script.

No server, database, or external proving service is required. The end-to-end
script uses a local Anvil instance only.

## Build and test

```bash
# Noir circuit, EVM verification key, and generated Solidity verifier
./scripts/build_circuit.sh

# Solidity compile
forge build

# Client dependencies and unit tests
cd client
npm ci
npm test
cd ..

# Everything: Noir, Foundry, client, local proof verification, underage
# rejection, and the security audit
./scripts/test_all.sh
```

Expected current results:

- `nargo test`: 22 passed.
- `forge test`: 47 passed (29 contract behavior, 8 date policy, 9 verifier
  binding, 1 real-proof smoke).
- `cd client && npm test`: 9 passed.
- `node scripts/test_underage.mjs`: underage witness rejected; no proof produced.
- `./scripts/security_audit.sh`: no private-witness fields in fixtures; no key
  material; `npm audit` reports 0 vulnerabilities.

The generated verifier is included in the repository. `scripts/build_circuit.sh` regenerates it;
use the pinned toolchain versions so the artifact, VK, verifier, and fixtures
stay in sync. If circuit constraints change, regenerate the synthetic fixtures
from a private spec and rerun the full suite. `scripts/generate_fixtures.mjs
--spec <path-outside-the-repo>` never commits a birth date.

## Deploy locally

```bash
anvil --port 8546
# In another terminal, using an Anvil development key:
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8546 \
  --private-key "$ANVIL_DEV_KEY" \
  --broadcast
python3 -c "import json; print(json.load(open('deployments/31337.json')))"
```

The deployment JSON contains `chainId`, `verifier`, and `pass`:

```json
{"chainId": 31337, "verifier": "0x...", "pass": "0x..."}
```

`deployments/*.json` is local state and is git-ignored; the directory is kept
with `.gitkeep`. The one-command local demonstration is:

```bash
./scripts/e2e_local.sh
```

It starts Anvil on port 8546, extracts the first development key from Anvil's
own log (no hard-coded key), deploys, generates and submits a claim with a
synthetic local-only birth date stored in a mode-600 temp file, checks the event
and `hasPass`, checks the proof file for the birth date, and verifies that a
replay is rejected.

## Client usage

Use a mode-600 file or stdin for the birth date. `--birth-date` is a convenience
for local testing and may be retained in shell history.

```bash
PASS="$(python3 -c "import json; print(json.load(open('deployments/31337.json'))['pass'])")"
RPC="http://127.0.0.1:8546"

# 1. Read the contract's current UTC date and policy (network read).
node client/claim.mjs context \
  --rpc-url "$RPC" --contract "$PASS" \
  --account "$ACCOUNT" --out context.json

# 2. Read the birth date from a mode-600 file and prove locally.
#    Replace YYYY-MM-DD with the claimant's date; do not commit it.
printf '%s\n' 'YYYY-MM-DD' > /tmp/dob
chmod 600 /tmp/dob
node client/claim.mjs prove \
  --context context.json --birth-date-file /tmp/dob --out proof.json

# 3. Verify the saved proof locally, with no network access.
node client/claim.mjs verify --proof proof.json

# 4. Submit the saved proof using a mode-600 private key file.
node client/claim.mjs submit \
  --rpc-url "$RPC" --contract "$PASS" --proof proof.json \
  --private-key-file /tmp/key

# Or run context + prove + submit in one command.
node client/claim.mjs claim \
  --rpc-url "$RPC" --contract "$PASS" --account "$ACCOUNT" \
  --birth-date-file /tmp/dob --private-key-file /tmp/key --out proof.json
```

The CLI also supports `--birth-date-stdin` and `--no-wait`. `RPC_URL`,
`CONTRACT_ADDRESS`, `ACCOUNT`, and `PRIVATE_KEY` are fallbacks when the
corresponding options are omitted. Prefer a key file; never commit a funded key
or a filled `.env`.

### Public inputs

The circuit has exactly eight public inputs. The client encodes each as a
32-byte big-endian field element; the contract builds the same array from
`msg.sender`, `block.timestamp`, its constants, and the supplied nullifier.

| Index | Name | Type | Meaning |
|-------|------|------|---------|
| 0 | `account_hi` | `u32` | top 32 bits of `uint160(msg.sender)` |
| 1 | `account_lo` | `u128` | low 128 bits of `uint160(msg.sender)` |
| 2 | `claim_year` | `u32` | UTC year derived from `block.timestamp` |
| 3 | `claim_month` | `u8` | UTC month |
| 4 | `claim_day` | `u8` | UTC day |
| 5 | `minimum_age` | `u8` | contract constant `18` |
| 6 | `domain` | `Field` | `FESTIVAL_ID = 0x4f4c44454e4f5547485f5631` (ASCII `OLDENOUGH_V1`) |
| 7 | `nullifier` | `Field` | Poseidon2 of account, date, minimum age, domain, and secret |

The generated verifier reports `NUMBER_OF_PUBLIC_INPUTS = 16` and
`PAIRING_POINTS_SIZE = 8`; callers supply the eight circuit inputs, and the
verifier manages the eight pairing-point slots internally. `LateNightPass`
passes exactly eight, and tests assert the exact array and order.

### Proof file

`proof.json` contains the proof, the eight public inputs, the nullifier, the
public context (account, chain/contract when present, claim date, minimum age,
domain), toolchain versions, and the circuit artifact SHA-256. It contains no
birth date and no nullifier secret. The client writes it mode 0600 by default;
it is still public proof data, so treat it as non-sensitive but do not publish a
claimant's account association casually.

## Contract policy

- **Minimum age:** fixed at `18` in the contract and passed as public input 5.
  The circuit's generic policy supports 1..150 for testing, but the client
  enforces 18 and the deployed contract always supplies 18.
- **Claim date:** derived from `block.timestamp` as a UTC Gregorian date using
  the Howard Hinnant civil-from-days algorithm. The claim function accepts no
  caller-supplied date.
- **Domain:** fixed `FESTIVAL_ID`, mirrored in the circuit; proofs for another
  domain fail.
- **Nullifier:** deterministic Poseidon2 over the account, claim date, minimum
  age, domain, and a private random secret. The secret is never transmitted.
- **Replay defenses:** `hasClaimed[account]` plus a global
  `consumedNullifiers[nullifier]`. Checks happen before the verifier call;
  effects happen only after successful verification.
- **No admin:** no owner, pause, mint, upgrade, or administrative bypass. The
  verifier is immutable. A policy change means deploying a new contract/domain.
- **Reentrancy:** the only external call is the verifier, typed as `view` and
  compiled as `STATICCALL`; a reentrant mock verifier is blocked and tested.
- **Date boundary:** a proof is valid only on its bound UTC date. The client
  reads `currentClaimDate` before proving; if the transaction is included on a
  different UTC date, verification fails and the transaction reverts.

Age comparison uses the full `(year, month, day)` tuple, so the exact 18th
birthday is accepted and the day before is rejected. A February 29 birth date is
treated as March 1 in non-leap years; leap-year rules, century rules, and the
contract's date algorithm are covered by tests.

## Privacy model

- Proving is local: `client/lib/prove.mjs` imports Noir/bb.js and filesystem
  code, not viem or network code. `prove` and `verify` make no RPC calls.
- `context` and `submit` use the RPC. `submit` sends only the proof, public
  inputs, nullifier, and account transaction. It never sends the birth date,
  witness, or secret.
- The contract never receives the birth date; it is not in calldata, storage, or
  events. Events contain only the account, nullifier, and claim date.
- The RPC and chain observers can see the claimant's account, timing, and public
  proof context, but not the birth date. Chain data is public.
- The proof file is public proof data; the birth date is not in it. The e2e
  script explicitly greps the generated proof file for the synthetic date and
  private-witness field names.
- The client writes proof/context files mode 0600 and never logs the birth date.
  `--birth-date` may be retained in shell history; prefer a mode-600 file or
  stdin.

## Security model and limitations

- **Issuer authenticity is absent (critical).** A user can choose an adult birth
  date. The proof is only as meaningful as the input date. See
  [docs/INTEGRATION.md](docs/INTEGRATION.md) for the required attestation layer.
- **Sybil resistance is per address.** One person can use multiple accounts.
  Bind to a ticket/attendee credential or issuer uniqueness if one pass per
  person is required.
- **Device and key compromise.** A compromised machine can leak the birth date
  or key. The client cannot protect a compromised host.
- **Timestamp edge cases.** The date is `block.timestamp` UTC. A transaction
  crossing midnight reverts; miner timestamp manipulation is bounded by consensus
  rules and cannot move the date arbitrarily. The proof cannot be reused on a
  different date.
- **No revocation or upgrade.** The verifier and policy are immutable. Revoking
  a pass or changing policy requires a new deployment.
- **Test suite, not a formal audit.** The tests cover the listed behaviors, but
  they are not a substitute for an independent security review of the circuit,
  generated verifier, client, and deployment.
- **The generated verifier is trusted code.** It is produced by the pinned
  Barretenberg toolchain; verify the VK/verifier correspondence when changing
  versions.
- **Public proof context.** The proof does not hide the account, claim date,
  minimum age, domain, or nullifier. It hides the birth date and secret.

## Tests and acceptance

- `./scripts/test_all.sh` — required checks (Noir, Foundry, client, local proof
  verification, underage rejection, security audit).
- `./scripts/e2e_local.sh` — Anvil deploy, claim, event/state checks, proof-file
  privacy grep, replay rejection.
- `./scripts/test_underage.mjs` — computes a synthetic underage date at runtime
  and asserts that witness generation fails and no proof is produced.
- `./scripts/security_audit.sh` — checks for environment/key files, 32-byte
  private-key literals in source, birth-date/secret fields in fixtures, and a
  non-empty `PRIVATE_KEY` in `.env.example`; runs `npm audit`.

See [docs/ACCEPTANCE_MATRIX.md](docs/ACCEPTANCE_MATRIX.md) for the ten required
checks and exact commands. The issuer-authenticity gap is listed explicitly
there as a non-goal of the current design.

## Door partners

Use `ILateNightPass.hasPass(address)` or index `PassClaimed`; see
[docs/INTEGRATION.md](docs/INTEGRATION.md). The interface returns no birth date
and no exact age.

## Repository hygiene

- `.env.example` has an empty `PRIVATE_KEY`; `.env`, key files, PEM files, and
  local deployment JSON are git-ignored.
- No private key is hard-coded. The e2e script reads a fresh Anvil development
  key from Anvil's log into a mode-600 temp file.
- `test/fixtures/*.json` are synthetic public proof fixtures; the fixture spec
  with birth dates lives outside the repository.
- `client/node_modules`, `target/`, `out/`, `cache/`, `broadcast/`, and
  `deployments/*.json` are ignored. `client/package-lock.json`,
  `lib/forge-std`, the generated verifier, and the fixtures are included in the repository.
