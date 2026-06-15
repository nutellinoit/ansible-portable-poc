#!/usr/bin/env bash
#
# smoke-test.sh — prove a built bundle is self-contained AFTER relocation.
#
# Usage:
#   ./smoke-test.sh <tarball.tar.gz>
#
# It extracts the tarball into a fresh temp dir (a path different from where it was built,
# simulating extraction into furyctl's vendor/bin), strips system python/ansible from PATH,
# and asserts:
#   1. ansible-playbook --version runs (relocatable CPython + ansible-core, no system deps)
#   2. the baked ansible.posix collection resolves
#   3. a localhost play actually executes on the bundle interpreter
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL="${1:-}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
  echo "Usage: $0 <tarball.tar.gz>" >&2
  exit 2
fi
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"

RELOC="$(mktemp -d "${TMPDIR:-/tmp}/ansible-portable-reloc.XXXXXX")"
cleanup() { rm -rf "$RELOC"; }
trap cleanup EXIT

echo ">> Relocating bundle into ${RELOC}"
tar -xzf "$TARBALL" -C "$RELOC"

PY="${RELOC}/python/bin/python3"
AP="${RELOC}/python/bin/ansible-playbook"
AG="${RELOC}/python/bin/ansible-galaxy"
for f in "$PY" "$AP" "$AG"; do
  [ -e "$f" ] || { echo "FAIL: missing ${f} in bundle" >&2; exit 1; }
done

# Strip anything that could leak a system python/ansible; keep only base system bins
# (ssh, sh, coreutils). We never call bare `python3`/`ansible-playbook` — always via $PY.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export ANSIBLE_COLLECTIONS_PATH="${RELOC}/collections"
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

if command -v ansible-playbook >/dev/null 2>&1; then
  echo ">> note: a system ansible-playbook is on PATH ($(command -v ansible-playbook)); the test ignores it (uses the bundle explicitly)."
fi

echo
echo "== 1. ansible-playbook --version (relocated) =="
"$PY" "$AP" --version

echo
echo "== 2. baked collections =="
"$PY" "$AG" collection list 2>/dev/null | tee "${RELOC}/collections.txt"
if ! grep -qi 'ansible.posix' "${RELOC}/collections.txt"; then
  echo "FAIL: ansible.posix not found in the relocated bundle" >&2
  exit 1
fi

echo
echo "== 3. execute localhost play =="
"$PY" "$AP" -i "${SCRIPT_DIR}/test/inventory.ini" "${SCRIPT_DIR}/test/ping.yml"

echo
echo "PASS: bundle is self-contained after relocation."
