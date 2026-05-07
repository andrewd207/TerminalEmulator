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

  { TTermScreenBuffer }

  TTermScreenBuffer = class
  private
    FCols: Integer;
    FRows: Integer;
    FScrollbackLimit: Integer;
    FLines: TTermLines;
    FHistory: TTermHistoryRing;
    FBlankCell: TTermCell;
    function GetHistoryCount: Integer;
    procedure RecreateHistory;
    procedure SetSizeInternal(ACols: Integer; ARows: Integer; Preserve: Boolean);
    procedure InitBlankCell;
    procedure SetBlankCell(const ACell: TTermCell);
    procedure AppendHistory(const ALine: TTermLine);
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
  end;

  TTerminalCore = class
  private
    FBracketedPasteMode: Boolean;
    FMainBuffer: TTermScreenBuffer;
    FAltBuffer: TTermScreenBuffer;
    FUseAltBuffer: Boolean;
    FCursor: TTermCursor;
    FSavedCursor: TTermCursor;
    FPen: TTermPen;
    FDefaultPen: TTermPen;
    FCols: Integer;
    FRows: Integer;
    FTopMargin: Integer;
    FBottomMargin: Integer;
    FAutoWrap: Boolean;
    FOriginMode: Boolean;
    FInsertMode: Boolean;
    FTabStops: array of Boolean;
    FOnInvalidate: TTerminalInvalidateEvent;
    FOnBell: TTerminalBellEvent;
    FOnTitle: TTerminalTitleEvent;
    FOnWrite: TTerminalWriteEvent;
    function ActiveBuffer: TTermScreenBuffer;
    function MakeBlankCell: TTermCell;
    procedure ClampCursor;
    procedure MarkAllDirty;
    procedure InvalidateRect(ALeft, ATop, ARight, ABottom: Integer);
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

    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property Cursor: TTermCursor read FCursor;
    property BracketedPasteMode: Boolean read FBracketedPasteMode write SetBracketedPasteMode;
    property OnInvalidate: TTerminalInvalidateEvent read FOnInvalidate write FOnInvalidate;
    property OnBell: TTerminalBellEvent read FOnBell write FOnBell;
    property OnTitle: TTerminalTitleEvent read FOnTitle write FOnTitle;
    property OnWrite: TTerminalWriteEvent read FOnWrite write FOnWrite;
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
  Result.Mode := tcmRGB;
  Result.Index := 0;
  Result.R := (TERM_DEFAULT_FG shr 16) and $FF;
  Result.G := (TERM_DEFAULT_FG shr 8) and $FF;
  Result.B := TERM_DEFAULT_FG and $FF;
end;

function TermDefaultColorBG: TTermColor;
begin
  Result.Mode := tcmRGB;
  Result.Index := 0;
  Result.R := (TERM_DEFAULT_BG shr 16) and $FF;
  Result.G := (TERM_DEFAULT_BG shr 8) and $FF;
  Result.B := TERM_DEFAULT_BG and $FF;
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

  OldLines := FLines;
  SetLength(NewLines, ARows);

  for I := 0 to ARows - 1 do
    NewLines[I].Init(ACols, FBlankCell);

  if Length(OldLines) < ARows then
    CopyRows := Length(OldLines)
  else
    CopyRows := ARows;

  OldStart := Length(OldLines) - CopyRows;
  NewStart := 0;

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
  if not Assigned(FHistory) then
    RecreateHistory;

  CopyLine := ALine.MakeResizedCopy(FCols, FBlankCell);
  FHistory.Push(TTermHistoryLine.Create(CopyLine));
  WriteLn('Added to history: ', CopyLine.AsPlainText);

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
  if not Assigned(FOnInvalidate) then
    Exit;

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
  FOnInvalidate(Self, R);
end;

procedure TTerminalCore.SetBracketedPasteMode(AValue: Boolean);
begin
  FBracketedPasteMode := AValue;
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
begin
  if WithCarriageReturn then
    FCursor.Col := 0;

  if FCursor.Row = FBottomMargin then
    ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1)
  else if FCursor.Row < FRows - 1 then
    Inc(FCursor.Row);

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

  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);

  if not AdvanceCursor then
    Exit;

  if FCursor.Col = FCols - 1 then
  begin
    if FAutoWrap then
    begin
      if FCursor.Row = FBottomMargin then
        ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1)
      else if FCursor.Row < FRows - 1 then
        Inc(FCursor.Row);
      FCursor.Col := 0;
      if ActiveBuffer.InBounds(0, FCursor.Row) then
        Include(ActiveBuffer.FLines[FCursor.Row].Flags, tlfWrapped);
    end;
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
  FSavedCursor := FCursor;

  FTopMargin := 0;
  FBottomMargin := FRows - 1;

  FAutoWrap := True;
  FOriginMode := False;
  FInsertMode := False;
  FBracketedPasteMode := False;

  SetTabStopDefaults;

  FMainBuffer.BlankCell := TermBlankCell(FDefaultPen);
  FAltBuffer.BlankCell := TermBlankCell(FDefaultPen);

  FMainBuffer.Clear;
  FAltBuffer.Clear;

  MarkAllDirty;
