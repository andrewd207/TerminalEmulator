unit Terminal.Backend.Unix;
{$IFNDEF UNIX}
interface
implementation
{$ENDIF}

{$IFDEF UNIX}
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix, Unix, Termio,
  Terminal.Backend.Base,
  Terminal.Core,
  Terminal.Parser;

type
  TTerminalBackendUnix = class(TTerminalBackendBase)
  private
    FMasterFD: cint;
    FChildPID: TPid;
    function SetNonBlocking(AFD: cint): Boolean;
    function BuildArgv(const ACommand: array of string): PPChar;
    procedure FreeArgv(AArgv: PPChar; ACount: Integer);
    function BuildEnvp: PPChar;
    procedure FreeEnvp(AEnvp: PPChar; ACount: Integer);
    procedure InternalCloseMaster;
  public
    constructor Create(ACore: TTerminalCore; AParser: TTerminalParser); override;
    destructor Destroy; override;

    function StartShell(const AShell: string = ''; const AArgs: array of string): Boolean; override;
    function StartCommand(const AProgram: string; const AArgs: array of string): Boolean; override;
    procedure Stop; override;
    function PumpInput: Integer; override;
    function WriteInput(const AData: RawByteString): Integer; override;
    function Resize(ACols, ARows: Integer): Boolean; override;
    function IsRunning: Boolean; override;

    property MasterFD: cint read FMasterFD;
    property ChildPID: TPid read FChildPID;
    property Active: Boolean read FActive;
    property TermProgram: string read FTermProgram write FTermProgram;
    property TermName: string read FTermName write FTermName;
  end;

implementation

uses
  Terminal.Unicode;

const
  READ_BUFFER_SIZE = 8192;

{ Define the types used by forkpty }
type
  PInteger = ^Integer;
  PTermios = Pointer; { Replace with proper termios definition if needed }
  PWinsize = Pointer; { Replace with proper winsize definition if needed }

{ Import forkpty from libutil }
function forkpty(var amaster: Integer; name: PChar; termp: PTermios; winp: PWinsize): Integer; cdecl; external 'c' name 'forkpty';


constructor TTerminalBackendUnix.Create(ACore: TTerminalCore; AParser: TTerminalParser);
begin
  inherited Create(ACore, AParser);
  FMasterFD := -1;
  FChildPID := 0;
end;

destructor TTerminalBackendUnix.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TTerminalBackendUnix.SetNonBlocking(AFD: cint): Boolean;
var
  Flags: cint;
begin
  Flags := fpFcntl(AFD, F_GETFL, 0);
  if Flags < 0 then
    Exit(False);
  Result := fpFcntl(AFD, F_SETFL, Flags or O_NONBLOCK) >= 0;
end;

function TTerminalBackendUnix.BuildArgv(const ACommand: array of string): PPChar;
var
  I, Count: Integer;
begin
  Count := Length(ACommand);
  GetMem(Result, SizeOf(PChar) * (Count + 1));
  FillChar(Result^, SizeOf(PChar) * (Count + 1), 0);
  for I := 0 to Count - 1 do
    Result[I] := StrAlloc(Length(ACommand[I]) + 1);
  for I := 0 to Count - 1 do
    StrPCopy(Result[I], ACommand[I]);
  Result[Count] := nil;
end;

procedure TTerminalBackendUnix.FreeArgv(AArgv: PPChar; ACount: Integer);
var
  I: Integer;
begin
  if AArgv = nil then
    Exit;
  for I := 0 to ACount - 1 do
    if AArgv[I] <> nil then
      StrDispose(AArgv[I]);
  FreeMem(AArgv);
end;

function TTerminalBackendUnix.BuildEnvp: PPChar;
var
  EnvList: TStringList;
  I: Integer;
  S: string;
begin
  EnvList := TStringList.Create;
  try
    for I := 1 to GetEnvironmentVariableCount do
      EnvList.Add(GetEnvironmentString(I));
    EnvList.Values['TERM'] := FTermName;
    EnvList.Values['COLORTERM'] := 'truecolor';
    EnvList.Values['TERM_PROGRAM'] := FTermProgram;

    GetMem(Result, SizeOf(PChar) * (EnvList.Count + 1));
    FillChar(Result^, SizeOf(PChar) * (EnvList.Count + 1), 0);
    for I := 0 to EnvList.Count - 1 do
    begin
      S := EnvList[I];
      Result[I] := StrAlloc(Length(S) + 1);
      StrPCopy(Result[I], S);
    end;
    Result[EnvList.Count] := nil;
  finally
    EnvList.Free;
  end;
end;

procedure TTerminalBackendUnix.FreeEnvp(AEnvp: PPChar; ACount: Integer);
var
  I: Integer;
begin
  if AEnvp = nil then
    Exit;
  for I := 0 to ACount - 1 do
    if AEnvp[I] <> nil then
      StrDispose(AEnvp[I]);
  FreeMem(AEnvp);
end;

procedure TTerminalBackendUnix.InternalCloseMaster;
begin
  if FMasterFD >= 0 then
  begin
    fpClose(FMasterFD);
    FMasterFD := -1;
  end;
