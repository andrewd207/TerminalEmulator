{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Pascal -> C ABI shim. Exports the Controller/Core surface so any C host
  (here, a GTK4 widget) can drive a PTY and render the cell grid. The lib
  has no GUI dependency — paint and input handling live in the consumer.
}

library libtermview;

{$mode objfpc}{$H+}
{$packrecords c}

uses
  Classes, SysUtils, fgl, ctypes,
  Terminal.Core, Terminal.Controller, Terminal.Backend.Base,
  Terminal.Backend.Unix; { selects forkpty backend on Unix }

const
  { Attribute bits packed into tv_cell_t.flags. Keep in sync with termview.h. }
  TV_ATTR_BOLD       = 1 shl 0;
  TV_ATTR_FAINT      = 1 shl 1;
  TV_ATTR_ITALIC     = 1 shl 2;
  TV_ATTR_UNDERLINE  = 1 shl 3;
  TV_ATTR_BLINK      = 1 shl 4;
  TV_ATTR_INVERSE    = 1 shl 5;
  TV_ATTR_HIDDEN     = 1 shl 6;
  TV_ATTR_STRIKE     = 1 shl 7;
  TV_ATTR_WIDE_LEAD  = 1 shl 8;
  TV_ATTR_WIDE_TRAIL = 1 shl 9;

  TV_COLOR_DEFAULT   = $FF000001;

  TV_HTML_SELECTION = 0;
  TV_HTML_SCREEN    = 1;
  TV_HTML_ALL       = 2;

  TV_MOUSE_LEFT       = 0;
  TV_MOUSE_MIDDLE     = 1;
  TV_MOUSE_RIGHT      = 2;
  TV_MOUSE_WHEEL_UP   = 3;
  TV_MOUSE_WHEEL_DOWN = 4;

type
  TTvBridge = class
  public
    procedure CoreInvalidate(Sender: TObject; const ARect: TTermRect);
    procedure CoreBell(Sender: TObject);
    procedure CoreTitle(Sender: TObject; const ATitle: string);
    procedure CoreClipSet(Sender: TObject; const ATargets: string; const AText: RawByteString);
    procedure CoreClipGet(Sender: TObject; const ATargets: string; out AText: RawByteString);
  end;

  tv_cell_t = record
    codepoint: cuint32;
    fg_rgb:    cuint32;
    bg_rgb:    cuint32;
    flags:     cuint32;
    link_id:   cuint32;   { OSC 8 hyperlink id; 0 = none. Resolve via tv_hyperlink_uri. }
    cluster:   array[0..15] of cchar;
  end;
  ptv_cell = ^tv_cell_t;

  tv_invalidate_cb = procedure(user: Pointer); cdecl;
  tv_bell_cb       = procedure(user: Pointer); cdecl;
  tv_title_cb      = procedure(title: PAnsiChar; user: Pointer); cdecl;
  tv_exit_cb       = procedure(user: Pointer); cdecl;
  tv_clip_set_cb   = procedure(targets, text: PAnsiChar; len: csize_t; user: Pointer); cdecl;
  tv_clip_get_cb   = procedure(targets: PAnsiChar; out_text: PPAnsiChar; user: Pointer); cdecl;

  PTvHandle = ^TTvHandle;
  TTvHandle = record
    Ctrl: TTerminalController;
    OnInvalidate: tv_invalidate_cb;
    OnBell:       tv_bell_cb;
    OnTitle:      tv_title_cb;
    OnExit:       tv_exit_cb;
    OnClipSet:    tv_clip_set_cb;
    OnClipGet:    tv_clip_get_cb;
    UserData:     Pointer;
    LastRunning:  Boolean;
    Bridge:       TTvBridge;
  end;

  TCoreHandleMap = specialize TFPGMap<Pointer, PTvHandle>;

var
  GHandleMap: TCoreHandleMap;

function HandleFor(Sender: TObject): PTvHandle;
var
  Idx: Integer;
begin
  Result := nil;
  if (GHandleMap = nil) or (Sender = nil) then Exit;
  Idx := GHandleMap.IndexOf(Pointer(Sender));
  if Idx >= 0 then Result := GHandleMap.Data[Idx];
