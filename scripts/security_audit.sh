#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

python3 - "${ROOT}" <<'PY'
import json
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
failures = []
excluded_dirs = {
    ".git",
    "broadcast",
    "cache",
    "client/node_modules",
    "deployments",
    "foundry-pp",
    "lib",
    "out",
    "target",
}
scan_roots = [
    root / "client" / "lib",
    root / "client" / "claim.mjs",
    root / "client" / "test",
    root / "script",
    root / "scripts",
    root / "contracts" / "LateNightPass.sol",
    root / "contracts" / "interfaces",
    root / "src",
    root / "foundry.toml",
    root / "Nargo.toml",
]
fixture_dir = root / "test" / "fixtures"
key_pattern = re.compile(r"0x[0-9a-fA-F]{64}")
forbidden_key_prefixes = ("birth",)
forbidden_key_fragments = ("secret",)
forbidden_key_exact = {"dob", "dateofbirth"}

def relative(path):
    return path.relative_to(root).as_posix()

def iter_files(path):
    if path.is_file():
        yield path
        return
    if not path.exists():
        return
    for current, dirnames, filenames in os.walk(path):
        rel_dir = os.path.relpath(current, root).replace(os.sep, "/")
        if rel_dir == ".":
            rel_dir = ""
        dirnames[:] = [
            name
            for name in dirnames
            if (f"{rel_dir}/{name}" if rel_dir else name) not in excluded_dirs
        ]
        for name in sorted(filenames):
            yield pathlib.Path(current) / name

seen = set()
for path in iter_files(root):
    rel = relative(path)
    if rel in seen:
        continue
    seen.add(rel)
    if path.name == ".env" or (path.name.startswith(".env.") and path.name != ".env.example"):
        failures.append(f"unexpected environment file: {rel}")
    if path.suffix in {".key", ".pem"}:
        failures.append(f"unexpected key material file: {rel}")

for scan_root in scan_roots:
    for path in iter_files(scan_root):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            if key_pattern.search(line):
                failures.append(f"possible 32-byte private key literal in {relative(path)}:{line_number}")

for path in sorted(fixture_dir.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        failures.append(f"invalid JSON fixture: {relative(path)}")
        continue
    if not isinstance(data, dict):
        failures.append(f"fixture is not a JSON object: {relative(path)}")
        continue
    stack = [data]
    while stack:
        value = stack.pop()
        if isinstance(value, dict):
            for key, nested in value.items():
                normalized = re.sub(r"[^a-z0-9]", "", key.lower())
                if (
                    normalized.startswith(forbidden_key_prefixes)
                    or any(fragment in normalized for fragment in forbidden_key_fragments)
                    or normalized in forbidden_key_exact
                ):
                    failures.append(f"private-witness field '{key}' in {relative(path)}")
                stack.append(nested)
        elif isinstance(value, list):
            stack.extend(value)
    lower = json.dumps(data).lower()
    for forbidden in ("birth", "secret"):
        if forbidden in lower:
            failures.append(f"private-witness marker '{forbidden}' in {relative(path)}")

env_example = root / ".env.example"
if env_example.exists():
    for line_number, line in enumerate(env_example.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("PRIVATE_KEY=") and stripped != "PRIVATE_KEY=":
            failures.append(f"non-empty PRIVATE_KEY in .env.example:{line_number}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)

print("Security audit checks passed.")
print(f"Checked {len(list(fixture_dir.glob('*.json')))} synthetic proof fixtures; no birth-date or secret fields found.")
PY

(cd client && npm audit --omit=dev --audit-level=high)
