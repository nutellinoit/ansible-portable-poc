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

# Derive the bundle's target os/arch from the filename (…-<os>-<arch>.tar.gz). If the bundle
# is darwin/amd64 but we're on Apple silicon, run its interpreter under Rosetta 2. PYRUN
# holds that prefix (empty for a native run).
base="$(basename "$TARBALL")"; base="${base%.tar.gz}"
B_ARCH="${base##*-}"; rest="${base%-*}"; B_OS="${rest##*-}"
host_os() { case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo unknown ;; esac; }
host_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; arm64|aarch64) echo arm64 ;; *) echo unknown ;; esac; }
PYRUN=()
if [ "$B_OS" = "darwin" ] && [ "$B_ARCH" = "amd64" ] && [ "$(host_os)" = "darwin" ] && [ "$(host_arch)" = "arm64" ]; then
  PYRUN=(arch -x86_64)
  echo ">> Testing darwin/amd64 bundle on arm via Rosetta 2"
fi

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
${PYRUN[@]+"${PYRUN[@]}"} "$PY" "$AP" --version

echo
echo "== 2. baked collections =="
${PYRUN[@]+"${PYRUN[@]}"} "$PY" "$AG" collection list 2>/dev/null | tee "${RELOC}/collections.txt"
for coll in ansible.posix community.general; do
  if ! grep -qi "$coll" "${RELOC}/collections.txt"; then
    echo "FAIL: ${coll} not found in the relocated bundle" >&2
    exit 1
  fi
done

echo
echo "== 3. execute localhost play =="
${PYRUN[@]+"${PYRUN[@]}"} "$PY" "$AP" -i "${SCRIPT_DIR}/test/inventory.ini" "${SCRIPT_DIR}/test/ping.yml"

echo
echo "PASS: bundle is self-contained after relocation."
