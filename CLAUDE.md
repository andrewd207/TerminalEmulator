# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

The project uses **pasbuild** (a Maven-style build tool for Free Pascal) with Lazarus IDE project files (`.lpi`/`.lpk`).

Build everything (debug profile):
```
pasbuild compile -f project.xml -p debug
```

Build a specific module:
```
pasbuild compile -f project.xml -m ExampleTerminal -p debug
pasbuild compile -f project.xml -m TerminalFramework -p debug
```

The ExampleTerminal `.lpi` has an `ExecuteBefore` hook that calls pasbuild before Lazarus compiles, so opening it in Lazarus and pressing Run handles the full build. The compiled binary lands at `ExampleTerminal/target/exampleterminal`.

Run tests (fpcunit-based, console runner):
```
pasbuild compile -f project.xml -m TerminalFramework -p debug
# then run the compiled test binary in TerminalFramework/target/
```

## Architecture

The framework is layered: **Backend → Parser → Core → View**. Data flows up (bytes in → screen state), input flows down (keystrokes → PTY write).

### Terminal.Core (`Terminal.Core.pas`)
The screen model. `TTerminalCore` owns:
- Two `TTermScreenBuffer` instances: main buffer (with scrollback) and alternate buffer (no scrollback, used by full-screen apps via `?1049h/l`).
- Cursor state (`TTermCursor`), pen/attributes (`TTermPen`), scroll margins, tab stops, mode flags (autowrap, origin mode, insert mode).
- All terminal operations are methods here (`CursorUp`, `EraseInLine`, `PutCodePoint`, etc.). The parser calls these directly.
- Fires `OnInvalidate(rect)` so the view knows what to repaint; fires `OnWrite` to send escape replies back to the PTY; fires `OnBell` and `OnTitle`.

`TTermScreenBuffer` holds `TTermLines` (the visible screen rows) and `TTermHistoryRing` (a `TRingBuffer<TTermHistoryLine>` for scrollback). When the top row scrolls off, it's pushed into the ring buffer.

`TTermCell` is a record with managed operators (`Initialize`/`Finalize`/`Copy`) so it behaves safely in dynamic arrays. Key fields: `FCodePoint` (Unicode scalar), `Cluster` (UTF-8 bytes including combining marks), `Attrs` (`TTermAttrFlags` set), `FG`/`BG` (`TTermColor` with mode: default/indexed/RGB). Wide characters use `tafWideLead`/`tafWideTrail` flags across two adjacent cells.

### Terminal.Parser (`Terminal.Parser.pas`)
A byte-at-a-time VT/ANSI state machine (`TTerminalParser`). Accepts data via `FeedByte`/`FeedBytes`/`FeedBuffer`. Maintains parser state (ground, escape, CSI param/intermediate/ignore, OSC string, DCS entry/passthrough, etc.) and dispatches to `TTerminalCore` methods. Handles:
- C0 controls (BEL, BS, HT, LF, CR, ESC)
- C1 controls (via 8-bit bytes)
- ESC sequences (save/restore cursor, charset, soft reset, etc.)
- CSI sequences (cursor movement, erase, SGR, scroll region, mode set/reset, DA, CPR)
- SGR (`m`) including 256-color (`38;5;n`) and truecolor (`38;2;r;g;b`)
- OSC (window title: codes 0, 2)
- DCS (forwarded via `OnDCS` event for extension)
- UTF-8 buffering: accumulates continuation bytes, flushes to `PutCodePoint`; emits U+FFFD on error

Unknown CSI/ESC sequences are exposed via `OnUnknownCSI`/`OnUnknownESC` events.

### Terminal.Controller (`Terminal.Controller.pas`)
Composes Core + Parser + Backend. This is the primary public API for embedders:
- `StartShell` / `StartCommand` to launch a process in the PTY
- `Pump` — call on a timer; reads PTY output, feeds it to the parser, returns bytes read
- `Resize(cols, rows)` — updates both Core and Backend (sends `TIOCSWINSZ`)
- `SendInput` / `SendKeyEnter` / `SendArrowUp` etc. — writes input to the PTY
- `SendSignal(sig)` delivers a signal to the child now; `ShutdownSignal` is the signal sent on teardown (default `SIGTERM` 15; `0` = skip the kill and let closing the PTY deliver `SIGHUP`/EOF)
- `Core.OnWrite` is wired to `Backend.WriteInput` so parser reply sequences (CPR, DA) go back to the PTY automatically

### Terminal.Backend.Base / Terminal.Backend.Unix / Terminal.Backend.Windows
OS abstraction for PTY + child process. The active backend class is registered via `TTerminalBackendBase.CDefaultClass` in the `initialization` block of the platform unit — the Unix unit sets it to `TTerminalBackendUnix`. `CreateDefaultBackend` instantiates whatever class is registered.

Unix backend uses `forkpty` (from libc) to open a PTY master fd and fork the child. Sets master fd non-blocking. `PumpInput` reads in 8 KB chunks, feeding bytes to the parser. Sets `TERM=xterm-256color` and `COLORTERM=truecolor` in the child environment.

