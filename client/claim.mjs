#!/usr/bin/env node
import { readFile, stat, writeFile, rename } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { parseCalendarDate, formatCalendarDate, parseContext } from './lib/policy.mjs';
import { proveClaim, verifyProofFile } from './lib/prove.mjs';
import { describeChainError, loadPrivateKey, readContext, submitClaim } from './lib/chain.mjs';

const DEFAULT_CIRCUIT = fileURLToPath(new URL('../target/old_enough.json', import.meta.url));

class UsageError extends Error {}

const HELP = `Old Enough local proving client

Usage:
  node claim.mjs context  --rpc-url <url> --contract <address> --account <address> [--out context.json]
  node claim.mjs prove    --context context.json (--birth-date-file <path> | --birth-date-stdin | --birth-date YYYY-MM-DD) [--out proof.json]
  node claim.mjs verify   [--proof proof.json] [--circuit target/old_enough.json]
  node claim.mjs submit   --rpc-url <url> --contract <address> --proof proof.json [--private-key-file <path>] [--no-wait]
  node claim.mjs claim    --rpc-url <url> --contract <address> --account <address> (--birth-date-file <path> | --birth-date-stdin | --birth-date YYYY-MM-DD) [--private-key-file <path>] [--out proof.json] [--no-wait]

Commands:
  context  Read the contract's current UTC claim date and policy. This is the only
           network read needed before proving.
  prove    Generate and locally verify an UltraHonk proof. Proving uses only local
           files and never sends the birth date or witness to the RPC or any server.
  verify   Verify a saved proof locally, without any network access.
  submit   Submit a saved proof to the claim contract using a local private key.
  claim    Run context, prove, and submit in one command.

Privacy:
  Prefer --birth-date-file with mode 600 or --birth-date-stdin. --birth-date is a
  convenience for local testing and may be retained in shell history. The birth date
  and nullifier secret are never written to the proof file or sent to the chain.
  The proof file contains only the proof and its public inputs.

Environment:
  RPC_URL, CONTRACT_ADDRESS, ACCOUNT, PRIVATE_KEY are used when the corresponding
  option is omitted. A private key should come from a mode-600 file or a protected
  environment, never from a committed .env file.
`;

function usageError(message) {
  throw new UsageError(message);
}

function requireOption(values, name, envName, label) {
  const value = values[name] ?? (envName === undefined ? undefined : process.env[envName]);
  if (typeof value !== 'string' || value.trim() === '') {
    usageError(`${label} is required (use --${name}${envName === undefined ? '' : ` or ${envName}`})`);
  }
  return value.trim();
}

function resolveCircuit(values) {
  return values.circuit ?? DEFAULT_CIRCUIT;
}

async function readJson(filePath) {
  let raw;
  try {
    raw = await readFile(filePath, 'utf8');
  } catch {
    throw new Error(`could not read ${filePath}`);
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error(`${filePath} is not valid JSON`);
  }
}