end;

procedure TTerminalCore.Resize(ACols, ARows: Integer);
begin
  if ACols < 1 then ACols := 1;
  if ARows < 1 then ARows := 1;

  FCols := ACols;
  FRows := ARows;

  FMainBuffer.Resize(ACols, ARows, True);
  FAltBuffer.Resize(ACols, ARows, True);

  SetTabStopDefaults;
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  ClampCursor;
  MarkAllDirty;
end;

procedure TTerminalCore.SwitchToMainBuffer;
begin
  if not FUseAltBuffer then
    Exit;
  FUseAltBuffer := False;
  ClampCursor;
  MarkAllDirty;
end;

procedure TTerminalCore.SwitchToAltBuffer(AClear: Boolean);
begin
  FUseAltBuffer := True;
  if AClear then
    FAltBuffer.Clear;
  ClampCursor;
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

  ClampCursor;
end;

procedure TTerminalCore.MoveCursor(ADeltaCol, ADeltaRow: Integer);
begin
  Inc(FCursor.Col, ADeltaCol);
  Inc(FCursor.Row, ADeltaRow);
  ClampCursor;
end;

procedure TTerminalCore.SaveCursor;
begin
  FSavedCursor := FCursor;
end;

procedure TTerminalCore.RestoreCursor;
begin
  FCursor := FSavedCursor;
  ClampCursor;
end;

procedure TTerminalCore.CursorHome;
begin
  if FOriginMode then
    SetCursorPos(0, 0)
  else
  begin
    FCursor.Col := 0;
    FCursor.Row := 0;
    ClampCursor;
  end;
end;

procedure TTerminalCore.CursorUp(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  Dec(FCursor.Row, ACount);
  ClampCursor;
end;

procedure TTerminalCore.CursorDown(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  Inc(FCursor.Row, ACount);
  ClampCursor;
end;

procedure TTerminalCore.CursorForward(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  Inc(FCursor.Col, ACount);
  ClampCursor;
end;

procedure TTerminalCore.CursorBackward(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  Dec(FCursor.Col, ACount);
  ClampCursor;
end;

procedure TTerminalCore.NextLine(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  FCursor.Col := 0;
  Inc(FCursor.Row, ACount);
  ClampCursor;
end;

procedure TTerminalCore.PrevLine(ACount: Integer);
begin
  if ACount < 1 then ACount := 1;
  FCursor.Col := 0;
  Dec(FCursor.Row, ACount);
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
  CursorHome;
end;

procedure TTerminalCore.ResetScrollRegion;
begin
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  CursorHome;
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
      for C := FCursor.Col to FCols - 1 do
      begin
        P := ActiveBuffer.CellAt(C, FCursor.Row);
        if P <> nil then ClearCell(P^);
      end;
    1:
      for C := 0 to FCursor.Col do
      begin
        P := ActiveBuffer.CellAt(C, FCursor.Row);
        if P <> nil then ClearCell(P^);
      end;
    2:
      ActiveBuffer.ClearRow(FCursor.Row);
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
end;

procedure TTerminalCore.LineFeed;
begin
  InternalLineFeed(False);
end;

procedure TTerminalCore.ReverseIndex;
begin
  if FCursor.Row = FTopMargin then
    ActiveBuffer.ScrollDown(FTopMargin, FBottomMargin, 1)
  else if FCursor.Row > 0 then
    Dec(FCursor.Row);
  InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.Backspace;
begin
  if FCursor.Col > 0 then
    Dec(FCursor.Col);
end;

procedure TTerminalCore.HorizontalTab;
var
  C: Integer;
begin
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
begin
  Width := CodePointCellWidth(ACodePoint, False);

  if Width = 0 then
  begin
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

  if Width = 2 then
  begin
    if FCols < 2 then
      Exit;

    if FCursor.Col >= FCols - 1 then
    begin
      if FAutoWrap then
      begin
        FCursor.Col := 0;
        if FCursor.Row = FBottomMargin then
          InternalLineFeed(False)
        else
          Inc(FCursor.Row);
        ClampCursor;
      end
      else
        Exit;
    end;
  end;

  Cell := MakeBlankCell;
  Cell.CodePoint := ACodePoint;
  Cell.Cluster := EncodeUTF8CodePoint(ACodePoint);
  SetLength(Cell.Combining, 0);

  Exclude(Cell.Attrs, tafWideLead);
  Exclude(Cell.Attrs, tafWideTrail);
  Exclude(Cell.Attrs, tafDirty);

  if Width = 2 then
    Include(Cell.Attrs, tafWideLead);

  if Width = 1 then
  begin
    PutCellAtCursor(Cell, True);
    Exit;
  end;

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
  else if FAutoWrap then
  begin
    FCursor.Col := 0;
    if FCursor.Row = FBottomMargin then
      InternalLineFeed(False)
    else
      Inc(FCursor.Row);
    ClampCursor;
  end
  else
    FCursor.Col := FCols - 1;
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


end.