end;

procedure TTvBridge.CoreInvalidate(Sender: TObject; const ARect: TTermRect);
var H: PTvHandle;
begin
  H := HandleFor(Sender);
  if (H <> nil) and Assigned(H^.OnInvalidate) then
    H^.OnInvalidate(H^.UserData);
end;

procedure TTvBridge.CoreBell(Sender: TObject);
var H: PTvHandle;
begin
  H := HandleFor(Sender);
  if (H <> nil) and Assigned(H^.OnBell) then
    H^.OnBell(H^.UserData);
end;

procedure TTvBridge.CoreTitle(Sender: TObject; const ATitle: string);
var H: PTvHandle;
    Buf: AnsiString;
begin
  H := HandleFor(Sender);
  if (H <> nil) and Assigned(H^.OnTitle) then
  begin
    Buf := ATitle + #0;
    H^.OnTitle(PAnsiChar(Buf), H^.UserData);
  end;
end;

procedure TTvBridge.CoreClipSet(Sender: TObject; const ATargets: string; const AText: RawByteString);
var H: PTvHandle;
    TBuf: AnsiString;
    LText: RawByteString;
begin
  H := HandleFor(Sender);
  if (H = nil) or not Assigned(H^.OnClipSet) then Exit;
  TBuf := ATargets + #0;
  LText := AText + #0;
  H^.OnClipSet(PAnsiChar(TBuf), PAnsiChar(LText), Length(AText), H^.UserData);
end;

procedure TTvBridge.CoreClipGet(Sender: TObject; const ATargets: string; out AText: RawByteString);
var H: PTvHandle;
    TBuf: AnsiString;
    Cstr: PAnsiChar;
begin
  AText := '';
  H := HandleFor(Sender);
  if (H = nil) or not Assigned(H^.OnClipGet) then Exit;
  TBuf := ATargets + #0;
  Cstr := nil;
  H^.OnClipGet(PAnsiChar(TBuf), @Cstr, H^.UserData);
  if Cstr <> nil then
  begin
    AText := StrPas(Cstr);
    StrDispose(Cstr);
  end;
end;

{ ---- Color helpers ---- }

function MapColor(const C: TTermColor; IsBackground: Boolean): cuint32;
begin
  case C.Mode of
    tcmIndexed, tcmRGB: Result := cuint32(TermColorToRGB(C));
  else
    Result := TV_COLOR_DEFAULT;
  end;
end;

function MapAttrs(const A: TTermAttrFlags): cuint32;
begin
  Result := 0;
  if tafBold       in A then Result := Result or TV_ATTR_BOLD;
  if tafFaint      in A then Result := Result or TV_ATTR_FAINT;
  if tafItalic     in A then Result := Result or TV_ATTR_ITALIC;
  if tafUnderline  in A then Result := Result or TV_ATTR_UNDERLINE;
  if tafBlink      in A then Result := Result or TV_ATTR_BLINK;
  if tafInverse    in A then Result := Result or TV_ATTR_INVERSE;
  if tafHidden     in A then Result := Result or TV_ATTR_HIDDEN;
  if tafStrike     in A then Result := Result or TV_ATTR_STRIKE;
  if tafWideLead   in A then Result := Result or TV_ATTR_WIDE_LEAD;
  if tafWideTrail  in A then Result := Result or TV_ATTR_WIDE_TRAIL;
end;

procedure FillCell(out Dest: tv_cell_t; const Src: TTermCell);
var
  N: Integer;
begin
  FillChar(Dest, SizeOf(Dest), 0);
  Dest.codepoint := Src.CodePoint;
  Dest.fg_rgb    := MapColor(Src.FG, False);
  Dest.bg_rgb    := MapColor(Src.BG, True);
  Dest.flags     := MapAttrs(Src.Attrs);
  Dest.link_id   := cuint32(Src.LinkId);
  if Src.Cluster <> '' then
  begin
    N := Length(Src.Cluster);
    if N > High(Dest.cluster) then N := High(Dest.cluster);
    Move(Src.Cluster[1], Dest.cluster[0], N);
    Dest.cluster[N] := 0;
  end;
