# HEAT spack-build migration — plan, progress & gotchas

_Working doc / handoff. Branch: `spackBuild` (off `main`) in `/data/home/tbody/HEAT_dir/HEAT`._
_Last updated mid-session; builder image compile still running in background._

## Goal
Rebuild HEAT's Docker dependency stack with **spack**, in two images (an expensive,
rarely-rebuilt "builder" carrying all deps + native components; a fast "final" image
built FROM it), targeting a portable **x86_64_v3** microarch with a self-warming spack
binary cache. Final image stays on **Docker Hub** (`plasmapotential/heat`); builder
image + spack OCI cache go to **ghcr.io** (eventually). arm64 deferred (arch-switch stubbed).

No external-project names appear in any HEAT file (the hermes-3 repo was inspiration only).

## Key architecture decisions (as they evolved)
1. **Scope:** spack owns compilers, OpenMPI, HDF5, netCDF, BLAS/LAPACK, python + compiled
   py-* (numpy/scipy/pandas/matplotlib/h5py/netcdf4/mpi4py), **OpenFOAM 2306, gmsh, VTK,
   Elmer, and FreeCAD**.
2. **ParaView → apt** (NOT spack). It is Qt-heavy and used via `pvpython` (subprocess) /
   system-python bindings, not imported in-process, so it needn't share HEAT's interpreter.
3. **FreeCAD → spack.** HEAT does `import FreeCAD` in-process, so FreeCAD must be built
   against the same python HEAT runs on. This is the constraint that shaped everything.
4. **Native components (no spack package)** — MAFOT (CUDA/GPU, sm_89, static cudart),
   M3DC1/fusion-io, swak4Foam, heatFoam — built from source in the builder against spack
   deps, reusing docker/buildMAFOT + docker/buildM3DC1 (adapted to spack view paths).
5. **Registry/cache:** local directory buildcache for dev NOW; ghcr OCI cache for later.
6. **Python leaves** (scikit-image/-learn, pillow, trimesh) + pip-only stack (dash*,
   mitsuba, open3d, PyFoam, skorch, usd-core, pygltflib) → **pip venv** in the final image
   (layered on the spack view python with `--system-site-packages`).

## Base image
`spack/ubuntu-noble:1.2.2@sha256:8949b2615bc4de2c12399510a0dfcc38ae586cf6e0de2ae886fdc849e17cda97`
(spack 1.2.2, gcc 13.3.0). Spack lives at `/opt/spack/bin/spack` (NOT on login PATH).

## Files created/changed (committed on `spackBuild`)
- `docker/spack/spack.yaml` — the environment (see gotchas for why it looks as it does).
- `docker/spack/spack_config.yaml` — `config.install_tree.root: /opt/software`.
- `docker/spack/entrypoint.sh` — sources activate.sh + pip venv, exec "$@".
- `docker/heat-builder.dockerfile` — step 1 (spack deps). Native builds (phase 2) to be appended.
- `source/launchHEAT.py` — docker-mode external paths now env-var overridable (defaults unchanged).
- `.github/workflows/build-heat-builder.yml` — builder CI (ghcr, scaffolding, not yet run).

Commit log (newest first):
```
a7cd32f ci: add build-heat-builder workflow (phase 5, scaffolding)
00f06c7 launchHEAT: make docker-mode external paths env-var overridable (phase 4)
a41b835 docker/spack: use per-language gcc requires instead of all:require %gcc
a7de1ee docker: add heat-builder image (phase 1) — spack deps stage
163fc5f docker/spack: add validated spack environment for HEAT (phase 0)
```
Also: machine-wide no-push/no-PR deny rules added to `~/.claude/settings.json`; memory note
`no-push-no-pr-without-instruction.md`.

## Progress by phase
- [x] **Phase 0 — spack env**: authored + **concretization VERIFIED** inside the pinned image.
      Resolves to ONE runtime python (3.11.15) and ONE numpy (2.4.6); freecad/vtk/scipy/
      matplotlib/h5py all link that single python. 276 total concrete specs.
- [~] **Phase 1a — builder image (spack deps)**: Dockerfile mechanics verified. First cold
      build reached ~236/276 then **DIED when the Claude harness process exited** (it was a
      harness-anchored background task, not tmux). Because the buildcache push happens only
      at the END of `spack install`, **nothing was cached** — total loss, confirming the
      push-at-end fragility. Relaunched (see Session-2 update below) under **tmux** (session
      `heatbuild`) with a persistent log at `/data/home/tbody/HEAT_dir/heat-builder-build.log`,
      and with the opengl optimization that removes mesa+llvm.