async function writeJson(filePath, value) {
  const temporary = `${filePath}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, filePath);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

async function resolveBirthDate(values) {
  const sources = [values['birth-date'], values['birth-date-file'], values['birth-date-stdin'] === true]
    .filter((value) => value !== undefined && value !== false);
  if (sources.length !== 1) {
    usageError('provide exactly one of --birth-date-file, --birth-date-stdin, or --birth-date');
  }
  let birthDate;
  if (values['birth-date'] !== undefined) {
    console.error('Warning: --birth-date may be retained in shell history; prefer a mode-600 file or stdin.');
    birthDate = values['birth-date'];
  } else if (values['birth-date-file'] !== undefined) {
    const filePath = values['birth-date-file'];
    const info = await stat(filePath);
    if (!info.isFile()) throw new Error('birth date path is not a regular file');
    if ((info.mode & 0o077) !== 0) {
      console.error('Warning: birth date file is readable by group or others; chmod 600 is recommended.');
    }
    birthDate = (await readFile(filePath, 'utf8')).split(/\r?\n/, 1)[0].trim();
  } else {
    birthDate = (await readStdin()).split(/\r?\n/, 1)[0].trim();
  }
  if (birthDate === '') throw new Error('birth date is empty');
  return parseCalendarDate(birthDate, 'birth date');
}

function printContext(context) {
  console.log(`Account: ${context.account}`);
  if (context.chainId !== undefined) console.log(`Chain ID: ${context.chainId}`);
  if (context.contract !== undefined) console.log(`Contract: ${context.contract}`);
  console.log(`Current UTC claim date: ${formatCalendarDate(context.claimDate)}`);
  console.log(`Minimum age: ${context.minimumAge}`);
  console.log(`Domain: ${context.domain}`);
  console.log(`Has pass: ${context.hasPass === true ? 'yes' : 'no'}`);
}

function printProofSummary(proof, verified) {
  printContext({
    account: proof.context.account,
    chainId: proof.context.chainId,
    contract: proof.context.contract,
    claimDate: proof.context.claimDate,
    minimumAge: proof.context.minimumAge,
    domain: proof.context.domain,
    hasPass: false,
  });
  console.log(`Nullifier: ${proof.nullifier}`);
  console.log(`Proof size: ${(proof.proof.length - 2) / 2} bytes`);
  console.log(`Public inputs: ${proof.publicInputs.length}`);
  console.log(`Local verification: ${verified ? 'passed' : 'FAILED'}`);
}

async function commandContext(values) {
  const rpcUrl = requireOption(values, 'rpc-url', 'RPC_URL', 'RPC URL');
  const contract = requireOption(values, 'contract', 'CONTRACT_ADDRESS', 'contract address');
  const account = requireOption(values, 'account', 'ACCOUNT', 'account address');
  const output = values.out ?? 'claim-context.json';
  let context;
  try {
    context = await readContext({ rpcUrl, contract, account });
  } catch (error) {
    throw new Error(describeChainError(error));
  }
  await writeJson(output, context);
  printContext(context);
  console.log(`Context written to ${output}`);
  if (context.hasPass) console.error('Warning: this account already has a pass; the contract will reject another claim.');
}

async function commandProve(values) {
  const contextPath = values.context ?? 'claim-context.json';
  const context = parseContext(await readJson(contextPath));
  const output = values.out ?? 'proof.json';
  const birthDate = await resolveBirthDate(values);
  const proof = await proveClaim({
    circuitPath: resolveCircuit(values),
    account: context.account,
    claimDate: context.claimDate,
    minimumAge: context.minimumAge,
    domain: BigInt(context.domain),
    birthDate,
    context,
  });
  await writeJson(output, proof);
  printProofSummary(proof, true);
  console.log(`Proof written to ${output}`);
  console.log(`This proof is bound to the UTC claim date ${formatCalendarDate(context.claimDate)}.`);
}

async function commandVerify(values) {
  const proofPath = values.proof ?? 'proof.json';
  const result = await verifyProofFile({ circuitPath: resolveCircuit(values), proofPath });
  printProofSummary(
    {
      context: result.context,
      nullifier: result.nullifier,
      proof: result.proof,
      publicInputs: result.publicInputs,
    },
    result.verified,
  );
  if (!result.verified) process.exitCode = 1;
}

async function commandSubmit(values) {
  const rpcUrl = requireOption(values, 'rpc-url', 'RPC_URL', 'RPC URL');
  const contract = requireOption(values, 'contract', 'CONTRACT_ADDRESS', 'contract address');
  const proofPath = values.proof ?? 'proof.json';
  const { privateKey, warning } = await loadPrivateKey({ filePath: values['private-key-file'] });
  if (warning !== undefined) console.error(`Warning: ${warning}`);
  let result;
  try {
    result = await submitClaim({
      rpcUrl,
      contract,
      proofPath,
      privateKey,
      expectedAccount: values.account,
      wait: values['no-wait'] !== true,
    });
  } catch (error) {
    throw new Error(describeChainError(error));
  }
  console.log(`Transaction: ${result.hash}`);
  console.log(`Account: ${result.account}`);
  console.log(`Claim date: ${formatCalendarDate(result.claimDate)}`);
  console.log(`Nullifier: ${result.nullifier}`);
  if (result.receipt !== undefined) {
    console.log(`Block: ${result.receipt.blockNumber.toString()}`);
    console.log(`Status: ${result.receipt.status}`);
  }
  if (result.event !== undefined) {
    console.log(
      `PassClaimed: account=${result.event.account} date=${result.event.year}-${String(result.event.month).padStart(2, '0')}-${String(result.event.day).padStart(2, '0')}`,
    );
  } else if (values['no-wait'] === true) {
    console.log('Transaction submitted without waiting for a receipt.');
  }
}

async function commandClaim(values) {
  const rpcUrl = requireOption(values, 'rpc-url', 'RPC_URL', 'RPC URL');
  const contract = requireOption(values, 'contract', 'CONTRACT_ADDRESS', 'contract address');
  const account = requireOption(values, 'account', 'ACCOUNT', 'account address');
  const output = values.out ?? 'proof.json';
  const birthDate = await resolveBirthDate(values);
  let context;
  try {
    context = await readContext({ rpcUrl, contract, account });
  } catch (error) {
    throw new Error(describeChainError(error));
  }
  if (context.hasPass) throw new Error('this account already has a late-night pass');
  console.log(`Current UTC claim date: ${formatCalendarDate(context.claimDate)}`);
  console.log('Generating proof locally. The birth date is not sent over the network.');
  const proof = await proveClaim({
    circuitPath: resolveCircuit(values),
    account: context.account,
    claimDate: context.claimDate,
    minimumAge: context.minimumAge,
    domain: BigInt(context.domain),
    birthDate,
    context,
  });
  await writeJson(output, proof);
  printProofSummary(proof, true);
  console.log(`Proof written to ${output}`);
  const { privateKey, warning } = await loadPrivateKey({ filePath: values['private-key-file'] });
  if (warning !== undefined) console.error(`Warning: ${warning}`);
  let result;
  try {
    result = await submitClaim({
      rpcUrl,
      contract,
      proofPath: output,
      privateKey,
      expectedAccount: account,
      wait: values['no-wait'] !== true,
    });
  } catch (error) {
    throw new Error(describeChainError(error));
  }
  console.log(`Transaction: ${result.hash}`);
  console.log(`Account: ${result.account}`);
  console.log(`Claim date: ${formatCalendarDate(result.claimDate)}`);
  if (result.receipt !== undefined) console.log(`Block: ${result.receipt.blockNumber.toString()}`);
  if (result.event !== undefined) {
    console.log(
      `PassClaimed: account=${result.event.account} date=${result.event.year}-${String(result.event.month).padStart(2, '0')}-${String(result.event.day).padStart(2, '0')}`,
    );
  }
}

async function main() {
  let parsed;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: {
        help: { type: 'boolean', short: 'h' },
        circuit: { type: 'string' },
        context: { type: 'string' },
        out: { type: 'string' },
        proof: { type: 'string' },
        'rpc-url': { type: 'string' },
        contract: { type: 'string' },
        account: { type: 'string' },
        'birth-date': { type: 'string' },
        'birth-date-file': { type: 'string' },
        'birth-date-stdin': { type: 'boolean' },
        'private-key-file': { type: 'string' },
        'no-wait': { type: 'boolean' },
      },
    });
  } catch (error) {
    usageError(typeof error?.message === 'string' ? error.message : 'invalid arguments');
  }
  const { values, positionals } = parsed;
  if (values.help === true || positionals.length === 0) {
    console.log(HELP);
    if (positionals.length === 0 && values.help !== true) process.exitCode = 2;
    return;
  }
  const command = positionals[0];
  if (positionals.length > 1) usageError(`unexpected argument: ${positionals[1]}`);
  if (command === 'context') return commandContext(values);
  if (command === 'prove') return commandProve(values);
  if (command === 'verify') return commandVerify(values);
  if (command === 'submit') return commandSubmit(values);
  if (command === 'claim') return commandClaim(values);
  usageError(`unknown command: ${command}`);
}

main().catch((error) => {
  if (error instanceof UsageError) {
    console.error(`Error: ${error.message}`);
    console.error('Run with --help for usage.');
    process.exitCode = 2;
    return;
  }
  console.error(`Error: ${error instanceof Error ? error.message : 'unknown error'}`);
  process.exitCode = 1;
});