end;

function GetVirtualLine(Core: TTerminalCore; VRow: Integer): TTermCellLine;
var Hist: Integer;
begin
  Hist := Core.HistoryCount;
  if VRow < 0 then Exit(nil);
  if VRow < Hist then Result := Core.GetHistoryLine(VRow)
  else Result := Core.GetLine(VRow - Hist);
end;

{ ---- Exported API ---- }

function tv_controller_new(cols, rows, scrollback: cint): PTvHandle; cdecl;
begin
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.Ctrl := TTerminalController.Create(cols, rows, scrollback);
  Result^.Bridge := TTvBridge.Create;
  GHandleMap.Add(Pointer(Result^.Ctrl.Core), Result);
  Result^.Ctrl.Core.OnInvalidate   := @Result^.Bridge.CoreInvalidate;
  Result^.Ctrl.Core.OnBell         := @Result^.Bridge.CoreBell;
  Result^.Ctrl.Core.OnTitle        := @Result^.Bridge.CoreTitle;
  Result^.Ctrl.Core.OnClipboardSet := @Result^.Bridge.CoreClipSet;
  Result^.Ctrl.Core.OnClipboardGet := @Result^.Bridge.CoreClipGet;
  Result^.LastRunning := False;
end;

procedure tv_controller_free(h: PTvHandle); cdecl;
var Idx: Integer;
begin
  if h = nil then Exit;
  if h^.Ctrl <> nil then
  begin
    Idx := GHandleMap.IndexOf(Pointer(h^.Ctrl.Core));
    if Idx >= 0 then GHandleMap.Delete(Idx);
    h^.Ctrl.Free;
  end;
  h^.Bridge.Free;
  Dispose(h);
end;

function tv_start_shell(h: PTvHandle; shell: PAnsiChar): cint; cdecl;
var S: string;
begin
  if h = nil then Exit(0);
  if shell = nil then S := '' else S := StrPas(shell);
  if h^.Ctrl.StartShell(S, []) then Result := 1 else Result := 0;
end;

{ Run an arbitrary command line in the PTY (via /bin/sh -c) instead of a login
  shell.  Empty cmd falls back to a shell.  Returns 1 on success. }
function tv_start_command(h: PTvHandle; cmd: PAnsiChar): cint; cdecl;
var S: string;
begin
  if h = nil then Exit(0);
  if cmd = nil then S := '' else S := StrPas(cmd);
  if Trim(S) = '' then
  begin
    if h^.Ctrl.StartShell('', []) then Result := 1 else Result := 0;
    Exit;
  end;
  if h^.Ctrl.StartCommand('/bin/sh', ['-c', S]) then Result := 1 else Result := 0;
end;

{ Deliver a signal to the hosted child immediately. }
procedure tv_send_signal(h: PTvHandle; sig: cint); cdecl;
begin
  if h <> nil then h^.Ctrl.SendSignal(sig);
end;

{ Signal sent to the child on teardown (default 15=SIGTERM; 0 = none, let the
  PTY close deliver SIGHUP). }
procedure tv_set_shutdown_signal(h: PTvHandle; sig: cint); cdecl;
begin
  if h <> nil then h^.Ctrl.ShutdownSignal := sig;
end;

function tv_get_shutdown_signal(h: PTvHandle): cint; cdecl;
begin
  if h = nil then Exit(0);
  Result := h^.Ctrl.ShutdownSignal;
end;

function tv_pump(h: PTvHandle): cint; cdecl;
begin
  if h = nil then Exit(0);
  Result := h^.Ctrl.Pump;
  { Edge-trigger an exit callback when the child dies. }
  if h^.LastRunning and (h^.Ctrl.Backend <> nil) and (not h^.Ctrl.Backend.IsRunning) then
  begin
    h^.LastRunning := False;
    if Assigned(h^.OnExit) then h^.OnExit(h^.UserData);
  end
  else if (h^.Ctrl.Backend <> nil) and h^.Ctrl.Backend.IsRunning then
    h^.LastRunning := True;
end;

