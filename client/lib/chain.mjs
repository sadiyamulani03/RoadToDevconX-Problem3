import { readFile, stat } from 'node:fs/promises';
import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  getAddress,
  http,
  isAddress,
  parseAbi,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import {
  DOMAIN,
  MINIMUM_AGE,
  fieldHex,
  formatCalendarDate,
  normalizeAddress,
  validateCalendarDate,
} from './policy.mjs';
import { readProofFile } from './proof_file.mjs';

const PASS_ABI = parseAbi([
  'function MINIMUM_AGE() view returns (uint256)',
  'function FESTIVAL_ID() view returns (uint256)',
  'function currentClaimDate() view returns (uint256 year, uint256 month, uint256 day)',
  'function hasPass(address account) view returns (bool)',
  'function hasClaimed(address account) view returns (bool)',
  'function consumedNullifiers(bytes32 nullifier) view returns (bool)',
  'function claim(bytes proof, bytes32 nullifier)',
  'event PassClaimed(address indexed account, bytes32 indexed nullifier, uint256 claimYear, uint256 claimMonth, uint256 claimDay)',
]);

function validateRpcUrl(rpcUrl) {
  let url;
  try {
    url = new URL(rpcUrl);
  } catch {
    throw new Error('RPC URL must be a valid http(s) URL');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('RPC URL must use http or https');
  }
  return rpcUrl;
}

