#!/usr/bin/env bash
# Build ExampleTerminalLCL with lazbuild.
# Registers the TerminalFramework and ViewLCL packages on the fly, then builds the .lpi.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

LAZBUILD="${LAZBUILD:-lazbuild}"

"$LAZBUILD" --add-package-link "$ROOT/TerminalFramework/TerminalFramework.lpk"
"$LAZBUILD" --add-package-link "$ROOT/ViewLCL/ViewLCL.lpk"

"$LAZBUILD" "$HERE/src/main/pascal/ExampleTerminalLCL.lpi" "$@"

echo
echo "Built: $HERE/target/exampleterminallcl"