procedure tv_send_input(h: PTvHandle; data: PAnsiChar; len: csize_t); cdecl;
var S: RawByteString;
begin
  if (h = nil) or (data = nil) or (len = 0) then Exit;
  SetLength(S, len);
  Move(data^, S[1], len);
  h^.Ctrl.SendInput(S);
end;

procedure tv_resize(h: PTvHandle; cols, rows: cint); cdecl;
begin
  if h <> nil then h^.Ctrl.Resize(cols, rows);
end;

function tv_cols(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); Result := h^.Ctrl.Core.Cols; end;

function tv_rows(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); Result := h^.Ctrl.Core.Rows; end;

function tv_history_count(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); Result := h^.Ctrl.Core.HistoryCount; end;

function tv_cursor_col(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); Result := h^.Ctrl.Core.Cursor.Col; end;

function tv_cursor_row(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); Result := h^.Ctrl.Core.Cursor.Row; end;

function tv_cursor_visible(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); if h^.Ctrl.Core.Cursor.Visible then Result := 1 else Result := 0; end;

function tv_in_alt_buffer(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); if h^.Ctrl.Core.InAltBuffer then Result := 1 else Result := 0; end;

function tv_bracketed_paste(h: PTvHandle): cint; cdecl;
begin if h = nil then Exit(0); if h^.Ctrl.Core.BracketedPasteMode then Result := 1 else Result := 0; end;

function tv_is_running(h: PTvHandle): cint; cdecl;
begin
  Result := 0;
  if (h = nil) or (h^.Ctrl.Backend = nil) then Exit;
  if h^.Ctrl.Backend.IsRunning then Result := 1;
end;

function tv_subprocess_running(h: PTvHandle): cint; cdecl;
begin
  if (h = nil) then Exit(0);
  if h^.Ctrl.SubProcessRunning then Result := 1 else Result := 0;
end;

function tv_line_wrapped(h: PTvHandle; virtual_row: cint): cint; cdecl;
begin
  if h = nil then Exit(0);
  if h^.Ctrl.Core.IsLineWrapped(virtual_row) then Result := 1 else Result := 0;
end;

function tv_get_cell(h: PTvHandle; virtual_row, col: cint; out cell: tv_cell_t): cint; cdecl;
var Line: TTermCellLine;
begin
  Result := 0;
  FillChar(cell, SizeOf(cell), 0);
  if h = nil then Exit;
  Line := GetVirtualLine(h^.Ctrl.Core, virtual_row);
  if (col < 0) or (col > High(Line)) then Exit;
  FillCell(cell, Line[col]);
  Result := 1;
end;

function tv_line_length(h: PTvHandle; virtual_row: cint): cint; cdecl;
var Line: TTermCellLine;
begin
  Result := 0;
  if h = nil then Exit;
  Line := GetVirtualLine(h^.Ctrl.Core, virtual_row);
  Result := Length(Line);
end;

procedure tv_send_mouse(h: PTvHandle; button, col, row, pressed, motion, shift, alt, ctrl: cint); cdecl;
var Btn: TTermMouseButton;
begin
  if h = nil then Exit;
  case button of
    TV_MOUSE_LEFT:       Btn := tmbLeft;
    TV_MOUSE_MIDDLE:     Btn := tmbMiddle;
    TV_MOUSE_RIGHT:      Btn := tmbRight;
    TV_MOUSE_WHEEL_UP:   Btn := tmbWheelUp;
    TV_MOUSE_WHEEL_DOWN: Btn := tmbWheelDown;
  else
    Btn := tmbLeft;
  end;
  h^.Ctrl.Core.SendMouse(Btn, col, row, pressed <> 0, motion <> 0,
    shift <> 0, alt <> 0, ctrl <> 0);
end;

function tv_mouse_protocol_active(h: PTvHandle): cint; cdecl;
begin
  if h = nil then Exit(0);
  if h^.Ctrl.Core.MouseProtocol <> tmpNone then Result := 1 else Result := 0;
end;

{ HTML export. Returned pointer must be freed with tv_str_free. The selection
  is described as virtual-row/col anchor+focus (the C side has its own
  selection state; we just turn it into a TTermSelection). }

