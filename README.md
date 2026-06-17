# ansible-portable

A **recipe** to package Ansible as a single, self-contained, relocatable tarball with
**zero host dependencies** — no system Python, no `pip`, no container runtime. A consumer
(e.g. `furyctl`) downloads the tarball, extracts it, and runs Ansible from it exactly like
it would download `kubectl` or `terraform`.

The only thing the host still needs is an `ssh` client (Ansible's default connection),
which is present everywhere on Linux/macOS control nodes.

## What's in a bundle

```
python/          relocatable CPython (from astral-sh/python-build-standalone)
  bin/python3        + ansible-core installed straight into its site-packages (no venv)
  bin/ansible
  bin/ansible-playbook
  bin/ansible-galaxy
collections/     Galaxy collections baked in (ansible.posix, community.general)
```

## Repository layout

```
mise.toml            task runner + tool manager (run `mise tasks`)
config/              version pins: versions.env, requirements.yml, constraints.txt
scripts/             build.sh, smoke-test.sh, checksums.sh
  lib/common.sh      shared helpers (host os/arch, pbs triple, rosetta, sha256)
test/                minimal localhost play for the smoke test
.github/workflows/   build (matrix + release) and lint
docs/presentations/  Marp deck explaining the work
```

## Tasks (via mise)

```sh
mise run build                  # build a bundle for the host os/arch
mise run build -- linux amd64   # build a specific target (must match the runner, except
                                # darwin/amd64 which cross-builds on arm via Rosetta 2)
mise run test -- <tarball>      # relocate the tarball and prove it's self-contained
mise run verify                 # build the host bundle + smoke-test it (local packaging test)
mise run checksums              # emit the kfd.yaml `checksums:` block from local tarballs
mise run checksums -- v0.2.1    # ...or from a published release's SHA256SUMS (needs gh)
mise run lint                   # shellcheck the scripts
mise run fmt                    # shfmt -w the scripts
mise run clean                  # remove dist/ and tarballs
mise run presentation-build     # build the docs/presentations deck (HTML + PDF)
```

## The recipe (how the build works)

`scripts/build.sh <os> <arch>` does, for one target:

1. **Download a relocatable CPython** — the `install_only` build from
   [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
   and **verify it against the upstream `SHA256SUMS`** before extracting (plus a best-effort
   `gh attestation verify` for provenance).
2. **Install ansible-core into that interpreter's tree** (not a venv → no absolute paths in
   `pyvenv.cfg`, so the tree can be moved anywhere):
   `python/bin/python3 -m pip install --only-binary=:all: -c config/constraints.txt ansible-core==<pin>`.
   - `--only-binary=:all:` forbids source builds: a missing wheel fails loudly instead of
     silently compiling (which would need a toolchain and break reproducibility).
   - `config/constraints.txt` pins native deps to versions that ship wheels on every target.
3. **Bake the Galaxy collections** from `config/requirements.yml` into `collections/`.
4. **Package** with `tar | gzip -9` → `ansible-portable-<bundle_version>-<os>-<arch>.tar.gz`
   (+ `.sha256`).

Two build details worth knowing:

- **Each target builds on a matching machine.** `pip` resolves native wheels for the host,
  so `build.sh` refuses a mismatched local build. CI uses native runners — except
  `darwin/amd64`, which is cross-built on an Apple-silicon runner via **Rosetta 2**.
- **Versioning is decoupled.** The tarball is named by **our own bundle release version**
  (the git tag, via `BUNDLE_VERSION` / `github.ref_name`), *not* by the ansible-core version.

CI (`.github/workflows/build.yml`) runs this for all four targets via `mise run build`,
smoke-tests each, uploads workflow artifacts, and on a `v*` tag publishes a GitHub Release
with the four tarballs + `SHA256SUMS`. `.github/workflows/lint.yml` runs shellcheck + shfmt.

## How to use a bundle

Download and extract anywhere:

```sh
BUNDLE=/opt/ansible-portable
mkdir -p "$BUNDLE"
curl -fsSL https://github.com/nutellinoit/ansible-portable-poc/releases/download/v0.2.1/ansible-portable-v0.2.1-linux-amd64.tar.gz \
  | tar -xz -C "$BUNDLE"
```

Run it — **always invoke the console script through the bundle's Python** (the script's
shebang points at the build-time path and is wrong after relocation), and point Ansible at
the baked collections:

```sh
ANSIBLE_COLLECTIONS_PATH="$BUNDLE/collections" \
  "$BUNDLE/python/bin/python3" "$BUNDLE/python/bin/ansible-playbook" \
  -i inventory.ini playbook.yml
```

No system Python or Ansible is involved. This is exactly how `furyctl` invokes the bundle
once integrated (it sets the paths + env from Go and runs the playbooks as usual).

## Integrity

- The build verifies the **upstream CPython** against python-build-standalone's `SHA256SUMS`.
- Each bundle ships a `.sha256`; the release aggregates them into `SHA256SUMS`.
- The consumer pins the per-arch bundle SHA-256 (`mise run checksums`) in its manifest and
  verifies the download (furyctl uses go-getter `?checksum=sha256:…`).

## Pins

See `config/versions.env` / `config/requirements.yml` / `config/constraints.txt`. Current:
CPython 3.12.13 (pbs `20260610`), `ansible-core` 2.21.0, `ansible.posix` 2.2.0,
`community.general` 13.0.1, `cryptography` 48.0.1.
