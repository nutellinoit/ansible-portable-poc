#!/usr/bin/env bash
#
# common.sh — shared helpers for the ansible-portable build/test scripts.
#
# Source it from a script in scripts/:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# It defines: REPO_ROOT, host_os, host_arch, pbs_triple, rosetta_prefix, sha256_of.
# No side effects beyond setting REPO_ROOT and (optionally) cd-ing is left to the caller.

# Repository root: this file lives in scripts/lib/, so root is two levels up.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# host_os / host_arch — normalize uname to the linux|darwin / amd64|arm64 we use everywhere.
host_os() { case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo unknown ;; esac }
host_arch() { case "$(uname -m)" in x86_64 | amd64) echo amd64 ;; arm64 | aarch64) echo arm64 ;; *) echo unknown ;; esac }

# pbs_triple <os> <arch> — map a target to its python-build-standalone triple.
pbs_triple() {
	case "$1/$2" in
	linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
	linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
	darwin/amd64) echo "x86_64-apple-darwin" ;;
	darwin/arm64) echo "aarch64-apple-darwin" ;;
	*)
		echo "ERROR: unsupported target $1/$2" >&2
		return 1
		;;
	esac
}

# rosetta_prefix <os> <arch> — echo the command prefix to run an interpreter for the target.
# Only darwin/amd64 on an Apple-silicon host needs `arch -x86_64` (Rosetta 2); everything else
# is native (empty prefix). A native build for a non-host target is rejected by the caller.
# Fails if Rosetta is required but not installed.
rosetta_prefix() {
	local os="$1" arch="$2"
	if [ "$os" = "darwin" ] && [ "$arch" = "amd64" ] && [ "$(host_os)" = "darwin" ] && [ "$(host_arch)" = "arm64" ]; then
		if ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
			echo "ERROR: building/running darwin/amd64 on arm needs Rosetta 2." >&2
			echo "       Install it: softwareupdate --install-rosetta --agree-to-license" >&2
			return 1
		fi
		echo "arch -x86_64"
	fi
}

# sha256_of <file> — print the lowercase sha256 hex of a file (portable: sha256sum or shasum).
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}