function makeChain(chainId, rpcUrl) {
  if (chainId > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('chain ID is too large for this client');
  return {
    id: Number(chainId),
    name: `old-enough-${chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  };
}

async function makeClients(rpcUrl) {
  const url = validateRpcUrl(rpcUrl);
  const probe = createPublicClient({ transport: http(url, { timeout: 30_000, retryCount: 1 }) });
  const chainId = BigInt(await probe.getChainId());
  const chain = makeChain(chainId, url);
  const publicClient = createPublicClient({ chain, transport: http(url, { timeout: 30_000, retryCount: 1 }) });
  return { chainId, chain, publicClient };
}

function validateContract(contract) {
  if (typeof contract !== 'string' || !isAddress(contract)) throw new Error('contract must be a valid 20-byte address');
  return getAddress(contract);
}

function validateAccount(account) {
  if (typeof account !== 'string' || !isAddress(account)) throw new Error('account must be a valid 20-byte address');
  return getAddress(account);
}

async function assertContractDeployed(publicClient, address) {
  const code = await publicClient.getCode({ address });
  if (code === undefined || code === '0x' || code === '0x0') {
    throw new Error('no contract bytecode found at the configured address');
  }
}

function currentDateFromContract(value) {
  let year;
  let month;
  let day;
  if (Array.isArray(value) && value.length === 3) {
    [year, month, day] = value;
  } else if (value !== null && typeof value === 'object' && 'year' in value && 'month' in value && 'day' in value) {
    ({ year, month, day } = value);
  } else {
    throw new Error('contract returned an invalid current claim date');
  }
  const date = { year: Number(year), month: Number(month), day: Number(day) };
  validateCalendarDate(date.year, date.month, date.day, 'contract claim date');
  return date;
}

function findPassClaimedEvent(receipt, contract) {
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== contract.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi: PASS_ABI, data: log.data, topics: log.topics });
      if (decoded.eventName !== 'PassClaimed') continue;
      return {
        account: decoded.args.account,
        nullifier: decoded.args.nullifier,
        year: Number(decoded.args.claimYear),
        month: Number(decoded.args.claimMonth),
        day: Number(decoded.args.claimDay),
      };
    } catch {
      continue;
    }
  }
  return undefined;
}

export function describeChainError(error) {
  if (typeof error?.shortMessage === 'string' && error.shortMessage.trim() !== '') {
    return error.shortMessage.trim();
  }
  if (typeof error?.message === 'string') {
    const firstLine = error.message.split('\n')[0].trim();
    if (firstLine !== '') return firstLine.length > 300 ? `${firstLine.slice(0, 300)}...` : firstLine;
  }
  return 'unknown RPC or contract error';
}

export async function readContext({ rpcUrl, contract, account }) {
  const target = validateContract(contract);
  const owner = validateAccount(account);
  const { chainId, publicClient } = await makeClients(rpcUrl);
  await assertContractDeployed(publicClient, target);
  const [dateValue, minimumAge, festivalId, hasPass] = await Promise.all([
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'currentClaimDate' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'MINIMUM_AGE' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'FESTIVAL_ID' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'hasPass', args: [owner] }),
  ]);
  if (BigInt(minimumAge) !== MINIMUM_AGE) throw new Error('contract minimum age does not match this client');
  if (BigInt(festivalId) !== DOMAIN) throw new Error('contract festival domain does not match this client');
  const claimDate = currentDateFromContract(dateValue);
  return {
    version: 1,
    chainId: Number(chainId),
    contract: target.toLowerCase(),
    account: owner.toLowerCase(),
    claimDate,
    minimumAge: Number(minimumAge),
    domain: fieldHex(festivalId),
    hasPass: Boolean(hasPass),
    generatedAt: new Date().toISOString(),
  };
}

export async function loadPrivateKey({ filePath, env = process.env }) {
  let privateKey;
  let warning;
  if (filePath !== undefined) {
    const info = await stat(filePath);
    if (!info.isFile()) throw new Error('private key path is not a regular file');
    if ((info.mode & 0o077) !== 0) {
      warning = 'private key file is readable by group or others; chmod 600 is recommended';
    }
    privateKey = (await readFile(filePath, 'utf8')).trim();
  } else if (typeof env.PRIVATE_KEY === 'string' && env.PRIVATE_KEY.trim() !== '') {
    privateKey = env.PRIVATE_KEY.trim();
  } else {
    throw new Error('private key not provided; use --private-key-file or PRIVATE_KEY');
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
    throw new Error('private key must be a 32-byte 0x-prefixed hex string');
  }
  return { privateKey, warning };
}

export async function submitClaim({ rpcUrl, contract, proofPath, privateKey, expectedAccount, wait = true }) {
  const target = validateContract(contract);
  const file = await readProofFile(proofPath);
  const signer = privateKeyToAccount(privateKey);
  const signerAddress = signer.address.toLowerCase();
  if (expectedAccount !== undefined && signerAddress !== normalizeAddress(expectedAccount)) {
    throw new Error('signer address does not match the requested account');
  }
  if (signerAddress !== file.context.account) {
    throw new Error('proof is bound to a different account than the transaction signer');
  }
  const { chain, chainId, publicClient } = await makeClients(rpcUrl);
  await assertContractDeployed(publicClient, target);
  if (file.context.chainId !== undefined && BigInt(file.context.chainId) !== chainId) {
    throw new Error('proof was generated for a different chain');
  }
  if (file.context.contract !== undefined && file.context.contract !== target.toLowerCase()) {
    throw new Error('proof was generated for a different contract address');
  }
  const [dateValue, minimumAge, festivalId, hasPass, nullifierUsed] = await Promise.all([
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'currentClaimDate' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'MINIMUM_AGE' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'FESTIVAL_ID' }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'hasPass', args: [signer.address] }),
    publicClient.readContract({ address: target, abi: PASS_ABI, functionName: 'consumedNullifiers', args: [file.nullifier] }),
  ]);
  if (BigInt(minimumAge) !== MINIMUM_AGE) throw new Error('contract minimum age does not match this client');
  if (BigInt(festivalId) !== DOMAIN) throw new Error('contract festival domain does not match this client');
  if (Boolean(hasPass)) throw new Error('this account already has a late-night pass');
  if (Boolean(nullifierUsed)) throw new Error('this proof nullifier has already been consumed');
  const claimDate = currentDateFromContract(dateValue);
  if (
    claimDate.year !== file.context.claimDate.year ||
    claimDate.month !== file.context.claimDate.month ||
    claimDate.day !== file.context.claimDate.day
  ) {
    throw new Error(
      `proof is valid for ${formatCalendarDate(file.context.claimDate)}, but the current claim date is ${formatCalendarDate(claimDate)}; regenerate the proof`,
    );
  }
  let simulation;
  try {
    simulation = await publicClient.simulateContract({
      address: target,
      abi: PASS_ABI,
      functionName: 'claim',
      args: [file.proof, file.nullifier],
      account: signer,
    });
  } catch (error) {
    throw new Error(`claim simulation failed: ${describeChainError(error)}`);
  }
  const walletClient = createWalletClient({ chain, account: signer, transport: http(validateRpcUrl(rpcUrl), { timeout: 30_000, retryCount: 1 }) });
  const hash = await walletClient.writeContract(simulation.request);
  let receipt;
  if (wait) {
    receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`claim transaction reverted: ${hash}`);
  }
  const event = receipt === undefined ? undefined : findPassClaimedEvent(receipt, target);
  return {
    hash,
    receipt,
    account: signer.address,
    nullifier: file.nullifier,
    claimDate: file.context.claimDate,
    event,
  };
}
