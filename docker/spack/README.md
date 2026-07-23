# HEAT spack builder — maintainer guide

This directory holds the **spack-based dependency build** for HEAT: the expensive
scientific stack (VTK, Qt, FreeCAD, OpenCASCADE, Elmer, gmsh, HDF5, MPI, …) is
compiled once by spack into a "builder" image, and the fast final HEAT image is built
`FROM` that builder. This guide is for whoever maintains that build.

> **Migration status.** The builder currently produces the *spack dependency stack*.
> The native components with no spack package (M3DC1/fusion-io, MAFOT+CUDA, heatFoam,
> swak4Foam) and the final-image wiring are **Phase 2**, appended to
> `docker/heat-builder.dockerfile` later. Until then, the legacy single-file build in
> `docker/Dockerfile` (see `docker/README.md`) is still the one that ships.

---

## Files

| File | Role |
|---|---|
| `../heat-builder.dockerfile` | The builder image. Installs the spack env, then (Phase 2) the native components. This is the artifact CI publishes. |
| `spack.yaml` | The spack environment: specs, externals, providers, concretizer settings. **Single source of truth for the dependency set.** |
| `spack_config.yaml` | spack `config.yaml` (install tree layout, build jobs, etc.), copied to `~/.spack/config.yaml`. |
| `repo/spack_repo/heat/` | Custom spack repo overlay (namespace `heat`) holding local package fixes. Currently: `py-pivy` (adds the missing C build-dep). |
| `entrypoint.sh` | Image entrypoint; sources the generated `activate.sh`. |
| `build-local.sh` | **Local iteration harness** — build/debug the env on your machine with a persistent cache and reachable logs. Dev tool, not the image build. |

---

## Testing a build locally

There are two ways to test, and they answer different questions.

### Option A — fast iteration (`build-local.sh`)  ← use this while developing

Use this when you're **changing `spack.yaml` or the repo overlay** and want a tight
loop: it builds the *same* environment the image uses, but keeps a **persistent
host-directory buildcache** and prints **full stage logs on failure**. A killed or
failed run loses nothing — every spec built so far is cached (spack `--autopush`), so
the next run resumes instead of recompiling.

```bash
# whole environment (first run is a long cold build; later runs reuse the cache):
docker/spack/build-local.sh

# just one spec + its deps — the fast way to debug a single failing package:
docker/spack/build-local.sh --spec qt

# put the cache somewhere with room (default is ~/.cache/heat-spack):
HEAT_SPACK_CACHE=/data/heat-spack-cache docker/spack/build-local.sh
```

What it does under the hood, and why it differs from `docker build`:

- Runs via `docker run` (not `docker build`) so the buildcache can be a **host
  directory** that survives across runs. On some Docker hosts BuildKit
  `--mount=type=cache` does **not** persist between builds; a host bind mount always does.
- Mounts a **tmpfs at the spack stage root with `exec`** (the default tmpfs is `noexec`,
  which makes `configure` scripts die with "Permission denied" at 0s).
- Adds the **public spack mirror** (`binaries.spack.io/develop`) for prebuilt
  toolchain binaries, then installs with `--no-checksum` — matching the image defaults,
  so what builds here builds in the image.

It is **not** a substitute for building the image: it doesn't produce a runnable HEAT
image and doesn't exercise Phase-2 native components. It answers *"does the spack env
concretize and compile?"*.

### Option B — faithful image build (`docker build`)  ← use this before you push

Builds the real builder image exactly as CI does. Do this as a final check once
`build-local.sh` is green.

```bash
# from the repo root:
docker build -f docker/heat-builder.dockerfile -t heat-builder:test .

# strict, checksum-verified source build (drop the --no-checksum default):
docker build -f docker/heat-builder.dockerfile --build-arg SPACK_INSTALL_FLAGS= \
  -t heat-builder:test .
```

