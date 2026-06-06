#!/usr/bin/env bash
# Build and package release zips for the four shipping front-ends:
#   - termview-gtk4-<VER>-linux-x86_64.zip     (GTK4 C: bins + .so + .h + install.sh)
#   - termview-lcl-<VER>-linux-x86_64.zip      (LCL Linux demo binary + install.sh)
#   - termview-fpgui-<VER>-linux-x86_64.zip    (fpGUI Linux demo binary + install.sh)
#   - termview-fpgui-<VER>-win64.zip           (fpGUI Win64 .exe, no installer)
#
# Each install.sh supports:
#   ./install.sh              -> /usr/local (sudo)
#   ./install.sh --user       -> $HOME/.local (no sudo)
#   PREFIX=/opt/foo ./install.sh    -> explicit prefix
#
# Output: release/*.zip
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION_BASE="$(grep -oP '<version>\K[^<]+' project.xml | head -1)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
VER="${VERSION_BASE}+${SHA}"

REL="$ROOT/release"
STAGE="$REL/staging"
rm -rf "$REL"
mkdir -p "$REL" "$STAGE"

echo "==> Version: $VER"

# ------------------------------------------------------------------
# Prereqs: build everything we need.
# ------------------------------------------------------------------
echo "==> Building Linux artifacts (make)"
make >/dev/null

# Re-link the GTK4 components for release with clean ($ORIGIN-only) rpath.
GTK4_REL_DIR="$REL/build-gtk4"
mkdir -p "$GTK4_REL_DIR"
echo "==> Re-linking GTK4 binaries for distribution rpath"
CFLAGS=$(pkg-config --cflags gtk4 pangocairo)
LIBS=$(pkg-config --libs gtk4 pangocairo)
cc -Wall -O2 -fPIC $CFLAGS \
   -I ViewGtk4/include -I LibTermView/src/main/pascal \
   -c ViewGtk4/src/term_view_widget.c -o "$GTK4_REL_DIR/term_view_widget.o"
cp LibTermView/target/libtermview.so "$GTK4_REL_DIR/"
cc -shared -o "$GTK4_REL_DIR/libtermviewgtk4.so" \
   "$GTK4_REL_DIR/term_view_widget.o" \
   -L "$GTK4_REL_DIR" -ltermview $LIBS \
   -Wl,-rpath,'$ORIGIN'
cc -Wall -O2 $(pkg-config --cflags gtk4) \
   -I ViewGtk4/include \
   ExampleTerminalGtk4/src/main.c \
   -L "$GTK4_REL_DIR" -ltermviewgtk4 -ltermview \
   $(pkg-config --libs gtk4) \
   -Wl,-rpath,'$ORIGIN/../lib' \
   -o "$GTK4_REL_DIR/exampleterminalgtk4"

# Build win64 fpGUI.
if [[ ! -x tools/build-win64.sh ]]; then
  echo "warning: tools/build-win64.sh not found; skipping win64 zip" >&2
  HAVE_WIN64=0
else
  echo "==> Building Win64 fpGUI demo"
  bash tools/build-win64.sh >/dev/null
  HAVE_WIN64=1
fi

