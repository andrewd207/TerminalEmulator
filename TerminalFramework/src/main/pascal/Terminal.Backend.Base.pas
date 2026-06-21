{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.Backend.Base;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, terminal.core, terminal.parser;

type
  TTerminalBackendBaseClass = class of TTerminalBackendBase;
  TTerminalBackendBase = class
  public
    class var CDefaultClass: TTerminalBackendBaseClass;
  protected
    FCore: TTerminalCore;
    FParser: TTerminalParser;
    FActive: Boolean;
    FTermProgram: string;
    FTermName: string;
    FShutdownSignal: Integer;
    FExitCode: Integer;
  public
    class function CreateDefaultBackend(ACore: TTerminalCore; AParser: TTerminalParser): TTerminalBackendBase;
    constructor Create(ACore: TTerminalCore; AParser: TTerminalParser); virtual;
    destructor Destroy; override;

    function StartShell(const AShell: string = ''; const AArgs: array of string): Boolean; virtual; abstract;
    function StartCommand(const AProgram: string; const AArgs: array of string): Boolean; virtual; abstract;
    procedure Stop; virtual; abstract;
    function PumpInput: Integer; virtual; abstract;
    function WriteInput(const AData: RawByteString): Integer; virtual; abstract;
    function Resize(ACols, ARows: Integer): Boolean; virtual; abstract;
    function IsRunning: Boolean; virtual; abstract;
    { True when the PTY's foreground process group is something other than
      the shell itself — i.e. the shell has spawned a child that's currently
      in the foreground. Returns False if the backend can't determine this
      (e.g. ConPTY on Windows). }
    function SubProcessRunning: Boolean; virtual;
    { Deliver a signal to the hosted child now (no-op where unsupported, e.g.
      Windows). }
    procedure SendSignal(ASignal: Integer); virtual;

    property Core: TTerminalCore read FCore;
    property Parser: TTerminalParser read FParser;
    property Active: Boolean read FActive;
    property TermProgram: string read FTermProgram write FTermProgram;
    property TermName: string read FTermName write FTermName;
    { Signal sent to the child on Stop/teardown.  Defaults to SIGTERM (15) so
      ordinary tabs behave as before; set to 0 to skip the explicit kill and let
      closing the PTY master deliver SIGHUP/EOF naturally. }
    property ShutdownSignal: Integer read FShutdownSignal write FShutdownSignal;
    { The child's exit status once it has been reaped: a process exit code, or
      128+signal if it was killed.  -1 until the child has exited. }
    property ExitCode: Integer read FExitCode;
  end;

implementation
uses
  Terminal.Backend.Windows,
  Terminal.Backend.Unix;

class function TTerminalBackendBase.CreateDefaultBackend(ACore: TTerminalCore; AParser: TTerminalParser): TTerminalBackendBase;
begin
  Result := CDefaultClass.Create(ACore, AParser);
end;

constructor TTerminalBackendBase.Create(ACore: TTerminalCore; AParser: TTerminalParser);
begin
  inherited Create;
  FCore := ACore;
  FParser := AParser;
  FActive := False;
  FTermProgram := 'fpc-terminal';
  FTermName := 'xterm-256color';
  FShutdownSignal := 15;   { SIGTERM }
  FExitCode := -1;
end;

destructor TTerminalBackendBase.Destroy;
begin
  inherited Destroy;
end;

function TTerminalBackendBase.SubProcessRunning: Boolean;
begin
  Result := False;
end;

procedure TTerminalBackendBase.SendSignal(ASignal: Integer);
begin
  { No-op by default; Unix overrides. }
end;

end.

