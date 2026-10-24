import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  DOMAIN,
  addressToLimbs,
  bigintToBe32,
  buildPublicInputs,
  fieldHex,
  formatCalendarDate,
  normalizeAddress,
  parseCalendarDate,
  parseContext,
} from '../lib/policy.mjs';
import { readProofFile } from '../lib/proof_file.mjs';

const fixturePath = path.resolve(import.meta.dirname, '../../test/fixtures/adult_alice.json');

test('calendar parsing accepts real leap days and rejects invalid dates', () => {
  assert.deepEqual(parseCalendarDate('2000-02-29'), { year: 2000, month: 2, day: 29 });
  assert.deepEqual(parseCalendarDate('2024-02-29'), { year: 2024, month: 2, day: 29 });
  assert.throws(() => parseCalendarDate('2100-02-29'));
  assert.throws(() => parseCalendarDate('2023-02-29'));
  assert.throws(() => parseCalendarDate('2026-04-31'));
  assert.throws(() => parseCalendarDate('2026-13-01'));
  assert.throws(() => parseCalendarDate('26-01-01'));
});

test('calendar formatting pads components', () => {
  assert.equal(formatCalendarDate({ year: 2026, month: 3, day: 1 }), '2026-03-01');
  assert.equal(formatCalendarDate({ year: 999, month: 12, day: 31 }), '0999-12-31');
});

test('address encoding covers all 160 bits', () => {
  const limbs = addressToLimbs('0x1234567890AbcdEF1234567890aBcdef12345678');
  assert.equal(limbs.hi, 0x12345678n);
  assert.equal(limbs.lo, 0x90abcdef1234567890abcdef12345678n);
  assert.equal(limbs.hi << 128n | limbs.lo, 0x1234567890abcdef1234567890abcdef12345678n);
  assert.equal(normalizeAddress('0x1234567890AbcdEF1234567890aBcdef12345678'), '0x1234567890abcdef1234567890abcdef12345678');
  assert.throws(() => addressToLimbs('0x1234'));
});

test('field encoding is canonical 32-byte hex', () => {
  assert.equal(fieldHex(1n), `0x${'0'.repeat(63)}1`);
  assert.equal(fieldHex(DOMAIN), `0x${DOMAIN.toString(16).padStart(64, '0')}`);
  const encoded = bigintToBe32(1n);
  assert.equal(encoded.length, 32);
  assert.equal(encoded[31], 1);
  assert.throws(() => fieldHex(-1n));
});

test('public input order matches the circuit ABI', () => {
  const inputs = buildPublicInputs({
    accountHi: 0n,
    accountLo: 0xa11cen,
    claimDate: { year: 2026, month: 10, day: 24 },
    minimumAge: 18n,
    domain: DOMAIN,
    nullifier: 0x1234n,
  });
  assert.equal(inputs.length, 8);
  assert.equal(inputs[0], fieldHex(0n));
  assert.equal(inputs[1], fieldHex(0xa11cen));
  assert.equal(inputs[2], fieldHex(2026n));
  assert.equal(inputs[3], fieldHex(10n));
  assert.equal(inputs[4], fieldHex(24n));
  assert.equal(inputs[5], fieldHex(18n));
  assert.equal(inputs[6], fieldHex(DOMAIN));
  assert.equal(inputs[7], fieldHex(0x1234n));
});

test('parseContext rejects the wrong policy or account', () => {
  const context = {
    version: 1,
    account: '0x00000000000000000000000000000000000a11ce',
    claimDate: { year: 2026, month: 10, day: 24 },
    minimumAge: 18,
    domain: fieldHex(DOMAIN),
  };
  assert.equal(parseContext(context).account, context.account);
  assert.throws(() => parseContext({ ...context, minimumAge: 21 }));
  assert.throws(() => parseContext({ ...context, domain: fieldHex(DOMAIN + 1n) }));
  assert.throws(() => parseContext({ ...context, claimDate: { year: 2026, month: 2, day: 30 } }));
});

test('saved fixture contains only public proof data', async () => {
  const raw = await readFile(fixturePath, 'utf8');
  const file = JSON.parse(raw);
  assert.equal(file.synthetic, true);
  assert.equal(file.context.account, '0x00000000000000000000000000000000000a11ce');
  assert.equal(file.publicInputs.length, 8);
  assert.equal(file.publicInputs[7], file.nullifier);
  assert.deepEqual(Object.keys(file.context).sort(), ['account', 'claimDate', 'domain', 'minimumAge', 'version']);
  assert.equal(raw.toLowerCase().includes('birth'), false);
  assert.equal(raw.toLowerCase().includes('secret'), false);
});

test('readProofFile agrees with fixture metadata', async () => {
  const file = await readProofFile(fixturePath);
  assert.equal(file.publicInputs.length, 8);
  assert.equal(file.nullifier, file.proofFile.nullifier);
  assert.equal(file.context.account, file.proofFile.context.account);
  assert.ok(file.proof.length > 2);
});

test('readProofFile rejects tampered public inputs', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'old-enough-test-'));
  try {
    const raw = JSON.parse(await readFile(fixturePath, 'utf8'));
    raw.publicInputs[0] = fieldHex(BigInt(raw.publicInputs[0]) + 1n);
    const tamperedPath = path.join(directory, 'tampered.json');
    await writeFile(tamperedPath, JSON.stringify(raw), { mode: 0o600 });
    await assert.rejects(() => readProofFile(tamperedPath), /public inputs do not match|context/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