# ------------------------------------------------------------------
# Shared install.sh writer for the Linux zips.
# ------------------------------------------------------------------
write_install_sh() {
  local dest="$1"; shift
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
# Install layout (relative paths under PREFIX):
#   bin/   -> $PREFIX/bin
#   lib/   -> $PREFIX/lib
#   include/ -> $PREFIX/include
#
# Default: PREFIX=/usr/local (may need sudo).
# Pass --user for $HOME/.local. Or set PREFIX=... explicitly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--user" ]]; then
  PREFIX="${PREFIX:-$HOME/.local}"
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 [--user]"
  echo "  default: install to /usr/local (may need sudo)"
  echo "  --user : install to \$HOME/.local"
  echo "  PREFIX=/opt/foo $0 : explicit prefix"
  exit 0
else
  PREFIX="${PREFIX:-/usr/local}"
fi

install_dir() {
  local src="$1"; local dst="$2"; local mode="$3"
  [[ -d "$src" ]] || return 0
  install -d -m 755 "$dst"
  for f in "$src"/*; do
    [[ -e "$f" ]] || continue
    install -m "$mode" "$f" "$dst/$(basename "$f")"
  done
}

echo "Installing to: $PREFIX"
install_dir "$HERE/bin"     "$PREFIX/bin"     755
install_dir "$HERE/lib"     "$PREFIX/lib"     755
install_dir "$HERE/include" "$PREFIX/include" 644

if command -v ldconfig >/dev/null 2>&1 && [[ -d "$HERE/lib" ]]; then
  if [[ "$PREFIX" == "/usr/local" || "$PREFIX" == "/usr" ]]; then
    ldconfig "$PREFIX/lib" 2>/dev/null || true
  else
    echo "note: add $PREFIX/lib to your loader path (LD_LIBRARY_PATH or /etc/ld.so.conf.d) if needed"
  fi
fi
echo "Done."
EOF
  chmod +x "$dest"
}

# ------------------------------------------------------------------
# 1) GTK4 zip — binaries + headers + install.sh
# ------------------------------------------------------------------
GTK4_STAGE="$STAGE/termview-gtk4-${VER}-linux-x86_64"
mkdir -p "$GTK4_STAGE"/{bin,lib,include}
install -m 755 "$GTK4_REL_DIR/exampleterminalgtk4" "$GTK4_STAGE/bin/"
install -m 755 "$GTK4_REL_DIR/libtermview.so"     "$GTK4_STAGE/lib/"
install -m 755 "$GTK4_REL_DIR/libtermviewgtk4.so" "$GTK4_STAGE/lib/"
install -m 644 ViewGtk4/include/termview.h          "$GTK4_STAGE/include/"
install -m 644 ViewGtk4/include/term_view_widget.h  "$GTK4_STAGE/include/"

cat > "$GTK4_STAGE/README.md" <<EOF
# TermView — GTK4 (Linux x86_64) — ${VER}

A GTK4 terminal widget backed by the Free Pascal TerminalEmulator core.

## Install

\`\`\`
./install.sh           # /usr/local (sudo)
./install.sh --user    # \$HOME/.local
PREFIX=/opt/term ./install.sh
\`\`\`

Installs:
- \`bin/exampleterminalgtk4\` — demo
- \`lib/libtermview.so\` + \`lib/libtermviewgtk4.so\`
- \`include/termview.h\` (C ABI) + \`include/term_view_widget.h\` (GTK4 widget)

## Run

\`\`\`
\$PREFIX/bin/exampleterminalgtk4
\`\`\`

## Embed in your own GTK4 app

\`\`\`c
#include <term_view_widget.h>
GtkWidget *t = term_view_widget_new();
term_view_widget_start_shell(TERM_VIEW_WIDGET(t), NULL);
gtk_box_append(GTK_BOX(box), t);
\`\`\`

Link: \`-ltermview -ltermviewgtk4 \$(pkg-config --libs gtk4)\`

Requires GTK4 ≥ 4.10. Right-click the widget for Copy/Paste/Copy as HTML/Font…
EOF
write_install_sh "$GTK4_STAGE/install.sh"

(cd "$STAGE" && zip -r -q "$REL/$(basename "$GTK4_STAGE").zip" "$(basename "$GTK4_STAGE")")
echo "==> $(basename "$GTK4_STAGE").zip"

# ------------------------------------------------------------------
# 2) LCL Linux zip — binary + install.sh
# ------------------------------------------------------------------
LCL_STAGE="$STAGE/termview-lcl-${VER}-linux-x86_64"
mkdir -p "$LCL_STAGE"/bin
install -m 755 ExampleTerminalLCL/target/exampleterminallcl "$LCL_STAGE/bin/"

cat > "$LCL_STAGE/README.md" <<EOF
# TermView — LCL Linux demo — ${VER}

LCL (Lazarus) terminal demo, statically linked against the LCL runtime.

## Install

\`\`\`
./install.sh           # /usr/local
./install.sh --user    # \$HOME/.local
\`\`\`

Installs:
- \`bin/exampleterminallcl\`

Right-click the terminal for Copy/Paste/Copy as HTML.
EOF
write_install_sh "$LCL_STAGE/install.sh"

(cd "$STAGE" && zip -r -q "$REL/$(basename "$LCL_STAGE").zip" "$(basename "$LCL_STAGE")")
echo "==> $(basename "$LCL_STAGE").zip"

# ------------------------------------------------------------------
# 3) fpGUI Linux zip — binary + install.sh
# ------------------------------------------------------------------
FPGUI_STAGE="$STAGE/termview-fpgui-${VER}-linux-x86_64"
mkdir -p "$FPGUI_STAGE"/bin
install -m 755 ExampleTerminal/target/exampleterminal "$FPGUI_STAGE/bin/"

cat > "$FPGUI_STAGE/README.md" <<EOF
# TermView — fpGUI Linux demo — ${VER}

fpGUI terminal demo, statically linked against the fpGUI runtime.

## Install

\`\`\`
./install.sh           # /usr/local
./install.sh --user    # \$HOME/.local
\`\`\`

Installs:
- \`bin/exampleterminal\`

Right-click the terminal for Copy/Paste/Font/Copy as HTML.
EOF
write_install_sh "$FPGUI_STAGE/install.sh"

(cd "$STAGE" && zip -r -q "$REL/$(basename "$FPGUI_STAGE").zip" "$(basename "$FPGUI_STAGE")")
echo "==> $(basename "$FPGUI_STAGE").zip"

# ------------------------------------------------------------------
# 4) fpGUI Win64 zip — .exe + README
# ------------------------------------------------------------------
if [[ $HAVE_WIN64 -eq 1 ]]; then
  WIN_STAGE="$STAGE/termview-fpgui-${VER}-win64"
  mkdir -p "$WIN_STAGE"
  install -m 755 target/win64/ExampleTerminal.exe "$WIN_STAGE/"
  cat > "$WIN_STAGE/README.txt" <<EOF
TermView — fpGUI Win64 demo — ${VER}

Run ExampleTerminal.exe.

Requires Windows 10 1809 or newer (uses ConPTY for the PTY backend).
fpGUI is statically linked; no extra DLLs needed.

Right-click the terminal for Copy/Paste/Font/Copy as HTML.
EOF
  (cd "$STAGE" && zip -r -q "$REL/$(basename "$WIN_STAGE").zip" "$(basename "$WIN_STAGE")")
  echo "==> $(basename "$WIN_STAGE").zip"
fi

# ------------------------------------------------------------------
echo
echo "Release artifacts:"
ls -lh "$REL"/*.zip
