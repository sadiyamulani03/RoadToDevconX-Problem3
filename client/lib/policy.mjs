export const DOMAIN = 0x4f4c44454e4f5547485f5631n;
export const MINIMUM_AGE = 18n;
export const BN254_FR_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
export const PUBLIC_INPUT_COUNT = 8;

const UINT32_MAX = (1n << 32n) - 1n;
const UINT128_MAX = (1n << 128n) - 1n;
const UINT160_MAX = (1n << 160n) - 1n;
const UINT256_MAX = (1n << 256n) - 1n;

export function isLeapYear(year) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

export function daysInMonth(year, month) {
  if (!Number.isInteger(year) || year < 1 || year > 9999) {
    throw new Error('year must be an integer between 1 and 9999');
  }
  if (!Number.isInteger(month) || month < 1 || month > 12) {
    throw new Error('month must be an integer between 1 and 12');
  }
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

export function validateCalendarDate(year, month, day, label = 'date') {
  if (!Number.isInteger(year) || year < 1 || year > 9999) {
    throw new Error(`${label} year must be between 1 and 9999`);
  }
  if (!Number.isInteger(month) || month < 1 || month > 12) {
    throw new Error(`${label} month must be between 1 and 12`);
  }
  const maxDay = daysInMonth(year, month);
  if (!Number.isInteger(day) || day < 1 || day > maxDay) {
    throw new Error(`${label} day must be between 1 and ${maxDay} for ${year}-${String(month).padStart(2, '0')}`);
  }
}

export function parseCalendarDate(input, label = 'date') {
  if (typeof input !== 'string') throw new Error(`${label} must be a YYYY-MM-DD string`);
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(input);
  if (!match) throw new Error(`${label} must be a YYYY-MM-DD string`);
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  validateCalendarDate(year, month, day, label);
  return { year, month, day };
}

export function formatCalendarDate(date) {
  validateCalendarDate(date.year, date.month, date.day);
  return `${String(date.year).padStart(4, '0')}-${String(date.month).padStart(2, '0')}-${String(date.day).padStart(2, '0')}`;
}

export function normalizeAddress(input) {
  if (typeof input !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(input)) {
    throw new Error('account must be a 20-byte 0x-prefixed address');
  }
  return input.toLowerCase();
}

export function addressToLimbs(input) {
  const account = normalizeAddress(input);
  const value = BigInt(account);
  if (value > UINT160_MAX) throw new Error('account must fit in 160 bits');
  return { hi: value >> 128n, lo: value & UINT128_MAX };
}

export function fieldHex(value) {
  let number;
  try {
    number = BigInt(value);
  } catch {
    throw new Error('value must be an integer');
  }
  if (number < 0n || number > UINT256_MAX) throw new Error('value must fit in 256 bits');
  return `0x${number.toString(16).padStart(64, '0')}`;
}

export function fieldElementHex(value) {
  const number = BigInt(value);
  if (number < 0n || number >= BN254_FR_MODULUS) throw new Error('field element must be canonical BN254 Fr');
  return fieldHex(number);
}

export function bigintToBe32(value) {
  const number = BigInt(value);
  if (number < 0n || number > UINT256_MAX) throw new Error('value must fit in 256 bits');
  const output = new Uint8Array(32);
  let remaining = number;
  for (let index = 31; index >= 0; index -= 1) {
    output[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  return output;
}

export function bytesToHex(bytes) {
  return `0x${Buffer.from(bytes).toString('hex')}`;
}

export function hexToBytes(input, expectedBytes) {
  if (typeof input !== 'string' || !/^0x[0-9a-fA-F]*$/.test(input) || input.length % 2 !== 0) {
    throw new Error('expected an even-length 0x-prefixed hex string');
  }
  if (expectedBytes !== undefined && input.length !== 2 + expectedBytes * 2) {
    throw new Error(`expected ${expectedBytes} bytes of hex data`);
  }
  return new Uint8Array(Buffer.from(input.slice(2), 'hex'));
}

export function normalizeHex(input, expectedBytes) {
  if (typeof input !== 'string' || !/^0x[0-9a-fA-F]*$/.test(input) || input.length % 2 !== 0) {
    throw new Error('expected an even-length 0x-prefixed hex string');
  }
  if (expectedBytes !== undefined && input.length !== 2 + expectedBytes * 2) {
    throw new Error(`expected ${expectedBytes} bytes of hex data`);
  }
  return `0x${input.slice(2).toLowerCase()}`;
}

export function buildPublicInputs({ accountHi, accountLo, claimDate, minimumAge, domain, nullifier }) {
  validateCalendarDate(claimDate.year, claimDate.month, claimDate.day);
  const high = BigInt(accountHi);
  const low = BigInt(accountLo);
  if (high < 0n || high > UINT32_MAX) throw new Error('account high limb must fit in 32 bits');
  if (low < 0n || low > UINT128_MAX) throw new Error('account low limb must fit in 128 bits');
  const age = BigInt(minimumAge);
  if (age < 1n || age > 150n) throw new Error('minimum age must be between 1 and 150');
  const domainValue = BigInt(domain);
  if (domainValue < 0n || domainValue >= BN254_FR_MODULUS) throw new Error('domain must be a canonical field element');
  const nullifierValue = BigInt(nullifier);
  if (nullifierValue <= 0n || nullifierValue >= BN254_FR_MODULUS) throw new Error('nullifier must be a non-zero canonical field element');
  return [
    fieldHex(high),
    fieldHex(low),
    fieldHex(claimDate.year),
    fieldHex(claimDate.month),
    fieldHex(claimDate.day),
    fieldHex(age),
    fieldHex(domainValue),
    fieldHex(nullifierValue),
  ];
}

export function parseContext(input, { expectedAccount, expectedContract, expectedChainId } = {}) {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('context must be a JSON object');
  }
  if (input.version !== 1) throw new Error('unsupported context version');
  const account = normalizeAddress(input.account);
  const claimDate = {
    year: Number(input.claimDate?.year),
    month: Number(input.claimDate?.month),
    day: Number(input.claimDate?.day),
  };
  validateCalendarDate(claimDate.year, claimDate.month, claimDate.day, 'context claim date');
  const minimumAge = Number(input.minimumAge);
  if (!Number.isInteger(minimumAge) || minimumAge < 1 || minimumAge > 150) {
    throw new Error('context minimum age must be between 1 and 150');
  }
  if (minimumAge !== Number(MINIMUM_AGE)) throw new Error(`context minimum age must be ${MINIMUM_AGE}`);
  const domain = BigInt(input.domain);
  if (domain !== DOMAIN) throw new Error('context domain does not match the Old Enough circuit');
  const chainId = input.chainId === undefined || input.chainId === null ? undefined : BigInt(input.chainId);
  const contract = input.contract === undefined || input.contract === null ? undefined : normalizeAddress(input.contract);
  if (expectedAccount !== undefined && account !== normalizeAddress(expectedAccount)) {
    throw new Error('context account does not match the requested account');
  }
  if (expectedContract !== undefined && contract !== normalizeAddress(expectedContract)) {
    throw new Error('context contract does not match the requested contract');
  }
  if (expectedChainId !== undefined && chainId !== BigInt(expectedChainId)) {
    throw new Error('context chain ID does not match the current chain');
  }
  return {
    version: 1,
    chainId,
    contract,
    account,
    claimDate,
    minimumAge,
    domain: fieldHex(domain),
    hasPass: Boolean(input.hasPass),
  };
}
