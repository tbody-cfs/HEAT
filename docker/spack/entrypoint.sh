#!/usr/bin/env bash
# Container entrypoint for the HEAT spack images.
# Activates the spack environment (populating PATH/LD_LIBRARY_PATH/PYTHONPATH for the
# view) and the pip venv (if present), then execs the container command.
set -e

if [ -f /opt/spack-environment/activate.sh ]; then
    . /opt/spack-environment/activate.sh
fi

# pip-only Python packages live in a venv layered on the spack view's python
# (created with --system-site-packages so spack's numpy/scipy/vtk stay authoritative).
if [ -f /opt/venv/bin/activate ]; then
    . /opt/venv/bin/activate
fi

exec "$@"
