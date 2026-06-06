{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.Backend.Windows;
{$IFNDEF WINDOWS}
interface
implementation
{$ENDIF}
{$IFDEF WINDOWS}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows, terminal.backend.base;

type
  HPCON = THandle;
  SIZE_T = NativeUInt;

  TCreatePseudoConsole = function(size: TCoord; hInput, hOutput: THandle; dwFlags: DWORD; out phPC: HPCON): HRESULT; stdcall;
  TResizePseudoConsole = function(hPC: HPCON; size: TCoord): HRESULT; stdcall;
  TClosePseudoConsole = procedure(hPC: HPCON); stdcall;

  TTerminalBackendWindows = class(TTerminalBackendBase)
  private
    FKernel32: HMODULE;
    FCreatePseudoConsole: TCreatePseudoConsole;
    FResizePseudoConsole: TResizePseudoConsole;
    FClosePseudoConsole: TClosePseudoConsole;
    FPC: HPCON;
    FInputRead: THandle;
    FInputWrite: THandle;
    FOutputRead: THandle;
    FOutputWrite: THandle;
    FProcessInfo: TProcessInformation;
    function LoadConPtyAPI: Boolean;
    procedure UnloadConPtyAPI;
    procedure ClosePipe(var AHandle: THandle);
    procedure CloseProcessHandles;
    function CreatePipes: Boolean;
    procedure ClosePipes;
    function BuildCommandLine(const AProgram: string; const AArgs: array of string): UnicodeString;
    function CreatePseudoConsoleHandle(ACols, ARows: Integer): Boolean;
    function InitializeStartupInfoEx(var ASI: TStartupInfoExW; out AAttrListSize: SIZE_T): Boolean;
    procedure FinalizeStartupInfoEx(var ASI: TStartupInfoExW);
  public
    constructor Create(ACore: TTerminalCore; AParser: TTerminalParser); override;
    destructor Destroy; override;

    function StartShell(const AShell: string = ''; const AArgs: array of string = []): Boolean; override;
    function StartCommand(const AProgram: string; const AArgs: array of string): Boolean; override;
    procedure Stop; override;
    function PumpInput: Integer; override;
    function WriteInput(const AData: RawByteString): Integer; override;
    function Resize(ACols, ARows: Integer): Boolean; override;
    function IsRunning: Boolean; override;

    property PseudoConsole: HPCON read FPC;
    property InputWriteHandle: THandle read FInputWrite;
    property OutputReadHandle: THandle read FOutputRead;
  end;

implementation

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT = $00080000;
  READ_BUFFER_SIZE = 8192;

function FAILED(Status: HRESULT): Boolean; inline;
begin
  Result := Status < 0;
end;

constructor TTerminalBackendWindows.Create(ACore: TTerminalCore; AParser: TTerminalParser);
begin
  inherited Create(ACore, AParser);
  FKernel32 := 0;
  FPC := 0;
  FInputRead := 0;
  FInputWrite := 0;
  FOutputRead := 0;
  FOutputWrite := 0;
  FillChar(FProcessInfo, SizeOf(FProcessInfo), 0);
end;

destructor TTerminalBackendWindows.Destroy;
begin
  Stop;
  UnloadConPtyAPI;
  inherited Destroy;
end;

function TTerminalBackendWindows.LoadConPtyAPI: Boolean;
begin
  if FKernel32 <> 0 then
    Exit(Assigned(FCreatePseudoConsole) and Assigned(FResizePseudoConsole) and Assigned(FClosePseudoConsole));

  FKernel32 := LoadLibrary('kernel32.dll');
  if FKernel32 = 0 then
    Exit(False);

  Pointer(FCreatePseudoConsole) := GetProcAddress(FKernel32, 'CreatePseudoConsole');
  Pointer(FResizePseudoConsole) := GetProcAddress(FKernel32, 'ResizePseudoConsole');
  Pointer(FClosePseudoConsole) := GetProcAddress(FKernel32, 'ClosePseudoConsole');
  Result := Assigned(FCreatePseudoConsole) and Assigned(FResizePseudoConsole) and Assigned(FClosePseudoConsole);
  if not Result then
    UnloadConPtyAPI;
end;

procedure TTerminalBackendWindows.UnloadConPtyAPI;
begin
  FCreatePseudoConsole := nil;
  FResizePseudoConsole := nil;
  FClosePseudoConsole := nil;
  if FKernel32 <> 0 then
  begin
    FreeLibrary(FKernel32);
    FKernel32 := 0;
  end;
end;

procedure TTerminalBackendWindows.ClosePipe(var AHandle: THandle);
begin
  if AHandle <> 0 then
  begin
    CloseHandle(AHandle);
    AHandle := 0;
  end;
end;

procedure TTerminalBackendWindows.CloseProcessHandles;
begin
  if FProcessInfo.hThread <> 0 then
  begin
    CloseHandle(FProcessInfo.hThread);
    FProcessInfo.hThread := 0;
  end;
  if FProcessInfo.hProcess <> 0 then
  begin
    CloseHandle(FProcessInfo.hProcess);
    FProcessInfo.hProcess := 0;
  end;
  FProcessInfo.dwProcessId := 0;
  FProcessInfo.dwThreadId := 0;
end;

function TTerminalBackendWindows.CreatePipes: Boolean;
var
  SA: TSecurityAttributes;
begin
  Result := False;
  ClosePipes;

  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;

  if not CreatePipe(FInputRead, FInputWrite, @SA, 0) then
    Exit(False);
  if not CreatePipe(FOutputRead, FOutputWrite, @SA, 0) then
  begin
    ClosePipes;
    Exit(False);
  end;

  SetHandleInformation(FInputWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(FOutputRead, HANDLE_FLAG_INHERIT, 0);
  Result := True;
end;

procedure TTerminalBackendWindows.ClosePipes;
begin
  ClosePipe(FInputRead);
  ClosePipe(FInputWrite);
  ClosePipe(FOutputRead);
  ClosePipe(FOutputWrite);
end;

function TTerminalBackendWindows.BuildCommandLine(const AProgram: string; const AArgs: array of string): UnicodeString;
var
  I: Integer;
  function QuoteArg(const S: string): UnicodeString;
  begin
    if (Pos(' ', S) > 0) or (Pos(#9, S) > 0) or (Pos('"', S) > 0) then
      Result := '"' + StringReplace(UnicodeString(S), '"', '\"', [rfReplaceAll]) + '"'
    else
      Result := UnicodeString(S);
  end;
begin
  Result := QuoteArg(AProgram);
  for I := 0 to High(AArgs) do
    Result := Result + ' ' + QuoteArg(AArgs[I]);
end;

function TTerminalBackendWindows.CreatePseudoConsoleHandle(ACols, ARows: Integer): Boolean;
var
  Size: TCoord;
  HR: HRESULT;
begin
  Result := False;
  if not Assigned(FCreatePseudoConsole) then
    Exit;

  Size.X := ACols;
  Size.Y := ARows;
  HR := FCreatePseudoConsole(Size, FInputRead, FOutputWrite, 0, FPC);
  Result := not FAILED(HR);
end;

function TTerminalBackendWindows.InitializeStartupInfoEx(var ASI: TStartupInfoExW; out AAttrListSize: SIZE_T): Boolean;
begin
  Result := False;
  FillChar(ASI, SizeOf(ASI), 0);
  ASI.StartupInfo.cb := SizeOf(ASI);
  AAttrListSize := 0;
  InitializeProcThreadAttributeList(nil, 1, 0, AAttrListSize);
  GetMem(ASI.lpAttributeList, AAttrListSize);
  if not InitializeProcThreadAttributeList(ASI.lpAttributeList, 1, 0, AAttrListSize) then
    Exit(False);
  if not UpdateProcThreadAttribute(ASI.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    Pointer(FPC), SizeOf(FPC), nil, nil) then
    Exit(False);
  Result := True;
end;

procedure TTerminalBackendWindows.FinalizeStartupInfoEx(var ASI: TStartupInfoExW);
begin
  if ASI.lpAttributeList <> nil then
  begin
    DeleteProcThreadAttributeList(ASI.lpAttributeList);
    FreeMem(ASI.lpAttributeList);
    ASI.lpAttributeList := nil;
  end;
end;

function TTerminalBackendWindows.StartShell(const AShell: string; const AArgs: array of string): Boolean;
var
  ShellPath: string;
  Args: array of string;
  I: Integer;
begin
  ShellPath := AShell;
  if ShellPath = '' then
    ShellPath := GetEnvironmentVariable('COMSPEC');
  if ShellPath = '' then
    ShellPath := 'cmd.exe';

  SetLength(Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Args[I] := AArgs[I];
  Result := StartCommand(ShellPath, Args);
end;

function TTerminalBackendWindows.StartCommand(const AProgram: string; const AArgs: array of string): Boolean;
var
  SI: TStartupInfoExW;
  PI: TProcessInformation;
  AttrListSize: SIZE_T;
  CmdLine: UnicodeString;
  MutableCmd: PWideChar;
begin
  Result := False;
  Stop;

  if not LoadConPtyAPI then
    Exit(False);
  if not CreatePipes then
    Exit(False);
  if not CreatePseudoConsoleHandle(FCore.Cols, FCore.Rows) then
  begin
    ClosePipes;
    Exit(False);
  end;

  if not InitializeStartupInfoEx(SI, AttrListSize) then
  begin
    Stop;
    Exit(False);
  end;

  try
    FillChar(PI, SizeOf(PI), 0);
    CmdLine := BuildCommandLine(AProgram, AArgs);
    MutableCmd := PWideChar(CmdLine);
    if not CreateProcessW(nil, MutableCmd, nil, nil, False,
      EXTENDED_STARTUPINFO_PRESENT, nil, nil, SI.StartupInfo, PI) then
    begin
      Stop;
      Exit(False);
    end;

    FProcessInfo := PI;
    ClosePipe(FInputRead);
    ClosePipe(FOutputWrite);
    FActive := True;
    Result := True;
  finally
    FinalizeStartupInfoEx(SI);
  end;
end;

procedure TTerminalBackendWindows.Stop;
begin
  if FProcessInfo.hProcess <> 0 then
  begin
    TerminateProcess(FProcessInfo.hProcess, 0);
    WaitForSingleObject(FProcessInfo.hProcess, 100);
  end;
  CloseProcessHandles;
  if (FPC <> 0) and Assigned(FClosePseudoConsole) then
  begin
    FClosePseudoConsole(FPC);
    FPC := 0;
  end;
  ClosePipes;
  FActive := False;
end;

function TTerminalBackendWindows.PumpInput: Integer;
var
  Buffer: array[0..READ_BUFFER_SIZE - 1] of Byte;
  BytesAvail, BytesRead: DWORD;
  Data: RawByteString;
begin
  Result := 0;
  if FOutputRead = 0 then
    Exit;

  while PeekNamedPipe(FOutputRead, nil, 0, nil, @BytesAvail, nil) and (BytesAvail > 0) do
  begin
    if not ReadFile(FOutputRead, Buffer[0], Min(DWORD(SizeOf(Buffer)), BytesAvail), BytesRead, nil) then
      Break;
    if BytesRead = 0 then
      Break;
    SetLength(Data, BytesRead);
    Move(Buffer[0], Data[1], BytesRead);
    FParser.FeedBytes(Data);
    Inc(Result, BytesRead);
  end;

  if not IsRunning then
    FActive := False;
end;

function TTerminalBackendWindows.WriteInput(const AData: RawByteString): Integer;
var
  BytesWritten: DWORD;
begin
  Result := 0;
  if (FInputWrite = 0) or (AData = '') then
    Exit;
  if WriteFile(FInputWrite, AData[1], Length(AData), BytesWritten, nil) then
    Result := BytesWritten;
end;

function TTerminalBackendWindows.Resize(ACols, ARows: Integer): Boolean;
var
  Size: TCoord;
  HR: HRESULT;
begin
  Result := False;
  if (FPC = 0) or not Assigned(FResizePseudoConsole) then
    Exit;
  Size.X := ACols;
  Size.Y := ARows;
  HR := FResizePseudoConsole(FPC, Size);
  Result := not FAILED(HR);
end;

function TTerminalBackendWindows.IsRunning: Boolean;
var
  WaitRes: DWORD;
begin
  Result := FActive;
  if Result and (FProcessInfo.hProcess <> 0) then
  begin
    WaitRes := WaitForSingleObject(FProcessInfo.hProcess, 0);
    if WaitRes <> WAIT_TIMEOUT then
    begin
      FActive := False;
      Result := False;
    end;
  end;
end;

initialization
  TTerminalBackendBase.CDefaultClass := TTerminalBackendWindows;
{$ENDIF}

end.
