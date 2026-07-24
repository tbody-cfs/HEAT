# HEAT builder image
# ==================
# Step 1 of the two-step spack build. This image carries the entire scientific
# dependency stack (installed by spack into /opt/software and exposed at
# /opt/views/view) PLUS the native components that have no spack package
# (M3DC1/fusion-io, MAFOT w/ CUDA, heatFoam, swak4Foam), built against the spack
# dependencies. It is expensive and rebuilt rarely (dependency or native-component
# changes); the fast final image (docker/heat.dockerfile) is built FROM it.
#
# Published to ghcr.io (the final HEAT image stays on Docker Hub). The spack binary
# cache is an unsigned OCI mirror, also on ghcr.io, that warms itself over builds.
#
# Build (from repo root), warming/reading the OCI cache with a GitHub token:
#   DOCKER_BUILDKIT=1 docker build -f docker/heat-builder.dockerfile \
#     --build-arg SPACK_OCI_USER=<gh-user> \
#     --secret id=ghcr_token,env=GHCR_TOKEN \
#     -t ghcr.io/plasmapotential/heat-builder:latest .
# Without a token it still builds, using only the public spack mirror.

FROM spack/ubuntu-noble:1.2.2@sha256:8949b2615bc4de2c12399510a0dfcc38ae586cf6e0de2ae886fdc849e17cda97 AS builder
SHELL ["/bin/bash", "-c"]
LABEL maintainer="tlooby@cfs.energy"

# OCI binary cache location + user (auth token supplied as a BuildKit secret, never
# baked into a layer). Override the org/namespace for a different ghcr account.
ARG SPACK_OCI_CACHE=oci://ghcr.io/plasmapotential/heat-spack-cache
ARG SPACK_OCI_USER=""
ENV SPACK_OCI_CACHE=${SPACK_OCI_CACHE} \
    SPACK_OCI_USER=${SPACK_OCI_USER}

# Extra flags passed to `spack install`. Defaults to --no-checksum because spack 1.2.2
# ships without a source checksum for a few specs in this graph (e.g. perl@5.42.2), so a
# source build of them would otherwise fail on fetch. This only relaxes SOURCE-archive
# checksums; buildcache binaries are still verified by their own gpg signatures. The
# local test harness (docker/spack/build-local.sh) uses the same default, so local and CI
# concretize/build identically. Override to "" (`--build-arg SPACK_INSTALL_FLAGS=`) for a
# strict, checksum-verified source build.
ARG SPACK_INSTALL_FLAGS="--no-checksum"

# The base image exposes spack via its entrypoint, not on the login PATH. Put it on
# PATH for all subsequent RUN steps.
ENV PATH=/opt/spack/bin:$PATH

