# HEAT runtime image
# ==================
# Step 2 of the two-step spack build (step 1: docker/heat-builder.dockerfile).
# Copies the ready-built spack tree out of the builder and layers on:
#   * apt runtime bits (GL/X runtime libs, ParaView, git/git-lfs, small tools)
#   * /opt/venv — pip-only python packages on top of the spack view's python
#     (--system-site-packages, so spack's numpy/scipy/vtk stay authoritative;
#     see docker/requirements-spack.txt)
#   * the ORNL EFIT reader and the HEAT source tree
# It contains no compilers and no build trees, so it is comparatively small and
# fast to build: iterating on HEAT itself never re-runs spack.
#
# NOT YET INCLUDED (phase 2 of the migration, to be built in the builder):
# MAFOT, M3DC1/fusion-io, heatFoam, swak4Foam. Workflows that invoke those
# binaries (3D plasmas, openFOAM thermal solves) will fail in this image for now.
#
# Requires BuildKit (default in modern docker): per-Dockerfile .dockerignore,
# --mount=type=bind, COPY --chmod.
# Build (from the repo root):
#   docker build -f docker/heat.dockerfile -t plasmapotential/heat:spack .
# Against a locally produced builder (see docker/spack/make-builder-local.sh):
#   docker build -f docker/heat.dockerfile \
#     --build-arg BUILDER_IMAGE=heat-builder:local -t heat:spack-test .

ARG BUILDER_IMAGE=ghcr.io/plasmapotential/heat-builder:latest
FROM ${BUILDER_IMAGE} AS builder

# Pinned by manifest-list digest (multi-arch: one pin serves amd64 + arm64) so
# releases are reproducible; bump the digest deliberately, with the builder's base.
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
SHELL ["/bin/bash", "-c"]
LABEL org.opencontainers.image.authors="tlooby@cfs.energy"
ARG DEBIAN_FRONTEND=noninteractive
ENV runMode=docker

# The spack environment: metadata + activate.sh, the package tree, and the view.
# /opt/views/view is a symlink into the view storage; copying the PARENT directory
# keeps it a symlink instead of dereferencing and duplicating the whole tree.
COPY --from=builder /opt/spack-environment /opt/spack-environment
COPY --from=builder /opt/software /opt/software
COPY --from=builder /opt/views /opt/views

# apt runtime layer.
#  * GL/X runtime libraries: the spack env declares opengl as an external at /usr
#    (the builder apt-installs the -dev packages); these are the matching runtime
#    .so's that spack-built vtk/freecad/gmsh/qt link against. libgl1-mesa-dri
#    supplies software rasterization so headless hosts can render offscreen.
#  * python3-paraview: ParaView is deliberately NOT in spack (see spack.yaml) —
#    HEAT drives it through pvpython as a subprocess, so it does not need to share
#    the view python's ABI.
#  * git/git-lfs: HEAT workflows shell out to git; the rest are small diagnostics.
RUN apt-get -yqq update && apt-get -yqq install --no-install-recommends \
      libgl1 libglx0 libopengl0 libegl1 libglu1-mesa libgl1-mesa-dri \
      libx11-6 libxext6 libxrender1 libsm6 libice6 \
      python3-paraview \
      git git-lfs ca-certificates nano htop iputils-ping iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Paths for launchHEAT.py (docker mode). Each ENV below overrides the matching
# legacy-image default in source/launchHEAT.py:loadEnviron (see the comment there);
# unset vars keep their legacy defaults, which already fit this image (rootDir,
# EFITPath, PVPath, pvpythonCMD). OFversion is read unconditionally by launchHEAT
# and must match the openfoam version in docker/spack/spack.yaml. These are all
# validated at build time: pyFoamPath by the venv layer's asserts, the rest by
# the guard RUN further down — divergence fails the build with a message.
ENV OFversion=2306 \
    FreeCADPath=/opt/views/view/lib \
    FreeCADFEMPath=/opt/views/view/Mod/Fem \
    pyFoamPath=/opt/venv/lib/python3.11/site-packages

