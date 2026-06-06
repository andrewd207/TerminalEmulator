{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.Controller;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Terminal.Core, Terminal.Parser, Terminal.Backend.Base;

type

  { TTerminalController }

  TTerminalController = class
  private
    FCore: TTerminalCore;
    FParser: TTerminalParser;
    FBackend: TTerminalBackendBase;
    procedure HandleCoreWrite(Sender: TObject; const AData: RawByteString);
  public
    constructor Create(ACols, ARows: Integer; AScrollbackLimit: Integer = 5000);
    destructor Destroy; override;

    function StartShell(const AShell: string = ''; const AArgs: array of string): Boolean;
    function StartCommand(const AProgram: string; const AArgs: array of string): Boolean;
    procedure Stop;
    function  Pump: Integer;
    procedure Resize(ACols, ARows: Integer);
    procedure SendInput(const AData: RawByteString);
    procedure SendTextUTF8(const AUTF8: RawByteString);
    procedure SendKeyEnter;
    procedure SendKeyBackspace;
    procedure SendKeyTab(AShiftPressed: Boolean);
    procedure SendKeyEscape;
    procedure SendArrowUp(Ctrl: Boolean);
    procedure SendArrowDown(Ctrl: Boolean);
    procedure SendArrowLeft(Ctrl: Boolean);
    procedure SendArrowRight(Ctrl: Boolean);

    property Core: TTerminalCore read FCore;
    property Parser: TTerminalParser read FParser;
    property Backend: TTerminalBackendBase read FBackend;
  end;

implementation

constructor TTerminalController.Create(ACols, ARows: Integer; AScrollbackLimit: Integer);
begin
  inherited Create;
  FCore := TTerminalCore.Create(ACols, ARows, AScrollbackLimit);
  FParser := TTerminalParser.Create(FCore);
  FBackend := TTerminalBackendBase.CreateDefaultBackend(FCore, FParser);
  FCore.OnWrite := @HandleCoreWrite;
end;

destructor TTerminalController.Destroy;
begin
  FreeAndNil(FBackend);
  FreeAndNil(FParser);
  FreeAndNil(FCore);
  inherited Destroy;
end;

procedure TTerminalController.HandleCoreWrite(Sender: TObject; const AData: RawByteString);
begin
  if FBackend <> nil then
    FBackend.WriteInput(AData);
end;

function TTerminalController.StartShell(const AShell: string; const AArgs: array of string): Boolean;
begin
  Result := FBackend.StartShell(AShell, AArgs);

end;

function TTerminalController.StartCommand(const AProgram: string; const AArgs: array of string): Boolean;
begin
  Result := FBackend.StartCommand(AProgram, AArgs);
end;

procedure TTerminalController.Stop;
begin
  FBackend.Stop;
end;

function TTerminalController.Pump: Integer;
begin
  Result := FBackend.PumpInput;
  FCore.CheckSyncTimeout;
end;

procedure TTerminalController.Resize(ACols, ARows: Integer);
var
  F: TextFile;
begin
  FCore.Resize(ACols, ARows);
  FBackend.Resize(ACols, ARows);
  try
    AssignFile(F, '/tmp/term-raw.log');
    if FileExists('/tmp/term-raw.log') then Append(F) else Rewrite(F);
    WriteLn(F, '--- resize cols=', ACols, ' rows=', ARows, ' ---');
    CloseFile(F);
  except
  end;
end;

procedure TTerminalController.SendInput(const AData: RawByteString);
begin
  FBackend.WriteInput(AData);
end;

procedure TTerminalController.SendTextUTF8(const AUTF8: RawByteString);
begin
  SendInput(AUTF8);
end;

procedure TTerminalController.SendKeyEnter;
begin
  SendInput(#13);
end;

procedure TTerminalController.SendKeyBackspace;
begin
  SendInput(#127);
end;

procedure TTerminalController.SendKeyTab(AShiftPressed: Boolean);
begin
  if AShiftPressed then
    SendInput(#27'[Z')   // common Shift+Tab / BackTab sequence
  else
    SendInput(#9);
end;

procedure TTerminalController.SendKeyEscape;
begin
  SendInput(#27);
end;

procedure TTerminalController.SendArrowUp(Ctrl: Boolean);
begin
  if Ctrl then
    SendInput(#27'[1;5A')
  else
    SendInput(#27'[A');
end;

procedure TTerminalController.SendArrowDown(Ctrl: Boolean);
begin
  if Ctrl then
    SendInput(#27'[1;5B')
  else
    SendInput(#27'[B');
end;

procedure TTerminalController.SendArrowLeft(Ctrl: Boolean);
begin
  if Ctrl then
    SendInput(#27'[1;5D')
  else
    SendInput(#27'[D');
end;

procedure TTerminalController.SendArrowRight(Ctrl: Boolean);
begin
  if Ctrl then
    SendInput(#27'[1;5C')
  else
    SendInput(#27'[C');
end;

end.
