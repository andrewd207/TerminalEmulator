{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.Core;
{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}
{$ModeSwitch typehelpers}

interface

uses
  Classes, SysUtils, fgl,
  Terminal.Unicode,
  Terminal.Core.Ringbuffer;

const
  TERM_DEFAULT_TAB_WIDTH = 8;
  TERM_DEFAULT_FG = $C0C0C0;
  TERM_DEFAULT_BG = $000000;

type

   TTermColorMode = (tcmDefault, tcmIndexed, tcmRGB);

 TTermAttrFlag = (
   tafBlank, { unset cell. returns #32 ' ' }
   tafBold,
   tafFaint,
   tafItalic,
   tafUnderline,
   tafBlink,
   tafInverse,
   tafHidden,
   tafStrike,
   tafDirty,
   tafWideLead,
   tafWideTrail
 );
 TTermAttrFlags = set of TTermAttrFlag;

 TTermColor = record
   Mode: TTermColorMode;
   Index: Byte;
   R: Byte;
   G: Byte;
   B: Byte;
 end;

 TTermCodePointArray = array of Cardinal;

 { TTermCell }

 TTermCell = record
  private
    procedure SetCodePoint(AValue: Cardinal);
  public
    FCodePoint: Cardinal;
    Cluster: RawByteString;
    Combining: TTermCodePointArray;
    Attrs: TTermAttrFlags;
    FG: TTermColor;
    BG: TTermColor;

    class operator Initialize(var ADest: TTermCell);
    class operator Finalize(var ADest: TTermCell);
    class operator Copy(constref ASrc: TTermCell; var ADest: TTermCell);

    function IsBlank: Boolean;
    property CodePoint: Cardinal read FCodePoint write SetCodePoint;
  end;
 PTermCell = ^TTermCell;

  { TTermCellLine }

  // A line posibly longer that the width of the terminal. it returns it's line as several lines if needed.

  { TTermLine }

  type
  TTermCellLine = array of TTermCell;

  TTermCellLineHelper = type helper for TTermCellLine
    function UsedLength: Integer;
    procedure FillBlanks(ACols: Integer; const ABlank: TTermCell);
    procedure ClearToBlank(const ABlank: TTermCell);
    function MakeCopy(NewColumnCount: Integer; const ABlank: TTermCell): TTermCellLine;
  end;

  TTermLineFlags = set of (
    tlfWrapped
  );

  TTermLine = record
    Cells: TTermCellLine;
    Flags: TTermLineFlags;
  end;

  { TTermLineHelper }

  TTermLineHelper = type helper for TTermLine
    procedure Init(ACols: Integer; const ACellValue: TTermCell);
    procedure Clear(const ABlank: TTermCell);
    function MakeResizedCopy(NewColumnCount: Integer; const ABlank: TTermCell): TTermLine;
    function AsPlainText: UTF8String;
  end;

  TTermLines = array of TTermLine;

  TTermLinesHelper = type helper for TTermLines
    function Length: Integer;
    function MakeCopy(NewColumnCount: Integer; var ABlank: TTermCell): TTermLines;
    procedure Init(ALineCount, ACols: Integer; var ABlank: TTermCell);
    procedure Clear(const ABlank: TTermCell);
  end;


  { TTermHistoryLine }

  TTermHistoryLine = class
  private
    FLine: TTermLine;
    function GetAsPlainText: UTF8String;
  public
    constructor Create(const ALine: TTermLine);
    destructor Destroy; override;
    property Line: TTermLine read FLine;
    property AsPlainText: UTF8String read GetAsPlainText;
  end;

  TTermHistoryRing = specialize TRingBuffer<TTermHistoryLine>;

  TTermCursor = record
    Col: Integer;
    Row: Integer;
    Visible: Boolean;
    PendingWrap: Boolean; // set when cursor is at last col; next printable char wraps first
  end;

  TTermCellPos = record
    Col: Integer;
    Row: Integer; // virtual row: history + screen
  end;

  TTermSelectionMode = (tsmNone, tsmLinear);

  TTermSelection = record
    Active: Boolean;
    Selecting: Boolean;
    Mode: TTermSelectionMode;
    Anchor: TTermCellPos;
    Focus: TTermCellPos;
  end;

  TTermMouseProtocol = (
    tmpNone,       { reporting disabled }
    tmpX10,        { ?9  press only }
    tmpVT200,      { ?1000 press + release }
    tmpBtnEvent,   { ?1002 press + release + motion while button held }
    tmpAnyEvent    { ?1003 press + release + all motion }
  );

  TTermMouseEncoding = (
    tmeDefault,    { legacy   ESC[M Cb Cx Cy (+32 offset, capped at 223) }
    tmeSGR         { ?1006    ESC[<b;x;yM/m }
  );

  TTermMouseButton = (
    tmbLeft   = 0,
    tmbMiddle = 1,
    tmbRight  = 2,
    tmbRelease = 3,  { default-encoding release (button unknown) }
    tmbWheelUp   = 64,
    tmbWheelDown = 65
  );

  TTermPen = record
    Attrs: TTermAttrFlags;
    FG: TTermColor;
    BG: TTermColor;
  end;

  TTermRect = record
    Left: Integer;
    Top: Integer;
    Right: Integer;
    Bottom: Integer;
  end;

  TTerminalInvalidateEvent = procedure(Sender: TObject; const ARect: TTermRect) of object;
  TTerminalBellEvent = procedure(Sender: TObject) of object;
  TTerminalTitleEvent = procedure(Sender: TObject; const ATitle: string) of object;
  TTerminalWriteEvent = procedure(Sender: TObject; const AData: RawByteString) of object;
  { Fired for OSC 52 clipboard writes. ATargets is the Pc field ('c','p','s', combinations, or empty=>'s0' per xterm). AText is the decoded UTF-8 payload. }
  TTerminalClipboardSetEvent = procedure(Sender: TObject; const ATargets: string; const AText: RawByteString) of object;
  { Fired for OSC 52 clipboard reads. Handler should set AText to the current clipboard contents. }
  TTerminalClipboardGetEvent = procedure(Sender: TObject; const ATargets: string; out AText: RawByteString) of object;

  { TTermScreenBuffer }

  TTermBufferAnchor = (abBottom, abTop);

  TTermScreenBuffer = class
  private
    FCols: Integer;
    FRows: Integer;
    FScrollbackLimit: Integer;
    FLines: TTermLines;
    FHistory: TTermHistoryRing;
    FBlankCell: TTermCell;
    FAnchor: TTermBufferAnchor;
    function GetHistoryCount: Integer;
    procedure RecreateHistory;
    procedure SetSizeInternal(ACols: Integer; ARows: Integer; Preserve: Boolean);
    procedure InitBlankCell;
    procedure SetBlankCell(const ACell: TTermCell);
    procedure AppendHistory(const ALine: TTermLine);
    procedure PopHistoryToTop(ACount: Integer);
    procedure ReflowToWidth(ANewCols, ANewRows: Integer;
      var ACursorRow, ACursorCol: Integer);
  public
    constructor Create(ACols, ARows, AScrollbackLimit: Integer);
    destructor Destroy; override;
    procedure Resize(ACols: Integer; ARows: Integer; Preserve: Boolean = True);
    procedure Clear;
    procedure ClearRow(ARow: Integer);
    procedure ScrollUp(ATopRow, ABottomRow, ACount: Integer);
    procedure ScrollDown(ATopRow, ABottomRow, ACount: Integer);
    function InBounds(ACol, ARow: Integer): Boolean;
    function CellAt(ACol, ARow: Integer): PTermCell;
    function GetLine(ARow: Integer): TTermCellLine;
    function GetHistoryLine(AIndex: Integer): TTermCellLine;
    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property ScrollbackLimit: Integer read FScrollbackLimit write FScrollbackLimit;
    property HistoryCount: Integer read GetHistoryCount;
    property BlankCell: TTermCell read FBlankCell write SetBlankCell;
    property Anchor: TTermBufferAnchor read FAnchor write FAnchor;
    property Lines: TTermLines read FLines;
  end;

  TTerminalCore = class
  private
    FBracketedPasteMode: Boolean;
    FMainBuffer: TTermScreenBuffer;
    FAltBuffer: TTermScreenBuffer;
    FUseAltBuffer: Boolean;
    FCursor: TTermCursor;
    FSavedCursors: array[Boolean] of TTermCursor; // indexed by FUseAltBuffer
    FPen: TTermPen;
    FDefaultPen: TTermPen;
    FCols: Integer;
    FRows: Integer;
    FTopMargin: Integer;
    FBottomMargin: Integer;
    FAutoWrap: Boolean;
    FOriginMode: Boolean;
    FInsertMode: Boolean;
    FMouseProtocol: TTermMouseProtocol;
    FMouseEncoding: TTermMouseEncoding;
    FTabStops: array of Boolean;
    FOnInvalidate: TTerminalInvalidateEvent;
    FOnBell: TTerminalBellEvent;
    FOnTitle: TTerminalTitleEvent;
    FOnWrite: TTerminalWriteEvent;
    FOnClipboardSet: TTerminalClipboardSetEvent;
    FOnClipboardGet: TTerminalClipboardGetEvent;
    FSyncDepth: Integer;
    FSyncDirty: TTermRect;
    FSyncDirtyValid: Boolean;
    FSyncStartTick: QWord;
    { Debug ring of recent ops, dumped on the U+2502-bottom-rows trap. }
    FDbgRing: array[0..255] of string;
    FDbgRingHead: Integer;
    FDbgCounter: Integer;
    FTrapTail: string;
    FTrapFired: Boolean;
    function ActiveBuffer: TTermScreenBuffer;
    function MakeBlankCell: TTermCell;
    procedure ClampCursor;
    procedure MarkAllDirty;
    procedure InvalidateRect(ALeft, ATop, ARight, ABottom: Integer);
    procedure EmitInvalidate(const R: TTermRect);
    procedure SetBracketedPasteMode(AValue: Boolean);
    procedure SetTabStopDefaults;
    procedure InternalLineFeed(WithCarriageReturn: Boolean);
    procedure PutCellAtCursor(const ACell: TTermCell; AdvanceCursor: Boolean = True);
    procedure ClearCell(var ACell: TTermCell);
    procedure CopyCell(const ASource: TTermCell; var ADest: TTermCell);
    procedure InitializeCell(var ACell: TTermCell; ACodePoint: Cardinal; const ACluster: RawByteString;
      const AAttrs: TTermAttrFlags; const AFG, ABG: TTermColor);
    function PreviousBaseCell(out ACol, ARow: Integer; out ACell: PTermCell): Boolean;
  public
    constructor Create(ACols, ARows: Integer; AScrollbackLimit: Integer = 5000);
    destructor Destroy; override;

    procedure Reset;
    procedure Resize(ACols, ARows: Integer);
    procedure SwitchToMainBuffer;
    procedure SwitchToAltBuffer(AClear: Boolean = True);
    procedure ClearAltBuffer;
    procedure BeginSyncUpdate;
    procedure EndSyncUpdate;
    procedure CheckSyncTimeout;
    procedure DbgRecord(const ALine: string);
    procedure DbgDump;

    procedure SetCursorPos(ACol, ARow: Integer);
    procedure MoveCursor(ADeltaCol, ADeltaRow: Integer);
    procedure SaveCursor;
    procedure RestoreCursor;
    procedure CursorHome;
    procedure CursorUp(ACount: Integer = 1);
    procedure CursorDown(ACount: Integer = 1);
    procedure CursorForward(ACount: Integer = 1);
    procedure CursorBackward(ACount: Integer = 1);
    procedure NextLine(ACount: Integer = 1);
    procedure PrevLine(ACount: Integer = 1);
    procedure SetScrollRegion(ATopRow, ABottomRow: Integer);
    procedure ResetScrollRegion;
    procedure ScrollUp(ACount: Integer = 1);
    procedure ScrollDown(ACount: Integer = 1);

    procedure ClearScreen;
    procedure ClearLine;
    procedure EraseInDisplay(AMode: Integer);
    procedure EraseInLine(AMode: Integer);
    procedure EraseChars(ACount: Integer);
    procedure InsertChars(ACount: Integer);
    procedure DeleteChars(ACount: Integer);
    procedure InsertLines(ACount: Integer);
    procedure DeleteLines(ACount: Integer);

    procedure CarriageReturn;
    procedure LineFeed;
    procedure ReverseIndex;
    procedure Backspace;
    procedure HorizontalTab;
    procedure BackTab(ACount: Integer = 1);
    procedure TabSet;
    procedure TabClear(AAll: Boolean = False);

    procedure PutCodePoint(ACodePoint: Cardinal);
    procedure WriteUTF8(const AUTF8: RawByteString);

    procedure SetAutoWrap(AValue: Boolean);
    procedure SetOriginMode(AValue: Boolean);
    procedure SetInsertMode(AValue: Boolean);
    procedure SetCursorVisible(AValue: Boolean);

    procedure SetMouseProtocol(AValue: TTermMouseProtocol);
    procedure SetMouseEncoding(AValue: TTermMouseEncoding);
    { Build and send a mouse report to the host (PTY).
      ACol/ARow are 0-based screen coordinates.
      For wheel events, use AButton in {tmbWheelUp, tmbWheelDown} and APressed=True. }
    procedure SendMouse(AButton: TTermMouseButton; ACol, ARow: Integer;
      APressed, AMotion, AShift, AAlt, ACtrl: Boolean);
    property MouseProtocol: TTermMouseProtocol read FMouseProtocol;
    property MouseEncoding: TTermMouseEncoding read FMouseEncoding;

    procedure ResetPen;
    procedure SetBold(AValue: Boolean);
    procedure SetFaint(AValue: Boolean);
    procedure SetItalic(AValue: Boolean);
    procedure SetUnderline(AValue: Boolean);
    procedure SetBlink(AValue: Boolean);
    procedure SetInverse(AValue: Boolean);
    procedure SetHidden(AValue: Boolean);
    procedure SetStrike(AValue: Boolean);
    procedure SetFGDefault;
    procedure SetBGDefault;
    procedure SetFGIndexed(AIndex: Byte);
    procedure SetBGIndexed(AIndex: Byte);
    procedure SetFGRGB(ARed, AGreen, ABlue: Byte);
    procedure SetBGRGB(ARed, AGreen, ABlue: Byte);

    procedure Bell;
    procedure SetWindowTitle(const ATitle: string);
    procedure WriteReply(const AData: RawByteString);

    function GetCell(ACol, ARow: Integer): TTermCell;
    function GetLine(ARow: Integer): TTermCellLine;
    function GetHistoryLine(AIndex: Integer): TTermCellLine;
    function HistoryCount: Integer;
    function IsUsingAltBuffer: Boolean;
    function GetInSyncUpdate: Boolean;
    { True when the line at AVirtualRow (history rows first, then screen)
      ends in a soft wrap — i.e. the next physical row continues the same
      logical line because the cursor hit the right edge. }
    function IsLineWrapped(AVirtualRow: Integer): Boolean;
    { Snapshot terminal content as a styled HTML <pre> block. Honors fg/bg
      colors, bold/italic/underline/strike, faint, inverse, hidden, blink,
      and wide-cell layout. Output is self-contained (no external CSS);
      paste it into anything that accepts HTML and the colors come along.

      Row indices in GetHtmlRange are *virtual*: 0..HistoryCount-1 reach
      into scrollback, HistoryCount..HistoryCount+Rows-1 cover the screen.
      Use -1 for AStartCol/AEndCol to select the full row width. }
    function GetHtmlRange(AStartRow, AEndRow, AStartCol, AEndCol: Integer;
                          const ATitle: string = ''): RawByteString;
    function GetHtmlScreen(const ATitle: string = ''): RawByteString;
    function GetHtmlAll(const ATitle: string = ''): RawByteString;
    function GetHtmlSelection(const ASelection: TTermSelection;
                              const ATitle: string = ''): RawByteString;

    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property Cursor: TTermCursor read FCursor;
    property InSyncUpdate: Boolean read GetInSyncUpdate;
    property InAltBuffer: Boolean read FUseAltBuffer;
    function CellAt(ACol, ARow: Integer): PTermCell;
    property BracketedPasteMode: Boolean read FBracketedPasteMode write SetBracketedPasteMode;
    property OnInvalidate: TTerminalInvalidateEvent read FOnInvalidate write FOnInvalidate;
    property OnBell: TTerminalBellEvent read FOnBell write FOnBell;
    property OnTitle: TTerminalTitleEvent read FOnTitle write FOnTitle;
    property OnWrite: TTerminalWriteEvent read FOnWrite write FOnWrite;
    property OnClipboardSet: TTerminalClipboardSetEvent read FOnClipboardSet write FOnClipboardSet;
    property OnClipboardGet: TTerminalClipboardGetEvent read FOnClipboardGet write FOnClipboardGet;
    procedure FireClipboardSet(const ATargets: string; const AText: RawByteString);
    function FireClipboardGet(const ATargets: string; out AText: RawByteString): Boolean;
  end;


procedure TermNormalizeSelection(const A, B: TTermCellPos; out S, E: TTermCellPos);
function TermDefaultColorFG: TTermColor;
function TermDefaultColorBG: TTermColor;
function TermIndexedColor(AIndex: Byte): TTermColor;
function TermRGBColor(ARed, AGreen, ABlue: Byte): TTermColor;
function TermColorToRGB(const AColor: TTermColor): Cardinal;
function TermBlankCell(const APen: TTermPen): TTermCell;



implementation

uses
  Math;

const
  ANSI_16_COLORS: array[0..15] of Cardinal = (
    $000000, $800000, $008000, $808000,
    $000080, $800080, $008080, $C0C0C0,
    $808080, $FF0000, $00FF00, $FFFF00,
    $0000FF, $FF00FF, $00FFFF, $FFFFFF
  );

operator = (const A,B: TTermCellPos): Boolean;
begin
  Result := (A.Col = B.Col) and (A.Row = B.Row);
end;


procedure TermNormalizeSelection(const A, B: TTermCellPos; out S, E: TTermCellPos);
begin
  if (A.Row < B.Row) or ((A.Row = B.Row) and (A.Col <= B.Col)) then
  begin
    S := A;
    E := B;
  end
  else
  begin
    S := B;
    E := A;
  end;
end;

function TermDefaultColorFG: TTermColor;
begin
  Result := Default(TTermColor);
  Result.Mode := tcmDefault;
end;

function TermDefaultColorBG: TTermColor;
begin
  Result := Default(TTermColor);
  Result.Mode := tcmDefault;
end;

function TermIndexedColor(AIndex: Byte): TTermColor;
begin
  Result.Mode := tcmIndexed;
  Result.Index := AIndex;
  Result.R := 0;
  Result.G := 0;
  Result.B := 0;
end;

function TermRGBColor(ARed, AGreen, ABlue: Byte): TTermColor;
begin
  Result.Mode := tcmRGB;
  Result.Index := 0;
  Result.R := ARed;
  Result.G := AGreen;
  Result.B := ABlue;
end;

function XTerm256ToRGB(AIndex: Byte): Cardinal;
var
  V, R, G, B: Integer;
  Steps: array[0..5] of Integer = (0, 95, 135, 175, 215, 255);
begin
  if AIndex < 16 then
    Exit(ANSI_16_COLORS[AIndex]);

  if AIndex <= 231 then
  begin
    V := AIndex - 16;
    R := Steps[V div 36];
    G := Steps[(V div 6) mod 6];
    B := Steps[V mod 6];
    Exit((R shl 16) or (G shl 8) or B);
  end;

  V := 8 + (AIndex - 232) * 10;
  Exit((V shl 16) or (V shl 8) or V);
end;

function TermColorToRGB(const AColor: TTermColor): Cardinal;
begin
  case AColor.Mode of
    tcmIndexed:
      Result := XTerm256ToRGB(AColor.Index);
    tcmRGB:
      Result := (Cardinal(AColor.R) shl 16) or (Cardinal(AColor.G) shl 8) or Cardinal(AColor.B);
  else
      Result := TERM_DEFAULT_FG;
  end;
end;


function TermBlankCell(const APen: TTermPen): TTermCell;
begin
  Result.FCodePoint := Ord(' ');
  Result.Cluster := '';
  SetLength(Result.Combining, 0);
  Result.Attrs := APen.Attrs;
  Result.FG := APen.FG;
  Result.BG := APen.BG;
end;

{ TTermCell }

procedure TTermCell.SetCodePoint(AValue: Cardinal);
begin
  FCodePoint := AValue;
end;

function TTermCell.IsBlank: Boolean;
begin
  Result :=
    (FCodePoint = Ord(' ')) and
    (Cluster = '') and
    (Length(Combining) = 0);
end;

class operator TTermCell.Initialize(var ADest: TTermCell);
begin
  ADest.FCodePoint := Ord(' ');
  ADest.Cluster := '';
  SetLength(ADest.Combining, 0);
  ADest.Attrs := [];
  ADest.FG := TermDefaultColorFG;
  ADest.BG := TermDefaultColorBG;
end;

class operator TTermCell.Finalize(var ADest: TTermCell);
begin
  ADest.Cluster := '';
  SetLength(ADest.Combining, 0);
  ADest.Attrs := [];
  ADest.FCodePoint := 0;
  ADest.FG := Default(TTermColor);
  ADest.BG := Default(TTermColor);
end;

class operator TTermCell.Copy(constref ASrc: TTermCell; var ADest: TTermCell);
begin
  ADest.FCodePoint := ASrc.FCodePoint;
  ADest.Cluster := Copy(ASrc.Cluster, 1, MaxInt);
  ADest.Combining := Copy(ASrc.Combining, 0, Length(ASrc.Combining));
  ADest.Attrs := ASrc.Attrs;
  ADest.FG := ASrc.FG;
  ADest.BG := ASrc.BG;
end;


{ TTermLine }

function TTermCellLineHelper.UsedLength: Integer;
begin
  Result := System.Length(Self);
  while (Result > 0) and Self[Result - 1].IsBlank do
    Dec(Result);
end;

procedure TTermCellLineHelper.FillBlanks(ACols: Integer; const ABlank: TTermCell);
var
  I: Integer;
begin
  SetLength(Self, ACols);
  for I := 0 to ACols - 1 do
    Self[I] := ABlank;
end;

procedure TTermCellLineHelper.ClearToBlank(const ABlank: TTermCell);
var
  I: Integer;
begin
  for I := 0 to High(Self) do
    Self[I] := ABlank;
end;

function TTermCellLineHelper.MakeCopy(NewColumnCount: Integer; const ABlank: TTermCell): TTermCellLine;
var
  CopyCount: Integer;
  I: Integer;
begin
  if NewColumnCount < 0 then
    NewColumnCount := 0;

  SetLength(Result, NewColumnCount);

  for I := 0 to NewColumnCount - 1 do
    Result[I] := ABlank;

  if Length(Self) < NewColumnCount then
    CopyCount := Length(Self)
  else
    CopyCount := NewColumnCount;

  for I := 0 to CopyCount - 1 do
    Result[I] := Self[I];
end;

procedure TTermLineHelper.Init(ACols: Integer; const ACellValue: TTermCell);
var
  I: Integer;
begin
  if ACols < 0 then
    ACols := 0;

  SetLength(Self.Cells, ACols);
  for I := 0 to ACols - 1 do
    Self.Cells[I] := ACellValue;

  Self.Flags := [];
end;

procedure TTermLineHelper.Clear(const ABlank: TTermCell);
var
  I: Integer;
begin
  for I := 0 to High(Self.Cells) do
    Self.Cells[I] := ABlank;
  Self.Flags := [];
end;

function TTermLineHelper.MakeResizedCopy(NewColumnCount: Integer; const ABlank: TTermCell): TTermLine;
begin
  Result.Cells := Cells.MakeCopy(NewColumnCount, ABlank);
  Result.Flags := Flags;
end;

function TTermLineHelper.AsPlainText: UTF8String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Self.Cells) do
    Result := Result+Self.Cells[i].Cluster;
end;


function TTermLinesHelper.Length: Integer;
begin
  Result := System.Length(Self);
end;

procedure TTermLinesHelper.Init(ALineCount, ACols: Integer; var ABlank: TTermCell);
var
  I: Integer;
begin
  SetLength(Self, ALineCount);
  for I := 0 to ALineCount - 1 do
    Self[I].Init(ACols, ABlank);
end;

function TTermLinesHelper.MakeCopy(NewColumnCount: Integer; var ABlank: TTermCell): TTermLines;
var
  I: Integer;
begin
  SetLength(Result, System.Length(Self));
  for I := 0 to High(Self) do
    Result[I] := Self[I].MakeResizedCopy(NewColumnCount, ABlank);
end;

procedure TTermLinesHelper.Clear(const ABlank: TTermCell);
var
  I: Integer;
begin
  for I := 0 to High(Self) do
    Self[I].Clear(ABlank);
end;

{ TTermHistoryLine }

function TTermHistoryLine.GetAsPlainText: UTF8String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FLine.Cells) do
    Result := Result +FLine.Cells[i].Cluster;
end;

constructor TTermHistoryLine.Create(const ALine: TTermLine);
begin
  inherited Create;
  FLine := ALine.MakeResizedCopy(System.Length(ALine.Cells), Default(TTermCell));
end;

destructor TTermHistoryLine.Destroy;
begin
  FLine.Clear(Default(TTermCell));
  inherited Destroy;
end;


constructor TTermScreenBuffer.Create(ACols, ARows, AScrollbackLimit: Integer);
begin
  inherited Create;
  FCols := 0;
  FRows := 0;
  FScrollbackLimit := AScrollbackLimit;
  FAnchor := abBottom;
  RecreateHistory;
  InitBlankCell;
  SetSizeInternal(ACols, ARows, False);
end;

destructor TTermScreenBuffer.Destroy;
begin
  FreeAndNil(FHistory);
  inherited Destroy;
end;

procedure TTermScreenBuffer.RecreateHistory;
begin
  FreeAndNil(FHistory);

  if FScrollbackLimit > 0 then
    FHistory := TTermHistoryRing.Create(FScrollbackLimit, True, True)
  else
    FHistory := nil;
end;

procedure TTermScreenBuffer.InitBlankCell;
begin
  FBlankCell.FCodePoint := Ord(' ');
  FBlankCell.Cluster := '';
  SetLength(FBlankCell.Combining, 0);
  FBlankCell.Attrs := [];
  FBlankCell.FG := TermDefaultColorFG;
  FBlankCell.BG := TermDefaultColorBG;
end;

procedure TTermScreenBuffer.SetBlankCell(const ACell: TTermCell);
begin
  FBlankCell := ACell; // class class TTermCell.Copy
end;

function TTermScreenBuffer.GetHistoryCount: Integer;
begin
  if Assigned(FHistory) then
    Result := FHistory.Count
  else
    Result := 0;
end;

procedure TTermScreenBuffer.SetSizeInternal(ACols: Integer; ARows: Integer; Preserve: Boolean);
var
  OldLines: TTermLines;
  NewLines: TTermLines;
  CopyRows: Integer;
  OldStart: Integer;
  NewStart: Integer;
  I: Integer;
begin
  if ACols < 1 then ACols := 1;
  if ARows < 1 then ARows := 1;

  if (not Preserve) or (Length(FLines) = 0) then
  begin
    FCols := ACols;
    FRows := ARows;
    SetLength(FLines, FRows);
    for I := 0 to FRows - 1 do
      FLines[I].Init(FCols, FBlankCell);
    Exit;
  end;

  if (ACols = FCols) and (ARows = FRows) then
    Exit;

  { Fast path: same width, grow rows — just append blank rows at the bottom. }
  if (ACols = FCols) and (ARows > FRows) and (FAnchor = abTop) then
  begin
    SetLength(FLines, ARows);
    for I := FRows to ARows - 1 do
      FLines[I].Init(FCols, FBlankCell);
    FRows := ARows;
    Exit;
  end;

  OldLines := FLines;
  SetLength(NewLines, ARows);

  for I := 0 to ARows - 1 do
    NewLines[I].Init(ACols, FBlankCell);

  if Length(OldLines) < ARows then
    CopyRows := Length(OldLines)
  else
    CopyRows := ARows;

  case FAnchor of
    abBottom:
      begin
        { Preserve the bottom rows of the old buffer; place them at the bottom
          of the new buffer.  On shrink, the top rows are dropped (typical
          shell behaviour: keep the prompt/cursor at the bottom).  On grow,
          blank rows are added above the old content. }
        OldStart := Length(OldLines) - CopyRows;
        NewStart := ARows - CopyRows;
      end;
    abTop:
      begin
        { Preserve the top rows of the old buffer; place them at the top of
          the new buffer.  On shrink, the bottom rows are dropped (right for
          full-screen TUI apps that draw top-down).  On grow, blank rows are
          added below the old content. }
        OldStart := 0;
        NewStart := 0;
      end;
  end;

  for I := 0 to CopyRows - 1 do
    NewLines[NewStart + I] := OldLines[OldStart + I].MakeResizedCopy(ACols, FBlankCell);

  FLines := NewLines;
  FCols := ACols;
  FRows := ARows;
end;


procedure TTermScreenBuffer.Resize(ACols: Integer; ARows: Integer; Preserve: Boolean);
begin
  SetSizeInternal(ACols, ARows, Preserve);
end;

procedure TTermScreenBuffer.Clear;
var
  I: Integer;
begin
  for I := 0 to High(FLines) do
    FLines[I].Clear(FBlankCell);

end;

procedure TTermScreenBuffer.ClearRow(ARow: Integer);
begin
  if (ARow < 0) or (ARow >= FRows) then
    Exit;
  FLines[ARow].Clear(FBlankCell);
end;

procedure TTermScreenBuffer.AppendHistory(const ALine: TTermLine);
var
  CopyLine: TTermLine;
begin
  if FScrollbackLimit <= 0 then Exit;
  if not Assigned(FHistory) then
    RecreateHistory;
  if not Assigned(FHistory) then Exit;

  CopyLine := ALine.MakeResizedCopy(FCols, FBlankCell);
  FHistory.Push(TTermHistoryLine.Create(CopyLine));
end;

procedure TTermScreenBuffer.ReflowToWidth(ANewCols, ANewRows: Integer;
  var ACursorRow, ACursorCol: Integer);
type
  TLogicalLine = record
    Cells: TTermCellLine;
    EndsWithWrap: Boolean; { the source line ran past its right margin }
  end;
var
  Logicals: array of TLogicalLine;
  LogCount: Integer;
  CurLogCells: TTermCellLine;
  CurLogLen: Integer;
  CurLogWrapped: Boolean;
  CursorLogIdx, CursorLogOffset: Integer;
  HistCount: Integer;
  TotalSrc: Integer;
  SrcRow: Integer;
  SrcLine: TTermLine;
  EffLen: Integer;
  I: Integer;

  procedure AppendCellToLog(const C: TTermCell);
  begin
    if Length(CurLogCells) <= CurLogLen then
      SetLength(CurLogCells, CurLogLen + 64);
    CurLogCells[CurLogLen] := C;
    Inc(CurLogLen);
  end;

  procedure CloseCurrentLogical;
  begin
    if LogCount >= Length(Logicals) then
      SetLength(Logicals, LogCount + 16);
    SetLength(CurLogCells, CurLogLen);
    Logicals[LogCount].Cells := CurLogCells;
    Logicals[LogCount].EndsWithWrap := CurLogWrapped;
    Inc(LogCount);
    CurLogCells := nil;
    CurLogLen := 0;
    CurLogWrapped := False;
  end;

  function EffectiveLength(const ALine: TTermLine; AIsWrapped: Boolean): Integer;
  var
    K: Integer;
  begin
    if AIsWrapped then
      Exit(Length(ALine.Cells));
    K := Length(ALine.Cells) - 1;
    while (K >= 0)
          and ((ALine.Cells[K].CodePoint = 0)
               or (ALine.Cells[K].CodePoint = Ord(' '))) do
      Dec(K);
    Result := K + 1;
  end;

var
  NewRows: array of TTermLine;
  NewRowCount: Integer;
  Logical: TLogicalLine;
  Pieces, P, Start, ChunkLen, Idx: Integer;
  ReflowBlank: TTermCell;
  CursorAbsRow, CursorAbsCol: Integer;
  KeepInVisible, ExcessForHistory: Integer;

  function StartNewRow: Integer;
  begin
    if NewRowCount >= Length(NewRows) then
      SetLength(NewRows, NewRowCount + 32);
    NewRows[NewRowCount].Cells := nil;
    NewRows[NewRowCount].Flags := [];
    NewRows[NewRowCount].Init(ANewCols, ReflowBlank);
    Result := NewRowCount;
    Inc(NewRowCount);
  end;

begin
  if ANewCols < 1 then ANewCols := 1;
  if ANewRows < 1 then ANewRows := 1;
  ReflowBlank := FBlankCell;

  if Assigned(FHistory) then
    HistCount := FHistory.Count
  else
    HistCount := 0;
  TotalSrc := HistCount + Length(FLines);

  { 1. Collect cells into logical lines, joining runs where the previous row
     was tlfWrapped. Track where the cursor maps to in logical coordinates. }
  CursorLogIdx := -1;
  CursorLogOffset := 0;
  CurLogCells := nil;
  CurLogLen := 0;
  CurLogWrapped := False;
  LogCount := 0;

  for SrcRow := 0 to TotalSrc - 1 do
  begin
    if SrcRow < HistCount then
      SrcLine := FHistory[SrcRow].Line
    else
      SrcLine := FLines[SrcRow - HistCount];
    EffLen := EffectiveLength(SrcLine, tlfWrapped in SrcLine.Flags);

    if SrcRow = HistCount + ACursorRow then
    begin
      CursorLogIdx := LogCount;
      CursorLogOffset := CurLogLen + ACursorCol;
    end;

    for I := 0 to EffLen - 1 do
      AppendCellToLog(SrcLine.Cells[I]);

    { CurLogWrapped reflects whether the CURRENT (most recently added) source
      row ends with a wrap. If it does, this logical continues into the next
      source row; otherwise close out the logical here. }
    CurLogWrapped := tlfWrapped in SrcLine.Flags;
    if not CurLogWrapped then
      CloseCurrentLogical;
  end;
  if (CurLogLen > 0) or CurLogWrapped then
    CloseCurrentLogical;

  { Trim trailing empty (blank) logical lines that came from padding at the
    bottom of the source buffer. We'll re-pad with blanks at emit time if
    the visible buffer still has room; without this trim we'd push the
    OLDEST real content into history just to make room for trailing blanks. }
  while (LogCount > 0)
        and (Length(Logicals[LogCount - 1].Cells) = 0)
        and (not Logicals[LogCount - 1].EndsWithWrap)
        and (CursorLogIdx <> LogCount - 1) do
    Dec(LogCount);

  { 2. Re-emit at the new width. Each logical line of length L becomes
     ceil(L/ANewCols) rows; all but the last get tlfWrapped (and if the
     source logical ended with wrap, so does the last new row). }
  NewRows := nil;
  NewRowCount := 0;
  CursorAbsRow := -1;
  CursorAbsCol := 0;

  for I := 0 to LogCount - 1 do
  begin
    Logical := Logicals[I];
    if Length(Logical.Cells) = 0 then
    begin
      Idx := StartNewRow;
      if Logical.EndsWithWrap then
        Include(NewRows[Idx].Flags, tlfWrapped);
      if I = CursorLogIdx then
      begin
        CursorAbsRow := Idx;
        CursorAbsCol := 0;
      end;
      Continue;
    end;

    Pieces := (Length(Logical.Cells) + ANewCols - 1) div ANewCols;
    for P := 0 to Pieces - 1 do
    begin
      Start := P * ANewCols;
      ChunkLen := Length(Logical.Cells) - Start;
      if ChunkLen > ANewCols then ChunkLen := ANewCols;

      Idx := StartNewRow;
      for ChunkLen := 0 to (Length(Logical.Cells) - Start) - 1 do
      begin
        if ChunkLen >= ANewCols then Break;
        NewRows[Idx].Cells[ChunkLen] := Logical.Cells[Start + ChunkLen];
      end;
      if (P < Pieces - 1) or Logical.EndsWithWrap then
        Include(NewRows[Idx].Flags, tlfWrapped);

      if (I = CursorLogIdx) and (CursorLogOffset >= Start)
         and (CursorLogOffset < Start + ANewCols)
         and (CursorAbsRow = -1) then
      begin
        CursorAbsRow := Idx;
        CursorAbsCol := CursorLogOffset - Start;
      end;
    end;
  end;

  SetLength(NewRows, NewRowCount);

  { 3. Split rows into history and the new visible buffer. Keep the most
     recent ANewRows for the visible buffer; older rows go to history. If
     the cursor would land below the new visible buffer, slide more rows
     into history until it fits. }
  KeepInVisible := ANewRows;
  if KeepInVisible > NewRowCount then KeepInVisible := NewRowCount;
  ExcessForHistory := NewRowCount - KeepInVisible;

  if (CursorAbsRow >= 0) and (CursorAbsRow - ExcessForHistory >= KeepInVisible) then
  begin
    ExcessForHistory := CursorAbsRow - (KeepInVisible - 1);
    if ExcessForHistory > NewRowCount - 1 then ExcessForHistory := NewRowCount - 1;
  end;

  if Assigned(FHistory) then
  begin
    FHistory.Clear;
    for I := 0 to ExcessForHistory - 1 do
      FHistory.Push(TTermHistoryLine.Create(NewRows[I]));
  end;

  SetLength(FLines, ANewRows);
  for I := 0 to ANewRows - 1 do
    FLines[I].Init(ANewCols, ReflowBlank);

  for I := 0 to KeepInVisible - 1 do
  begin
    if ExcessForHistory + I < NewRowCount then
      FLines[I] := NewRows[ExcessForHistory + I];
  end;

  FCols := ANewCols;
  FRows := ANewRows;

  { 4. Translate the cursor's absolute new-row into visible coordinates. }
  if CursorAbsRow >= 0 then
  begin
    ACursorRow := CursorAbsRow - ExcessForHistory;
    ACursorCol := CursorAbsCol;
    if ACursorRow < 0 then ACursorRow := 0;
    if ACursorRow >= ANewRows then ACursorRow := ANewRows - 1;
    if ACursorCol < 0 then ACursorCol := 0;
    if ACursorCol >= ANewCols then ACursorCol := ANewCols - 1;
  end
  else
  begin
    if ACursorRow >= ANewRows then ACursorRow := ANewRows - 1;
    if ACursorCol >= ANewCols then ACursorCol := ANewCols - 1;
  end;
end;

procedure TTermScreenBuffer.PopHistoryToTop(ACount: Integer);
var
  I, R: Integer;
  HLine: TTermHistoryLine;
begin
  if (ACount <= 0) or (not Assigned(FHistory)) then Exit;
  if ACount > FHistory.Count then ACount := FHistory.Count;
  if ACount > FRows then ACount := FRows;

  { Shift existing rows down by ACount; bottom ACount rows are dropped. }
  for R := FRows - 1 downto ACount do
    FLines[R] := FLines[R - ACount];

  { Pop most-recent history rows and place them at the top, with the most-
    recent appearing just above where the live view used to start. }
  for I := ACount - 1 downto 0 do
  begin
    HLine := FHistory.PopLast;
    try
      FLines[I] := HLine.Line.MakeResizedCopy(FCols, FBlankCell);
    finally
      HLine.Free;
    end;
  end;
end;

procedure TTermScreenBuffer.ScrollUp(ATopRow, ABottomRow, ACount: Integer);
var
  I, R: Integer;
begin
  if ACount <= 0 then Exit;
  if ATopRow < 0 then ATopRow := 0;
  if ABottomRow >= FRows then ABottomRow := FRows - 1;
  if ATopRow > ABottomRow then Exit;

  while ACount > 0 do
  begin
    if ATopRow = 0 then
      AppendHistory(FLines[ATopRow]);

    for R := ATopRow to ABottomRow - 1 do
      FLines[R] := FLines[R + 1].MakeResizedCopy(FCols, FBlankCell);

    FLines[ABottomRow].Clear(FBlankCell);
    Dec(ACount);
  end;
end;

procedure TTermScreenBuffer.ScrollDown(ATopRow, ABottomRow, ACount: Integer);
var
  R: Integer;
begin
  if ACount <= 0 then Exit;
  if ATopRow < 0 then ATopRow := 0;
  if ABottomRow >= FRows then ABottomRow := FRows - 1;
  if ATopRow > ABottomRow then Exit;

  while ACount > 0 do
  begin
    for R := ABottomRow downto ATopRow + 1 do
      FLines[R] := FLines[R - 1].MakeResizedCopy(FCols, FBlankCell);

    FLines[ATopRow].Clear(FBlankCell);
    Dec(ACount);
  end;
end;

function TTermScreenBuffer.InBounds(ACol, ARow: Integer): Boolean;
begin
  Result := (ARow >= 0) and (ARow < FRows) and
            (ACol >= 0) and (ACol < FCols);
end;

function TTermScreenBuffer.CellAt(ACol, ARow: Integer): PTermCell;
begin
  if InBounds(ACol, ARow) then
    Result := @FLines[ARow].Cells[ACol]
  else
    Result := nil;
end;

function TTermScreenBuffer.GetLine(ARow: Integer): TTermCellLine;
begin
  if (ARow >= 0) and (ARow < FRows) then
    Result := FLines[ARow].Cells
  else
    Result := nil;
end;

function TTermScreenBuffer.GetHistoryLine(AIndex: Integer): TTermCellLine;
begin
  if Assigned(FHistory) and (AIndex >= 0) and (AIndex < FHistory.Count) then
    Result := FHistory[AIndex].Line.Cells
  else
    Result := nil;
end;

constructor TTerminalCore.Create(ACols, ARows: Integer; AScrollbackLimit: Integer);
begin
  inherited Create;

  if ACols < 1 then ACols := 1;
  if ARows < 1 then ARows := 1;

  FCols := ACols;
  FRows := ARows;

  FMainBuffer := TTermScreenBuffer.Create(ACols, ARows, AScrollbackLimit);
  FAltBuffer  := TTermScreenBuffer.Create(ACols, ARows, 0);
  FAltBuffer.Anchor := abTop;
  FUseAltBuffer := False;

  SetLength(FTabStops, FCols);
  Reset;
end;

destructor TTerminalCore.Destroy;
begin
  FAltBuffer.Free;
  FMainBuffer.Free;
  inherited Destroy;
end;

function TTerminalCore.CellAt(ACol, ARow: Integer): PTermCell;
begin
  Result := ActiveBuffer.CellAt(ACol, ARow);
end;

function TTerminalCore.ActiveBuffer: TTermScreenBuffer;
begin
  if FUseAltBuffer then
    Result := FAltBuffer
  else
    Result := FMainBuffer;
end;

function TTerminalCore.MakeBlankCell: TTermCell;
begin
  Result := TermBlankCell(FPen);
end;

procedure TTerminalCore.ClampCursor;
var
  TopRow, BottomRow: Integer;
begin
  if FOriginMode then
  begin
    TopRow := FTopMargin;
    BottomRow := FBottomMargin;
  end
  else
  begin
    TopRow := 0;
    BottomRow := FRows - 1;
  end;

  if FCursor.Col < 0 then FCursor.Col := 0;
  if FCursor.Col >= FCols then FCursor.Col := FCols - 1;
  if FCursor.Row < TopRow then FCursor.Row := TopRow;
  if FCursor.Row > BottomRow then FCursor.Row := BottomRow;
end;

procedure TTerminalCore.MarkAllDirty;
begin
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.InvalidateRect(ALeft, ATop, ARight, ABottom: Integer);
var
  R: TTermRect;
begin
  if ALeft < 0 then ALeft := 0;
  if ATop < 0 then ATop := 0;
  if ARight >= FCols then ARight := FCols - 1;
  if ABottom >= FRows then ABottom := FRows - 1;
  if (ALeft > ARight) or (ATop > ABottom) then
    Exit;

  R.Left := ALeft;
  R.Top := ATop;
  R.Right := ARight;
  R.Bottom := ABottom;
  EmitInvalidate(R);
end;

procedure TTerminalCore.EmitInvalidate(const R: TTermRect);
begin
  if FSyncDepth > 0 then
  begin
    { Accumulate dirty rects into a single bounding rectangle.  Flushed
      on EndSyncUpdate so the view paints the whole frame in one go. }
    if not FSyncDirtyValid then
    begin
      FSyncDirty := R;
      FSyncDirtyValid := True;
    end
    else
    begin
      if R.Left   < FSyncDirty.Left   then FSyncDirty.Left   := R.Left;
      if R.Top    < FSyncDirty.Top    then FSyncDirty.Top    := R.Top;
      if R.Right  > FSyncDirty.Right  then FSyncDirty.Right  := R.Right;
      if R.Bottom > FSyncDirty.Bottom then FSyncDirty.Bottom := R.Bottom;
    end;
    Exit;
  end;

  if Assigned(FOnInvalidate) then
    FOnInvalidate(Self, R);
end;

procedure TTerminalCore.BeginSyncUpdate;
begin
  if FSyncDepth = 0 then
    FSyncStartTick := GetTickCount64;
  Inc(FSyncDepth);
  DbgRecord(Format('BSU depth=%d', [FSyncDepth]));
end;

procedure TTerminalCore.EndSyncUpdate;
var
  R: TTermRect;
begin
  if FSyncDepth = 0 then begin DbgRecord('ESU at depth=0 (ignored)'); Exit; end;
  Dec(FSyncDepth);
  DbgRecord(Format('ESU depth=%d', [FSyncDepth]));
  if FSyncDepth > 0 then Exit;
  if FSyncDirtyValid and Assigned(FOnInvalidate) then
  begin
    R := FSyncDirty;
    FSyncDirtyValid := False;
    FOnInvalidate(Self, R);
  end
  else
    FSyncDirtyValid := False;
end;

procedure TTerminalCore.CheckSyncTimeout;
const
  SyncTimeoutMs = 150;
begin
  if FSyncDepth = 0 then Exit;
  if GetTickCount64 - FSyncStartTick < SyncTimeoutMs then Exit;
  { Force-end an apparently stuck synchronized update.  The unbalanced 2026l
    that a well-behaved app would send is treated as having arrived here. }
  FSyncDepth := 0;
  if FSyncDirtyValid and Assigned(FOnInvalidate) then
    FOnInvalidate(Self, FSyncDirty);
  FSyncDirtyValid := False;
end;

procedure TTerminalCore.SetBracketedPasteMode(AValue: Boolean);
begin
  FBracketedPasteMode := AValue;
end;

procedure TTerminalCore.DbgRecord(const ALine: string);
var
  F: TextFile;
  Path: string;
begin
  { In-memory ring is always kept (DbgDump reads it). On-disk trace is only
    enabled when the TERM_TRACE env var is set to a writable path. }
  FDbgRing[FDbgRingHead] := ALine;
  FDbgRingHead := (FDbgRingHead + 1) and 255;
  Inc(FDbgCounter);
  Path := SysUtils.GetEnvironmentVariable('TERM_TRACE');
  if Path = '' then Exit;
  try
    AssignFile(F, Path);
    if FileExists(Path) then Append(F) else Rewrite(F);
    WriteLn(F, '[', FDbgCounter, '] ', ALine);
    CloseFile(F);
  except
    { Swallow: trace file is best-effort, don't spam stderr. }
  end;
end;

procedure TTerminalCore.DbgDump;
var
  I, Idx: Integer;
begin
  WriteLn('=== DBG RING (oldest -> newest) ===');
  for I := 0 to 255 do
  begin
    Idx := (FDbgRingHead + I) and 255;
    if FDbgRing[Idx] <> '' then
      WriteLn(FDbgRing[Idx]);
  end;
  WriteLn('=== END DBG RING ===');
end;

procedure TTerminalCore.SetTabStopDefaults;
var
  I: Integer;
begin
  SetLength(FTabStops, FCols);
  for I := 0 to FCols - 1 do
    FTabStops[I] := (I mod 8) = 0;
  if FCols > 0 then
    FTabStops[0] := True;
end;

procedure TTerminalCore.InternalLineFeed(WithCarriageReturn: Boolean);
var OldRow: Integer;
begin
  OldRow := FCursor.Row;
  if WithCarriageReturn then
    FCursor.Col := 0;

  FCursor.PendingWrap := False;

  if FCursor.Row = FBottomMargin then
  begin
    ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1);
    DbgRecord(Format('LF SCROLL r=%d (top=%d bot=%d alt=%d)',
      [OldRow, FTopMargin, FBottomMargin, Integer(Byte(FUseAltBuffer))]));
  end
  else if FCursor.Row < FRows - 1 then
  begin
    Inc(FCursor.Row);
    DbgRecord(Format('LF ADV %d -> %d', [OldRow, FCursor.Row]));
  end;

  InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.PutCellAtCursor(const ACell: TTermCell; AdvanceCursor: Boolean);
var
  Cell: PTermCell;
  R: Integer;
begin
  if not ActiveBuffer.InBounds(FCursor.Col, FCursor.Row) then
    Exit;

  if FInsertMode then
  begin
    for R := FCols - 1 downto FCursor.Col + 1 do
      ActiveBuffer.CellAt(R, FCursor.Row)^ := ActiveBuffer.CellAt(R - 1, FCursor.Row)^;
    ActiveBuffer.CellAt(FCursor.Col, FCursor.Row)^ := MakeBlankCell;
  end;

  Cell := ActiveBuffer.CellAt(FCursor.Col, FCursor.Row);
  if Cell <> nil then
    Cell^ := ACell;

  if FUseAltBuffer and (FCursor.Row >= 35) then
    DbgRecord(Format('PUT-SUSPECT alt=%d r=%d c=%d cp=%d cluster="%s"',
      [Integer(Byte(FUseAltBuffer)), FCursor.Row, FCursor.Col, ACell.CodePoint, ACell.Cluster]));

  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);

  if not AdvanceCursor then
    Exit;

  if FCursor.Col = FCols - 1 then
  begin
    if FAutoWrap and not FUseAltBuffer then
      FCursor.PendingWrap := True;
    { don't advance — wrap fires on the next printable character }
  end
  else
    Inc(FCursor.Col);

  { WriteLn(Format('PutCell: CP=%d Cluster="%s" FG=%d', [
    ACell.CodePoint,
    ACell.Cluster,
    PInteger(@ACell.FG.Index)^
  ]));}
end;

procedure TTerminalCore.ClearCell(var ACell: TTermCell);
begin
  ACell := MakeBlankCell;
end;

procedure TTerminalCore.CopyCell(const ASource: TTermCell; var ADest: TTermCell);
begin
  ADest := ASource;
end;

procedure TTerminalCore.InitializeCell(var ACell: TTermCell; ACodePoint: Cardinal;
  const ACluster: RawByteString; const AAttrs: TTermAttrFlags;
  const AFG, ABG: TTermColor);
begin
  ACell.CodePoint := ACodePoint;
  ACell.Cluster := ACluster;
  ACell.Combining := nil;
  ACell.Attrs := AAttrs;
  ACell.FG := AFG;
  ACell.BG := ABG;
end;

function TTerminalCore.PreviousBaseCell(out ACol, ARow: Integer; out ACell: PTermCell): Boolean;
begin
  Result := False;
  ACell := nil;

  ACol := FCursor.Col;
  ARow := FCursor.Row;

  if (ACol > 0) then
    Dec(ACol)
  else if (ARow > 0) then
  begin
    Dec(ARow);
    ACol := FCols - 1;
  end
  else
    Exit;

  ACell := ActiveBuffer.CellAt(ACol, ARow);
  Result := ACell <> nil;
end;

procedure TTerminalCore.Reset;
begin
  FUseAltBuffer := False;

  FDefaultPen.Attrs := [];
  FDefaultPen.FG := TermDefaultColorFG;
  FDefaultPen.BG := TermDefaultColorBG;
  FPen := FDefaultPen;

  FCursor.Col := 0;
  FCursor.Row := 0;
  FCursor.Visible := True;
  FCursor.PendingWrap := False;
  FSavedCursors[False] := FCursor;
  FSavedCursors[True]  := FCursor;

  FTopMargin := 0;
  FBottomMargin := FRows - 1;

  FAutoWrap := True;
  FOriginMode := False;
  FInsertMode := False;
  FBracketedPasteMode := False;
  FMouseProtocol := tmpNone;
  FMouseEncoding := tmeDefault;

  SetTabStopDefaults;

  FMainBuffer.BlankCell := TermBlankCell(FDefaultPen);
  FAltBuffer.BlankCell := TermBlankCell(FDefaultPen);

  FMainBuffer.Clear;
  FAltBuffer.Clear;

  MarkAllDirty;
end;

procedure TTerminalCore.Resize(ACols, ARows: Integer);
var
  OldRows, OldCols: Integer;
  OldAnchor: TTermBufferAnchor;
  TopRowsToDrop, RowsFromHistory, I: Integer;
  CR, CC: Integer;
begin
  if ACols < 1 then ACols := 1;
  if ARows < 1 then ARows := 1;

  OldRows := FRows;
  OldCols := FCols;

  { Column change: re-flow logical lines (history + visible) to the new
    width so wrapped fragments are merged or split as needed. After reflow,
    columns are at the new value and we proceed with row adjustments using
    the new column count. }
  if ACols <> OldCols then
  begin
    CR := FCursor.Row;
    CC := FCursor.Col;
    FMainBuffer.ReflowToWidth(ACols, FRows, CR, CC);
    FCursor.Row := CR;
    FCursor.Col := CC;
  end;

  FCols := ACols;
  FRows := ARows;

  { Main-buffer resize policy.

    SHRINK: keep the cursor row stable. Drop bottom rows when there is room;
    if the cursor would fall off-screen, push the top rows (cursor would have
    overshot by) into scrollback history first.

    GROW: pull rows back from scrollback history if available, prepending
    them to the top of the buffer and shifting existing content down. Cursor
    moves with the shifted content. If history can't fill the new space, the
    remaining rows are added as blank at the bottom. }
  TopRowsToDrop := 0;
  RowsFromHistory := 0;

  if (ARows < OldRows) and (FCursor.Row >= ARows) then
    TopRowsToDrop := FCursor.Row - (ARows - 1)
  else if (ARows > OldRows) and (FMainBuffer.HistoryCount > 0) then
    RowsFromHistory := Min(ARows - OldRows, FMainBuffer.HistoryCount);

  if TopRowsToDrop > 0 then
  begin
    for I := 0 to TopRowsToDrop - 1 do
      FMainBuffer.AppendHistory(FMainBuffer.Lines[I]);
    DbgRecord(Format('Resize: pushed %d top rows to history (newhist=%d)',
      [TopRowsToDrop, FMainBuffer.HistoryCount]));
  end;

  OldAnchor := FMainBuffer.Anchor;
  if TopRowsToDrop > 0 then
    FMainBuffer.Anchor := abBottom
  else
    FMainBuffer.Anchor := abTop;
  FMainBuffer.Resize(ACols, ARows, True);
  FMainBuffer.Anchor := OldAnchor;

  if RowsFromHistory > 0 then
  begin
    FMainBuffer.PopHistoryToTop(RowsFromHistory);
    DbgRecord(Format('Resize: popped %d rows from history to top (newhist=%d)',
      [RowsFromHistory, FMainBuffer.HistoryCount]));
  end;

  FAltBuffer.Resize(ACols, ARows, True);

  SetTabStopDefaults;
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  FCursor.PendingWrap := False;

  if not FUseAltBuffer then
  begin
    if TopRowsToDrop > 0 then
      Dec(FCursor.Row, TopRowsToDrop)
    else if RowsFromHistory > 0 then
      Inc(FCursor.Row, RowsFromHistory);
  end;

  ClampCursor;
  MarkAllDirty;
end;

procedure TTerminalCore.SwitchToMainBuffer;
begin
  if not FUseAltBuffer then
    Exit;
  FUseAltBuffer := False;
  MarkAllDirty;
end;

procedure TTerminalCore.SwitchToAltBuffer(AClear: Boolean);
begin
  FUseAltBuffer := True;
  if AClear then
    FAltBuffer.Clear;
  MarkAllDirty;
end;

procedure TTerminalCore.ClearAltBuffer;
begin
  FAltBuffer.Clear;
  if FUseAltBuffer then
    MarkAllDirty;
end;

procedure TTerminalCore.SetCursorPos(ACol, ARow: Integer);
begin
  if ACol < 0 then ACol := 0;
  if ARow < 0 then ARow := 0;

  FCursor.Col := ACol;
  if FOriginMode then
    FCursor.Row := FTopMargin + ARow
  else
    FCursor.Row := ARow;

  FCursor.PendingWrap := False;
  ClampCursor;
  DbgRecord(Format('CUP req(c=%d,r=%d) -> (c=%d,r=%d)',
    [ACol, ARow, FCursor.Col, FCursor.Row]));
end;

procedure TTerminalCore.MoveCursor(ADeltaCol, ADeltaRow: Integer);
begin
  Inc(FCursor.Col, ADeltaCol);
  Inc(FCursor.Row, ADeltaRow);
  FCursor.PendingWrap := False;
  ClampCursor;
end;

procedure TTerminalCore.SaveCursor;
begin
  FSavedCursors[FUseAltBuffer] := FCursor;
  DbgRecord(Format('SC saved (c=%d,r=%d) alt=%d',
    [FCursor.Col, FCursor.Row, Integer(Byte(FUseAltBuffer))]));
end;

procedure TTerminalCore.RestoreCursor;
begin
  FCursor := FSavedCursors[FUseAltBuffer];
  FCursor.PendingWrap := False;
  ClampCursor;
  DbgRecord(Format('RC restored to (c=%d,r=%d) alt=%d',
    [FCursor.Col, FCursor.Row, Integer(Byte(FUseAltBuffer))]));
end;

procedure TTerminalCore.CursorHome;
begin
  if FOriginMode then
    SetCursorPos(0, 0)
  else
  begin
    FCursor.Col := 0;
    FCursor.Row := 0;
    FCursor.PendingWrap := False;
    ClampCursor;
  end;
  DbgRecord('HOME');
end;

procedure TTerminalCore.CursorUp(ACount: Integer);
var Old: Integer;
begin
  if ACount < 1 then ACount := 1;
  Old := FCursor.Row;
  Dec(FCursor.Row, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
  DbgRecord(Format('CUU n=%d %d->%d', [ACount, Old, FCursor.Row]));
end;

procedure TTerminalCore.CursorDown(ACount: Integer);
var Old: Integer;
begin
  if ACount < 1 then ACount := 1;
  Old := FCursor.Row;
  Inc(FCursor.Row, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
  DbgRecord(Format('CUD n=%d  r=%d -> r=%d', [ACount, Old, FCursor.Row]));
end;

procedure TTerminalCore.CursorForward(ACount: Integer);
var Old: Integer;
begin
  if ACount < 1 then ACount := 1;
  Old := FCursor.Col;
  Inc(FCursor.Col, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
  DbgRecord(Format('CUF n=%d %d->%d r=%d', [ACount, Old, FCursor.Col, FCursor.Row]));
end;

procedure TTerminalCore.CursorBackward(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  Dec(FCursor.Col, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
end;

procedure TTerminalCore.NextLine(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  FCursor.Col := 0;
  Inc(FCursor.Row, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
end;

procedure TTerminalCore.PrevLine(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  FCursor.Col := 0;
  Dec(FCursor.Row, ACount);
  FCursor.PendingWrap := False;
  ClampCursor;
end;

procedure TTerminalCore.SetScrollRegion(ATopRow, ABottomRow: Integer);
begin
  if ATopRow < 0 then ATopRow := 0;
  if ABottomRow >= FRows then ABottomRow := FRows - 1;
  if ATopRow >= ABottomRow then
  begin
    ResetScrollRegion;
    Exit;
  end;

  FTopMargin := ATopRow;
  FBottomMargin := ABottomRow;
  DbgRecord(Format('DECSTBM top=%d bot=%d (rows=%d)', [ATopRow, ABottomRow, FRows]));
  CursorHome;
end;

procedure TTerminalCore.ResetScrollRegion;
begin
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  CursorHome;
end;

procedure TTerminalCore.ScrollUp(ACount: Integer);
var
  Before, After: string;
  C: PTermCell;
begin
  if ACount < 1 then ACount := 1;
  Before := '';
  C := ActiveBuffer.CellAt(2, 8);
  if C <> nil then Before := C^.Cluster;
  DbgRecord(Format('SU n=%d (top=%d bot=%d) row8col2-before="%s"',
    [ACount, FTopMargin, FBottomMargin, Before]));
  ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, ACount);
  After := '';
  C := ActiveBuffer.CellAt(2, 8);
  if C <> nil then After := C^.Cluster;
  DbgRecord(Format('SU AFTER row8col2="%s"', [After]));
  InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.ScrollDown(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  DbgRecord(Format('SD n=%d (top=%d bot=%d)', [ACount, FTopMargin, FBottomMargin]));
  ActiveBuffer.ScrollDown(FTopMargin, FBottomMargin, ACount);
  InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.ClearScreen;
begin
  ActiveBuffer.Clear;
  CursorHome;
  MarkAllDirty;
end;

procedure TTerminalCore.ClearLine;
begin
  ActiveBuffer.ClearRow(FCursor.Row);
  InvalidateRect(0, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.EraseInDisplay(AMode: Integer);
var
  R, C: Integer;
  P: PTermCell;
begin
  case AMode of
    0:
      begin
        EraseInLine(0);
        for R := FCursor.Row + 1 to FRows - 1 do
          ActiveBuffer.ClearRow(R);
        InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FRows - 1);
      end;
    1:
      begin
        for R := 0 to FCursor.Row - 1 do
          ActiveBuffer.ClearRow(R);
        for C := 0 to FCursor.Col do
        begin
          P := ActiveBuffer.CellAt(C, FCursor.Row);
          if P <> nil then ClearCell(P^);
        end;
        InvalidateRect(0, 0, FCursor.Col, FCursor.Row);
      end;
    2:
      begin
        ActiveBuffer.Clear;
        MarkAllDirty;
      end;
    3:
      begin
        if not FUseAltBuffer then
        begin
          FMainBuffer.Clear;
          MarkAllDirty;
        end;
      end;
  end;
end;

procedure TTerminalCore.EraseInLine(AMode: Integer);
var
  C: Integer;
  P: PTermCell;
begin
  case AMode of
    0:
      begin
        for C := FCursor.Col to FCols - 1 do
        begin
          P := ActiveBuffer.CellAt(C, FCursor.Row);
          if P <> nil then ClearCell(P^);
        end;
        { EL 0 erases to end of line — the line no longer overruns its right
          margin, so any prior autowrap-continuation flag must clear. If the
          erase covers the entire line (cursor at col 0), the row above can
          no longer be flagged as wrapping into this row either. }
        Exclude(ActiveBuffer.Lines[FCursor.Row].Flags, tlfWrapped);
        if (FCursor.Col = 0) and (FCursor.Row > 0) then
          Exclude(ActiveBuffer.Lines[FCursor.Row - 1].Flags, tlfWrapped);
      end;
    1:
      for C := 0 to FCursor.Col do
      begin
        P := ActiveBuffer.CellAt(C, FCursor.Row);
        if P <> nil then ClearCell(P^);
      end;
    2:
      begin
        ActiveBuffer.ClearRow(FCursor.Row);
        Exclude(ActiveBuffer.Lines[FCursor.Row].Flags, tlfWrapped);
        if FCursor.Row > 0 then
          Exclude(ActiveBuffer.Lines[FCursor.Row - 1].Flags, tlfWrapped);
      end;
  end;
  InvalidateRect(0, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.EraseChars(ACount: Integer);
var
  I: Integer;
  P: PTermCell;
begin
  if ACount < 1 then ACount := 1;
  for I := 0 to ACount - 1 do
  begin
    if FCursor.Col + I >= FCols then Break;
    P := ActiveBuffer.CellAt(FCursor.Col + I, FCursor.Row);
    if P <> nil then ClearCell(P^);
  end;
  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.InsertChars(ACount: Integer);
var
  C: Integer;
  P: PTermCell;
begin
  if ACount < 1 then ACount := 1;
  if ACount > FCols - FCursor.Col then
    ACount := FCols - FCursor.Col;

  for C := FCols - 1 downto FCursor.Col + ACount do
    ActiveBuffer.CellAt(C, FCursor.Row)^ := ActiveBuffer.CellAt(C - ACount, FCursor.Row)^;

  for C := FCursor.Col to FCursor.Col + ACount - 1 do
  begin
    P := ActiveBuffer.CellAt(C, FCursor.Row);
    if P <> nil then ClearCell(P^);
  end;

  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.DeleteChars(ACount: Integer);
var
  C: Integer;
  P: PTermCell;
begin
  if ACount < 1 then ACount := 1;
  if ACount > FCols - FCursor.Col then
    ACount := FCols - FCursor.Col;

  for C := FCursor.Col to FCols - ACount - 1 do
    ActiveBuffer.CellAt(C, FCursor.Row)^ := ActiveBuffer.CellAt(C + ACount, FCursor.Row)^;

  for C := FCols - ACount to FCols - 1 do
  begin
    P := ActiveBuffer.CellAt(C, FCursor.Row);
    if P <> nil then ClearCell(P^);
  end;

  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.InsertLines(ACount: Integer);
begin
  if (FCursor.Row < FTopMargin) or (FCursor.Row > FBottomMargin) then
    Exit;
  if ACount < 1 then ACount := 1;
  ActiveBuffer.ScrollDown(FCursor.Row, FBottomMargin, ACount);
  InvalidateRect(0, FCursor.Row, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.DeleteLines(ACount: Integer);
begin
  if (FCursor.Row < FTopMargin) or (FCursor.Row > FBottomMargin) then
    Exit;
  if ACount < 1 then ACount := 1;
  ActiveBuffer.ScrollUp(FCursor.Row, FBottomMargin, ACount);
  InvalidateRect(0, FCursor.Row, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.CarriageReturn;
begin
  FCursor.Col := 0;
  FCursor.PendingWrap := False;
  DbgRecord(Format('CR r=%d', [FCursor.Row]));
end;

procedure TTerminalCore.LineFeed;
begin
  InternalLineFeed(False);
end;

procedure TTerminalCore.ReverseIndex;
begin
  FCursor.PendingWrap := False;
  if FCursor.Row = FTopMargin then
    ActiveBuffer.ScrollDown(FTopMargin, FBottomMargin, 1)
  else if FCursor.Row > 0 then
    Dec(FCursor.Row);
  InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.Backspace;
begin
  FCursor.PendingWrap := False;
  if FCursor.Col > 0 then
    Dec(FCursor.Col);
end;

procedure TTerminalCore.HorizontalTab;
var
  C: Integer;
begin
  FCursor.PendingWrap := False;
  for C := FCursor.Col + 1 to FCols - 1 do
    if FTabStops[C] then
    begin
      FCursor.Col := C;
      Exit;
    end;
  FCursor.Col := FCols - 1;
end;

procedure TTerminalCore.BackTab(ACount: Integer);
var
  I, C: Integer;
begin
  FCursor.PendingWrap := False;
  if ACount < 1 then ACount := 1;
  for I := 1 to ACount do
  begin
    for C := FCursor.Col - 1 downto 0 do
      if FTabStops[C] then
      begin
        FCursor.Col := C;
        Break;
      end;
  end;
end;

procedure TTerminalCore.TabSet;
begin
  if (FCursor.Col >= 0) and (FCursor.Col < Length(FTabStops)) then
    FTabStops[FCursor.Col] := True;
end;

procedure TTerminalCore.TabClear(AAll: Boolean);
var
  I: Integer;
begin
  if AAll then
    for I := 0 to High(FTabStops) do
      FTabStops[I] := False
  else if (FCursor.Col >= 0) and (FCursor.Col < Length(FTabStops)) then
    FTabStops[FCursor.Col] := False;
end;

procedure TTerminalCore.PutCodePoint(ACodePoint: Cardinal);
var
  Cell: TTermCell;
  Width: Integer;
  BaseCell, Trail: PTermCell;
  BaseCol, BaseRow: Integer;
  N: Integer;
  EntryRow: Integer;
begin
  EntryRow := FCursor.Row;
  Width := CodePointCellWidth(ACodePoint, False);

  if Width = 0 then
  begin
    { combining/zero-width: attach to the previous base cell, no wrap resolution }
    if PreviousBaseCell(BaseCol, BaseRow, BaseCell) then
    begin
      BaseCell^.Cluster := BaseCell^.Cluster + EncodeUTF8CodePoint(ACodePoint);
      N := Length(BaseCell^.Combining);
      SetLength(BaseCell^.Combining, N + 1);
      BaseCell^.Combining[N] := ACodePoint;
      Include(BaseCell^.Attrs, tafDirty);
      InvalidateRect(BaseCol, BaseRow, BaseCol, BaseRow);
    end;
    Exit;
  end;

  if Width < 0 then
    Exit;

  { Resolve deferred wrap: the previous char filled the last column and set
    PendingWrap.  The actual scroll/row-advance happens here, before we place
    this character, so CR/LF after a full line don't double-advance. }
  if FCursor.PendingWrap then
  begin
    FCursor.PendingWrap := False;
    if ActiveBuffer.InBounds(0, FCursor.Row) then
      Include(ActiveBuffer.FLines[FCursor.Row].Flags, tlfWrapped);
    if FCursor.Row = FBottomMargin then
    begin
      ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1);
      FCursor.Col := 0;
      InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
    end
    else
    begin
      if FCursor.Row < FRows - 1 then
        Inc(FCursor.Row);
      FCursor.Col := 0;
      InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
    end;
    { Clear the destination row of stale content — the wrap continuation owns
      this row from col 0 onward, so any leftover characters from a previous
      redraw at this row would otherwise survive past the wrap fill. }
    ActiveBuffer.ClearRow(FCursor.Row);
  end;

  if Width = 2 then
  begin
    if FCols < 2 then
      Exit;

    { wide char doesn't fit starting at the last column — wrap now }
    if FCursor.Col >= FCols - 1 then
    begin
      if FAutoWrap then
      begin
        if ActiveBuffer.InBounds(0, FCursor.Row) then
          Include(ActiveBuffer.FLines[FCursor.Row].Flags, tlfWrapped);
        if FCursor.Row = FBottomMargin then
          ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1)
        else if FCursor.Row < FRows - 1 then
          Inc(FCursor.Row);
        FCursor.Col := 0;
        InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
      end
      else
        Exit;
    end;
  end;

  Cell := MakeBlankCell;
  Cell.CodePoint := ACodePoint;
  Cell.Cluster := EncodeUTF8CodePoint(ACodePoint);
  //if Length(Cell.Cluster) > 1 then
  //  WriteLn(Format('U+%04X %s', [ACodePoint, EncodeUTF8CodePoint(ACodePoint)]));
  SetLength(Cell.Combining, 0);

  Exclude(Cell.Attrs, tafWideLead);
  Exclude(Cell.Attrs, tafWideTrail);
  Exclude(Cell.Attrs, tafDirty);

  if Width = 2 then
    Include(Cell.Attrs, tafWideLead);

  if Width = 1 then
    PutCellAtCursor(Cell, True)
  else
  begin

  PutCellAtCursor(Cell, False);
  Trail := ActiveBuffer.CellAt(FCursor.Col + 1, FCursor.Row);
  if Trail <> nil then
  begin
    Trail^ := MakeBlankCell;
    Trail^.CodePoint := 0;
    Trail^.Cluster := '';
    SetLength(Trail^.Combining, 0);
    Exclude(Trail^.Attrs, tafWideLead);
    Include(Trail^.Attrs, tafWideTrail);
    Include(Trail^.Attrs, tafDirty);
  end;

  Include(ActiveBuffer.CellAt(FCursor.Col, FCursor.Row)^.Attrs, tafDirty);
  InvalidateRect(FCursor.Col, FCursor.Row, FCursor.Col + 1, FCursor.Row);

  if FCursor.Col <= FCols - 3 then
    Inc(FCursor.Col, 2)
  else
  begin
    { wide char occupied the last two columns; next char must wrap first }
    FCursor.Col := FCols - 1;
    if FAutoWrap and not FUseAltBuffer then
      FCursor.PendingWrap := True;
  end;
  end;

end;

procedure TTerminalCore.WriteUTF8(const AUTF8: RawByteString);
var
  I: Integer;
begin
  for I := 1 to Length(AUTF8) do
    PutCodePoint(Byte(AUTF8[I]));
end;

procedure TTerminalCore.SetAutoWrap(AValue: Boolean);
begin
  FAutoWrap := AValue;
end;

procedure TTerminalCore.SetOriginMode(AValue: Boolean);
begin
  FOriginMode := AValue;
  CursorHome;
end;

procedure TTerminalCore.SetInsertMode(AValue: Boolean);
begin
  FInsertMode := AValue;
end;

procedure TTerminalCore.SetCursorVisible(AValue: Boolean);
begin
  FCursor.Visible := AValue;
  InvalidateRect(FCursor.Col, FCursor.Row, FCursor.Col, FCursor.Row);
end;

procedure TTerminalCore.SetMouseProtocol(AValue: TTermMouseProtocol);
begin
  FMouseProtocol := AValue;
end;

procedure TTerminalCore.SetMouseEncoding(AValue: TTermMouseEncoding);
begin
  FMouseEncoding := AValue;
end;

procedure TTerminalCore.SendMouse(AButton: TTermMouseButton; ACol, ARow: Integer;
  APressed, AMotion, AShift, AAlt, ACtrl: Boolean);
var
  Cb, X, Y: Integer;
  IsWheel: Boolean;
  S: RawByteString;
begin
  if FMouseProtocol = tmpNone then Exit;
  if not Assigned(FOnWrite) then Exit;

  { Filter by protocol. Wheel events report under any active protocol >= VT200. }
  IsWheel := (AButton = tmbWheelUp) or (AButton = tmbWheelDown);
  case FMouseProtocol of
    tmpX10:
      if (not APressed) or AMotion then Exit;
    tmpVT200:
      if AMotion then Exit;
    tmpBtnEvent:
      if AMotion and (not APressed) and (not IsWheel) then Exit; { only motion-with-button }
    tmpAnyEvent: ;
  end;

  Cb := Integer(AButton) and $FF;
  if AShift then Cb := Cb or 4;
  if AAlt   then Cb := Cb or 8;
  if ACtrl  then Cb := Cb or 16;
  if AMotion and not IsWheel then Cb := Cb or 32;

  X := ACol + 1;
  Y := ARow + 1;
  if X < 1 then X := 1;
  if Y < 1 then Y := 1;

  case FMouseEncoding of
    tmeSGR:
      begin
        { In SGR, button is the real button (not 3 for release); 'M' = press/motion, 'm' = release. }
        if AButton = tmbRelease then Cb := 0 or (Cb and not $03);
        S := #27 + '[<' + RawByteString(IntToStr(Cb)) + ';' +
             RawByteString(IntToStr(X)) + ';' +
             RawByteString(IntToStr(Y));
        if APressed or IsWheel or AMotion then
          S := S + 'M'
        else
          S := S + 'm';
        WriteReply(S);
      end;
    tmeDefault:
      begin
        { Legacy: release is button=3; cap col/row at 223 (255-32). }
        if (not APressed) and (not IsWheel) then
          Cb := (Cb and not $03) or 3;
        if X > 223 then X := 223;
        if Y > 223 then Y := 223;
        S := #27 + '[M' +
             AnsiChar(Byte(Cb + 32)) +
             AnsiChar(Byte(X + 32)) +
             AnsiChar(Byte(Y + 32));
        WriteReply(S);
      end;
  end;
end;

procedure TTerminalCore.ResetPen;
begin
  FPen := FDefaultPen;
end;

procedure TTerminalCore.SetBold(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafBold) else Exclude(FPen.Attrs, tafBold);
end;

procedure TTerminalCore.SetFaint(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafFaint) else Exclude(FPen.Attrs, tafFaint);
end;

procedure TTerminalCore.SetItalic(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafItalic) else Exclude(FPen.Attrs, tafItalic);
end;

procedure TTerminalCore.SetUnderline(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafUnderline) else Exclude(FPen.Attrs, tafUnderline);
end;

procedure TTerminalCore.SetBlink(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafBlink) else Exclude(FPen.Attrs, tafBlink);
end;

procedure TTerminalCore.SetInverse(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafInverse) else Exclude(FPen.Attrs, tafInverse);
end;

procedure TTerminalCore.SetHidden(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafHidden) else Exclude(FPen.Attrs, tafHidden);
end;

procedure TTerminalCore.SetStrike(AValue: Boolean);
begin
  if AValue then Include(FPen.Attrs, tafStrike) else Exclude(FPen.Attrs, tafStrike);
end;

procedure TTerminalCore.SetFGDefault;
begin
  FPen.FG := FDefaultPen.FG;
end;

procedure TTerminalCore.SetBGDefault;
begin
  FPen.BG := FDefaultPen.BG;
end;

procedure TTerminalCore.SetFGIndexed(AIndex: Byte);
begin
  FPen.FG := TermIndexedColor(AIndex);
end;

procedure TTerminalCore.SetBGIndexed(AIndex: Byte);
begin
  FPen.BG := TermIndexedColor(AIndex);
end;

procedure TTerminalCore.SetFGRGB(ARed, AGreen, ABlue: Byte);
begin
  FPen.FG := TermRGBColor(ARed, AGreen, ABlue);
end;

procedure TTerminalCore.SetBGRGB(ARed, AGreen, ABlue: Byte);
begin
  FPen.BG := TermRGBColor(ARed, AGreen, ABlue);
end;

procedure TTerminalCore.Bell;
begin
  if Assigned(FOnBell) then
    FOnBell(Self);
end;

procedure TTerminalCore.SetWindowTitle(const ATitle: string);
begin
  if Assigned(FOnTitle) then
    FOnTitle(Self, ATitle);
end;

procedure TTerminalCore.WriteReply(const AData: RawByteString);
begin
  if Assigned(FOnWrite) then
    FOnWrite(Self, AData);
end;

procedure TTerminalCore.FireClipboardSet(const ATargets: string; const AText: RawByteString);
begin
  if Assigned(FOnClipboardSet) then
    FOnClipboardSet(Self, ATargets, AText);
end;

function TTerminalCore.FireClipboardGet(const ATargets: string; out AText: RawByteString): Boolean;
begin
  AText := '';
  Result := Assigned(FOnClipboardGet);
  if Result then
    FOnClipboardGet(Self, ATargets, AText);
end;

function TTerminalCore.GetCell(ACol, ARow: Integer): TTermCell;
var
  P: PTermCell;
begin
  P := ActiveBuffer.CellAt(ACol, ARow);
  if P <> nil then
    Result := P^
  else
    Result := TermBlankCell(FDefaultPen);
end;

function TTerminalCore.GetLine(ARow: Integer): TTermCellLine;
begin
  Result := ActiveBuffer.GetLine(ARow);
end;

function TTerminalCore.GetHistoryLine(AIndex: Integer): TTermCellLine;
begin
  if FUseAltBuffer then
    SetLength(Result, 0)
  else
    Result := FMainBuffer.GetHistoryLine(AIndex);
end;

function TTerminalCore.HistoryCount: Integer;
begin
  if FUseAltBuffer then
    Result := 0
  else
    Result := FMainBuffer.HistoryCount;
end;

function TTerminalCore.IsUsingAltBuffer: Boolean;
begin
  Result := FUseAltBuffer;
end;

function TTerminalCore.GetInSyncUpdate: Boolean;
begin
  Result := FSyncDepth > 0;
end;

function TTerminalCore.IsLineWrapped(AVirtualRow: Integer): Boolean;
var
  Hist: Integer;
  Buf: TTermScreenBuffer;
  ScreenRow: Integer;
begin
  Result := False;
  Hist := HistoryCount;
  if AVirtualRow < 0 then Exit;
  if AVirtualRow < Hist then
  begin
    Buf := ActiveBuffer;
    if (Buf <> nil) and Assigned(Buf.FHistory)
       and (AVirtualRow < Buf.FHistory.Count) then
      Result := tlfWrapped in Buf.FHistory[AVirtualRow].Line.Flags;
    Exit;
  end;
  ScreenRow := AVirtualRow - Hist;
  Buf := ActiveBuffer;
  if (Buf <> nil) and (ScreenRow >= 0) and (ScreenRow < Buf.FRows) then
    Result := tlfWrapped in Buf.FLines[ScreenRow].Flags;
end;

{ --- HTML export helpers ------------------------------------------------ }

procedure HtmlEscapeTo(AStream: TStream; const S: RawByteString);
var
  I, RunStart: Integer;
  Ch: AnsiChar;
  Esc: RawByteString;
begin
  { Stream the bytes in runs: copy unescaped spans verbatim, only break out
    to write the entity when we actually hit a special char. Avoids the per-
    byte O(n²) concat the previous implementation did. }
  RunStart := 1;
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if (Ch = '&') or (Ch = '<') or (Ch = '>') or (Ch = '"') then
    begin
      if I > RunStart then
        AStream.WriteBuffer(S[RunStart], I - RunStart);
      case Ch of
        '&': Esc := '&amp;';
        '<': Esc := '&lt;';
        '>': Esc := '&gt;';
        '"': Esc := '&quot;';
      end;
      AStream.WriteBuffer(Esc[1], Length(Esc));
      RunStart := I + 1;
    end;
  end;
  if Length(S) >= RunStart then
    AStream.WriteBuffer(S[RunStart], Length(S) - RunStart + 1);
end;

procedure WriteStr(AStream: TStream; const S: RawByteString); inline;
begin
  if Length(S) > 0 then
    AStream.WriteBuffer(S[1], Length(S));
end;

function HtmlHexColor(ARGB: Cardinal): RawByteString;
const Hex: array[0..15] of AnsiChar = '0123456789abcdef';
var R, G, B: Byte;
begin
  R := (ARGB shr 16) and $FF;
  G := (ARGB shr 8)  and $FF;
  B :=  ARGB         and $FF;
  SetLength(Result, 7);
  Result[1] := '#';
  Result[2] := Hex[R shr 4]; Result[3] := Hex[R and $F];
  Result[4] := Hex[G shr 4]; Result[5] := Hex[G and $F];
  Result[6] := Hex[B shr 4]; Result[7] := Hex[B and $F];
end;

function HtmlDefaultRGB(IsBackground: Boolean): Cardinal;
begin
  if IsBackground then Result := $000000 else Result := $D0D0D0;
end;

function HtmlColorRGB(const AColor: TTermColor; IsBackground: Boolean): Cardinal;
begin
  case AColor.Mode of
    tcmIndexed, tcmRGB: Result := TermColorToRGB(AColor);
  else
    Result := HtmlDefaultRGB(IsBackground);
  end;
end;

function HtmlSameStyle(const A, B: TTermCell): Boolean;
const
  STYLE_BITS = [tafBold, tafItalic, tafUnderline, tafStrike,
                tafFaint, tafInverse, tafHidden, tafBlink];
begin
  Result := (A.FG.Mode = B.FG.Mode)
        and (A.FG.Index = B.FG.Index)
        and (A.FG.R = B.FG.R) and (A.FG.G = B.FG.G) and (A.FG.B = B.FG.B)
        and (A.BG.Mode = B.BG.Mode)
        and (A.BG.Index = B.BG.Index)
        and (A.BG.R = B.BG.R) and (A.BG.G = B.BG.G) and (A.BG.B = B.BG.B)
        and ((A.Attrs * STYLE_BITS) = (B.Attrs * STYLE_BITS));
end;

function HtmlOpenSpan(const ACell: TTermCell): RawByteString;
var
  FG, BG, T: Cardinal;
  Style, Deco: RawByteString;
begin
  FG := HtmlColorRGB(ACell.FG, False);
  BG := HtmlColorRGB(ACell.BG, True);
  if tafInverse in ACell.Attrs then
  begin
    T := FG; FG := BG; BG := T;
  end;
  if tafHidden in ACell.Attrs then FG := BG;

  Style := 'color:' + HtmlHexColor(FG) + ';background:' + HtmlHexColor(BG);
  if tafFaint in ACell.Attrs then Style := Style + ';opacity:0.5';
  if tafBlink in ACell.Attrs then Style := Style + ';animation:term-blink 1s steps(2) infinite';

  Deco := '';
  if tafUnderline in ACell.Attrs then Deco := 'underline';
  if tafStrike in ACell.Attrs then
  begin
    if Deco <> '' then Deco := Deco + ' line-through'
    else Deco := 'line-through';
  end;
  if Deco <> '' then Style := Style + ';text-decoration:' + Deco;

  Result := '<span style="' + Style + '">';
  if tafBold in ACell.Attrs then Result := Result + '<b>';
  if tafItalic in ACell.Attrs then Result := Result + '<i>';
end;

function HtmlCloseSpan(const ACell: TTermCell): RawByteString;
begin
  Result := '';
  if tafItalic in ACell.Attrs then Result := Result + '</i>';
  if tafBold in ACell.Attrs then Result := Result + '</b>';
  Result := Result + '</span>';
end;

function TTerminalCore.GetHtmlRange(AStartRow, AEndRow, AStartCol, AEndCol: Integer;
                                    const ATitle: string): RawByteString;

  function LineIsBlank(ARowIdx: Integer): Boolean;
  var
    L: TTermCellLine;
    I: Integer;
  begin
    if ARowIdx < HistoryCount then L := GetHistoryLine(ARowIdx)
    else L := GetLine(ARowIdx - HistoryCount);
    for I := 0 to High(L) do
      if not L[I].isBlank then Exit(False);
    Result := True;
  end;

  function LastNonBlankCol(const L: TTermCellLine): Integer;
  var I: Integer;
  begin
    for I := High(L) downto 0 do
      if not L[I].isBlank then Exit(I);
    Result := -1;
  end;

var
  TotalRows, R, C, RowStart, RowEnd: Integer;
  Line: TTermCellLine;
  Cell, RunCell: TTermCell;
  HaveRun: Boolean;
  Text: RawByteString;
  Stream: TStringStream;
begin
  TotalRows := HistoryCount + Rows;
  AStartRow := Max(0, Min(AStartRow, TotalRows - 1));
  AEndRow   := Max(0, Min(AEndRow,   TotalRows - 1));
  if AEndRow < AStartRow then Exit('');

  while (AEndRow > AStartRow) and LineIsBlank(AEndRow) do
    Dec(AEndRow);

  Stream := TStringStream.Create('');
  try
    WriteStr(Stream,
        '<!DOCTYPE html>'#10
      + '<html lang="en">'#10
      + '<head>'#10
      + '<meta charset="utf-8">'#10
      + '<title>');
    if ATitle <> '' then
      HtmlEscapeTo(Stream, RawByteString(ATitle))
    else
      WriteStr(Stream, 'Terminal snapshot');
    WriteStr(Stream,
        '</title>'#10
      + '<style>html,body{margin:0;background:' + HtmlHexColor(HtmlDefaultRGB(True)) + '}</style>'#10
      + '</head>'#10
      + '<body>'#10);

    WriteStr(Stream, '<pre style="font-family:monospace;line-height:1.2;margin:0;'
                   + 'padding:8px;background:' + HtmlHexColor(HtmlDefaultRGB(True))
                   + ';color:' + HtmlHexColor(HtmlDefaultRGB(False)) + '">');

    for R := AStartRow to AEndRow do
    begin
      if R < HistoryCount then Line := GetHistoryLine(R)
      else Line := GetLine(R - HistoryCount);

      if R = AStartRow then RowStart := Max(0, AStartCol) else RowStart := 0;
      if R = AEndRow then
      begin
        if AEndCol < 0 then RowEnd := High(Line)
        else RowEnd := Min(AEndCol, High(Line));
      end
      else
        RowEnd := High(Line);

      if not IsLineWrapped(R) then
        RowEnd := Min(RowEnd, LastNonBlankCol(Line));

      HaveRun := False;
      if Length(Line) > 0 then
        for C := RowStart to RowEnd do
        begin
          Cell := Line[C];
          if tafWideTrail in Cell.Attrs then Continue;

          if (not HaveRun) or (not HtmlSameStyle(RunCell, Cell)) then
          begin
            if HaveRun then WriteStr(Stream, HtmlCloseSpan(RunCell));
            WriteStr(Stream, HtmlOpenSpan(Cell));
            RunCell := Cell;
            HaveRun := True;
          end;

          if Cell.Cluster <> '' then Text := Cell.Cluster
          else Text := ' ';
          HtmlEscapeTo(Stream, Text);
        end;
      if HaveRun then WriteStr(Stream, HtmlCloseSpan(RunCell));
      if (R < AEndRow) and (not IsLineWrapped(R)) then
        WriteStr(Stream, #10);
    end;

    WriteStr(Stream, #10'</pre>'#10'</body>'#10'</html>'#10);
    Result := Stream.DataString;
  finally
    Stream.Free;
  end;
end;

function TTerminalCore.GetHtmlScreen(const ATitle: string): RawByteString;
begin
  Result := GetHtmlRange(HistoryCount, HistoryCount + Rows - 1, -1, -1, ATitle);
end;

function TTerminalCore.GetHtmlAll(const ATitle: string): RawByteString;
begin
  Result := GetHtmlRange(0, HistoryCount + Rows - 1, -1, -1, ATitle);
end;

function TTerminalCore.GetHtmlSelection(const ASelection: TTermSelection;
                                        const ATitle: string): RawByteString;
var
  S, E: TTermCellPos;
begin
  if not ASelection.Active then Exit('');
  TermNormalizeSelection(ASelection.Anchor, ASelection.Focus, S, E);
  Result := GetHtmlRange(S.Row, E.Row, S.Col, E.Col, ATitle);
end;

end.
