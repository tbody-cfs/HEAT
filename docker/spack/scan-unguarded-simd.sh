#!/usr/bin/env bash
#
# scan-unguarded-simd.sh — portability regression gate for the HEAT spack build.
#
# Fails (exit 1) if any installed library carries post-baseline SIMD that is NOT behind
# runtime CPU dispatch — i.e. a `-march=native`-style leak past the portable spack target
# (x86_64_v3 on amd64, baseline armv8-a on aarch64). Such instructions SIGILL on any CPU
# below the build host, silently breaking the "portable" image.
#
# Background: PCL's CMake bakes `-march=native` into its own objects and its exported
# PCLConfig.cmake, which leaked unguarded AVX-512 into pcl AND freecad (fixed by the heat
# pcl overlay, PCL_ENABLE_MARCHNATIVE=OFF). This gate catches the next such leak automatically.
#
# Method (same one used to diagnose that leak):
#   1. Disassemble each lib; find post-baseline SIMD instructions.
#        x86_64 : AVX-512 — %zmm regs / {%k1..7} opmask writemask.
#        aarch64: SVE (z-regs / ptrue / whilelo / movprfx) + post-baseline ISA mnemonics
#                 (dotprod sdot/udot, i8mm *mmla, bf16 bfdot/bfmmla, sha512/sha3 eor3/bcax/xar).
#      NEON v-regs (arm) and SSE/AVX2 (x86) are baseline — never flagged.
#   2. Attribute each hit to its enclosing symbol. A lib is a LEAK only if a hit lands in a
#      "plain" symbol — one NOT named like a runtime-dispatch variant (*_avx*/*_sve/dispatch/
#      resolver/cpu/ifunc/...). Guarded kernels (chosen at runtime by CPUID/HWCAP) are fine.
#   3. Allowlist packages whose dispatch uses a mechanism step 2's name heuristic can't see
#      (raw cpuid / getauxval at init, function tables, vendor-internal dispatch) and which we
#      do not compile with native flags — e.g. openssl, py-numpy, zlib-ng, libgfortran, openmpi.
#      See ALLOW_RE below for the full list + the per-package verification behind each entry.
#
# Usage: scan-unguarded-simd.sh [INSTALL_ROOT]   (default: /opt/software)
set -uo pipefail

ROOT="${1:-/opt/software}"
ARCH="$(uname -m)"

# Packages allowlisted: upstream libraries that ship post-baseline SIMD fast paths selected
# by their OWN runtime CPU dispatch (raw cpuid/getauxval at init, function tables, vendor
# dispatchers) — a mechanism the symbol-name heuristic below cannot see — and which we do not
# compile with -march=native. Each verified by hand (cpuid/feature-detection present, fast
# path reached indirectly), not assumed. Matched against the spack prefix directory name:
#   gcc-runtime  libgfortran matmul (13 cpuid + guarded avx512 variants)
#   openmpi      op/avx & op/aarch64 MCA kernels (CPUID/HWCAP-gated at component init)
#   intel-oneapi SVML / imf (vendor-internal dispatch)
#   llvm         build-only; not shipped
#   openssl      libcrypto VAES/AVX-512 crypto via OPENSSL_ia32cap_P (10 cpuid at init)
#   py-numpy     npy_cpu_* dispatcher (baseline X86_V2 → X86_V4 targets) + embedded SVML
#   zlib-ng      functable/x86_check_features (VPCLMULQDQ CRC fast path; 3 cpuid at init)
#   openblas     gotoblas_dynamic_init DYNAMIC_ARCH: uarch-suffixed kernels (aarch64 ARMV8SVE/
#                NEOVERSE*/A64FX; x86 SKYLAKEX/COOPERLAKE) selected via getauxval+midr_el1 /
#                cpuid at init; SVE/AVX-512 absent from the baseline kernel. NB those uarch
#                names (SKYLAKEX ≠ _skx) don't match DISP_RE, so the allowlist — not the name
#                heuristic — is what covers openblas.
ALLOW_RE='(^|/)(gcc-runtime|openmpi|intel-oneapi|llvm|openssl|py-numpy|zlib-ng|openblas)-'

