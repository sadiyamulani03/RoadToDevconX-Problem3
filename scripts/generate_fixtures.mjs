#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { proveClaim } from '../client/lib/prove.mjs';

const DEFAULT_CIRCUIT = fileURLToPath(new URL('../target/old_enough.json', import.meta.url));
const DEFAULT_OUT = fileURLToPath(new URL('../test/fixtures', import.meta.url));

function usage(message) {
  if (message !== undefined) console.error(`Error: ${message}`);
  console.error('Usage: node scripts/generate_fixtures.mjs --spec <private-spec.json> [--out-dir test/fixtures] [--circuit target/old_enough.json]');
  console.error('The spec contains synthetic birth dates and must stay outside the repository.');
  process.exit(message === undefined ? 0 : 2);
}

const { values } = parseArgs({
  options: {
    spec: { type: 'string' },
    'out-dir': { type: 'string' },
    circuit: { type: 'string' },
    help: { type: 'boolean', short: 'h' },
  },
});

if (values.help === true) usage();
if (values.spec === undefined) usage('--spec is required');

let spec;
try {
  spec = JSON.parse(await readFile(values.spec, 'utf8'));
} catch {
  usage('could not read or parse the fixture spec');
}
const fixtures = Array.isArray(spec) ? spec : spec.fixtures;
if (!Array.isArray(fixtures) || fixtures.length === 0) usage('spec must contain a non-empty fixtures array');
const outDir = values['out-dir'] ?? DEFAULT_OUT;
const circuitPath = values.circuit ?? DEFAULT_CIRCUIT;
const names = new Set();

for (const fixture of fixtures) {
  if (fixture === null || typeof fixture !== 'object') usage('each fixture must be an object');
  const { name, account, claimDate, birthDate } = fixture;
  if (typeof name !== 'string' || !/^[a-z0-9_]+$/.test(name)) usage('fixture name must match ^[a-z0-9_]+$');
  if (names.has(name)) usage(`duplicate fixture name: ${name}`);
  names.add(name);
  if (typeof account !== 'string' || typeof claimDate !== 'string' || typeof birthDate !== 'string') {
    usage(`fixture ${name} must contain account, claimDate, and birthDate strings`);
  }
  const minimumAge = fixture.minimumAge ?? 18;
  let proof;
  try {
    proof = await proveClaim({
      circuitPath,
      account,
      claimDate,
      minimumAge,
      birthDate,
      enforcePolicy: false,
    });
  } catch (error) {
    console.error(`Fixture ${name} failed: ${error instanceof Error ? error.message : 'unknown error'}`);
    process.exitCode = 1;
    continue;
  }
  const output = {
    ...proof,
    name,
    synthetic: true,
  };
  const outputPath = `${outDir}/${name}.json`;
  await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
  console.log(
    `${name}: account=${proof.context.account} date=${proof.context.claimDate.year}-${String(proof.context.claimDate.month).padStart(2, '0')}-${String(proof.context.claimDate.day).padStart(2, '0')} nullifier=${proof.nullifier} proof=${(proof.proof.length - 2) / 2} bytes`,
  );
}

console.log(`Wrote ${fixtures.length} synthetic fixture(s) to ${outDir}.`);
console.log('Fixtures contain public proof data only. Keep the fixture spec outside the repository.');
