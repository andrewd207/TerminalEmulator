{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  The unified ACTION model.

  Both keybindings ("key chord -> action") and signal bindings ("OSC code /
  bell -> action") resolve to a TTermAction.  An action is either:

    * builtin  -- one of TTermBuiltinAction, executed by the window via a sink
                  callback (because builtins need access to tabs/clipboard/UI);
    * external -- a shell command line, run with placeholder substitution:
                    %p = payload   %c = OSC code   %t = tab title
                  e.g.  notify-send "Terminal" %p

  This unit knows nothing about the window or fpGUI widgets, so it stays a
  pure model that the settings layer and the window both build on.
}
unit TermFpGUI.Actions;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, process;

type
  { The catalog of built-in actions.  Add here, handle in the window's sink. }
  TTermBuiltinAction = (
    baNone,
    { clipboard }
    baCopy, baPaste,
    { tabs / windows }
    baNewTab, baCloseTab, baMoveToWindow, baNextTab, baPrevTab,
    { alerts }
    baBeep, baFlash, baNotify,
    { appearance }
    baApplyProfile, baSetTabTitle
  );

  TTermActionKind = (takBuiltin, takExternal);

  { Everything an action handler might need about the triggering event. The
    Source* fields are opaque (TObject) so this unit avoids depending on the
    view/window; the sink casts them back. }
  TTermActionContext = record
    SourceView: TObject;     // TTerminalFPGUIView that had focus / fired
    SourceTab: TObject;      // app's per-tab object
    Code: Integer;           // OSC code, or -1
    Payload: RawByteString;  // OSC payload / title text
    TabTitle: string;
  end;

  { Called to run a builtin.  The window implements this. }
  TTermActionSink = procedure(ABuiltin: TTermBuiltinAction; const AArg: string;
    const ACtx: TTermActionContext) of object;

  TTermAction = class
  public
    Kind: TTermActionKind;
    Builtin: TTermBuiltinAction;  // when Kind = takBuiltin
    Arg: string;                  // builtin parameter (e.g. profile name)
    Command: string;              // when Kind = takExternal
    constructor CreateBuiltin(ABuiltin: TTermBuiltinAction; const AArg: string = '');
    constructor CreateExternal(const ACommand: string);
    function Describe: string;
    procedure Execute(ASink: TTermActionSink; const ACtx: TTermActionContext);
  end;

{ INI / display helpers for the builtin catalog. }
function BuiltinToName(A: TTermBuiltinAction): string;
function NameToBuiltin(const S: string): TTermBuiltinAction;
procedure ListBuiltins(AItems: TStrings);

implementation

const
  CBuiltinNames: array[TTermBuiltinAction] of string = (
    'None',
    'Copy', 'Paste',
    'NewTab', 'CloseTab', 'MoveToWindow', 'NextTab', 'PrevTab',
    'Beep', 'Flash', 'Notify',
    'ApplyProfile', 'SetTabTitle'
  );

function BuiltinToName(A: TTermBuiltinAction): string;
begin
  Result := CBuiltinNames[A];
end;

function NameToBuiltin(const S: string): TTermBuiltinAction;
var
  A: TTermBuiltinAction;
begin
  for A := Low(TTermBuiltinAction) to High(TTermBuiltinAction) do
    if SameText(CBuiltinNames[A], S) then
      Exit(A);
  Result := baNone;
end;

procedure ListBuiltins(AItems: TStrings);
var
  A: TTermBuiltinAction;
begin
  for A := Low(TTermBuiltinAction) to High(TTermBuiltinAction) do
    if A <> baNone then
      AItems.Add(CBuiltinNames[A]);
end;

{ Wrap a value in single quotes for /bin/sh, escaping embedded quotes. }
function ShellQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

{ TTermAction }

constructor TTermAction.CreateBuiltin(ABuiltin: TTermBuiltinAction; const AArg: string);
begin
  inherited Create;
  Kind := takBuiltin;
  Builtin := ABuiltin;
  Arg := AArg;
end;

constructor TTermAction.CreateExternal(const ACommand: string);
begin
  inherited Create;
  Kind := takExternal;
  Builtin := baNone;
  Command := ACommand;
end;

function TTermAction.Describe: string;
begin
  if Kind = takExternal then
    Result := 'run: ' + Command
  else if Arg <> '' then
    Result := BuiltinToName(Builtin) + ' (' + Arg + ')'
  else
    Result := BuiltinToName(Builtin);
end;

procedure TTermAction.Execute(ASink: TTermActionSink; const ACtx: TTermActionContext);
var
  Proc: TProcess;
  Cmd: string;
begin
  if Kind = takBuiltin then
  begin
    if Assigned(ASink) then
      ASink(Builtin, Arg, ACtx);
    Exit;
  end;

  { External: substitute placeholders, run detached via the shell so the user
    can write pipelines/quoting naturally.  Fire-and-forget — we do not block
    the pump waiting for it. }
  Cmd := Command;
  Cmd := StringReplace(Cmd, '%p', ShellQuote(string(ACtx.Payload)), [rfReplaceAll]);
  Cmd := StringReplace(Cmd, '%c', IntToStr(ACtx.Code), [rfReplaceAll]);
  Cmd := StringReplace(Cmd, '%t', ShellQuote(ACtx.TabTitle), [rfReplaceAll]);

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := '/bin/sh';
    Proc.Parameters.Add('-c');
    Proc.Parameters.Add(Cmd);
    Proc.Options := [];          // detached; child outlives this call
    try
      Proc.Execute;
    except
      on E: Exception do
        { swallow — a misconfigured command must not crash the terminal };
    end;
  finally
    Proc.Free;
  end;
end;

end.
