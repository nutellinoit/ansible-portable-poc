#!/usr/bin/env bash
#
# build.sh — build ONE self-contained, relocatable Ansible bundle for a given (os, arch).
#
# Usage:
#   scripts/build.sh [os] [arch]        (or: mise run build -- [os] [arch])
#     os   = linux | darwin   (default: host OS)
#     arch = amd64 | arm64    (default: host arch)
#
# Output (at the repo root, names unchanged so furyctl/kfd.yaml keep working):
#   dist/<os>-<arch>/                                      (unpacked bundle: python/ + collections/)
#   ansible-portable-<bundle_version>-<os>-<arch>.tar.gz   (+ .sha256)
#
# The tarball is named by the BUNDLE release version (our own versioning), NOT by the
# ansible-core version — so we can rebuild the bundle (e.g. change a collection) keeping the
# same ansible-core but bumping the release. BUNDLE_VERSION comes from the env (CI passes the
# git tag via github.ref_name); locally it falls back to `git describe`.
#
# The bundle contains a relocatable CPython (python-build-standalone) with ansible-core
# pip-installed directly into its tree (no venv → no absolute paths in pyvenv.cfg) plus
# the Galaxy collections from config/requirements.yml baked in. ansible-playbook MUST be
# invoked as `python3 <path>/ansible-playbook ...` so a relocated bundle ignores the
# build-time shebang.
#
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

# shellcheck disable=SC1091 # config/versions.env is the single source of version pins.
source config/versions.env

# ----- resolve target os/arch -------------------------------------------------
OS="${1:-$(host_os)}"
ARCH="${2:-$(host_arch)}"
HOST_OS="$(host_os)"
HOST_ARCH="$(host_arch)"

# pip resolves wheels for the RUNNER's platform (PyYAML/cryptography/cffi ship native wheels),
# so a target normally must be built on a matching machine. One exception: darwin/amd64 can be
# built on an Apple-silicon host via Rosetta 2 — PYRUN runs the x86_64 interpreter so pip
# installs genuine x86_64 wheels (empty for a native build).
PYRUN=()
if [ "$OS" != "$HOST_OS" ] || [ "$ARCH" != "$HOST_ARCH" ]; then
	if [ "$OS" = "darwin" ] && [ "$ARCH" = "amd64" ] && [ "$HOST_OS" = "darwin" ] && [ "$HOST_ARCH" = "arm64" ]; then
		prefix="$(rosetta_prefix "$OS" "$ARCH")" || exit 1
		read -ra PYRUN <<<"$prefix"
		echo ">> Cross-building darwin/amd64 on arm via Rosetta 2"
	elif [ "${ALLOW_CROSS:-0}" != "1" ]; then
		echo "ERROR: requested ${OS}/${ARCH} but host is ${HOST_OS}/${HOST_ARCH}." >&2
		echo "       pip would install wheels for the host, producing a broken bundle." >&2
		echo "       Build each target on a matching runner (see .github/workflows/build.yml)." >&2
		exit 1
	fi
fi

TRIPLE="$(pbs_triple "$OS" "$ARCH")" || exit 1

PBS_ASSET="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${TRIPLE}-install_only.tar.gz"
PBS_BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}"
PBS_URL="${PBS_BASE_URL}/${PBS_ASSET}"
# python-build-standalone publishes a single aggregated SHA256SUMS per release (no per-asset .sha256).
PBS_SHA256SUMS_URL="${PBS_BASE_URL}/SHA256SUMS"

# Release version of the bundle (our own versioning), used for the tarball name.
# Precedence: env BUNDLE_VERSION (CI sets it to github.ref_name) -> git describe -> "dev".
BUNDLE_VERSION="${BUNDLE_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"

BUNDLE_DIR="dist/${OS}-${ARCH}"
TARBALL="ansible-portable-${BUNDLE_VERSION}-${OS}-${ARCH}.tar.gz"

echo ">> Target:            ${OS}/${ARCH} (${TRIPLE})"
echo ">> Bundle version:    ${BUNDLE_VERSION}"
echo ">> CPython:           ${PYTHON_VERSION} (pbs ${PBS_RELEASE})"
echo ">> ansible-core:      ${ANSIBLE_CORE_VERSION}"
echo ">> Output bundle dir: ${BUNDLE_DIR}"
echo ">> Output tarball:    ${TARBALL}"

# ----- clean & fetch CPython --------------------------------------------------
rm -rf "$BUNDLE_DIR" "$TARBALL" "${TARBALL}.sha256"
mkdir -p "$BUNDLE_DIR"

echo ">> Downloading ${PBS_URL}"
curl -fL --retry 3 -o "${BUNDLE_DIR}/python.tar.gz" "$PBS_URL"