end;

function TTerminalBackendUnix.StartShell(const AShell: string; const AArgs: array of string): Boolean;
var
  ShellPath: string;
  Cmd: array of string;
  I: Integer;
begin
  ShellPath := AShell;
  if ShellPath = '' then
    ShellPath := GetEnvironmentVariable('SHELL');
  if ShellPath = '' then
    ShellPath := '/bin/sh';

  SetLength(Cmd, 1 + Length(AArgs));
  Cmd[0] := ShellPath;
  for I := 0 to High(AArgs) do
    Cmd[I + 1] := AArgs[I];
  Result := StartCommand(ShellPath, Cmd);
end;

function TTerminalBackendUnix.StartCommand(const AProgram: string; const AArgs: array of string): Boolean;
var
  WS: winsize;
  PID: TPid;
  Argv: PPChar;
  Envp: PPChar;
  ArgCount, EnvCountLocal: Integer;
begin
  Result := False;
  Stop;

  WS.ws_col := FCore.Cols;
  WS.ws_row := FCore.Rows;
  WS.ws_xpixel := 0;
  WS.ws_ypixel := 0;

  ArgCount := Length(AArgs);
  Argv := BuildArgv(AArgs);
  EnvCountLocal := GetEnvironmentVariableCount;
  Envp := BuildEnvp;
  try
    PID := forkpty(FMasterFD, nil, nil, @WS);
    if PID < 0 then
      Exit(False);

    if PID = 0 then
    begin
      fpExecVE(PChar(AProgram), Argv, Envp);
      Halt(127);
    end;

    FChildPID := PID;
    FActive := True;
    SetNonBlocking(FMasterFD);
    Result := True;
  finally
    FreeArgv(Argv, ArgCount);
    FreeEnvp(Envp, EnvCountLocal + 3);
  end;
end;

procedure TTerminalBackendUnix.Stop;
var
  Status: cint;
begin
  if FChildPID > 0 then
  begin
    fpKill(FChildPID, SIGTERM);
    fpWaitPid(FChildPID, @Status, WNOHANG);
    FChildPID := 0;
  end;
  InternalCloseMaster;
  FActive := False;
end;

function TTerminalBackendUnix.PumpInput: Integer;
var
  Buffer: array[0..READ_BUFFER_SIZE - 1] of Byte;
  ReadCount: ssize_t;
  Data: RawByteString;
  Status: cint;
begin
  Result := 0;
  if FMasterFD < 0 then
    Exit;

  repeat
    ReadCount := fpRead(FMasterFD, Buffer{%H-}, SizeOf(Buffer));
    if ReadCount > 0 then
    begin
      SetLength(Data, ReadCount);
      Move(Buffer[0], Data[1], ReadCount);
      FParser.FeedBytes(Data);
      Inc(Result, ReadCount);
    end
    else if ReadCount = 0 then
    begin
      Stop;
      Break;
    end
    else
    begin
      if (fpgeterrno = ESysEAGAIN) or (fpgeterrno = ESysEWOULDBLOCK) then
        Break
      else
      begin
        Stop;
        Break;
      end;
    end;
  until ReadCount <= 0;

  if FChildPID > 0 then
    if fpWaitPid(FChildPID, @Status, WNOHANG) = FChildPID then
      Stop;
end;

function TTerminalBackendUnix.WriteInput(const AData: RawByteString): Integer;
var
  Written, Remaining, Offset: ssize_t;
begin
  Result := 0;
  if (FMasterFD < 0) or (AData = '') then
    Exit;

  Remaining := Length(AData);
  Offset := 1;
  while Remaining > 0 do
  begin
    Written := fpWrite(FMasterFD, AData[Offset], Remaining);
    if Written > 0 then
    begin
      Inc(Result, Written);
      Inc(Offset, Written);
      Dec(Remaining, Written);
    end
    else if (Written < 0) and ((fpgeterrno = ESysEAGAIN) or (fpgeterrno = ESysEWOULDBLOCK)) then
      Break
    else
      Break;
  end;
end;

function TTerminalBackendUnix.Resize(ACols, ARows: Integer): Boolean;
var
  WS: winsize;
begin
  Result := False;
  if FMasterFD < 0 then
    Exit;
  WS.ws_col := ACols;
  WS.ws_row := ARows;
  WS.ws_xpixel := 0;
  WS.ws_ypixel := 0;
  //Writeln(Format('%d:%d', [ACols, ARows]));
  Result := fpIOCtl(FMasterFD, TIOCSWINSZ, @WS) = 0;
end;

function TTerminalBackendUnix.IsRunning: Boolean;
var
  Status: cint;
begin
  Result := FActive;
  if Result and (FChildPID > 0) then
    if fpWaitPid(FChildPID, @Status, WNOHANG) = FChildPID then
    begin
      Stop;
      Result := False;
    end;
end;

initialization
  TTerminalBackendBase.CDefaultClass := TTerminalBackendUnix;
{$ENDIF}


end.


