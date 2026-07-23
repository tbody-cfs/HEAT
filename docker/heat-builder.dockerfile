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

# NOTE: the public spack mirror (binaries.spack.io/develop) is intentionally NOT used.
# It almost never has a binary for our x86_64_v3 + this-concretization hashes (gotcha 12),
# so it only adds key-trust + per-spec lookup overhead. All caching is via the ghcr OCI
# cache and/or the local directory cache configured in the install step below.

# The HEAT spack environment.
RUN mkdir -p /opt/spack-environment
COPY docker/spack/spack.yaml /opt/spack-environment/spack.yaml
# Custom repo overlay (namespace: heat) with local package fixes (py-pivy C-dep); the
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
# Install runs WITHOUT --fail-fast so one broken package does not abort the rest, and the
# successful specs are pushed regardless of the overall result (self-warming). The real
# install exit code is re-propagated so CI still fails on a broken build.
# NOTE: use the explicit `spack -e .` env flag on every command. `spack env activate .`
# does not persist inside a non-interactive RUN (activation is a shell-function effect;
# here we invoke the spack binary on PATH, so the activation would be lost).
RUN --mount=type=secret,id=ghcr_token,required=false \
    --mount=type=cache,target=/spack-cache,sharing=locked \
    if [ -n "${SPACK_OCI_USER}" ] && [ -s /run/secrets/ghcr_token ]; then \
      export SPACK_OCI_TOKEN="$(cat /run/secrets/ghcr_token)" && \
      spack -e . mirror add --unsigned \
        --oci-username-variable SPACK_OCI_USER \
        --oci-password-variable SPACK_OCI_TOKEN \
        heat-oci "${SPACK_OCI_CACHE}" && \
      PUSH_TARGET=heat-oci ; \
    else \
      spack -e . mirror add --unsigned local-cache file:///spack-cache && \
      { spack -e . mirror add --unsigned heat-oci "${SPACK_OCI_CACHE}" || true ; } && \
      PUSH_TARGET=local-cache ; \
    fi && \
    { spack -e . install ; rc=$? ; \
      spack -e . buildcache push --unsigned --update-index --without-build-dependencies "${PUSH_TARGET}" || true ; \
      exit $rc ; }

# Generate the environment activation script the final image / entrypoint sources.
RUN spack env activate --sh -d . > activate.sh

# ======================================================================
# Phase 2 (native source builds: M3DC1/fusion-io, MAFOT+CUDA, heatFoam,
# swak4Foam) is appended below in a later step of the migration.
# ======================================================================

COPY docker/spack/entrypoint.sh /entrypoint.sh
RUN chmod a+x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
CMD [ "/bin/bash" ]
