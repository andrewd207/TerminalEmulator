#!/usr/bin/env bash
# Cross-compile ExampleTerminal for Windows x86_64 using FPC -Twin64.
# pasbuild does not currently cross-compile well, so we drive fpc directly.
# Prereq: fpGUI win64 ppus at
#   ~/.pasbuild/repository/fpgui-framework/2.1.0/x86_64-win64-3.3.1/
# and a working FPC 3.3.1 with win64 RTL (the default install supports -Twin64).

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="target/win64"
UNIT_DIR="$OUT_DIR/units"
EXE_NAME="ExampleTerminal.exe"

FPGUI_WIN64_UNITS="$HOME/.pasbuild/repository/fpgui-framework/2.1.0/x86_64-win64-3.3.1"

if [[ ! -d "$FPGUI_WIN64_UNITS" ]]; then
  echo "error: fpGUI win64 units not found at: $FPGUI_WIN64_UNITS" >&2
  echo "       build/install fpgui-framework for x86_64-win64 first." >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"

echo "==> Cross-compiling for Win64 -> $OUT_DIR/$EXE_NAME"

fpc \
  -Twin64 -Px86_64 -Mobjfpc -O1 \
  -WG \
  -FE"$OUT_DIR" -FU"$UNIT_DIR" \
  -o"$EXE_NAME" \
  -Fu"$FPGUI_WIN64_UNITS" \
  -FuTerminalFramework/src/main/pascal \
  -FuViewfpGUI/src/main/pascal \
  -dGDI -dWINDOWS \
  ExampleTerminal/src/main/pascal/ExampleTerminal.pas

echo "==> Built $OUT_DIR/$EXE_NAME"
