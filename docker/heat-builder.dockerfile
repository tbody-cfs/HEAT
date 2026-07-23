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

# System OpenGL dev libraries. spack.yaml declares `opengl` as an external at /usr and
# uses it as the gl/glx/egl provider, so spack does NOT build mesa (and therefore does
# NOT build llvm — mesa is llvm's only consumer here). These packages provide the GL
# headers/libs that vtk/freecad/gmsh link against at build time. HEAT renders via the
# Dash web GUI + apt ParaView (no in-process GL), so system GL is sufficient at runtime.
RUN apt-get -yqq update && apt-get -yqq install --no-install-recommends \
      libglvnd-dev libgl-dev libglx-dev libegl-dev mesa-common-dev libglu1-mesa-dev \
      libx11-dev libxext-dev \
 && rm -rf /var/lib/apt/lists/*

# Install tree root (/opt/software) — the tree copied wholesale into the final image.
COPY docker/spack/spack_config.yaml /root/.spack/config.yaml

# Register the image's system gcc as an external so spack does not rebuild a compiler.
RUN spack external find gcc

# Public spack binary mirror (covers common deps) + trust its signing keys.
RUN spack mirror add --scope site spack-public https://binaries.spack.io/develop \
 && spack buildcache keys --install --trust --yes-to-all

# The HEAT spack environment.
RUN mkdir -p /opt/spack-environment
COPY docker/spack/spack.yaml /opt/spack-environment/spack.yaml
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
# Two binary caches accelerate this, both unsigned:
#   * local-cache  — a directory buildcache on a BuildKit cache mount (/spack-cache).
#                    It persists across local `docker build`s on this machine, so
#                    re-running the build (even after invalidating this layer by
#                    editing spack.yaml) pulls already-built specs instead of
#                    recompiling. This is the DEVELOPMENT default and needs no creds.
#                    [TEMPORARY: remove/relegate once the shared ghcr cache is primary.]
#   * heat-oci     — the shared ghcr OCI cache, added only when SPACK_OCI_USER is set
#                    and a ghcr_token secret is provided. This is the eventual primary
#                    cache (CI + team); it stays wired so the pivot is just supplying
#                    the token.
#
# Install runs WITHOUT --fail-fast so one broken package does not abort the rest, and
# every successfully-built spec is pushed back to whichever caches are configured
# regardless of the overall result (self-warming). The real install exit code is
# re-propagated so CI still fails on a broken build.
# NOTE: use the explicit `spack -e .` env flag on every command. `spack env activate .`
# does not persist inside a non-interactive RUN (activation is a shell-function effect;
# here we invoke the spack binary on PATH, so the activation would be lost).
RUN --mount=type=secret,id=ghcr_token,required=false \
    --mount=type=cache,target=/spack-cache,sharing=locked \
    spack -e . mirror add --unsigned local-cache file:///spack-cache && \
    if [ -n "${SPACK_OCI_USER}" ] && [ -s /run/secrets/ghcr_token ]; then \
      export SPACK_OCI_TOKEN="$(cat /run/secrets/ghcr_token)" && \
      spack -e . mirror add --unsigned \
        --oci-username-variable SPACK_OCI_USER \
        --oci-password-variable SPACK_OCI_TOKEN \
        heat-oci "${SPACK_OCI_CACHE}" ; \
    fi && \
    { spack -e . install ; rc=$? ; \
      spack -e . buildcache push --unsigned --update-index --without-build-dependencies local-cache || true ; \
      if spack -e . mirror list | grep -q heat-oci ; then \
        spack -e . buildcache push --unsigned --update-index --without-build-dependencies heat-oci || true ; \
      fi ; \
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
