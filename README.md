# ansible-portable-poc

PoC: package Ansible as a **self-contained, relocatable bundle** with **zero host
dependencies** (no system Python, no container runtime), so a tool like `furyctl` can
download and run a pinned Ansible exactly like it downloads `terraform`/`kubectl`.

A bundle = a relocatable [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
CPython with `ansible-core` pip-installed directly into its tree (no venv, so there are no
absolute paths in `pyvenv.cfg`) plus the Galaxy collections from `requirements.yml` baked
in. The only residual host dependency is the `ssh` client, used by Ansible's default
connection plugin (universally present on Linux/macOS control nodes).

This is **Fase 0** of the design at
`../research/docs/proposal/ansible-self-contained-bundle.md`.

## Layout

```
versions.env              # version pins (CPython, pbs release, ansible-core)
requirements.yml          # pinned Galaxy collections (ansible.posix)
build.sh                  # build one bundle: ./build.sh <os> <arch>
smoke-test.sh             # relocate a bundle and verify self-containment
test/                     # minimal localhost play used by the smoke test
.github/workflows/build.yml
```

A built bundle (and its tarball) contains:

```
python/                   # relocatable CPython + ansible-core in site-packages
  bin/python3
  bin/ansible
  bin/ansible-playbook
  bin/ansible-galaxy
collections/              # baked Galaxy collections (ansible.posix, ...)
  ansible_collections/...
```

## Build locally

```sh
./build.sh                # builds for the host os/arch
./build.sh darwin arm64   # explicit target (must match the host machine)
```

`pip` resolves native wheels (PyYAML, cryptography, ...) for the **machine it runs on**, so
each target must be built on a matching OS/arch. `build.sh` refuses a mismatched local
build (override with `ALLOW_CROSS=1` only if you know the wheels are compatible). CI builds
every target on a matching runner.

Output: `ansible-portable-<bundle_version>-<os>-<arch>.tar.gz` (+ `.sha256`). The tarball is
named by the **bundle release version** (our own versioning), not by the ansible-core version,
so the bundle can be rebuilt (e.g. changing a collection) at the same ansible-core version by
bumping the release. `BUNDLE_VERSION` comes from the env (CI = git tag); locally it falls back
to `git describe`.

## Test

```sh
./smoke-test.sh ansible-portable-v0.2.0-darwin-arm64.tar.gz
```

It extracts the tarball into a fresh temp dir (proving relocatability), strips system
python/ansible from `PATH`, and asserts: `ansible-playbook --version` runs, `ansible.posix`
resolves, and a localhost play executes on the bundle's interpreter.

## Running a relocated bundle (the shebang note)

The `bin/ansible-playbook` console script keeps the shebang from build time, which is wrong
after relocation. **Always invoke it through the bundle's Python**, passing the script as an
argument, and point Ansible at the baked collections:

```sh
ANSIBLE_COLLECTIONS_PATH="$BUNDLE/collections" \
  "$BUNDLE/python/bin/python3" "$BUNDLE/python/bin/ansible-playbook" \
  -i inventory.ini playbook.yml
```

This is exactly how `furyctl`'s Ansible runner will invoke the bundle once integrated.

## CI

`.github/workflows/build.yml` builds all four targets — `linux/amd64` (`ubuntu-latest`),
`linux/arm64` (`ubuntu-24.04-arm`), `darwin/arm64` (`macos-14`), `darwin/amd64`
(`macos-13`) — runs the smoke test on each, and uploads the tarballs as workflow
artifacts. Pushing a tag `v*` also attaches all tarballs + an aggregated `SHA256SUMS` to a
GitHub Release.

> Note: `ubuntu-24.04-arm` is free on public repos; on private repos it consumes minutes.
> If unavailable, build `linux/arm64` via QEMU on `ubuntu-latest` (slower, wheel-download only).

## Version pins

See `versions.env` and `requirements.yml`. Current: CPython 3.12.13 (pbs `20260610`),
`ansible-core` 2.21.0, `ansible.posix` 2.2.0.