function CopyStr(const S: RawByteString): PAnsiChar;
begin
  if S = '' then
    Result := StrAlloc(1)
  else
  begin
    Result := StrAlloc(Length(S) + 1);
    Move(S[1], Result^, Length(S));
  end;
  Result[Length(S)] := #0;
end;

function tv_get_html(h: PTvHandle; kind: cint; title: PAnsiChar;
                    anchor_row, anchor_col, focus_row, focus_col: cint): PAnsiChar; cdecl;
var
  T: string;
  Sel: TTermSelection;
  Html: RawByteString;
begin
  if h = nil then Exit(nil);
  if title = nil then T := '' else T := StrPas(title);
  case kind of
    TV_HTML_SCREEN: Html := h^.Ctrl.Core.GetHtmlScreen(T);
    TV_HTML_ALL:    Html := h^.Ctrl.Core.GetHtmlAll(T);
  else
    Sel.Active := True;
    Sel.Selecting := False;
    Sel.Mode := tsmLinear;
    Sel.Anchor.Row := anchor_row; Sel.Anchor.Col := anchor_col;
    Sel.Focus.Row  := focus_row;  Sel.Focus.Col  := focus_col;
    Html := h^.Ctrl.Core.GetHtmlSelection(Sel, T);
  end;
  Result := CopyStr(Html);
end;

procedure tv_str_free(p: PAnsiChar); cdecl;
begin
  if p <> nil then StrDispose(p);
end;

{ Resolve an OSC 8 link id (from tv_cell_t.link_id) to its URI. Returns a
  heap string the caller must free with tv_str_free, or NULL if unknown. }
function tv_hyperlink_uri(h: PTvHandle; link_id: cint): PAnsiChar; cdecl;
var
  URI: string;
begin
  Result := nil;
  if (h = nil) or (link_id = 0) then Exit;
  URI := h^.Ctrl.Core.HyperlinkURI(link_id);
  if URI <> '' then
    Result := CopyStr(URI);
end;

{ Callback registration. Pass NULL to unset. }

procedure tv_set_user_data(h: PTvHandle; user: Pointer); cdecl;
begin if h <> nil then h^.UserData := user; end;

procedure tv_set_on_invalidate(h: PTvHandle; cb: tv_invalidate_cb); cdecl;
begin if h <> nil then h^.OnInvalidate := cb; end;

procedure tv_set_on_bell(h: PTvHandle; cb: tv_bell_cb); cdecl;
begin if h <> nil then h^.OnBell := cb; end;

procedure tv_set_on_title(h: PTvHandle; cb: tv_title_cb); cdecl;
begin if h <> nil then h^.OnTitle := cb; end;

procedure tv_set_on_exit(h: PTvHandle; cb: tv_exit_cb); cdecl;
begin if h <> nil then h^.OnExit := cb; end;

procedure tv_set_on_clipboard_set(h: PTvHandle; cb: tv_clip_set_cb); cdecl;
begin if h <> nil then h^.OnClipSet := cb; end;

procedure tv_set_on_clipboard_get(h: PTvHandle; cb: tv_clip_get_cb); cdecl;
begin if h <> nil then h^.OnClipGet := cb; end;

exports
  tv_controller_new, tv_controller_free,
  tv_start_shell, tv_start_command, tv_pump,
  tv_send_signal, tv_set_shutdown_signal, tv_get_shutdown_signal,
  tv_send_input, tv_send_mouse,
  tv_resize,
  tv_cols, tv_rows, tv_history_count,
  tv_cursor_col, tv_cursor_row, tv_cursor_visible, tv_in_alt_buffer,
  tv_bracketed_paste, tv_is_running, tv_subprocess_running,
  tv_line_wrapped, tv_line_length, tv_get_cell,
  tv_mouse_protocol_active,
  tv_get_html, tv_hyperlink_uri, tv_str_free,
  tv_set_user_data,
  tv_set_on_invalidate, tv_set_on_bell, tv_set_on_title, tv_set_on_exit,
  tv_set_on_clipboard_set, tv_set_on_clipboard_get;

begin
  GHandleMap := TCoreHandleMap.Create;
  GHandleMap.Sorted := True;
end.
