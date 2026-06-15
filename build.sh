#!/usr/bin/env bash
#
# build.sh — build ONE self-contained, relocatable Ansible bundle for a given (os, arch).
#
# Usage:
#   ./build.sh [os] [arch]
#     os   = linux | darwin   (default: host OS)
#     arch = amd64 | arm64    (default: host arch)
#
# Output:
#   dist/<os>-<arch>/                        (the unpacked bundle: python/ + collections/)
#   ansible-portable-<ansible_version>-<os>-<arch>.tar.gz   (+ .sha256)
#
# The bundle contains a relocatable CPython (python-build-standalone) with ansible-core
# pip-installed directly into its tree (no venv → no absolute paths in pyvenv.cfg) plus
# the Galaxy collections from requirements.yml baked in. ansible-playbook MUST be invoked
# as `python3 <path>/ansible-playbook ...` so a relocated bundle ignores the build-time
# shebang.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source ./versions.env

# ----- resolve target os/arch -------------------------------------------------
host_os() { case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo unknown ;; esac; }
host_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; arm64|aarch64) echo arm64 ;; *) echo unknown ;; esac; }

OS="${1:-$(host_os)}"
ARCH="${2:-$(host_arch)}"

# pip resolves wheels for the RUNNER's platform (PyYAML/cryptography/cffi ship native
# wheels), so a target normally must be built on a matching machine. One exception:
# darwin/amd64 can be built on an Apple-silicon host via Rosetta 2 — we run the x86_64
# interpreter under `arch -x86_64`, so pip installs genuine x86_64 wheels. PYRUN holds the
# prefix used for every interpreter invocation (empty for a native build).
HOST_OS="$(host_os)"
HOST_ARCH="$(host_arch)"
PYRUN=()
if [ "$OS" != "$HOST_OS" ] || [ "$ARCH" != "$HOST_ARCH" ]; then
  if [ "$OS" = "darwin" ] && [ "$ARCH" = "amd64" ] && [ "$HOST_OS" = "darwin" ] && [ "$HOST_ARCH" = "arm64" ]; then
    if ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      echo "ERROR: building darwin/amd64 on arm needs Rosetta 2." >&2
      echo "       Install it: softwareupdate --install-rosetta --agree-to-license" >&2
      exit 1
    fi
    PYRUN=(arch -x86_64)
    echo ">> Cross-building darwin/amd64 on arm via Rosetta 2"
  elif [ "${ALLOW_CROSS:-0}" != "1" ]; then
    echo "ERROR: requested ${OS}/${ARCH} but host is ${HOST_OS}/${HOST_ARCH}." >&2
    echo "       pip would install wheels for the host, producing a broken bundle." >&2
    echo "       Build each target on a matching runner (see .github/workflows/build.yml)." >&2
    exit 1
  fi
fi

# ----- map (os, arch) -> python-build-standalone triple -----------------------
case "${OS}/${ARCH}" in
  linux/amd64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
  linux/arm64)  TRIPLE="aarch64-unknown-linux-gnu" ;;
  darwin/amd64) TRIPLE="x86_64-apple-darwin" ;;
  darwin/arm64) TRIPLE="aarch64-apple-darwin" ;;
  *) echo "ERROR: unsupported target ${OS}/${ARCH}" >&2; exit 1 ;;
esac

PBS_ASSET="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${TRIPLE}-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ASSET}"

BUNDLE_DIR="dist/${OS}-${ARCH}"
TARBALL="ansible-portable-${ANSIBLE_CORE_VERSION}-${OS}-${ARCH}.tar.gz"

echo ">> Target:            ${OS}/${ARCH} (${TRIPLE})"
echo ">> CPython:           ${PYTHON_VERSION} (pbs ${PBS_RELEASE})"
echo ">> ansible-core:      ${ANSIBLE_CORE_VERSION}"
echo ">> Output bundle dir: ${BUNDLE_DIR}"
echo ">> Output tarball:    ${TARBALL}"

# ----- clean & fetch CPython --------------------------------------------------
rm -rf "$BUNDLE_DIR" "$TARBALL" "${TARBALL}.sha256"
mkdir -p "$BUNDLE_DIR"

echo ">> Downloading ${PBS_URL}"
curl -fL --retry 3 -o "${BUNDLE_DIR}/python.tar.gz" "$PBS_URL"
echo ">> Extracting CPython"
tar -xzf "${BUNDLE_DIR}/python.tar.gz" -C "$BUNDLE_DIR"   # extracts to ${BUNDLE_DIR}/python/
rm -f "${BUNDLE_DIR}/python.tar.gz"

PY="${BUNDLE_DIR}/python/bin/python3"
[ -x "$PY" ] || { echo "ERROR: ${PY} not found after extraction" >&2; exit 1; }

# ----- install ansible-core into the python tree ------------------------------
echo ">> Upgrading pip"
${PYRUN[@]+"${PYRUN[@]}"} "$PY" -m pip install --no-input --disable-pip-version-check --upgrade pip >/dev/null
echo ">> Installing ansible-core==${ANSIBLE_CORE_VERSION}"
# --only-binary=:all: forbids source builds: a missing wheel fails loudly instead of
# silently compiling (which would need a host toolchain and break reproducibility).
# constraints.txt pins deps (e.g. cryptography) to versions that ship wheels everywhere.
${PYRUN[@]+"${PYRUN[@]}"} "$PY" -m pip install --no-input --disable-pip-version-check \
  --only-binary=:all: -c constraints.txt "ansible-core==${ANSIBLE_CORE_VERSION}"

# ----- bake Galaxy collections ------------------------------------------------
echo ">> Installing collections from requirements.yml -> ${BUNDLE_DIR}/collections"
${PYRUN[@]+"${PYRUN[@]}"} "$PY" "${BUNDLE_DIR}/python/bin/ansible-galaxy" collection install \
  -r requirements.yml -p "${BUNDLE_DIR}/collections"

# ----- package ----------------------------------------------------------------
echo ">> Creating ${TARBALL}"
tar -czf "$TARBALL" -C "$BUNDLE_DIR" .

echo ">> Computing checksum"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$TARBALL" > "${TARBALL}.sha256"
else
  shasum -a 256 "$TARBALL" > "${TARBALL}.sha256"
fi

echo ">> Done:"
ls -lh "$TARBALL" "${TARBALL}.sha256"
cat "${TARBALL}.sha256"
