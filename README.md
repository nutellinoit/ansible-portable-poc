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

## The recipe (how the build works)

`build.sh <os> <arch>` does, for one target:

1. **Download a relocatable CPython** — the `install_only` build from
   [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
   extracted to `python/`.
2. **Install ansible-core into that interpreter's tree** (not a venv → no absolute paths in
   `pyvenv.cfg`, so the tree can be moved anywhere):
   `python/bin/python3 -m pip install --only-binary=:all: -c constraints.txt ansible-core==<pin>`.
   - `--only-binary=:all:` forbids source builds: a missing wheel fails loudly instead of
     silently compiling (which would need a toolchain and break reproducibility).
   - `constraints.txt` pins native deps to versions that ship wheels on every target
     (e.g. `cryptography`, whose newest releases dropped macOS x86_64 wheels).
3. **Bake the Galaxy collections** from `requirements.yml` into `collections/`.
4. **Package** with `tar | gzip -9` → `ansible-portable-<bundle_version>-<os>-<arch>.tar.gz`
   (+ `.sha256`).

Two build details worth knowing:

- **Each target builds on a matching machine.** `pip` resolves native wheels for the host,
  so `build.sh` refuses a mismatched local build. CI uses native runners — except
  `darwin/amd64`, which is cross-built on an Apple-silicon runner via **Rosetta 2**
  (`arch -x86_64`), avoiding the scarce Intel runners.
- **Versioning is decoupled.** The tarball is named by **our own bundle release version**
  (the git tag, via `BUNDLE_VERSION` / `github.ref_name`), *not* by the ansible-core version.
  This lets us rebuild the bundle (e.g. add a collection) at the same ansible-core version by
  bumping the release. The ansible-core version lives in `versions.env` and only drives what
  gets installed.

CI (`.github/workflows/build.yml`) runs this for all four targets
(`linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`), smoke-tests each, uploads
workflow artifacts, and on a `v*` tag publishes a GitHub Release with the four tarballs +
`SHA256SUMS`.

## How to use a bundle

Download and extract anywhere:

```sh
BUNDLE=/opt/ansible-portable
mkdir -p "$BUNDLE"
curl -fsSL https://github.com/nutellinoit/ansible-portable-poc/releases/download/v0.2.0/ansible-portable-v0.2.0-linux-amd64.tar.gz \
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

## Build & test locally

```sh
./build.sh                 # builds for the host os/arch
BUNDLE_VERSION=v0.2.0 ./build.sh darwin arm64    # explicit version + target (must match host)
./smoke-test.sh ansible-portable-v0.2.0-darwin-arm64.tar.gz
```

`smoke-test.sh` extracts the tarball into a fresh temp dir (proving relocatability), strips
system python/ansible from `PATH`, and checks: `ansible-playbook --version` runs, the baked
collections resolve, and a localhost play executes on the bundle's interpreter.

## Files

| File | Role |
|------|------|
| `build.sh` | builds one bundle for a target |
| `smoke-test.sh` | relocates a bundle and verifies self-containment |
| `versions.env` | pins: CPython / pbs release / ansible-core |
| `requirements.yml` | Galaxy collections baked into the bundle |
| `constraints.txt` | pip constraints (native deps with wheels everywhere) |
| `test/` | minimal localhost play for the smoke test |
| `.github/workflows/build.yml` | multi-arch build + release |

## Pins

See `versions.env` / `requirements.yml` / `constraints.txt`. Current: CPython 3.12.13
(pbs `20260610`), `ansible-core` 2.21.0, `ansible.posix` 2.2.0, `community.general` 13.0.1,
`cryptography` 48.0.1.
