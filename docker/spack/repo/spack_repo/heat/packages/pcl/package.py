# HEAT overlay of the spack builtin pcl (spack 1.2.2).
#
# Sole change vs builtin: force PCL_ENABLE_MARCHNATIVE=OFF.
#
# PCL's cmake/pcl_find_sse.cmake appends "-march=native" to SSE_FLAGS whenever
# PCL_ENABLE_MARCHNATIVE is ON (its default). That flag is harmful twice over:
#   1. pcl's own objects get compiled for the build host's exact microarch, and
#   2. it is baked into the INSTALLED PCLConfig.cmake as PCL_COMPILE_OPTIONS
#      (PCLConfig.cmake: `list(APPEND PCL_COMPILE_OPTIONS ... -march=native)`), so every
#      downstream consumer that does find_package(PCL) inherits it too — e.g. freecad's
#      PCL-using modules (ReverseEngineering, Mesh) pick up -march=native purely via PCL.
# On an AVX-512-capable build host this yields unguarded AVX-512 in pcl AND in those freecad
# modules, silently overriding spack's portable target (x86_64_v3) — the resulting binaries
# SIGILL on any CPU without AVX-512.
#
# MARCHNATIVE=OFF drops ONLY "-march=native"; pcl keeps its -msse4.2/-mavx2 flags (both inside
# x86_64_v3) and spack's own -march=x86-64-v3 still applies, so there is no real vectorization
# loss. The flag is x86-specific in PCL (no-op on aarch64), but the override is unconditional:
# an overlay changes pcl's package hash on every arch regardless, and OFF is behaviourally
# neutral where the native path never fired.

from spack_repo.builtin.packages.pcl.package import Pcl as BuiltinPcl

from spack.package import *


class Pcl(BuiltinPcl):
    def cmake_args(self):
        args = super().cmake_args()
        args.append(self.define("PCL_ENABLE_MARCHNATIVE", False))
        return args
