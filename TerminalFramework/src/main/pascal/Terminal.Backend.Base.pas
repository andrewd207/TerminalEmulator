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

    property Core: TTerminalCore read FCore;
    property Parser: TTerminalParser read FParser;
    property Active: Boolean read FActive;
    property TermProgram: string read FTermProgram write FTermProgram;
    property TermName: string read FTermName write FTermName;
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
end;

destructor TTerminalBackendBase.Destroy;
begin
  inherited Destroy;
end;

end.

