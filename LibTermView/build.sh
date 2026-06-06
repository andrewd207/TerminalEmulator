#!/usr/bin/env bash
# Build libtermview.so (+ .a) from the Pascal source.
# Depends on TerminalFramework being pre-compiled (its .ppu/.o units land in
# ../TerminalFramework/target/units after `make TerminalFramework`).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FW_SRC="$ROOT/TerminalFramework/src/main/pascal"
PIC_UNITS="$HERE/target/fw-units-pic"
SRC="$HERE/src/main/pascal/libtermview.pas"
OUT_DIR="$HERE/target"
SO="$OUT_DIR/libtermview.so"

mkdir -p "$OUT_DIR/units" "$PIC_UNITS"

# Let FPC pull the framework sources in, compiling them with -Cg as needed.
# (Reusing the pasbuild .o cache would fail with "R_X86_64_32S against hidden
# symbol... can not be used when making a shared object" because the main
# build doesn't pass -Cg / PIC.)
UNITS="$FW_SRC"

# Force PIC (-Cg) so the units link into a shared library cleanly.
fpc \
  -MObjFPC -Sh \
  -Cg \
  -Fu"$UNITS" \
  -FU"$OUT_DIR/units" \
  -FE"$OUT_DIR" \
  -o"$SO" \
  -B \
  "$SRC"

# Static archive: bundle every .o the fpc bootstrap produced for the library.
# (FPC's static link from C requires the RTL too; archive what we built so
# downstream `cc *.o` style linking can pick units up. Pure libtermview .a is
# what we shipper here — host C app must still pull in the FPC runtime via
# .so or by linking against fpc's prtX.o/cprt0.o; the .so path is preferred.)
find "$OUT_DIR/units" -maxdepth 1 -name '*.o' -print0 \
  | xargs -0 ar rcs "$OUT_DIR/libtermview.a" 2>/dev/null || true

echo
echo "Built: $SO"
[ -f "$OUT_DIR/libtermview.a" ] && echo "Built: $OUT_DIR/libtermview.a"
