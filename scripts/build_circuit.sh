#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${PATH}"
cd "${ROOT}"

for tool in nargo bb; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Required tool not found: ${tool}" >&2
    exit 1
  fi
done

mkdir -p target/evm contracts/verifiers

echo "Compiling Noir circuit"
nargo compile

echo "Writing EVM verification key"
bb write_vk -b target/old_enough.json -o target/evm -t evm

echo "Generating Solidity verifier"
bb write_solidity_verifier -k target/evm/vk -o contracts/verifiers/OldEnoughVerifier.sol -t evm

echo "Circuit, verification key, and Solidity verifier regenerated."
echo "If circuit constraints changed, regenerate synthetic proof fixtures from a private spec and rerun all tests."
