#!/usr/bin/env bash
# Build the GTK4 C demo against the local libtermview + libtermviewgtk4.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

OUT="$HERE/target"
mkdir -p "$OUT"

CFLAGS=$(pkg-config --cflags gtk4)
LIBS=$(pkg-config --libs gtk4)

cc -Wall -Wextra -O0 -g $CFLAGS \
   -I"$ROOT/ViewGtk4/include" \
   "$HERE/src/main.c" \
   -L"$ROOT/ViewGtk4/target"   -ltermviewgtk4 \
   -L"$ROOT/LibTermView/target" -ltermview \
   -Wl,-rpath,"$ROOT/ViewGtk4/target" \
   -Wl,-rpath,"$ROOT/LibTermView/target" \
   $LIBS \
   -o "$OUT/exampleterminalgtk4"

echo
echo "Built: $OUT/exampleterminalgtk4"