# CRITICAL: VEC_RE is passed to `objdump | awk -v vec=…`, and awk's -v processes C escape
# sequences in the value — so a `\b` word-boundary becomes a literal BACKSPACE (0x08) and
# matches nothing, silently making the whole gate inert (always PASS, even on a real leak;
# caught in end-to-end aarch64 validation). Keep VEC_RE FREE OF BACKSLASH ESCAPES: use
# character-class boundaries [^[:alnum:]_] instead of \b, and [{] / [.] instead of \{ / \.
# (DISP_RE/ALLOW_RE below go to grep, not awk, so they're unaffected.)
B='[^[:alnum:]_]'
case "$ARCH" in
  x86_64)
    # %zmm regs / {%k1..7} opmask writemask = AVX-512 (sigil-prefixed, no word-boundary needed).
    VEC_RE='%zmm[0-9]|[{]%k[1-7][}]'
    # `cpu` alone is too broad (matches any symbol containing "cpu"); anchor it.
    # `x86_v[0-9]` = numpy/highway-style dispatch-target suffix (…_X86_V4); a deliberate
    # dispatch marker, never an incidental name in a genuine leak.
    DISP_RE='avx512|_avx|_skx|_znver|x86_v[0-9]|dispatch|resolver|cpuid|_cpu|cpu_|ifunc|multiversion'
    ISA_NAME='AVX-512' ;;
  aarch64)
    # z-registers/predicate ops = SVE (SVE-only; NEON uses v-regs). Plus post-baseline ISA mnemonics.
    # dot/mmla take a 1-2 char signedness prefix (sdot/udot/usdot/sudot, smmla/ummla/usmmla) —
    # usdot/usmmla are exactly what -mcpu=native emits on Graviton3+ (i8mm), so match all prefixes.
    VEC_RE="(^|$B)(z[0-9]+[.][bhsdq]|ptrue|whilel[eot]|movprfx|(s|u|us|su)dot|(s|u|us)mmla|bfdot|bfmmla|eor3|bcax|xar)($B|\$)"
    DISP_RE='_sve|sve2|_neon|dispatch|resolver|hwcap|ifunc|outline'
    ISA_NAME='SVE/post-baseline' ;;
  *)
    echo "scan-unguarded-simd: unknown arch '$ARCH' — skipping (no baseline defined)"; exit 0 ;;
esac

echo "===== unguarded-SIMD portability gate ($ISA_NAME, arch=$ARCH, root=$ROOT) ====="
leaks=0
scanned=0
skipped=0

# RECURSIVE on purpose: a non-recursive lib/ glob misses whole classes — openfoam ships
# its .so under platforms/<arch>/lib/, and spack py-* extensions live under
# lib/pythonX.Y/site-packages/. Both must be scanned. `find` also has no ARG_MAX limit.
ROOT="${ROOT%/}"
while IFS= read -r so; do
  case "$so" in *.debug) continue;; esac
  # pkg = the spack install dir, the component right under the arch dir:
  #   $ROOT/linux-<arch>/<pkg-ver-hash>/... (works for nested platforms/ and site-packages/ too)
  rel="${so#"$ROOT"/}"
  pkg="$(printf '%s\n' "$rel" | cut -d/ -f2)"
  if printf '%s\n' "$so" | grep -qE "$ALLOW_RE"; then
    skipped=$((skipped+1)); continue
  fi
  scanned=$((scanned+1))
  # symbols that CONTAIN a post-baseline instruction
  hit_syms="$(objdump -d "$so" 2>/dev/null | awk -v vec="$VEC_RE" '
      /^[0-9a-f]+ <.*>:/ { s=$0; sub(/^[0-9a-f]+ </,"",s); sub(/>:.*/,"",s) }
      $0 ~ vec { print s }' | sort -u)"
  [ -z "$hit_syms" ] && continue
  # of those, the ones NOT named like a runtime-dispatch variant = UNGUARDED.
  # Case-INSENSITIVE: numpy's guarded kernels use UPPERCASE suffixes (…_AVX512F, …_SKX);
  # a case-sensitive match would flag them as unguarded leaks.
  plain="$(printf '%s\n' "$hit_syms" | grep -viE "$DISP_RE")"
  if [ -n "$plain" ]; then
    leaks=$((leaks+1))
    echo "LEAK: $pkg :: $(basename "$so")"
    printf '%s\n' "$plain" | head -5 | sed 's/^/        /'
    np="$(printf '%s\n' "$plain" | grep -c .)"
    [ "$np" -gt 5 ] && echo "        … +$((np-5)) more unguarded symbols"
  fi
done < <(find "$ROOT" -type f -name '*.so*' 2>/dev/null | sort)

echo "===== scanned $scanned libs, allowlisted $skipped, $leaks leaking ====="
if [ "$leaks" -gt 0 ]; then
  echo "FAIL: unguarded $ISA_NAME found — a build flag ( -march=native / -mcpu=native ) is"
  echo "overriding the portable target. Fix at source (e.g. disable the package's native path),"
  echo "or if genuinely runtime-dispatched, add the package to ALLOW_RE with a comment."
  exit 1
fi
echo "PASS: no unguarded post-baseline SIMD; image is portable to the spack target."
exit 0