# Verify the upstream CPython against python-build-standalone's published SHA256SUMS BEFORE
# extracting it: a tampered/MITM'd interpreter must never be unpacked into the bundle.
echo ">> Verifying CPython checksum against upstream SHA256SUMS"
expected_sha="$(curl -fsL --retry 3 "$PBS_SHA256SUMS_URL" | awk -v f="$PBS_ASSET" '$2 == f {print $1}')"
if [ -z "$expected_sha" ]; then
	echo "ERROR: ${PBS_ASSET} not found in upstream SHA256SUMS (${PBS_SHA256SUMS_URL})" >&2
	exit 1
fi
actual_sha="$(sha256_of "${BUNDLE_DIR}/python.tar.gz")"
if [ "$expected_sha" != "$actual_sha" ]; then
	echo "ERROR: CPython checksum mismatch for ${PBS_ASSET}" >&2
	echo "       expected ${expected_sha}" >&2
	echo "       actual   ${actual_sha}" >&2
	exit 1
fi
echo ">> CPython checksum OK (${actual_sha})"

# Best-effort provenance check: python-build-standalone publishes GitHub Artifact Attestations
# (Sigstore). Verify them when the gh CLI is available; never fail the build if it isn't.
if command -v gh >/dev/null 2>&1; then
	echo ">> Verifying CPython provenance attestation (gh)"
	if ! gh attestation verify "${BUNDLE_DIR}/python.tar.gz" --repo astral-sh/python-build-standalone; then
		echo ">> WARN: attestation verification skipped/failed (non-fatal)" >&2
	fi
fi

echo ">> Extracting CPython"
tar -xzf "${BUNDLE_DIR}/python.tar.gz" -C "$BUNDLE_DIR" # extracts to ${BUNDLE_DIR}/python/
rm -f "${BUNDLE_DIR}/python.tar.gz"

PY="${BUNDLE_DIR}/python/bin/python3"
[ -x "$PY" ] || {
	echo "ERROR: ${PY} not found after extraction" >&2
	exit 1
}

# ----- install ansible-core into the python tree ------------------------------
echo ">> Upgrading pip"
${PYRUN[@]+"${PYRUN[@]}"} "$PY" -m pip install --no-input --disable-pip-version-check --upgrade pip >/dev/null
echo ">> Installing ansible-core==${ANSIBLE_CORE_VERSION}"
# --only-binary=:all: forbids source builds: a missing wheel fails loudly instead of
# silently compiling (which would need a host toolchain and break reproducibility).
# config/constraints.txt pins deps (e.g. cryptography) to versions that ship wheels everywhere.
${PYRUN[@]+"${PYRUN[@]}"} "$PY" -m pip install --no-input --disable-pip-version-check \
	--only-binary=:all: -c config/constraints.txt "ansible-core==${ANSIBLE_CORE_VERSION}"

# ----- bake Galaxy collections ------------------------------------------------
echo ">> Installing collections from config/requirements.yml -> ${BUNDLE_DIR}/collections"
${PYRUN[@]+"${PYRUN[@]}"} "$PY" "${BUNDLE_DIR}/python/bin/ansible-galaxy" collection install \
	-r config/requirements.yml -p "${BUNDLE_DIR}/collections"

# ----- package ----------------------------------------------------------------
# Pipe through `gzip -9` (max compression) instead of `tar -z` (level 6). Portable across
# macOS bsdtar and GNU tar.
# -h/--dereference resolves symlinks into real files: consumers that extract the tarball
# without preserving symlinks (e.g. furyctl's go-getter/cache copy) would otherwise turn the
# python interpreter symlinks (python3 -> python3.12, ...) into empty files and break it.
#
# Safety: dereferencing would bake EXTERNAL file contents into the tarball if any symlink
# escapes the bundle (absolute target or path traversal). Refuse to package in that case.
bundle_abs="$(cd "$BUNDLE_DIR" && pwd)"
while IFS= read -r link; do
	target="$(readlink "$link")"

	case "$target" in
	/*)
		echo "ERROR: absolute symlink in bundle, refusing to dereference: ${link} -> ${target}" >&2
		exit 1
		;;
	esac

	resolved_dir="$(cd "$(dirname "$link")" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd)" || resolved_dir=""

	case "${resolved_dir}/" in
	"${bundle_abs}"/*) : ;; # resolves inside the bundle, safe
	*)
		echo "ERROR: symlink escapes bundle, refusing to dereference: ${link} -> ${target}" >&2
		exit 1
		;;
	esac
done < <(find "$BUNDLE_DIR" -type l)

echo ">> Creating ${TARBALL} (gzip -9, dereferencing symlinks)"
tar -ch -f - -C "$BUNDLE_DIR" . | gzip -9 >"$TARBALL"

echo ">> Computing checksum"
# Keep the two-column "<hash>  <filename>" format: CI aggregates these into the release SHA256SUMS.
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$TARBALL" >"${TARBALL}.sha256"
else
	shasum -a 256 "$TARBALL" >"${TARBALL}.sha256"
fi

echo ">> Done:"
ls -lh "$TARBALL" "${TARBALL}.sha256"
cat "${TARBALL}.sha256"
