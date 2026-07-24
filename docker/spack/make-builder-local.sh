#!/usr/bin/env bash
# ============================================================================
# Make a LOCAL heat-builder image from the dev-harness buildcache
# ============================================================================
# `docker build -f docker/heat-builder.dockerfile` starts from an EMPTY BuildKit
# cache mount, so a first local build recompiles the whole stack even when the
# build-local.sh host cache (HEAT_SPACK_CACHE) is fully warm. This script
# produces an equivalent builder image FAST instead: it runs the same
# in-container install that build-local.sh runs (full binary reuse from the warm
# host cache), adds the two things the real builder image has on top of that
# (the generated activate.sh and /entrypoint.sh), and `docker commit`s the
# result as heat-builder:local.
#
# This is a TEST tool for iterating on docker/heat.dockerfile:
#   docker/spack/make-builder-local.sh          # -> image heat-builder:local
#   docker build -f docker/heat.dockerfile \
#     --build-arg BUILDER_IMAGE=heat-builder:local -t heat:spack-test .
# The shipped builder is still built by docker build / CI from
# docker/heat-builder.dockerfile.
#
# Environment overrides (same as build-local.sh, plus the output tag):
#   HEAT_SPACK_CACHE         host dir with the persistent buildcache
#   HEAT_STAGE_TMPFS_SIZE    build-stage tmpfs cap        (default: 40g)
#   HEAT_BUILDER_IMAGE       base spack image             (default: pinned below)
#   HEAT_BUILDER_LOCAL_TAG   tag for the committed image  (default: heat-builder:local)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${HEAT_SPACK_CACHE:-$HOME/.cache/heat-spack}"
TMPFS_SIZE="${HEAT_STAGE_TMPFS_SIZE:-40g}"
# Pinned to match docker/heat-builder.dockerfile's FROM (keep the two in sync).
IMAGE="${HEAT_BUILDER_IMAGE:-spack/ubuntu-noble:1.2.2@sha256:8949b2615bc4de2c12399510a0dfcc38ae586cf6e0de2ae886fdc849e17cda97}"
TAG="${HEAT_BUILDER_LOCAL_TAG:-heat-builder:local}"
CONTAINER=heat-builder-commit

echo ">> cache : $CACHE_DIR"
echo ">> base  : $IMAGE"
echo ">> tag   : $TAG"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# No --rm: the stopped container is committed below. The tmpfs (spack build
# stage) and the two mounts are excluded from the commit automatically, so the
# image carries only /opt/software + /opt/spack-environment + the apt layer —
# the same payload as the real builder.
docker run --name "$CONTAINER" --entrypoint bash \
  -v "$SCRIPT_DIR":/host:ro \
  -v "$CACHE_DIR":/spack-cache \
  --tmpfs "/tmp/root/spack-stage:rw,exec,size=${TMPFS_SIZE}" \
  "$IMAGE" -c '
    set -euo pipefail
    bash /host/build-local.sh --in-container
    export PATH=/opt/spack/bin:$PATH
    cd /opt/spack-environment
    spack env activate --sh -d . > activate.sh
    cp /host/entrypoint.sh /entrypoint.sh && chmod a+x /entrypoint.sh
    apt-get clean && rm -rf /var/lib/apt/lists/*
  '

docker commit \
  --change 'ENV PATH=/opt/spack/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  --change 'ENTRYPOINT ["/entrypoint.sh"]' \
  --change 'CMD ["/bin/bash"]' \
  "$CONTAINER" "$TAG" >/dev/null

docker rm "$CONTAINER" >/dev/null
echo ">> built $TAG"
