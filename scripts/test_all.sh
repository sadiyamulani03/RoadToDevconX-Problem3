#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${PATH}"
cd "${ROOT}"

for tool in nargo forge node npm python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ ! -f target/old_enough.json || ! -f contracts/verifiers/OldEnoughVerifier.sol ]]; then
  echo "Building circuit artifacts"
  ./scripts/build_circuit.sh
fi

echo "== Noir circuit tests =="
nargo test

echo "== Foundry contract tests =="
forge test

echo "== Client unit tests =="
(cd client && npm test)

echo "== Local proof verification =="
node client/claim.mjs verify --proof test/fixtures/adult_alice.json

echo "== Underage witness rejection =="
node scripts/test_underage.mjs

echo "== Security audit =="
./scripts/security_audit.sh

echo "All required checks passed."
