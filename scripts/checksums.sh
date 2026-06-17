#!/usr/bin/env bash
#
# checksums.sh — emit the `checksums:` YAML block to paste under tools.common.ansible in the
# distribution's kfd.yaml. Keys are "<os>-<arch>" (matching the tarball name and the key furyctl
# derives from runtime.GOOS/GOARCH).
#
# Usage:
#   scripts/checksums.sh                 # from local ./ansible-portable-*-<os>-<arch>.tar.gz
#   scripts/checksums.sh <release-tag>   # from a GitHub release's SHA256SUMS (needs gh)
#                                        # e.g. scripts/checksums.sh v0.2.1
#
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

REPO="${ANSIBLE_PORTABLE_REPO:-nutellinoit/ansible-portable-poc}"

# key_from_tarball <filename> — extract "<os>-<arch>" from ansible-portable-<ver>-<os>-<arch>.tar.gz
key_from_tarball() {
	local base="$1"
	base="${base##*/}"
	base="${base%.tar.gz}"
	local arch="${base##*-}"
	local rest="${base%-*}"
	local os="${rest##*-}"
	echo "${os}-${arch}"
}

emit_header() { echo "    checksums:"; }
emit_line() { printf '      %s: "%s"\n' "$1" "$2"; }

if [ "$#" -ge 1 ]; then
	# ----- from a published release -------------------------------------------
	tag="$1"
	command -v gh >/dev/null 2>&1 || {
		echo "ERROR: gh CLI required to read a release's SHA256SUMS" >&2
		exit 1
	}
	sums="$(gh release download "$tag" --repo "$REPO" --pattern SHA256SUMS --output - 2>/dev/null)" || {
		echo "ERROR: could not read SHA256SUMS from ${REPO}@${tag}" >&2
		exit 1
	}
	emit_header
	# Each line: "<hash>  ansible-portable-<ver>-<os>-<arch>.tar.gz"
	while read -r hash file; do
		case "$file" in
		ansible-portable-*.tar.gz) emit_line "$(key_from_tarball "$file")" "$hash" ;;
		esac
	done <<<"$sums" | sort
else
	# ----- from local tarballs ------------------------------------------------
	shopt -s nullglob
	tarballs=(ansible-portable-*-*.tar.gz)
	if [ "${#tarballs[@]}" -eq 0 ]; then
		echo "ERROR: no ansible-portable-*-<os>-<arch>.tar.gz found in ${REPO_ROOT}." >&2
		echo "       Build first (mise run build / build-all) or pass a release tag." >&2
		exit 1
	fi
	emit_header
	for t in "${tarballs[@]}"; do
		emit_line "$(key_from_tarball "$t")" "$(sha256_of "$t")"
	done | sort
fi