Without a ghcr token this uses only the public mirror (+ an anonymous read-only pull
from the shared ghcr cache if it's public), so a cold local `docker build` is slow.
That's expected — Option A is the fast path; Option B is the fidelity check.

---

## Building the image on GitHub (CI)

CI is `/.github/workflows/build-heat-builder.yml`. It builds
`docker/heat-builder.dockerfile`, publishes the builder to
`ghcr.io/<owner>/heat-builder`, and **warms a shared spack binary cache** at
`ghcr.io/<owner>/heat-spack-cache` so future builds (CI or local) pull prebuilt
binaries instead of recompiling.

### Triggers

- **`workflow_dispatch`** — run it by hand (Actions tab → *Build HEAT builder image* →
  *Run workflow*). Use this the first time and after dependency changes.
- **`release: [released]`** — a published GitHub release rebuilds the builder.
- **`schedule`** (monthly) — refreshes the toolchain and re-warms the cache.

`concurrency` is serialized (`cancel-in-progress: false`) so two runs never fight over
the same cache tag.

### Secrets / permissions (no manual setup needed)

The job uses only the automatic `GITHUB_TOKEN` with `packages: write`. That token both
logs in to ghcr and is handed to BuildKit as the `ghcr_token` **secret file**, which
spack uses to authenticate the OCI buildcache **push**. Nothing else to configure.

The Dockerfile's cache logic keys off whether that token is present:

- **Token present (CI):** the shared ghcr OCI cache (`heat-oci`) is the read **and**
  push target — the persistent, team-shared binary cache.
- **No token (local dev):** it falls back to the on-disk `local-cache` mount for
  push/pull, and adds the ghcr cache read-only/best-effort. A missing token can never
  make a push failure abort the build.

### Runtime and the first cold build

The **first** run compiles everything from source (OpenFOAM-adjacent libs, FreeCAD, VTK,
Elmer, Qt, OpenCASCADE, …) and can approach the `timeout-minutes: 360` cap on a hosted
`ubuntu-latest` runner. If it exceeds that, use a larger or self-hosted runner for the
first run; **every subsequent run is fast** because it pulls from the warmed ghcr cache.
Only specs whose hash changed (a spec you edited, or its dependents) recompile.

### x86_64 only, for now

The image targets the portable `x86_64_v3` microarchitecture (set in the Dockerfile).
The Dockerfile already has the `aarch64` branch; to publish a multi-arch builder later,
add a `linux/arm64` matrix entry on an arm runner plus a digest-merge step.

---

## How the spack environment is put together

Key decisions in `spack.yaml`, so a future edit doesn't accidentally undo them:

- **`unify: when_possible`** and **`concretizer.targets.granularity: generic`**, with a
  per-arch `packages:all:require:target=…` added at build time (the Dockerfile/​
  `build-local.sh` inject `x86_64_v3`). Keeps binaries portable across the CI runner and
  dev machines.
- **Externals** (built-from-apt, `buildable: false`):
  - **`opengl` @ `/usr`** — removes mesa *and* llvm-via-mesa from the graph, and provides
    the `gl`/`glx`/`egl` virtuals that spack-built Qt and `py-pyside2`'s `patch()` resolve
    against. (This is why Qt is **not** external — an apt-Qt external breaks pyside2's
    patch, which walks Qt's glx/xcb subtree.)
  - **`llvm-15` @ `/usr`** — satisfies `py-pyside2`/shiboken's `llvm@10:15+clang` *build*
    dep, avoiding a ~1.5–2 hr spack llvm build. llvm is build-only, so it never enters the
    final image.
- **Provider pins** (`blas`/`lapack` → openblas, `fftw-api` → fftw). Without pinning,
  reuse pulled in **MKL** via the `fftw-api` virtual.
- **`py-pyside2` pinned to `@5.15.14`** — `@develop` hit a `KeyError` on `self.spec["llvm"]`.
- **Repo overlay `heat`** — see the next section.

## The `heat` repo overlay

`repo/spack_repo/heat/` is a spack repo (new v2.5 API layout:
`spack_repo/heat/repo.yaml` + `packages/<pkg>/package.py`). `spack.yaml` points at it via
`repos: [/opt/spack-environment/repo/spack_repo/heat]`. Put **local package fixes** here
instead of patching spack's builtin repo.

- **`py_pivy`** — copy of the builtin plus `depends_on("c", type="build")`. The builtin's
  `patch()` enables the C language in pivy's CMake but only declares a C++ dep, so the C
  wrapper is never set up and the build fails with a misleading "coin was not found".

---

## Troubleshooting / known gotchas

| Symptom | Cause / fix |
|---|---|
| `configure: Permission denied` at 0s (cascades to many failures) | The build-stage tmpfs is `noexec`. `build-local.sh` mounts it `exec`; in a plain `docker build` this isn't an issue. |
| `perl@5.42.2` (or similar) fails to fetch — "no checksum" | spack 1.2.2 lacks the source checksum. The default `--no-checksum` (Dockerfile `SPACK_INSTALL_FLAGS`, and `build-local.sh`) handles it; the public mirror also provides it as a binary. |
| MKL appears in the graph | A provider pin was dropped. Re-check `packages:all:providers` in `spack.yaml`. |
| `py-pyside2` `KeyError: 'llvm'` / `'glx'` | Don't make Qt an apt external, and keep `py-pyside2@5.15.14` + the `llvm`/`opengl` externals. |
| `py-pivy` "coin was not found" | The `heat` repo overlay's C build-dep is missing/not picked up. Confirm `spack -e . repo list` shows `heat`. |
| Warning: `local-cache is missing layout.json … never been pushed` | Benign on a first run — the cache is created on the first push. |
| Local `docker build` is very slow | Expected without a ghcr token (no shared cache). Use `build-local.sh` (Option A) to iterate; reserve `docker build` for the final check. |
