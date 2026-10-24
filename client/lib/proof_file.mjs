import { readFile } from 'node:fs/promises';
import {
  BN254_FR_MODULUS,
  PUBLIC_INPUT_COUNT,
  addressToLimbs,
  buildPublicInputs,
  normalizeHex,
  parseContext,
} from './policy.mjs';

export async function readProofFile(proofPath) {
  const raw = await readFile(proofPath, 'utf8');
  let proofFile;
  try {
    proofFile = JSON.parse(raw);
  } catch {
    throw new Error(`proof file is not valid JSON: ${proofPath}`);
  }
  if (proofFile === null || typeof proofFile !== 'object' || Array.isArray(proofFile)) {
    throw new Error('proof file must contain a JSON object');
  }
  if (proofFile.version !== 1) throw new Error('unsupported proof file version');
  if (typeof proofFile.artifactSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(proofFile.artifactSha256)) {
    throw new Error('proof file must contain a lowercase SHA-256 of the circuit artifact');
  }
  const context = parseContext(proofFile.context);
  if (!Array.isArray(proofFile.publicInputs) || proofFile.publicInputs.length !== PUBLIC_INPUT_COUNT) {
    throw new Error(`proof file must contain exactly ${PUBLIC_INPUT_COUNT} public inputs`);
  }
  const publicInputs = proofFile.publicInputs.map((value) => normalizeHex(value, 32));
  const nullifier = normalizeHex(proofFile.nullifier, 32);
  const nullifierValue = BigInt(nullifier);
  if (nullifierValue <= 0n || nullifierValue >= BN254_FR_MODULUS) {
    throw new Error('proof nullifier must be a non-zero canonical field element');
  }
  if (publicInputs[7] !== nullifier) throw new Error('proof nullifier does not match the final public input');
  const limbs = addressToLimbs(context.account);
  const expected = buildPublicInputs({
    accountHi: limbs.hi,
    accountLo: limbs.lo,
    claimDate: context.claimDate,
    minimumAge: context.minimumAge,
    domain: BigInt(context.domain),
    nullifier: nullifierValue,
  });
  for (let index = 0; index < expected.length; index += 1) {
    if (publicInputs[index] !== expected[index]) {
      throw new Error('proof public inputs do not match the proof context');
    }
  }
  const proof = normalizeHex(proofFile.proof);
  if (proof.length <= 2) throw new Error('proof file contains an empty proof');
  return { proofFile, proof, publicInputs, nullifier, context };
}