- [x] **Phase 4 — launchHEAT.py** env-var paths (syntax verified).
- [x] **Phase 5 — builder CI workflow** (scaffolding, unrun).
- [ ] **Phase 1b — smoke tests**: once build completes, in-image check
      `import FreeCAD, vtk, numpy, scipy, h5py`; `simpleFoam -help`; `ElmerSolver`; `gmsh --version`.
- [ ] **Phase 2 — native builds** (BLOCKED on live view + MAFOT `make.inc.HEAT`):
      adapt docker/make.inc.ubuntu_x86 + docker/fusion-io-util-makefile + docker/buildMAFOT
      to point at `/opt/views/view/{include,lib}` and the spack mpicc/mpic++/mpif90; apt CUDA
      toolkit (cuda-nvcc-12-6, cuda-cudart-dev-12-6); build M3DC1, MAFOT (GPU), then heatFoam
      + swak4Foam against the spack OpenFOAM (source its `etc/bashrc`, then wmake / AllwmakeAll).
- [ ] **Phase 3 — final image** (`docker/heat.dockerfile`): FROM builder → FROM ubuntu:24.04;
      COPY /opt/spack-environment /opt/software /opt/views + native outputs + venv; apt-install
      paraview (+ runtime bits); create pip venv on the view python (`--system-site-packages`,
      numpy pinned to spack's 2.4.6 via constraints); clone EFIT + HEAT; set spack-view ENV
      (FreeCADPath, OFbashrc, pvpythonCMD, pyFoamPath...); entrypoint sources activate.sh.
- [ ] **Phase 6 — final CI (Docker Hub) + integration suite** (ciTest.py, batchFile_optical /
      _optical_elmer / _gyro / rad-goldens / _rzq / _optical_BYOM).

## Gotchas / dead-ends (what was tried and why it failed)
1. **`paraview +osmesa` → invalid variant.** Correct name is `+osmesa_fallback` in spack 1.2.2.
   (Moot now — paraview removed from spack.)
2. **`unify: true` with freecad + modern python stack is UNSATISFIABLE.** freecad →
   `py-pyside2` (old) caps `py-pip@:23.0`, while modern `py-numpy`'s build toolchain needs a
   newer py-pip. Both cannot hold under a single-version solve. spack's own hint: use
   `when_possible`.
3. **Trimming leaf py-packages didn't fix `unify:true`.** `py-matplotlib` (pulled by both
   paraview and freecad) drags `py-pillow@10 → py-pip@22.1:`, keeping the pip conflict alive.
4. **FreeCAD has NO headless/no-gui variant** in spack 1.2.2 — hard-depends on py-pyside2,
   qt@5, coin3d, py-pivy. Cannot drop the Qt/pyside baggage. This is why paraview left spack
   but freecad stayed (freecad must share HEAT's interpreter; paraview needn't).
5. **`unify: when_possible` is the resolution.** It forks ONLY `py-pip` (23.0 for pyside2 vs
   26.1.2) — a build-only tool never imported at runtime, so harmless. VERIFIED via spack.lock
   that runtime python + numpy stay single.
6. **`spack spec --json <root>` RE-CONCRETIZES the root standalone** — it does NOT reflect the
   env's unified solve (it reported python 3.14.5 for py-numpy standalone). Must parse
   `spack.lock` (`concrete_specs`) for the true unified graph. Big time-sink until realized.
7. **Two pythons in the view = collision.** Leaving `python@3.12` as an explicit root created a
   second runtime python node (freecad forces 3.11.15). Fix: pin the root to `python@3.11` so
   there is exactly one runtime python in the copied view. Build-tool python (3.12) is
   build-only and not in the view.
