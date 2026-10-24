#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { parseCalendarDate, formatCalendarDate } from '../client/lib/policy.mjs';
import { proveClaim } from '../client/lib/prove.mjs';

const DEFAULT_CIRCUIT = fileURLToPath(new URL('../target/old_enough.json', import.meta.url));
const account = '0x00000000000000000000000000000000000a11ce';
const claimDate = parseCalendarDate(process.argv[2] ?? '2026-10-24', 'claim date');
const underageBirthDate = { year: claimDate.year - 10, month: 1, day: 1 };

try {
  await proveClaim({
    circuitPath: DEFAULT_CIRCUIT,
    account,
    claimDate,
    minimumAge: 18,
    birthDate: underageBirthDate,
    enforcePolicy: true,
  });
  console.error('FAIL: an underage witness unexpectedly produced a proof');
  process.exit(1);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (!message.startsWith('Witness generation failed:')) {
    console.error(`FAIL: unexpected client error: ${message}`);
    process.exit(1);
  }
  console.log('Underage witness rejected by the circuit as expected.');
  console.log(`Claim date: ${formatCalendarDate(claimDate)}`);
  console.log(`Local-only synthetic birth date: ${formatCalendarDate(underageBirthDate)}`);
  console.log('No proof was produced.');
}