### Terminal.View.fpGUI (`Terminal.View.fpGUI.pas`)
fpGUI widget `TTerminalFPGUIView` (subclass of `TfpgWidget`). Renders the terminal using a fixed-width font, one `TTermCell` per character grid cell. Key details:
- Uses a "virtual row" coordinate: history rows first (index 0..HistoryCount-1), then screen rows. The scrollbar position maps directly to `FTopRow` (the first virtual row in the viewport).
- Two timers: `FTimer` (20 ms) calls `Pump` and repaints if bytes arrived; `FCursorTimer` (750 ms) toggles cursor blink.
- Controller is attached/detached explicitly (`AttachController`/`DetachController`); the view does not own the controller.
- `TTerminalFPGUIForm` is a convenience form wrapping the view.
- Overlay / keymap hooks used by the drawer (mirrored on the LCL view, `Terminal.View.LCL.pas`): `StartProgram` (run a command line), `OnKeyAction` (consume a chord before built-in handling; the matching char is then swallowed), `OnEdgeHover` / `OnViewClick`, `SetReservedRect`/`ClearReservedRect` (leave a region unpainted so an overlay isn't clobbered), `CaptureRegion` / `EnsureRendered` (snapshot the grid for reveal animations). On fpGUI these back the in-window direct-blit drawer; the LCL view exposes the same API surface (`CaptureRegion` returns a `TBitmap`). The C ABI (`LibTermView`) adds `tv_start_command` / `tv_send_signal` / `tv_set_shutdown_signal`.

### Terminal.Unicode (`Terminal.Unicode.pas`)
UTF-8 decode/encode helpers and terminal cell-width calculation (`CodePointCellWidth`): returns 0 for combining/zero-width, 2 for wide (East Asian fullwidth/wide, most emoji), 1 otherwise. Uses sorted interval tables with binary search.

### Terminal.Core.Ringbuffer (`Terminal.Core.Ringbuffer.pas`)
Generic `TRingBuffer<T: class>`. Fixed capacity, optional `OwnsObjects` (frees evicted items), optional `OverwriteWhenFull` (drops oldest). Indexed by logical position 0..Count-1. Used for scrollback history.

### TermFpGUI app (`TermFpGUI/src/main/pascal/TermFpGUI.*.pas`)
The full fpGUI application (`ExampleTerminal` is the minimal reference). Units:
- `TermFpGUI.Window` — `TTermWindow` (tabbed form): tabs, hamburger/tab menus, profile + theme application, deferred tab teardown (`QueueDispose`/`DisposeTick` — never free a view from inside its own timer callback), multi-window lifetime (`FWindows` class list, `FreeAll`), and `EnterAppMode` (single-program, tab strip hidden).
- `TermFpGUI.Drawer` — `TTermDrawer`, the per-tab hover side panel: own controller+view, reveal animations (fade/assemble/none) composited as opaque images and direct-blitted, gravity/size/colour-profile, and the shutdown policy (`ApplyShutdownPolicy` sets `Controller.ShutdownSignal` / sends keys before teardown).
- `TermFpGUI.Config` — INI model: `TTermProfile` (appearance + all `drawer_*` keys including shutdown), `TTermConfig` (profiles, key/signal bindings, theme), and `TTermAppConfig` (`[App]` launch config; `name=` mandatory, optional SVG `icon=`). `ReadProfileFields` is shared between profile and app-config parsing.
- `TermFpGUI.Desktop` — embedded HVIF window icon (`{$I termfpgui_icon.inc}`, generated from `icons/termfpgui.svg` by the fpgui `svg2hvif` tool) and XDG `.desktop` install (`MaybePromptInstall` for the app, `MaybePromptInstallApp` for a per-config launcher; `InstallEntry` writes the `.desktop` + scalable SVG).
- `TermFpGUI.SettingsForm` / `TermFpGUI.Actions` / `TermFpGUI.TabBar` — settings dialog, action model, tab strip.
- CLI: `--app <ini>` (app mode), trailing `--` passes the rest as the command; both handled in `TermFpGUI.pas` `MainProc`.

## Key Conventions

- All Pascal units use `{$mode objfpc}{$H+}`. Core and Ringbuffer additionally enable `advancedrecords` and `typehelpers`.
- Coordinates: `Col` is 0-based column, `Row` is 0-based screen row. Cursor positions passed to CSI commands are 1-based and converted in the parser.
- `TTermCell` must never be stored in a `var` that skips `Initialize` — always use dynamic arrays or local variables so the managed operators fire. Avoid `FillChar` on TTermCell arrays.
- The scrollback ring stores `TTermHistoryLine` objects (reference type wrapping a deep copy of the line). Index 0 is the oldest line.
- Debug `WriteLn` calls are scattered in the codebase (history push, resize IOCTL, scrollbar scroll). These are intentional development traces, not errors.
