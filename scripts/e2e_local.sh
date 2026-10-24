#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOUNDRY_BIN="${HOME}/.foundry/bin"
PORT="${PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
WORK="$(mktemp -d)"
ANVIL_PID=""

cleanup() {
  if [[ -n "${ANVIL_PID}" ]]; then
    kill "${ANVIL_PID}" 2>/dev/null || true
    wait "${ANVIL_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${ROOT}/deployments"
"${FOUNDRY_BIN}/anvil" --port "${PORT}" --chain-id 31337 > "${WORK}/anvil.log" 2>&1 &
ANVIL_PID=$!

for _ in $(seq 1 100); do
  if "${FOUNDRY_BIN}/cast" chain-id --rpc-url "${RPC}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

ANVIL_KEY="$(grep -m1 -oE '0x[0-9a-fA-F]{64}' "${WORK}/anvil.log")"
if [[ -z "${ANVIL_KEY}" ]]; then
  echo "Could not read the local anvil test key" >&2
  exit 1
fi
printf '%s\n' "${ANVIL_KEY}" > "${WORK}/key"
chmod 600 "${WORK}/key"
ACCOUNT="$("${FOUNDRY_BIN}/cast" wallet address --private-key "${ANVIL_KEY}")"

echo "Deploying verifier and claim contract to ${RPC}"
"${FOUNDRY_BIN}/forge" script script/Deploy.s.sol:Deploy \
  --root "${ROOT}" \
  --rpc-url "${RPC}" \
  --private-key "${ANVIL_KEY}" \
  --broadcast > "${WORK}/deploy.log" 2>&1
sed -n '1,80p' "${WORK}/deploy.log"

DEPLOYMENT="${ROOT}/deployments/31337.json"
PASS_ADDRESS="$(python3 -c "import json; print(json.load(open('${DEPLOYMENT}'))['pass'])")"
DOB="$(date -u -d '25 years ago' +%F)"
printf '%s\n' "${DOB}" > "${WORK}/birth-date"
chmod 600 "${WORK}/birth-date"

echo "Claiming from ${ACCOUNT} with a synthetic local-only birth date"
if ! node "${ROOT}/client/claim.mjs" claim \
  --rpc-url "${RPC}" \
  --contract "${PASS_ADDRESS}" \
  --account "${ACCOUNT}" \
  --birth-date-file "${WORK}/birth-date" \
  --private-key-file "${WORK}/key" \
  --out "${WORK}/proof.json" > "${WORK}/claim.log" 2>&1; then
  cat "${WORK}/claim.log" >&2
  exit 1
fi
cat "${WORK}/claim.log"

grep -q "Transaction: 0x" "${WORK}/claim.log"

if grep -q "${DOB}" "${WORK}/proof.json"; then
  echo "Privacy failure: the synthetic birth date appears in the proof file" >&2
  exit 1
fi
if grep -qiE '"(birth|dob|date_of_birth|nullifier_secret)' "${WORK}/proof.json"; then
  echo "Privacy failure: a private-witness field appears in the proof file" >&2
  exit 1
fi
grep -q "PassClaimed:" "${WORK}/claim.log"

node "${ROOT}/client/claim.mjs" context \
  --rpc-url "${RPC}" \
  --contract "${PASS_ADDRESS}" \
  --account "${ACCOUNT}" \
  --out "${WORK}/after.json" > "${WORK}/after.log" 2>&1
cat "${WORK}/after.log"
grep -q "Has pass: yes" "${WORK}/after.log"

if node "${ROOT}/client/claim.mjs" submit \
  --rpc-url "${RPC}" \
  --contract "${PASS_ADDRESS}" \
  --proof "${WORK}/proof.json" \
  --private-key-file "${WORK}/key" > "${WORK}/replay.log" 2>&1; then
  echo "Replay unexpectedly succeeded" >&2
  exit 1
fi
grep -q "already has a late-night pass" "${WORK}/replay.log"

echo "Local end-to-end claim and replay rejection passed"