# pip-only python packages, in a venv layered over the spack view's python 3.11.
# --system-site-packages makes spack's compiled stack (numpy/scipy/vtk/...) visible
# inside the venv, so pip treats them as satisfied and everything shares one ABI.
# The entrypoint activates this venv after the spack env.
# The trailing asserts enforce that design: numpy/vtk must resolve to the spack
# tree (a pip wheel shadowing them = mixed ABIs; spack's vtk ships no dist-info,
# so pip cannot detect it and a stray `vtk` requirement WOULD pull the wheel),
# and PyFoam must land where the pyFoamPath ENV above points (breaks silently if
# spack ever bumps python off 3.11).
RUN --mount=type=bind,source=docker/requirements-spack.txt,target=/tmp/requirements-spack.txt \
    source /opt/spack-environment/activate.sh && \
    python3 -m venv --system-site-packages /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements-spack.txt && \
    /opt/venv/bin/python3 -c 'import numpy; assert numpy.__file__.startswith(("/opt/views/", "/opt/software/")), f"pip wheel shadows spack numpy: {numpy.__file__}"' && \
    /opt/venv/bin/python3 -c 'import vtk;   assert vtk.__file__.startswith(("/opt/views/", "/opt/software/")),   f"pip wheel shadows spack vtk: {vtk.__file__}"' && \
    /opt/venv/bin/python3 -c 'import os, PyFoam; assert PyFoam.__file__.startswith(os.environ["pyFoamPath"]), f"pyFoamPath ENV is stale: {PyFoam.__file__}"'

# ORNL EFIT class (GEQDSK reader). launchHEAT's default EFITPath is $HOME/source.
# EFIT_REF takes a branch or tag; pin it for release builds.
ARG EFIT_REF=master
RUN git clone -b "${EFIT_REF}" --single-branch --depth 1 \
      https://github.com/ORNL-Fusion/EFIT.git /root/source/EFIT

# Guard RUN: validate the launchHEAT path ENVs against the copied spack tree, and
# resolve OpenFOAM's etc/bashrc (it lives in a hash-named spack install prefix)
# into a stable path for the OFbashrc env var.
RUN set -euo pipefail && shopt -s nullglob && \
    compgen -G "${FreeCADPath}/FreeCAD*.so" >/dev/null || \
      { echo "ERROR: no FreeCAD*.so under FreeCADPath=${FreeCADPath} — freecad missing from the view?" >&2; exit 1; } && \
    [ -d "${FreeCADFEMPath}" ] || \
      { echo "ERROR: FreeCADFEMPath=${FreeCADFEMPath} does not exist" >&2; exit 1; } && \
    of=(/opt/software/linux-*/openfoam-*) && \
    { [ ${#of[@]} -eq 1 ] && [ -f "${of[0]}/etc/bashrc" ]; } || \
      { echo "ERROR: expected exactly one openfoam prefix with etc/bashrc, got: ${of[*]:-none}" >&2; exit 1; } && \
    [[ "${of[0]}" == */openfoam-${OFversion}-* ]] || \
      { echo "ERROR: ${of[0]} does not match OFversion=${OFversion} — spack.yaml and this ENV diverged" >&2; exit 1; } && \
    ln -s "${of[0]}/etc/bashrc" /etc/openfoam-bashrc
ENV OFbashrc=/etc/openfoam-bashrc

COPY --chmod=755 docker/spack/entrypoint.sh /entrypoint.sh

# HEAT source, from the build context — kept LAST so iterating on HEAT invalidates
# only this layer and the lfs guard. docker-compose bind-mounts the live checkout
# over this path during development, so image rebuilds are only needed for releases.
COPY . /root/source/HEAT

# *.h5 test fixtures are git-lfs objects (.gitattributes). COPY takes the working
# tree as-is: on a checkout made without git-lfs, those files are 130-byte pointer
# stubs and integration tests would fail obscurely at runtime — catch it here.
# (grep -I skips binary files, so real HDF5 content never matches.)
RUN ! grep -rlI --include='*.h5' '^version https://git-lfs' /root/source/HEAT || \
    { echo "ERROR: git-lfs pointer files were copied in (listed above) — run 'git lfs pull' in the checkout, then rebuild" >&2; exit 1; }

EXPOSE 8050
WORKDIR /root

# /entrypoint.sh activates the spack env + venv, then execs the command. The
# launchHEAT invocation stays in ENTRYPOINT (legacy parity), so
# `docker run <image> --m t --f batch.dat` appends flags to launchHEAT rather
# than replacing the program; override --entrypoint for a raw shell.
ENTRYPOINT [ "/entrypoint.sh", "python3", "/root/source/HEAT/source/launchHEAT.py" ]
CMD [ "--a", "0.0.0.0", "--p", "8050", "--m", "g" ]
