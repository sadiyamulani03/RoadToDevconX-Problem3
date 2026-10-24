import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { readProofFile } from './proof_file.mjs';
import { Barretenberg, UltraHonkBackend } from '@aztec/bb.js';
import { Noir } from '@noir-lang/noir_js';
import {
  BN254_FR_MODULUS,
  DOMAIN,
  MINIMUM_AGE,
  addressToLimbs,
  bigintToBe32,
  buildPublicInputs,
  bytesToHex,
  fieldElementHex,
  fieldHex,
  hexToBytes,
  normalizeAddress,
  normalizeHex,
  parseCalendarDate,
  validateCalendarDate,
} from './policy.mjs';

function randomField() {
  for (;;) {
    const value = BigInt(bytesToHex(randomBytes(32)));
    if (value > 0n && value < BN254_FR_MODULUS) return value;
  }
}

function safeWitnessError(error) {
  const message = typeof error?.message === 'string' ? error.message : '';
  const prefix = 'Circuit execution failed: ';
  if (message.startsWith(prefix)) {
    const detail = message.slice(prefix.length).trim();
    if (detail.length > 0 && detail.length <= 240) {
      return new Error(`Witness generation failed: ${detail}`);
    }
  }
  return new Error('Witness generation failed: the circuit rejected the supplied private data.');
}

function asDate(input, label) {
  if (typeof input === 'string') return parseCalendarDate(input, label);
  if (input === null || typeof input !== 'object') throw new Error(`${label} must be a YYYY-MM-DD string or a date object`);
  const date = { year: Number(input.year), month: Number(input.month), day: Number(input.day) };
  validateCalendarDate(date.year, date.month, date.day, label);
  return date;
}

export async function loadCircuit(circuitPath) {
  const raw = await readFile(circuitPath, 'utf8');
  let circuit;
  try {
    circuit = JSON.parse(raw);
  } catch {
    throw new Error(`circuit artifact is not valid JSON: ${circuitPath}`);
  }
  if (circuit === null || typeof circuit !== 'object' || typeof circuit.bytecode !== 'string' || typeof circuit.abi !== 'object') {
    throw new Error('circuit artifact is missing bytecode or ABI');
  }
  if (typeof circuit.noir_version !== 'string' || !circuit.noir_version.startsWith('1.0.0-rc.5')) {
    throw new Error(`circuit artifact ${circuit.noir_version ?? '(unknown)'} is not compatible with noir_js 1.0.0-rc.5`);
  }
  return {
    circuit,
    artifactSha256: createHash('sha256').update(raw).digest('hex'),
  };
}

export async function computeNullifier(api, { accountHi, accountLo, claimDate, minimumAge, domain, secret }) {
  const elements = [
    BigInt(accountHi),
    BigInt(accountLo),
    BigInt(claimDate.year),
    BigInt(claimDate.month),
    BigInt(claimDate.day),
    BigInt(minimumAge),
    BigInt(domain),
    BigInt(secret),
  ].map((value) => bigintToBe32(value));
  const { hash } = await api.poseidon2Hash({ inputs: elements });
  return BigInt(bytesToHex(hash));
}