8. **`packages: all: require: "%gcc"` warns** ("applies to all packages… often leads to
   concretization errors"). Switched to per-language `c/cxx/fortran: require: gcc`.
9. **`spack env activate .` does NOT persist in a non-interactive RUN.** Activation is a shell-
   FUNCTION effect; invoking the spack binary on PATH loses it → `buildcache push: requires an
   active environment`. Fix: use `spack -e .` on EVERY command (mirror add / install / push).
10. **BuildKit secret must be `required=false`** so local builds without a ghcr token don't error.
11. **Local cache** = BuildKit `--mount=type=cache,target=/spack-cache` + directory mirror
    `file:///spack-cache`; push after install regardless of exit code (`|| true; exit $rc`).
    Cache mounts persist across (even failed) builds → true self-warming for local dev.
12. **Public mirror rarely matches our hashes.** `binaries.spack.io/develop` almost never has a
    binary for the `x86_64_v3` + this-concretization hashes → genuine cold source build
    (scipy 36 min, pandas 15 min). This is why the first build is many hours; the local cache
    makes subsequent builds fast.
13. **Session cwd is `/data/home/tbody/HEAT_dir` (parent of the repo), not the repo.** Use
    absolute paths for docker `-v` mounts; a `$PWD/docker/spack` mount silently missed once.

## Session-2 update (build crash + optimizations)
- The first builder build died on harness exit with nothing cached (see Phase 1a). Lesson:
  ALWAYS run long builds under tmux (now standing policy), and the push-at-end design has no
  partial safety net — an interrupted cold build is a total loss.
- **opengl apt-external (DONE, committed `c4186cf`):** declared spack `opengl` external at
  /usr + set as gl/glx/egl provider, and apt-install GL dev libs in the builder. This removes
  **mesa AND llvm** (llvm's only consumer was mesa) — cuts the single biggest ~2.5 hr build.
  Verified by concretization: mesa/llvm gone; vtk/freecad/gmsh still resolve.
- **Candidate NEXT apt-external wins (not yet done):** Qt5 (now the longest single build,
  ~30-60 min; Ubuntu 24.04 has 5.15.13, freecad wants qt@5:), then OpenCascade (libocct 7.6.3,
  version-sensitive), then boost. Each needs its own concretization validation (external only
  helps if the version satisfies the consumer; else spack silently rebuilds). Do NOT apt:
  OpenMPI/HDF5/netCDF/BLAS (perf + native-build ABI), python (interpreter), vtk (python ABI),
  freecad (in-process import).
- **Build monitoring:** tmux build emits NO harness completion notification; check progress by
  tailing `/data/home/tbody/HEAT_dir/heat-builder-build.log` or `tmux capture-pane -t heatbuild`.

## Session-3 update (qt5 apt-external + screen build)
- **qt5 apt-external (DONE, this session):** declared spack `qt` external at /usr
  (`qt@5.15.13+gui+opengl+sql+ssl+tools~webkit`, `buildable: false`) and apt-installed the
  Qt5 dev packages in the builder (qtbase5-dev + tools, qttools5-dev + tools, libqt5svg5-dev,
  libqt5opengl5-dev, qtdeclarative5-dev, libqt5x11extras5-dev). This removes qt@5 — the
  longest single build after mesa/llvm were gone (~30-60 min). Ubuntu 24.04 ships Qt 5.15.13
  (qmake at /usr/bin/qmake), which satisfies freecad/pyside2's qt@5:.
  - **Concretization VERIFIED** inside the pinned image: qt resolves to the external (`[e]`),
    freecad/coin3d/py-pyside2/py-pivy/vtk all still resolve, no errors. Runtime invariants
    hold: single python@3.11.15, single py-numpy@2.4.6. Total concrete specs now **221**
    (was 276 → mesa/llvm removal → now qt removal). Externals: gcc, glibc, opengl, qt.
- **Build now runs under `screen` (standing policy update):** replaced tmux with `screen`
  (detach/reattach ergonomics). Session name `heatbuild`, started with
  `screen -L -Logfile /data/home/tbody/HEAT_dir/heat-builder-screen.log -dmS heatbuild bash -lc '...docker build... | tee heat-builder-build.log; exec bash'`.
  The trailing `exec bash` keeps the window alive after the build so you can reattach and read
  the exit code (`=== heat-builder docker build EXITED rc=<N> ===`). Attach: `screen -r heatbuild`;
  detach: Ctrl-a d; force-attach: `screen -d -r heatbuild`. Log tail:
  `tail -f /data/home/tbody/HEAT_dir/heat-builder-build.log`.
  - apt layer cleared cleanly (Qt5 packages install fine on noble); spack install stage began
    pulling most specs from the local build cache (`fetching from build cache`/`relocating`) —
    the earlier build's cache mount is being reused, so this is not a full cold rebuild.
- **OPEN RISK — Qt-as-external is only proven at build time, not concretization.** freecad,
  coin3d, and py-pyside2 must actually COMPILE against apt's SPLIT Qt layout (headers under
  `/usr/include/x86_64-linux-gnu/qt5`, libs in `/usr/lib/x86_64-linux-gnu`, qmake at
  /usr/bin/qmake, cmake config in `/usr/lib/x86_64-linux-gnu/cmake/Qt5*`) — unlike spack's
  monolithic qt prefix. If a Qt consumer fails to find Qt5 at build time, likely fixes
  (in order): add missing `-dev` package; pass `Qt5_DIR`/`CMAKE_PREFIX_PATH` to the consumer;
  set the external's `extra_attributes` (e.g. cmake prefix); worst case revert qt to a spack
  build (drop the external, keep opengl). This is the thing to watch as the build reaches
  coin3d → py-pyside2 → freecad.

## Session-4 update (MKL removal + the FreeCAD/pyside2/llvm discovery)
_New commits on `spackBuild`: `40978f2` (qt external), `d3cf97c` (provider pin). Native
Session-3 build ran to warm the cache; several roots failed (diagnosed below)._

### 4a. intel-oneapi-mkl was silently pulled in — REMOVED via provider pins (commit `d3cf97c`)
- The Session-3 build installed **`intel-oneapi-mkl@2026.0.0`** (multi-GB) even though the env
  is designed around a single OpenBLAS ABI. Root cause: `spack.yaml` listed `openblas` as a
  **spec** (so it installs) but never pinned it as the **provider** for blas/lapack, and nothing
  pinned `fftw-api`. OpenFOAM hard-depends on `fftw-api`, satisfiable by fftw OR mkl; with
  binary-cache **reuse** on, the solver latched onto an MKL-linked cached binary.
- A cache-less concretization (no reuse) instead picks `fftw@3.3.11` (tiny) + openblas and NO
  mkl — proving mkl is unnecessary. **This is why a fresh `spack concretize` and the actual
  reuse-enabled `docker build` can disagree on the graph** (see also gotcha 6): reuse pulls
  older/mkl-linked cached specs a fresh solve would not.
- **Fix (committed):** `packages:all:providers` now pins `blas:[openblas] lapack:[openblas]
  fftw-api:[fftw]` (alongside the existing gl/glx/egl:[opengl]). Reconcretization VERIFIED: no
  mkl, fftw stays tiny, single python@3.11.15 / py-numpy@2.4.6, **221 specs**, no errors.
- Cache impact of the pin: it changes the hash of `openfoam` (the fftw-api consumer) + anything
  that had linked mkl, so those Session-3 cache entries go stale and rebuild once. boost / vtk /
  scipy / pandas / python / hdf5 are NOT downstream of fftw-api and stay reusable via `reuse`.

### 4b. Session-3 build failures (ran un-pinned: qt-external, pre-provider-pin)
Four `[x]` failures; `freecad` (root) then SKIPPED because its dep py-pyside2 failed:
| spec | dur | cause |
|---|---|---|
| `py-pyside2@develop` | 1s | **spack package bug — DIAGNOSED, see 4c** |
| `py-pivy@0.6.8` | 5s | numbered release (not @develop) — NOT yet diagnosed (coin3d+swig chain) |
| `flann@1.9.2` | 12s | independent (boost/hdf5/mpi, no Qt) — NOT yet diagnosed |
| `elmerfem@9.0` | 13m19s | root, independent of Qt — NOT yet diagnosed |
So the Qt-as-external risk from Session-3 did NOT bite (coin3d built fine; qt-external works so
far). The real blocker was pyside2's llvm bug.

### 4c. FreeCAD in spack REQUIRES llvm+clang (via py-pyside2/shiboken) — the big correction
- `py-pyside2` failed in its `setup_build_environment` (before any compile):
  `env.set("LLVM_INSTALL_DIR", self.spec["llvm"].prefix)` → `KeyError: No spec with name llvm`.
- The spack `py-pyside2` package declares `depends_on("llvm@10:15 +clang", type="build",
  when="@5.15")` (line ~51) but references `self.spec["llvm"]` **unconditionally** (line ~80).
  The solver chose **`@develop`** (which skips the `when="@5.15"` guard → no llvm in graph),
  almost certainly to dodge the old llvm build → `@develop` is simply BROKEN in spack 1.2.2.
- **This corrects the Session-2/opengl claim that "mesa is llvm's only consumer."** llvm was
  ALWAYS needed by pyside2 for FreeCAD; the solver just hid it by picking the broken @develop.
  shiboken uses libclang to parse Qt headers and generate the bindings — unavoidable for a spack
  FreeCAD. (NB `self.spec["x"]` only traverses a spec's OWN deps, not the whole env — so a
  package that reads `self.spec["llvm"]` MUST `depends_on` llvm.)
- **Fix = pin a real release:** `packages:py-pyside2:require:["@5.15.14"]` (available versions:
  develop, 5.15.14, 5.15.2.1). `@5.15.14` pulls `llvm@15.0.7 +clang`, which exactly matches
  the version Ubuntu 24.04 ships (`llvm-15` = 15.0.7). pyside2's llvm dep is **type=build only**
  → llvm is needed to build pyside2 but NOT at runtime (won't need to ship in the final image).

### 4d. Option A — apt-external llvm-15 (IN TESTING, not yet committed)
Rather than a ~1.5–2 hr spack `llvm@15` source build, satisfy it from apt like opengl/qt:
- apt: `llvm-15 llvm-15-dev llvm-15-tools libclang-15-dev clang-15 libclang-common-15-dev`
- `spack external find --not-buildable llvm` cleanly auto-detects it (robust vs hand-declaring).
- **Concretization VERIFIED:** py-pyside2@5.15.14 with BOTH `[e] llvm@15.0.7` and `[e] qt@5.15.13`
  external — zero spack llvm/qt build.
- **Build VERDICT (real pyside2 build in the diagnostic image):**
  - **llvm-external WORKS.** The @5.15.14 pin killed the llvm KeyError; pyside2 got past
    setup_build_environment with `LLVM_INSTALL_DIR` pointing at the apt llvm-15. So llvm-15 as an
    apt external is GOOD → keep it (translate to an explicit `packages:llvm` external block +
    apt the llvm-15 packages in the builder).
  - **qt-external FAILS — see 4g.** pyside2's `patch()` reaches THROUGH qt into its dep subtree
    (`self.spec["qt"]["glx"]["libglx"]` and `self.spec["qt"]["libxcb"]`); a depless external qt
    has neither → `KeyError: No spec with name glx in qt@5.15.13`.
- Fallback for llvm if the external ever misbehaves = Option B: spack-build `llvm@15+clang` (trim
  `~lldb~lld~polly~libomptarget` to cut time).

### 4g. qt-external is INCOMPATIBLE with building py-pyside2 (the headline reversal)
- py-pyside2 `patch()` (spack 1.2.2) hardcodes `self.spec["qt"]["glx"]["libglx"].prefix.include`
  and `self.spec["qt"]["libxcb"].prefix.include` — it walks qt's OWN dependency subtree for the
  GLX and xcb include dirs. An **external qt is a depless leaf**, so both lookups raise KeyError.
  (coin3d built fine only because it depends on glx DIRECTLY, never reaching through qt.)
- `spack providers libglx` = **mesa, opengl** → our **opengl external DOES provide glx+libglx**,
  so `qt["glx"]["libglx"]` WOULD resolve to the opengl external **iff qt is a real spack node**
  with a glx edge. i.e. the blocker is the qt-external specifically, NOT the opengl-external.
- **qt's ONLY consumers here are py-pyside2 + freecad** (vtk is `~qt`, coin3d needs glx not qt).
  So if that chain requires a spack-built qt, the qt-external buys nothing and must be dropped.
- **DECISION/PLAN: revert the qt-external; let spack BUILD qt (~30-60 min, one-time cached).**
  Keep opengl-external (provides gl/glx/libglx for both qt and pyside2's traversal), keep
  llvm-external, keep py-pyside2@5.15.14 pin, keep provider pins. (Confirming via concretize that
  a spack-built qt yields qt→glx→opengl and qt→libxcb edges so pyside2's patch() resolves; then a
  full pyside2 build to prove it. If even that fails, last resort = a repo patch to pyside2's
  patch()/ to point those includes at /usr/include.)
- **Net optimization scorecard after this session:** opengl-external ✅ (keep), llvm-15-external
  ✅ (keep, replaces the ~2 hr spack llvm), qt-external ❌ (revert — must build qt), MKL removal ✅
  (provider pins). FreeCAD-in-spack fundamentally needs a spack qt + spack-visible GL/xcb subtree.

### 4e. Diagnostic methodology that works (reusable for pivy/flann/elmer)
- **Ephemeral BuildKit RUN logs are unrecoverable** — `docker build` RUN steps can't bind-mount
  and their `/tmp/root/spack-stage/*.log` vanish on step exit. To diagnose, build an **"env-only"
  image** = the real Dockerfile up to but NOT including `spack install` (apt externals + gcc
  external + mirrors + env + concretize), then `docker run` it and run `spack -e . install <pkg>`
  by hand → stage logs PERSIST and you can iterate. Files: `scratchpad/heat-builder-env.dockerfile`
  and `scratchpad/heat-builder-env-llvm.dockerfile`.
- **MUST override the base image ENTRYPOINT.** `spack/ubuntu-noble` wraps every arg in `spack`,
  so `docker run img bash -c '...'` becomes `spack bash -c ...` → "bash is not a recognized Spack
  command". Use `docker run --entrypoint bash img -c '...'`.
- **The BuildKit cache mount is NOT bind-mountable** into `docker run` (separate storage from a
  `-v` host dir). So an interactive diagnostic container can't reuse the main build's warmed
  cache directly. To reuse it: run the diagnosis ALSO as a `docker build` sharing
  `--mount=type=cache,target=/spack-cache` (native reuse, but ephemeral logs), OR extract the
  cache once (a tiny `docker build` that `cp -a`s the mount into a layer, then `docker cp` to a
  host dir) and mount that dir as a `file://` mirror.
- **`--no-cache` on `spack install` exposes the perl checksum gap.** `perl@5.42.2` is too new for
  spack 1.2.2's builtin checksums; a source fetch dies with `FetchError: Will not fetch
  perl@5.42.2`. The real builder only survives because perl comes as a cached BINARY. For cold
  diagnostic installs use `--no-checksum` (and don't pass `--no-cache`).

### 4f. opencascade is mandatory and dominates the build (~1h13m, one-time)
`opencascade@7.9.1` (OCCT — the B-rep CAD geometry kernel) is a build/link dep of BOTH `freecad`
and `gmsh +opencascade`; it underpins HEAT's STEP→mesh pipeline. ~1h13m cold (huge templated
C++, no public-mirror binary for our hash). Already lean — `tbb/vtk/ffmpeg/freeimage/rapidjson`
all off. Not worth trimming further (`draw`/`visualization` risky, and it's now cached). Accept
it as a one-time cost the cache absorbs.

## Open questions to resolve during Phase 2/3
- Does HEAT `import paraview` in-process anywhere (PVPath into sys.path), or only via the
  `pvpythonCMD` subprocess? If in-process, apt paraview (system python) won't load under the
  spack python 3.11 → would need paraview back in spack or a subprocess-only path.
- Exact view locations to wire into ENV: FreeCAD module dir (for `FreeCADPath`), OpenFOAM
  `etc/bashrc` (for `OFbashrc` and for building heatFoam/swak4Foam), `pvpython` path.
- `import gmsh` in HEAT: currently spack gmsh is built WITHOUT `+python`; HEAT's gmsh python
  module should come from the pip wheel in the venv. Confirm.
- MAFOT `make.inc.HEAT` lives in the MAFOT `mafot_gpu` branch (not in HEAT repo) — must clone
  and read it to adapt CUDA_PATH / HDF5 / MPI include+lib paths to the spack view.
- Top risk still: building **heatFoam + swak4Foam against the spack OpenFOAM** wmake env.
  Fallback: keep only OpenFOAM as an in-builder source Allwmake if the spack wmake env fights.

## How to resume / useful commands
- Watch the build: tail the task output file (task `bzitcncda`).
- Re-verify concretization quickly:
  `docker run --rm --entrypoint bash -v <repo>/docker/spack:/host:ro spack/ubuntu-noble:1.2.2 -c '
     export PATH=/opt/spack/bin:$PATH; mkdir -p /root/.spack; cp /host/spack_config.yaml /root/.spack/config.yaml;
     spack external find gcc; mkdir -p /env; cp /host/spack.yaml /env/; cd /env;
     spack -e . config add "packages:all:require:target=x86_64_v3"; spack -e . concretize -f'`
- Build the builder locally (uses the local cache mount):
  `DOCKER_BUILDKIT=1 docker build -f docker/heat-builder.dockerfile -t heat-builder:dev .`
- With the ghcr cache instead (later): add `--build-arg SPACK_OCI_USER=$USER --secret id=ghcr_token,env=GHCR_TOKEN`.
- The full refactor plan file: `/data/home/tbody/.claude/plans/i-ve-been-working-on-synchronous-peacock.md`.
