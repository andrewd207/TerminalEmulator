#!/usr/bin/env bash
# Build libtermviewgtk4.so (+ .a) — the GTK4 widget layer.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

OUT="$HERE/target"
mkdir -p "$OUT"

CFLAGS=$(pkg-config --cflags gtk4 pangocairo)
LIBS=$(pkg-config --libs   gtk4 pangocairo)

WARN="-Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations"
INC="-I$HERE/include -I$ROOT/LibTermView/src/main/pascal"

cc $WARN $CFLAGS $INC -fPIC -c "$HERE/src/term_view_widget.c" -o "$OUT/term_view_widget.o"

cc -shared -o "$OUT/libtermviewgtk4.so" "$OUT/term_view_widget.o" \
    -L"$ROOT/LibTermView/target" -ltermview $LIBS \
    -Wl,-rpath,'$ORIGIN' -Wl,-rpath,"$ROOT/LibTermView/target"

ar rcs "$OUT/libtermviewgtk4.a" "$OUT/term_view_widget.o"

echo
echo "Built: $OUT/libtermviewgtk4.so"
echo "Built: $OUT/libtermviewgtk4.a"