export async function proveClaim({
  circuitPath,
  account,
  claimDate,
  minimumAge = MINIMUM_AGE,
  domain = DOMAIN,
  birthDate,
  context = {},
  enforcePolicy = true,
  secret,
}) {
  const normalizedAccount = normalizeAddress(account);
  const limbs = addressToLimbs(normalizedAccount);
  const claim = asDate(claimDate, 'claim date');
  const birth = asDate(birthDate, 'birth date');
  const age = BigInt(minimumAge);
  const domainValue = BigInt(domain);
  if (age < 1n || age > 150n) throw new Error('minimum age must be between 1 and 150');
  if (domainValue < 0n || domainValue >= BN254_FR_MODULUS) throw new Error('domain must be a canonical field element');
  if (enforcePolicy && age !== MINIMUM_AGE) throw new Error(`minimum age must be ${MINIMUM_AGE} for this deployment`);
  if (enforcePolicy && domainValue !== DOMAIN) throw new Error('domain must match the Old Enough circuit');
  const secretValue = secret === undefined ? randomField() : BigInt(secret);
  if (secretValue <= 0n || secretValue >= BN254_FR_MODULUS) {
    throw new Error('nullifier secret must be a non-zero canonical field element');
  }

  const { circuit, artifactSha256 } = await loadCircuit(circuitPath);
  const noir = new Noir(circuit);
  const api = await Barretenberg.new();
  try {
    const backend = new UltraHonkBackend(circuit.bytecode, api);
    const nullifier = await computeNullifier(api, {
      accountHi: limbs.hi,
      accountLo: limbs.lo,
      claimDate: claim,
      minimumAge: age,
      domain: domainValue,
      secret: secretValue,
    });
    const inputs = {
      account_hi: limbs.hi.toString(),
      account_lo: limbs.lo.toString(),
      claim_year: String(claim.year),
      claim_month: String(claim.month),
      claim_day: String(claim.day),
      minimum_age: String(age),
      domain: fieldHex(domainValue),
      nullifier: fieldElementHex(nullifier),
      birth_year: String(birth.year),
      birth_month: String(birth.month),
      birth_day: String(birth.day),
      nullifier_secret: fieldElementHex(secretValue),
    };

    let witness;
    try {
      ({ witness } = await noir.execute(inputs));
    } catch (error) {
      throw safeWitnessError(error);
    }

    const generated = await backend.generateProof(witness, { verifierTarget: 'evm' });
    const expectedPublicInputs = buildPublicInputs({
      accountHi: limbs.hi,
      accountLo: limbs.lo,
      claimDate: claim,
      minimumAge: age,
      domain: domainValue,
      nullifier,
    });
    const publicInputs = generated.publicInputs.map((value) => normalizeHex(value, 32));
    if (publicInputs.length !== expectedPublicInputs.length) {
      throw new Error('generated proof has an unexpected number of public inputs');
    }
    for (let index = 0; index < expectedPublicInputs.length; index += 1) {
      if (publicInputs[index] !== expectedPublicInputs[index]) {
        throw new Error('generated proof public inputs do not match the requested statement');
      }
    }

    let verified = false;
    try {
      verified = await backend.verifyProof(
        { proof: generated.proof, publicInputs },
        { verifierTarget: 'evm' },
      );
    } catch {
      throw new Error('generated proof failed local verification');
    }
    if (!verified) throw new Error('generated proof failed local verification');

    return {
      version: 1,
      proof: bytesToHex(generated.proof),
      publicInputs,
      nullifier: fieldElementHex(nullifier),
      context: {
        version: 1,
        chainId: context.chainId === undefined ? undefined : Number(context.chainId),
        contract: context.contract === undefined ? undefined : normalizeAddress(context.contract),
        account: normalizedAccount,
        claimDate: claim,
        minimumAge: Number(age),
        domain: fieldHex(domainValue),
      },
      proofSystem: 'ultra_honk',
      verifierTarget: 'evm',
      bbVersion: '5.2.1',
      noirVersion: circuit.noir_version,
      artifactSha256,
      createdAt: new Date().toISOString(),
    };
  } finally {
    await api.destroy();
  }
}

export async function verifyProofFile({ circuitPath, proofPath }) {
  const file = await readProofFile(proofPath);
  const { circuit, artifactSha256 } = await loadCircuit(circuitPath);
  if (file.proofFile.artifactSha256 !== artifactSha256) {
    throw new Error('proof file was generated for a different circuit artifact');
  }
  const api = await Barretenberg.new();
  try {
    const backend = new UltraHonkBackend(circuit.bytecode, api);
    const verified = await backend.verifyProof(
      { proof: hexToBytes(file.proof), publicInputs: file.publicInputs },
      { verifierTarget: 'evm' },
    );
    return { verified, ...file };
  } finally {
    await api.destroy();
  }
}

export { hexToBytes };
