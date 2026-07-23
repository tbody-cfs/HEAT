#!/usr/bin/env bash
# ============================================================================
# HEAT spack builder — LOCAL ITERATION HARNESS
# ============================================================================
# Runs the exact spack environment the builder image uses (docker/spack/spack.yaml
# + the heat repo overlay + spack_config.yaml) but via `docker run` instead of
# `docker build`, so that:
#
#   * the buildcache lives in a HOST directory and persists across runs — a killed
#     or failed run keeps every spec built so far (spack --autopush writes each spec
#     the instant it finishes), and re-running reuses them instead of recompiling;
#   * the spack stage logs are reachable (they are inside the running container and,
#     on failure, this script prints the full failed-build logs to stdout);
#   * you can install a SINGLE spec (+ its deps) to debug one package quickly.
#
# This is a DEV/DEBUG tool. It is NOT how the shipped image is built. To build the
# real builder image exactly as CI does:
#     docker build -f docker/heat-builder.dockerfile -t heat-builder:test .
# See docker/spack/README.md for the full maintainer guide.
#
# ----------------------------------------------------------------------------
# Usage (run from anywhere in the repo):
#   docker/spack/build-local.sh                    # concretize + install the whole env
#   docker/spack/build-local.sh --spec qt          # install just `qt` (+deps), e.g. to debug it
#   HEAT_SPACK_CACHE=/data/heat-cache docker/spack/build-local.sh   # custom cache location
#
# Environment overrides:
#   HEAT_SPACK_CACHE       host dir for the persistent buildcache (default: ~/.cache/heat-spack)
#   HEAT_STAGE_TMPFS_SIZE  size cap for the build-stage tmpfs   (default: 40g)
#   HEAT_BUILDER_IMAGE     base spack image                     (default: pinned below)
# ============================================================================
set -uo pipefail

# Pinned to match docker/heat-builder.dockerfile's FROM (keep the two in sync).
IMAGE="${HEAT_BUILDER_IMAGE:-spack/ubuntu-noble:1.2.2@sha256:8949b2615bc4de2c12399510a0dfcc38ae586cf6e0de2ae886fdc849e17cda97}"

# ---------------------------------------------------------------------------
# HOST SIDE: set up mounts and re-exec this same script inside the container.
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--in-container" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../docker/spack
  CACHE_DIR="${HEAT_SPACK_CACHE:-$HOME/.cache/heat-spack}"
  TMPFS_SIZE="${HEAT_STAGE_TMPFS_SIZE:-40g}"
  mkdir -p "$CACHE_DIR"
  echo ">> spack env  : $SCRIPT_DIR/spack.yaml"
  echo ">> repo overlay: $SCRIPT_DIR/repo"
  echo ">> buildcache : $CACHE_DIR  (persists across runs; safe to delete to start cold)"
  echo ">> image      : $IMAGE"
  # --entrypoint bash: the spack base image's entrypoint wraps args as spack subcommands;
  #   we need a raw shell to run this script.
  # tmpfs at the stage root MUST be exec (default is noexec) or configure scripts fail
  #   with "Permission denied" at 0s. size is a cap, not a reservation.
  exec docker run --rm -it \
    --name heat-build-local \
    --entrypoint bash \
    -v "$SCRIPT_DIR":/host:ro \
    -v "$CACHE_DIR":/spack-cache \
    --tmpfs "/tmp/root/spack-stage:rw,exec,size=${TMPFS_SIZE}" \
    "$IMAGE" /host/build-local.sh --in-container "$@"
fi

# ---------------------------------------------------------------------------
# IN-CONTAINER SIDE
# ---------------------------------------------------------------------------
shift                                    # drop the --in-container sentinel
SPEC="${2:-}"                            # if invoked as `--spec X`, $1=--spec $2=X
if [ "${1:-}" = "--spec" ] && [ -z "${SPEC}" ]; then
  echo "ERROR: --spec requires a spec argument, e.g. --spec qt" >&2; exit 2
fi
[ "${1:-}" = "--spec" ] || SPEC=""       # only honor a spec after the --spec flag

export PATH=/opt/spack/bin:$PATH
echo "===== SETUP $(grep VERSION= /etc/os-release) ====="
mkdir -p /root/.spack && cp /host/spack_config.yaml /root/.spack/config.yaml

# System OpenGL + LLVM-15 dev libs — declared as spack externals in spack.yaml.
# (Mirror the apt list in docker/heat-builder.dockerfile; keep the two in sync.)
apt-get -yqq update >/dev/null 2>&1
apt-get -yqq install --no-install-recommends \
  libglvnd-dev libgl-dev libglx-dev libegl-dev mesa-common-dev libglu1-mesa-dev \
  libx11-dev libxext-dev \
  llvm-15 llvm-15-dev llvm-15-tools libclang-15-dev clang-15 libclang-common-15-dev >/dev/null 2>&1

spack external find gcc >/dev/null 2>&1

# Public spack BINARY mirror: prebuilt binaries for the common toolchain (gmake, perl,
# cmake, ncurses, ...) at generic targets — big speedup on a cold build. Signed -> trust
# keys. Named "spack-binaries" NOT "spack-public": the base image ships a default
# "spack-public" -> mirror.spack.io SOURCE mirror; reusing that name would shadow it and
# break from-source fetches (see docker/heat-builder.dockerfile for the full note).
spack mirror add --scope site spack-binaries https://binaries.spack.io/develop >/dev/null 2>&1
spack buildcache keys --install --trust --yes-to-all >/dev/null 2>&1

mkdir -p /opt/spack-environment
cp /host/spack.yaml /opt/spack-environment/spack.yaml
cp -r /host/repo    /opt/spack-environment/repo
cd /opt/spack-environment

# Portable per-arch target (matches the Dockerfile). x86_64_v3 on amd64.
case "$(uname -m)" in
  aarch64) HEAT_TARGET=aarch64 ;;
  x86_64)  HEAT_TARGET=x86_64_v3 ;;
  *)       HEAT_TARGET="$(uname -m)" ;;
esac
spack -e . config add "packages:all:require:target=${HEAT_TARGET}"

# Persistent host buildcache with --autopush: each spec is pushed the moment it builds,
# so a killed/failed run still leaves every finished spec cached and reusable next time.
spack -e . mirror add --unsigned --autopush local-cache file:///spack-cache

echo "===== CACHE STATE BEFORE INSTALL ====="
spack -e . buildcache list --allarch local-cache 2>/dev/null | tail -8 || echo "(cache empty / first run)"

echo "===== INSTALL START ${SPEC:+(single spec: $SPEC)} ====="
# --no-checksum: same default as the Dockerfile (spack 1.2.2 lacks checksums for a few
# newer sources, e.g. perl@5.42.2). Buildcache binaries are still signature-verified.
spack -e . install --no-checksum ${SPEC}
rc=$?

echo "===== INSTALL DONE rc=$rc ====="
if [ "$rc" -ne 0 ]; then
  echo "===== FULL FAILED BUILD LOGS ====="
  for d in /tmp/root/spack-stage/spack-stage-*/; do
    echo "################################## $d"
    echo "----- spack-build-out.txt -----";  cat "$d"spack-build-out.txt  2>/dev/null
    echo "----- spack-build-error.txt -----"; cat "$d"spack-build-error.txt 2>/dev/null
  done
  echo "===== END FAILED LOGS ====="
fi
echo "===== HEAT LOCAL BUILD COMPLETE rc=$rc ====="
exit $rc