# System OpenGL + LLVM-15 dev libraries, declared as spack externals in spack.yaml.
#   * opengl (external at /usr) removes mesa AND llvm-via-mesa from the graph; it also
#     provides the gl/glx/libglx virtuals that spack-built qt (and py-pyside2's patch())
#     resolve against.
#   * llvm-15 / libclang-15 (external at /usr) satisfies py-pyside2/shiboken's
#     llvm@10:15+clang BUILD dep — avoiding a ~1.5-2 hr spack llvm@15 build. Ubuntu 24.04
#     ships 15.0.7; llvm is build-only so it never enters the final image.
# qt is NOT apt here: it is built by spack (the apt qt-external broke pyside2's patch(),
# which walks qt's glx/libxcb subtree — see spack.yaml / SPACK_MIGRATION_PROGRESS.md §4g).
# HEAT is headless (Dash web GUI + apt ParaView), so system GL suffices at runtime.
RUN apt-get -yqq update && apt-get -yqq install --no-install-recommends \
      libglvnd-dev libgl-dev libglx-dev libegl-dev mesa-common-dev libglu1-mesa-dev \
      libx11-dev libxext-dev \
      llvm-15 llvm-15-dev llvm-15-tools libclang-15-dev clang-15 libclang-common-15-dev \
 && rm -rf /var/lib/apt/lists/*

# Install tree root (/opt/software) — the tree copied wholesale into the final image.
COPY docker/spack/spack_config.yaml /root/.spack/config.yaml

# Register the image's system gcc as an external so spack does not rebuild a compiler.
RUN spack external find gcc

# Public spack BINARY mirror + trust its signing keys. It rarely has our x86_64_v3 heavy
# specs, BUT it does provide prebuilt binaries for the common toolchain (gmake, perl,
# ncurses, cmake, autotools, ...) at generic targets — which substantially speeds a cold
# build (no persistent local cache is available on some hosts; see §5a). Read-only source
# of binaries; our own caches (ghcr / local) are configured in the install step below.
# NAME MATTERS: call this "spack-binaries", NOT "spack-public". The base image already
# ships a default source mirror named "spack-public" -> https://mirror.spack.io (source,
# no binaries). Adding a site-scope mirror with the SAME name shadows that default,
# repointing "spack-public" to binaries.spack.io/develop — whose _source-cache lacks some
# tarballs (e.g. sz@2.1.12.5, whose upstream releases were deleted), so from-source fetches
# 404 with no fallback. Using a distinct name keeps the built-in source mirror intact; the
# explicit spack-public-src entry in spack.yaml also guarantees the source fallback.
RUN spack mirror add --scope site spack-binaries https://binaries.spack.io/develop \
 && spack buildcache keys --install --trust --yes-to-all

# The HEAT spack environment.
RUN mkdir -p /opt/spack-environment
COPY docker/spack/spack.yaml /opt/spack-environment/spack.yaml
# Custom repo overlay (namespace: heat) with local package fixes; the
# env's spack.yaml references it via `repos: [/opt/spack-environment/repo/spack_repo/heat]`.
COPY docker/spack/repo /opt/spack-environment/repo
WORKDIR /opt/spack-environment

# Portable per-arch target requirement (on top of granularity:generic in spack.yaml).
# x86_64_v3 on amd64 now; the aarch64 branch is here for a future arm-native image.
RUN case "$(uname -m)" in \
      aarch64) HEAT_TARGET=aarch64 ;; \
      x86_64)  HEAT_TARGET=x86_64_v3 ;; \
      *)       HEAT_TARGET="$(uname -m)" ;; \
    esac && \
    spack -e . config add "packages:all:require:target=${HEAT_TARGET}"

# Install the environment.
#
# Cache strategy — a ghcr token (BuildKit secret) selects which cache is read+pushed,
# so a missing token can never make a push fail the build. Both caches are unsigned:
#   * TOKEN PRESENT (CI / team): the shared ghcr OCI cache (heat-oci) is the read+push
#     cache — the persistent, shared cache. The local BuildKit cache is not used (it is
#     ephemeral on CI runners anyway).
#   * NO TOKEN (local dev): a directory buildcache on the BuildKit cache mount
#     (/spack-cache, local-cache) is the read+push cache — it persists across local
#     `docker build`s on this machine. The ghcr cache is ALSO added READ-ONLY (anonymous,
#     best-effort `|| true`) so local builds can still PULL team-built binaries when the
#     ghcr package is public; nothing is pushed there without a token.
# In both cases we push to exactly one target ($PUSH_TARGET) — never to a cache we lack
# credentials for.
#
# Install runs WITHOUT --fail-fast so one broken package does not abort the rest.
# --autopush on the push-target mirror pushes each spec the MOMENT it finishes building
# (continuous, not at-end), so a build that is killed or crashes partway — a long cold CI
# run hitting the 360-min cap, a broken package, a cancelled job — still banks every
# already-built spec to the cache. BUT autopush does NOT refresh the buildcache index, and
# spack needs that index to SEE/reuse cached specs. So a killed run leaves its banked specs
# UNINDEXED, and the next run would rebuild them from source (verified locally: an unindexed
# warm cache gave 0 reuse; indexing it first gave full reuse). We therefore `update-index`
# in TWO places: BEFORE install, so specs banked by a prior/killed run are reusable THIS run
# (this is what makes "resumes from there" actually true — cold first run indexes an empty
# cache, a harmless no-op); AND after install via the trailing `buildcache push
# --update-index`, the catch-all for a clean finish. The real install exit code is
# re-propagated so CI still fails on a broken build.
# NOTE: use the explicit `spack -e .` env flag on every command. `spack env activate .`
# does not persist inside a non-interactive RUN (activation is a shell-function effect;
# here we invoke the spack binary on PATH, so the activation would be lost).
RUN --mount=type=secret,id=ghcr_token,required=false \
    --mount=type=cache,target=/spack-cache,sharing=locked \
    if [ -n "${SPACK_OCI_USER}" ] && [ -s /run/secrets/ghcr_token ]; then \
      export SPACK_OCI_TOKEN="$(cat /run/secrets/ghcr_token)" && \
      spack -e . mirror add --unsigned --autopush \
        --oci-username-variable SPACK_OCI_USER \
        --oci-password-variable SPACK_OCI_TOKEN \
        heat-oci "${SPACK_OCI_CACHE}" && \
      PUSH_TARGET=heat-oci ; \
    else \
      spack -e . mirror add --unsigned --autopush local-cache file:///spack-cache && \
      { spack -e . mirror add --unsigned heat-oci "${SPACK_OCI_CACHE}" || true ; } && \
      PUSH_TARGET=local-cache ; \
    fi && \
    { spack -e . buildcache update-index "${PUSH_TARGET}" || true ; } && \
    { spack -e . install ${SPACK_INSTALL_FLAGS} ; rc=$? ; \
      spack -e . buildcache push --unsigned --update-index --without-build-dependencies "${PUSH_TARGET}" || true ; \
      exit $rc ; }

# Portability regression gate: fail the image build if any installed library carries
# unguarded post-baseline SIMD (an -march=native / -mcpu=native leak past the portable
# target x86_64_v3 / aarch64) — e.g. a package baking -march=native into its objects or
# its exported CMake flags. See the script header for the detection method + allowlist.
COPY docker/spack/scan-unguarded-simd.sh /opt/spack-environment/scan-unguarded-simd.sh
RUN bash /opt/spack-environment/scan-unguarded-simd.sh /opt/software

# Generate the environment activation script the final image / entrypoint sources.
RUN spack env activate --sh -d . > activate.sh

# ======================================================================
# Phase 2 — MAFOT (native build against the spack view).
# CRITICAL PATH: HEAT's optical-shadow field-line tracing runs `heatstructure`
# (source/MHDClass.py), so the image is not functional for shadowed heat-flux runs
# without it. Built here against /opt/views/view (openmpi + netcdf) and installed to
# /root/source/MAFOT/build — OUTSIDE /opt/software, so the unguarded-SIMD gate above
# (which scans /opt/software) does not see it; nvcc device code lives in .nv_fatbin,
# not host-ISA sections, so MAFOT is portability-neutral regardless.
#   2a MAFOT-CPU (default, BOTH arches): GPU=False, M3DC1=False — links only the view's
#      openmpi + netcdf; no CUDA, no fusion-io/HDF5-C++ dep. Fully covers optical shadowing.
#   2b GPU (x86 only; opt out with --build-arg HEAT_GPU=0): apt CUDA toolkit, GPU=True,
#      cudart linked STATICALLY (runtime ships no CUDA), gencode sm_89 + compute_89 PTX.
#   M3DC1=True (3D M3DC1 fields) is deferred: needs the M3DC1/fusion-io build first AND
#      libhdf5_cpp, which the view's hdf5 (+mpi+fortran+hl, no +cxx) does not provide.
# (M3DC1/fusion-io, heatFoam, swak4Foam remain later phase-2 steps.)
# ======================================================================
ARG HEAT_GPU=1
ARG MAFOT_BRANCH_CACHE_BUST=1
COPY docker/make.inc.HEAT.spack /opt/spack-environment/make.inc.HEAT.spack
COPY docker/buildMAFOT.spack    /opt/spack-environment/buildMAFOT.spack

# 2b: CUDA toolkit (x86_64 + HEAT_GPU=1 only), per the legacy docker/Dockerfile recipe.
RUN if [ "${HEAT_GPU}" = "1" ] && [ "$(uname -m)" = "x86_64" ]; then \
      apt-get -yqq update && apt-get -yqq install --no-install-recommends wget ca-certificates && \
      wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb && \
      dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb && \
      apt-get -yqq update && \
      apt-get -yqq install --no-install-recommends cuda-nvcc-12-6 cuda-cudart-dev-12-6 && \
      ln -sfn /usr/local/cuda-12.6 /usr/local/cuda && \
      rm -rf /var/lib/apt/lists/* ; \
    else \
      echo "Skipping CUDA toolkit (HEAT_GPU=${HEAT_GPU}, arch=$(uname -m)) — MAFOT will be CPU-only." ; \
    fi

# Clone + build MAFOT against the spack view. build/{bin,lib} mirror the legacy layout so
# the runtime COPY (heat.dockerfile) is a straight lift. GPU is decided from arch + HEAT_GPU;
# M3DC1 stays False (deferred). The two `test -x` guards fail the build if the critical-path
# binaries are missing.
RUN git clone -b mafot_gpu --single-branch https://github.com/ORNL-Fusion/MAFOT.git /root/source/MAFOT && \
    source /opt/spack-environment/activate.sh && \
    if [ "${HEAT_GPU}" = "1" ] && [ "$(uname -m)" = "x86_64" ]; then MAFOT_GPU=True; else MAFOT_GPU=False; fi && \
    echo "MAFOT build: GPU=${MAFOT_GPU} M3DC1=False arch=$(uname -m)" && \
    cp /opt/spack-environment/make.inc.HEAT.spack /root/source/MAFOT/install/make.inc.HEAT && \
    cp /opt/spack-environment/buildMAFOT.spack /root/source/MAFOT/buildMAFOT && \
    chmod +x /root/source/MAFOT/buildMAFOT && \
    mkdir -p /root/source/MAFOT/build/bin /root/source/MAFOT/build/lib && \
    MAFOT_GPU="${MAFOT_GPU}" MAFOT_M3DC1=False /root/source/MAFOT/buildMAFOT && \
    test -x /root/source/MAFOT/build/bin/heatstructure && \
    test -x /root/source/MAFOT/build/bin/heatlaminar_mpi

COPY docker/spack/entrypoint.sh /entrypoint.sh
RUN chmod a+x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
CMD [ "/bin/bash" ]
