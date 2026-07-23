# TEMP — arm64 builder trial (instructions for local Claude)

**Delete this file when the arm trial is done.** It is a scratch note, not part of the build.

## Goal

HEAT's dependency stack is being migrated to a two-image spack build (branch `spackBuild`).
The expensive "builder" image (`docker/heat-builder.dockerfile` + `docker/spack/`) currently
builds on `x86_64_v3`. We want to know whether it **also builds natively on arm64 (aarch64 /
ARMv8)** — the CI workflow already has a best-effort arm64 leg, but this Mac (Apple Silicon)
is a faster place to shake out arm-specific breakage. **This is exploratory ("try it"), not
required to succeed.** Report what builds and what doesn't.

## Environment assumptions

- Apple Silicon Mac (M-series) → native `linux/arm64`. Docker Desktop must be running.
- The pinned base image `spack/ubuntu-noble:1.2.2@sha256:8949b26…` is a **multi-arch index
  that includes linux/arm64**, so the build is genuinely native (no QEMU emulation). The
  Dockerfile's `uname -m` branch maps aarch64 → `spack target=aarch64` automatically.
- **Bump Docker Desktop resources first** (Settings → Resources): RAM as high as feasible
  (qt / vtk / llvm / opencascade builds are memory-hungry), disk ≥ ~100 GB. On a 16 GB
  machine also lower the stage tmpfs (see `HEAT_STAGE_TMPFS_SIZE` below).
- Expect a **long cold build (many hours / overnight)**: the public spack mirror has few
  arm64 binaries and there is no warm arm cache yet, so most specs compile from source.

## Step 0 — get the branch

```bash
git fetch && git checkout spackBuild && git pull
```

## Step 1 — fast sanity: does the arm graph even concretize? (~2 min, do this first)

Don't start the multi-hour build until concretization resolves on arm64.

```bash
cd <repo-root>
docker run --rm --entrypoint bash \
  -v "$PWD/docker/spack":/host:ro \
  spack/ubuntu-noble:1.2.2@sha256:8949b2615bc4de2c12399510a0dfcc38ae586cf6e0de2ae886fdc849e17cda97 -c '
    export PATH=/opt/spack/bin:$PATH
    echo "arch: $(uname -m)   (expect aarch64)"
    mkdir -p /root/.spack && cp /host/spack_config.yaml /root/.spack/config.yaml
    spack external find gcc >/dev/null 2>&1
    mkdir -p /env && cp /host/spack.yaml /env/ && cp -r /host/repo /env/ && cd /env
    spack -e . config add "packages:all:require:target=aarch64"
    spack -e . concretize -f 2>&1 | grep -iE "error|conflict|unsatisf" | head
    echo "CONCRETIZE OK if no errors above"'
```

- Confirm `arch: aarch64` (proves native, not emulated).
- If concretization ERRORS on arm (a spec with no aarch64 version, an x86-only variant),
  capture the message and report — that's a finding. Otherwise proceed.

## Step 2 — full build (the actual trial)

Use the committed harness — it keeps a persistent cache and dumps the failing stage log,
so a mid-build failure doesn't lose everything:

```bash
cd <repo-root>
# optional: shrink the stage tmpfs on a small-RAM machine (default 40g cap)
export HEAT_STAGE_TMPFS_SIZE=20g
docker/spack/build-local.sh
```

Monitor in another terminal:
```bash
docker logs -f heat-build-local 2>&1 | grep -E '^\[\+\]|^\[x\]|no binary available'
```
Markers: `[+]` installed · `[x]` FAILED · `[e]` external · `fetching from build cache` = reused.

## On a failure (this is the expected interesting outcome)

1. Note **which package** failed (`[x] <hash> <pkg>@<ver> failed`). The harness prints the full
   `spack-build-out/error.txt` at the end.
2. Iterate on just that spec (fast — deps come from the now-warm local cache):
   ```bash
   docker/spack/build-local.sh --spec <pkg>
   ```
3. **Do NOT assume it's one of the already-fixed packages.** These are already fixed on this
   branch and validated on x86_64 — if one of them fails it's an *arm-specific* variant of the
   problem, worth noting distinctly:
   - `flann` (built `~mpi` to avoid boost_system)
   - `elmerfem@9.0` (heat overlay patches DCRComplexSolve.F90 for gfortran)
   - `py-pyside2@5.15.14` (llvm external prefix `/usr/lib/llvm-15`)
   - `py-pivy` (heat overlay adds C build-dep)
   - MKL is intentionally excluded (fftw-api→fftw, blas/lapack→openblas hard requirements)
4. Likely genuinely-new arm issues to expect: a spec with no aarch64 build, an apt external
   missing on arm64 noble (`llvm-15`, GL libs — verify they installed), or a package that
   hard-codes x86 flags.

## What to report back

- Did it concretize on aarch64? (Step 1)
- How far did the full build get (`[+]` count), and which package (if any) is the first `[x]`?
- For each arm failure: package + version + the tail of the stage error log + whether it's a
  fresh arm issue or an arm variant of an already-fixed one.
- Do NOT commit fixes on the Mac unless asked — just gather findings and report; fixes get
  folded into `docker/spack/spack.yaml` / the `heat` overlay back on the main machine.

## Pointers

- Maintainer guide: `docker/spack/README.md`
- Full migration history + all fixes/gotchas: `SPACK_MIGRATION_PROGRESS.md` (see Session-6)
- The arm CI leg: `.github/workflows/build-heat-builder.yml` (matrix, best-effort arm64)
