unit Terminal.Core;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}
{$ModeSwitch typehelpers}

interface

uses
  Classes, SysUtils, Terminal.Unicode;

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
    function isBlank: Boolean;
    property CodePoint: Cardinal read FCodePoint write SetCodePoint;
  end;
  PTermCell = ^TTermCell;

  TTermCellLine = array of TTermCell;

  { TTermCellLineHelper }

  TTermCellLineHelper = type helper for TTermCellLine
    function UsedLength: Integer;
  end;

  TTermLineFlags = set of (
    tlfWrapped   // this row continues from the previous row due to soft wrap
  );



  TTermLine = record
    Cells: TTermCellLine;
    Flags: TTermLineFlags;
  end;

  { TTermLineHelper }

  TTermLineHelper = type helper for TTermLine
    procedure Init(ACols: Integer; var ACellValue: TTermCell);
  end;

  { TTermLines }

  TTermLines = Array of TTermLine;

  { TTermLinesHelper }

  TTermLinesHelper = type helper for TTermLines
    function Length: Integer;
    function MakeCopy(NewColumnCount: Integer; var ABlank: TTermCell): TTermLines;
  end;

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
    FHistory: TTermLines;
    FHistoryStart: Integer;
    FHistoryCount: Integer;
    FBlankCell: TTermCell;
    procedure SetSizeInternal(ACols: Integer; ARows: Integer; Preserve: Boolean);
    procedure InitBlankCell;
    procedure SetBlankCell(const ACell: TTermCell);
    procedure AppendHistory(const ALine: TTermLine);
  public
    constructor Create(ACols, ARows, AScrollbackLimit: Integer);
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
    property HistoryCount: Integer read FHistoryCount;
    property BlankCell: TTermCell read FBlankCell write SetBlankCell;
  end;

  { TTerminalCore }

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

operator = (const A,B: TTermCellPos): Boolean;

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
  Result.FCodePoint := MaxInt;// Ord(' ');
  Result.Cluster := ' ';
  SetLength(Result.Combining, 0);
  Result.Attrs := APen.Attrs + [tafDirty, tafBlank];
  Exclude(Result.Attrs, tafWideLead);
  Exclude(Result.Attrs, tafWideTrail);
  Result.FG := APen.FG;
  Result.BG := APen.BG;
end;

{ TTermCell }

procedure TTermCell.SetCodePoint(AValue: Cardinal);
begin
  if FCodePoint=AValue then Exit;
  FCodePoint:=AValue;
  Exclude(Attrs, tafBlank);
  Include(Attrs, tafDirty);
end;

function TTermCell.isBlank: Boolean;
begin
  Result := tafBlank in Attrs;
end;

{ TTermCellLineHelper }

function TTermCellLineHelper.UsedLength: Integer;
begin
  Result := Length(Self);
  //while (Result > 0) and (tafBlank in Self[Result - 1].Attrs) do  Dec(Result);
  while (Result > 0) and (Self[Result-1].CodePoint = MaxInt) do  Dec(Result);
end;

{ TTermLineHelper }

procedure TTermLineHelper.Init(ACols: Integer; var ACellValue: TTermCell);
var
  i: Integer;
begin
  SetLength(Self.Cells, ACols);
  for i := 0 to High(Self.Cells) do
    Self.Cells[i] := ACellValue;
end;

{ TTermLinesHelper }

function TTermLinesHelper.Length: Integer;
begin
  Result := System.Length(Self);
end;

function TTermLinesHelper.MakeCopy(NewColumnCount: Integer;
  var ABlank: TTermCell): TTermLines;
var
  SrcLine, DstLine: Integer;
  SrcUsed, SrcPos: Integer;
  DstPos: Integer;
  NeedLines: Integer;
  Available: Integer;
  ToCopy, i: Integer;
  ContinueWrap: Boolean;
begin
  SetLength(Result, 0);

  if NewColumnCount <= 0 then
    Exit;

  if Length = 0 then
    Exit;

  { Pass 1: count how many destination lines are needed }
  NeedLines := 0;
  DstPos := 0;
  ContinueWrap := False;

  for SrcLine := 0 to High(Self) do
  begin
    SrcUsed := Self[SrcLine].Cells.UsedLength;

    if (not ContinueWrap) or (not (tlfWrapped in Self[SrcLine].Flags)) then
    begin
      Inc(NeedLines);
      DstPos := 0;
    end;

    SrcPos := 0;
    while SrcPos < SrcUsed do
    begin
      Available := NewColumnCount - DstPos;
      if Available <= 0 then
      begin
        Inc(NeedLines);
        DstPos := 0;
        Available := NewColumnCount;
      end;

      ToCopy := SrcUsed - SrcPos;
      if ToCopy > Available then
        ToCopy := Available;

      Inc(SrcPos, ToCopy);
      Inc(DstPos, ToCopy);

      if SrcPos < SrcUsed then
      begin
        Inc(NeedLines);
        DstPos := 0;
      end
      else if DstPos = NewColumnCount then
        DstPos := 0;
    end;

    ContinueWrap := tlfWrapped in Self[SrcLine].Flags;
  end;

  SetLength(Result, NeedLines);

  { Initialize result lines }
  for DstLine := 0 to High(Result) do
  begin
    SetLength(Result[DstLine].Cells, NewColumnCount);
    Result[DstLine].Flags := [];
  end;

  { Pass 2: actually copy }
  DstLine := -1;
  DstPos := 0;
  ContinueWrap := False;

  for SrcLine := 0 to High(Self) do
  begin
    SrcUsed := Self[SrcLine].Cells.UsedLength;

    if (not ContinueWrap) or (not (tlfWrapped in Self[SrcLine].Flags)) then
    begin
      Inc(DstLine);
      DstPos := 0;
    end;

    SrcPos := 0;
    while SrcPos < SrcUsed do
    begin
      Available := NewColumnCount - DstPos;
      if Available <= 0 then
      begin
        Inc(DstLine);
        DstPos := 0;
        Available := NewColumnCount;
        Include(Result[DstLine].Flags, tlfWrapped);
      end;

      ToCopy := SrcUsed - SrcPos;
      if ToCopy > Available then
        ToCopy := Available;

      for i := 0 to ToCopy-1 do
      Result[DstLine].Cells[DstPos+i] := Self[SrcLine].Cells[SrcPos+i];
      {Move(
        Self[SrcLine].Cells[SrcPos],
        Result[DstLine].Cells[DstPos],
        ToCopy * SizeOf(TTermCell)
      );}

      // add 'blank' cells to fill it
      if Self.Length < NewColumnCount then
        for i := Self.Length to NewColumnCount-1 do
          Result[DstLine].Cells[i] := ABlank;

      Inc(SrcPos, ToCopy);
      Inc(DstPos, ToCopy);

      if SrcPos < SrcUsed then
      begin
        Inc(DstLine);
        DstPos := 0;
        Include(Result[DstLine].Flags, tlfWrapped);
      end;
    end;

    ContinueWrap := tlfWrapped in Self[SrcLine].Flags;
  end;
end;

constructor TTermScreenBuffer.Create(ACols, ARows, AScrollbackLimit: Integer);
begin
  inherited Create;
  FScrollbackLimit := Max(0, AScrollbackLimit);
  InitBlankCell;
  FRows := Max(1, ARows);
  SetSizeInternal(Max(1, ACols), FRows, False);
end;

procedure TTermScreenBuffer.InitBlankCell;
var
  Pen: TTermPen;
begin
  Pen.Attrs := [];
  Pen.FG := TermDefaultColorFG;
  Pen.BG := TermDefaultColorBG;
  FBlankCell := TermBlankCell(Pen);
end;

procedure TTermScreenBuffer.SetBlankCell(const ACell: TTermCell);
begin
  FBlankCell := ACell;
end;

procedure TTermScreenBuffer.SetSizeInternal(ACols: Integer; ARows: Integer;
  Preserve: Boolean);
var
  I, J: Integer;
  isBlank: Boolean;
begin
  if (ACols = FCols) and (ARows = FRows) then
    Exit;

  FCols := Max(1, ACols);
  FRows := Max(1, ARows);
  WriteLn('SetNewSize ', ACols, ':', Arows);
  if Preserve then
  begin
    FLines := FLines.MakeCopy(ACols, FBlankCell);
    if FLines.Length < ARows then
    begin
      J := FLines.Length;
      SetLength(FLines, ARows);
      for I := J to FLines.Length-1 do
        FLines[I].Init(ACols, FBlankCell);
    end;
    if FLines.Length > ARows then
    begin
      isBlank := True;
      for i := 0 to ACols-1 do begin
        isBlank := isBlank or (FLines[High(FLines)].Cells[i].CodePoint = MaxInt);
      end;
      if isBlank then
        SetLength(FLines, FLines.Length-1);
      Write;
    end;
  end
  else
  begin
    SetLength(FLines, ARows);
    for I := 0 to ARows - 1 do
    begin
      SetLength(FLines[I].Cells, ACols);
      FLines[I].Flags := [];
      for J := 0 to ACols - 1 do
        FLines[I].Cells[J] := FBlankCell;
    end;
  end;
end;
{procedure TTermScreenBuffer.SetSizeInternal(ACols, ARows: Integer; Preserve: Boolean);
var
  OldLines: array of TTermCellLine;
  OldRows, R, C, CopyRows, CopyCols: Integer;
begin
  if Preserve then
  begin
    OldRows := Length(FLines);
    SetLength(OldLines, OldRows);
    for R := 0 to OldRows - 1 do
    begin
      SetLength(OldLines[R], Length(FLines[R]));
      for C := 0 to High(FLines[R]) do
        OldLines[R][C] := FLines[R][C];
    end;
  end;

  FCols := Max(1, ACols);
  FRows := Max(1, ARows);
  SetLength(FLines, FRows);
  for R := 0 to FRows - 1 do
  begin
    SetLength(FLines[R], FCols);
    for C := 0 to FCols - 1 do
      FLines[R][C] := FBlankCell;
  end;

  if Preserve and (Length(OldLines) > 0) then
  begin
    CopyRows := Min(Length(OldLines), FRows);
    CopyCols := Min(Length(OldLines[0]), FCols);
    for R := 0 to CopyRows - 1 do
      for C := 0 to CopyCols - 1 do
        FLines[R][C] := OldLines[R][C];
  end;
end;}

procedure TTermScreenBuffer.AppendHistory(const ALine: TTermLine);
var
  Target: Integer;
begin
  if FScrollbackLimit <= 0 then
    Exit;

  if FHistory.Length <> FScrollbackLimit then
    SetLength(FHistory, FScrollbackLimit);

  if FHistoryCount < FScrollbackLimit then
  begin
    Target := (FHistoryStart + FHistoryCount) mod FScrollbackLimit;
    Inc(FHistoryCount);
  end
  else
  begin
    Target := FHistoryStart;
    FHistoryStart := (FHistoryStart + 1) mod FScrollbackLimit;
  end;

  FHistory[Target].Flags := ALine.Flags;
  FHistory[Target].Cells := Copy(ALine.Cells, 0, Length(ALine.Cells));
end;

procedure TTermScreenBuffer.Resize(ACols: Integer; ARows: Integer;
  Preserve: Boolean);
begin
  SetSizeInternal(ACols, ARows, Preserve);
end;

procedure TTermScreenBuffer.Clear;
var
  R, C: Integer;
begin
  for R := 0 to FRows - 1 do
  begin
    FLines[R].Flags:=[];
    for C := 0 to FCols - 1 do
      FLines[R].Cells[C] := FBlankCell;
  end;
end;

procedure TTermScreenBuffer.ClearRow(ARow: Integer);
var
  C: Integer;
begin
  if (ARow < 0) or (ARow >= FRows) then
    Exit;
  FLines[ARow].Flags:=[];
  for C := 0 to FCols - 1 do
    FLines[ARow].Cells[C] := FBlankCell;
end;

procedure TTermScreenBuffer.ScrollUp(ATopRow, ABottomRow, ACount: Integer);
var
  R, C, Count: Integer;
  Saved: TTermLine;
begin
  if (ATopRow < 0) or (ABottomRow >= FRows) or (ATopRow > ABottomRow) then
    Exit;

  Count := EnsureRange(ACount, 0, ABottomRow - ATopRow + 1);
  if Count = 0 then
    Exit;

  if (ATopRow = 0) and (ABottomRow = FRows - 1) then
  begin
    SetLength(Saved.Cells, FCols);
    Saved.Flags:=FLines[0].Flags;
    for C := 0 to FCols - 1 do
      Saved.Cells[C] := FLines[0].Cells[C];
    AppendHistory(Saved);
  end;

  for R := ATopRow to ABottomRow - Count do
  begin
    FLines[R].Flags := FLines[R + Count].Flags;
    for C := 0 to FCols - 1 do
      FLines[R].Cells[C] := FLines[R + Count].Cells[C];
  end;

  for R := ABottomRow - Count + 1 to ABottomRow do
  begin
    FLines[R].Flags:=[];
    for C := 0 to FCols - 1 do
      FLines[R].Cells[C] := FBlankCell;
  end;
end;

procedure TTermScreenBuffer.ScrollDown(ATopRow, ABottomRow, ACount: Integer);
var
  R, C, Count: Integer;
begin
  if (ATopRow < 0) or (ABottomRow >= FRows) or (ATopRow > ABottomRow) then
    Exit;

  Count := EnsureRange(ACount, 0, ABottomRow - ATopRow + 1);
  if Count = 0 then
    Exit;

  for R := ABottomRow downto ATopRow + Count do
  begin
    FLines[R].Flags := FLines[R - Count].Flags;
    for C := 0 to FCols - 1 do
      FLines[R].Cells[C] := FLines[R - Count].Cells[C];
  end;

  for R := ATopRow to ATopRow + Count - 1 do
  begin
    FLines[R].Flags:=[];
    for C := 0 to FCols - 1 do
      FLines[R].Cells[C] := FBlankCell;
  end;
end;

function TTermScreenBuffer.InBounds(ACol, ARow: Integer): Boolean;
begin
  Result := (ARow >= 0) and (ARow < FRows) and (ACol >= 0) and (ACol < FCols);
end;

function TTermScreenBuffer.CellAt(ACol, ARow: Integer): PTermCell;
begin
  if InBounds(ACol, ARow) then
    Result := @FLines[ARow].Cells[ACol]
  else
    Result := nil;
end;

function TTermScreenBuffer.GetLine(ARow: Integer): TTermCellLine;
var
  I: Integer;
begin
  Result := Default(TTermCellLine);
  if (ARow < 0) or (ARow >= FRows) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, FCols);
  for I := 0 to FCols - 1 do
    Result[I] := FLines[ARow].Cells[I];
end;

function TTermScreenBuffer.GetHistoryLine(AIndex: Integer): TTermCellLine;
var
  Source, I: Integer;
begin
  Result := Default(TTermCellLine);
  if (AIndex < 0) or (AIndex >= FHistoryCount) or (FScrollbackLimit <= 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  Source := (FHistoryStart + AIndex) mod FScrollbackLimit;
  SetLength(Result, Length(FHistory[Source].Cells));
  for I := 0 to High(Result) do
    Result[I] := FHistory[Source].Cells[I];
end;

constructor TTerminalCore.Create(ACols, ARows: Integer; AScrollbackLimit: Integer);
begin
  inherited Create;
  FCols := Max(1, ACols);
  FRows := Max(1, ARows);
  FMainBuffer := TTermScreenBuffer.Create(FCols, FRows, AScrollbackLimit);
  FAltBuffer := TTermScreenBuffer.Create(FCols, FRows, 0);
  Reset;
end;

destructor TTerminalCore.Destroy;
begin
  FreeAndNil(FAltBuffer);
  FreeAndNil(FMainBuffer);
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
  MinRow, MaxRow: Integer;
begin
  if FOriginMode then
  begin
    MinRow := FTopMargin;
    MaxRow := FBottomMargin;
  end
  else
  begin
    MinRow := 0;
    MaxRow := FRows - 1;
  end;
  FCursor.Col := EnsureRange(FCursor.Col, 0, FCols - 1);
  FCursor.Row := EnsureRange(FCursor.Row, MinRow, MaxRow);
end;

procedure TTerminalCore.MarkAllDirty;
var
  B: TTermScreenBuffer;
  R, C: Integer;
  P: PTermCell;
begin
  B := ActiveBuffer;
  for R := 0 to B.Rows - 1 do
    for C := 0 to B.Cols - 1 do
    begin
      P := B.CellAt(C, R);
      if P <> nil then
        Include(P^.Attrs, tafDirty);
    end;
end;

procedure TTerminalCore.InvalidateRect(ALeft, ATop, ARight, ABottom: Integer);
var
  R: TTermRect;
begin
  if not Assigned(FOnInvalidate) then
    Exit;
  R.Left := Max(0, ALeft);
  R.Top := Max(0, ATop);
  R.Right := Min(FCols - 1, ARight);
  R.Bottom := Min(FRows - 1, ABottom);
  if (R.Left <= R.Right) and (R.Top <= R.Bottom) then
    FOnInvalidate(Self, R);
end;

procedure TTerminalCore.SetBracketedPasteMode(AValue: Boolean);
begin
  if FBracketedPasteMode = AValue then
    Exit;

  FBracketedPasteMode := AValue;

  if AValue then
    WriteUTF8(#27'[?2004h')
  else
    WriteUTF8(#27'[?2004l');
end;

procedure TTerminalCore.SetTabStopDefaults;
var
  I: Integer;
begin
  SetLength(FTabStops, FCols);
  for I := 0 to FCols - 1 do
    FTabStops[I] := (I > 0) and ((I mod TERM_DEFAULT_TAB_WIDTH) = 0);
end;

procedure TTerminalCore.InternalLineFeed(WithCarriageReturn: Boolean);
begin
  if WithCarriageReturn then
    FCursor.Col := 0;

  if FCursor.Row = FBottomMargin then
  begin
    ActiveBuffer.ScrollUp(FTopMargin, FBottomMargin, 1);
    InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
  end
  else
    Inc(FCursor.Row);

  ClampCursor;
end;

procedure TTerminalCore.PutCellAtCursor(const ACell: TTermCell; AdvanceCursor: Boolean);
var
  B: TTermScreenBuffer;
  Cell: PTermCell;
  C: Integer;
begin
  B := ActiveBuffer;
  if FInsertMode then
  begin
    for C := FCols - 1 downto FCursor.Col + 1 do
      if (B.CellAt(C, FCursor.Row) <> nil) and (B.CellAt(C - 1, FCursor.Row) <> nil) then
        B.CellAt(C, FCursor.Row)^ := B.CellAt(C - 1, FCursor.Row)^;
  end;

  Cell := B.CellAt(FCursor.Col, FCursor.Row);
  if Cell <> nil then
  begin
    Cell^ := ACell;
    Include(Cell^.Attrs, tafDirty);
    InvalidateRect(FCursor.Col, FCursor.Row, FCursor.Col, FCursor.Row);
  end;

  if not AdvanceCursor then
    Exit;

  if FCursor.Col = FCols - 1 then
  begin
    if FAutoWrap then
    begin
      FCursor.Col := 0;
      if FCursor.Row = FBottomMargin then
        InternalLineFeed(False)
      else
        Inc(FCursor.Row);
    end;
  end
  else
    Inc(FCursor.Col);

  ClampCursor;
end;

procedure TTerminalCore.ClearCell(var ACell: TTermCell);
begin
  ACell.Cluster := '';
  SetLength(ACell.Combining, 0);
end;

procedure TTerminalCore.CopyCell(const ASource: TTermCell; var ADest: TTermCell);
begin
  ADest := ASource;
end;

procedure TTerminalCore.InitializeCell(var ACell: TTermCell; ACodePoint: Cardinal; const ACluster: RawByteString;
  const AAttrs: TTermAttrFlags; const AFG, ABG: TTermColor);
begin
  ACell.CodePoint := ACodePoint;
  ACell.Cluster := ACluster;
  SetLength(ACell.Combining, 0);
  ACell.Attrs := AAttrs;
  ACell.FG := AFG;
  ACell.BG := ABG;
end;

function TTerminalCore.PreviousBaseCell(out ACol, ARow: Integer; out ACell: PTermCell): Boolean;
var
  C, R: Integer;
begin
  Result := False;
  ACell := nil;
  R := FCursor.Row;
  C := FCursor.Col - 1;
  while R >= 0 do
  begin
    while C >= 0 do
    begin
      ACell := ActiveBuffer.CellAt(C, R);
      if (ACell <> nil) and not (tafWideTrail in ACell^.Attrs) then
      begin
        ACol := C;
        ARow := R;
        Exit(True);
      end;
      Dec(C);
    end;
    Dec(R);
    if R >= 0 then
      C := FCols - 1;
  end;
end;

procedure TTerminalCore.Reset;
begin
  FDefaultPen.Attrs := [];
  FDefaultPen.FG := TermDefaultColorFG;
  FDefaultPen.BG := TermDefaultColorBG;
  FPen := FDefaultPen;
  FMainBuffer.BlankCell := TermBlankCell(FDefaultPen);
  FAltBuffer.BlankCell := TermBlankCell(FDefaultPen);
  FUseAltBuffer := False;
  FMainBuffer.Clear;
  FAltBuffer.Clear;
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  FAutoWrap := True;
  FOriginMode := False;
  FInsertMode := False;
  FCursor.Col := 0;
  FCursor.Row := 0;
  FCursor.Visible := True;
  FSavedCursor := FCursor;
  SetTabStopDefaults;
  MarkAllDirty;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.Resize(ACols, ARows: Integer);
begin
  FCols := Max(1, ACols);
  FRows := Max(1, ARows);
  FMainBuffer.Resize(FCols, FRows, True);
  FAltBuffer.Resize(FCols, FRows, True);
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
  SetTabStopDefaults;
  ClampCursor;
  MarkAllDirty;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.SwitchToMainBuffer;
begin
  FUseAltBuffer := False;
  ClampCursor;
  MarkAllDirty;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.SwitchToAltBuffer(AClear: Boolean);
begin
  FUseAltBuffer := True;
  if AClear then
  begin
    FAltBuffer.BlankCell := TermBlankCell(FDefaultPen);
    FAltBuffer.Clear;
  end;
  ClampCursor;
  MarkAllDirty;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.SetCursorPos(ACol, ARow: Integer);
begin
  if FOriginMode then
    FCursor.Row := FTopMargin + ARow
  else
    FCursor.Row := ARow;
  FCursor.Col := ACol;
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
  SetCursorPos(0, 0);
end;

procedure TTerminalCore.CursorUp(ACount: Integer);
begin
  MoveCursor(0, -Max(1, ACount));
end;

procedure TTerminalCore.CursorDown(ACount: Integer);
begin
  MoveCursor(0, Max(1, ACount));
end;

procedure TTerminalCore.CursorForward(ACount: Integer);
begin
  MoveCursor(Max(1, ACount), 0);
end;

procedure TTerminalCore.CursorBackward(ACount: Integer);
begin
  MoveCursor(-Max(1, ACount), 0);
end;

procedure TTerminalCore.NextLine(ACount: Integer);
begin
  CursorDown(ACount);
  FCursor.Col := 0;
end;

procedure TTerminalCore.PrevLine(ACount: Integer);
begin
  CursorUp(ACount);
  FCursor.Col := 0;
end;

procedure TTerminalCore.SetScrollRegion(ATopRow, ABottomRow: Integer);
begin
  if (ATopRow < 0) or (ABottomRow >= FRows) or (ATopRow >= ABottomRow) then
    Exit;
  FTopMargin := ATopRow;
  FBottomMargin := ABottomRow;
  CursorHome;
end;

procedure TTerminalCore.ResetScrollRegion;
begin
  FTopMargin := 0;
  FBottomMargin := FRows - 1;
end;

procedure TTerminalCore.ClearScreen;
begin
  ActiveBuffer.BlankCell := MakeBlankCell;
  ActiveBuffer.Clear;
  MarkAllDirty;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.ClearLine;
begin
  ActiveBuffer.BlankCell := MakeBlankCell;
  ActiveBuffer.ClearRow(FCursor.Row);
  InvalidateRect(0, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.EraseInDisplay(AMode: Integer);
var
  B: TTermScreenBuffer;
  Blank: TTermCell;
  R, C: Integer;
  P: PTermCell;
begin
  B := ActiveBuffer;
  Blank := MakeBlankCell;
  B.BlankCell := Blank;
  case AMode of
    0:
      begin
        for C := FCursor.Col to FCols - 1 do
          if B.CellAt(C, FCursor.Row) <> nil then
            B.CellAt(C, FCursor.Row)^ := Blank;
        for R := FCursor.Row + 1 to FRows - 1 do
          B.ClearRow(R);
      end;
    1:
      begin
        for R := 0 to FCursor.Row - 1 do
          B.ClearRow(R);
        for C := 0 to FCursor.Col do
          if B.CellAt(C, FCursor.Row) <> nil then
            B.CellAt(C, FCursor.Row)^ := Blank;
      end;
  else
      B.Clear;
  end;
  for R := 0 to FRows - 1 do
    for C := 0 to FCols - 1 do
    begin
      P := B.CellAt(C, R);
      if P <> nil then
        Include(P^.Attrs, tafDirty);
    end;
  InvalidateRect(0, 0, FCols - 1, FRows - 1);
end;

procedure TTerminalCore.EraseInLine(AMode: Integer);
var
  B: TTermScreenBuffer;
  Blank: TTermCell;
  C: Integer;
begin
  B := ActiveBuffer;
  Blank := MakeBlankCell;
  case AMode of
    0:
      for C := FCursor.Col to FCols - 1 do
        if B.CellAt(C, FCursor.Row) <> nil then
          B.CellAt(C, FCursor.Row)^ := Blank;
    1:
      for C := 0 to FCursor.Col do
        if B.CellAt(C, FCursor.Row) <> nil then
          B.CellAt(C, FCursor.Row)^ := Blank;
  else
      begin
        B.BlankCell := Blank;
        B.ClearRow(FCursor.Row);
      end;
  end;
  InvalidateRect(0, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.EraseChars(ACount: Integer);
var
  B: TTermScreenBuffer;
  N, C: Integer;
  Blank: TTermCell;
begin
  B := ActiveBuffer;
  N := EnsureRange(ACount, 1, FCols);
  Blank := MakeBlankCell;
  for C := FCursor.Col to Min(FCols - 1, FCursor.Col + N - 1) do
    if B.CellAt(C, FCursor.Row) <> nil then
      B.CellAt(C, FCursor.Row)^ := Blank;
  InvalidateRect(FCursor.Col, FCursor.Row, Min(FCols - 1, FCursor.Col + N - 1), FCursor.Row);
end;

procedure TTerminalCore.InsertChars(ACount: Integer);
var
  B: TTermScreenBuffer;
  Count, C: Integer;
  Blank: TTermCell;
begin
  B := ActiveBuffer;
  Count := EnsureRange(ACount, 1, FCols);
  Blank := MakeBlankCell;
  for C := FCols - 1 downto FCursor.Col + Count do
    if (B.CellAt(C, FCursor.Row) <> nil) and (B.CellAt(C - Count, FCursor.Row) <> nil) then
      B.CellAt(C, FCursor.Row)^ := B.CellAt(C - Count, FCursor.Row)^;
  for C := FCursor.Col to Min(FCols - 1, FCursor.Col + Count - 1) do
    if B.CellAt(C, FCursor.Row) <> nil then
      B.CellAt(C, FCursor.Row)^ := Blank;
  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.DeleteChars(ACount: Integer);
var
  B: TTermScreenBuffer;
  Count, C: Integer;
  Blank: TTermCell;
begin
  B := ActiveBuffer;
  Count := EnsureRange(ACount, 1, FCols);
  Blank := MakeBlankCell;
  for C := FCursor.Col to FCols - Count - 1 do
    if (B.CellAt(C, FCursor.Row) <> nil) and (B.CellAt(C + Count, FCursor.Row) <> nil) then
      B.CellAt(C, FCursor.Row)^ := B.CellAt(C + Count, FCursor.Row)^;
  for C := Max(FCursor.Col, FCols - Count) to FCols - 1 do
    if B.CellAt(C, FCursor.Row) <> nil then
      B.CellAt(C, FCursor.Row)^ := Blank;
  InvalidateRect(FCursor.Col, FCursor.Row, FCols - 1, FCursor.Row);
end;

procedure TTerminalCore.InsertLines(ACount: Integer);
begin
  ActiveBuffer.BlankCell := MakeBlankCell;
  ActiveBuffer.ScrollDown(FCursor.Row, FBottomMargin, EnsureRange(ACount, 1, FRows));
  InvalidateRect(0, FCursor.Row, FCols - 1, FBottomMargin);
end;

procedure TTerminalCore.DeleteLines(ACount: Integer);
begin
  ActiveBuffer.BlankCell := MakeBlankCell;
  ActiveBuffer.ScrollUp(FCursor.Row, FBottomMargin, EnsureRange(ACount, 1, FRows));
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
  begin
    ActiveBuffer.BlankCell := MakeBlankCell;
    ActiveBuffer.ScrollDown(FTopMargin, FBottomMargin, 1);
    InvalidateRect(0, FTopMargin, FCols - 1, FBottomMargin);
  end
  else
    Dec(FCursor.Row);
  ClampCursor;
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
  C, N: Integer;
begin
  N := Max(1, ACount);
  while N > 0 do
  begin
    for C := FCursor.Col - 1 downto 0 do
      if FTabStops[C] then
      begin
        FCursor.Col := C;
        Break;
      end;
    Dec(N);
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

  if (Width = 2) and (FCursor.Col >= FCols - 1) then
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

  Cell := MakeBlankCell;
  Cell.CodePoint := ACodePoint;
  Cell.Cluster := EncodeUTF8CodePoint(ACodePoint);
  SetLength(Cell.Combining, 0);
  if Width = 2 then
    Include(Cell.Attrs, tafWideLead);
  PutCellAtCursor(Cell, Width = 1);

  if Width = 2 then
  begin
    Trail := ActiveBuffer.CellAt(FCursor.Col + 1, FCursor.Row);
    if Trail <> nil then
    begin
      Trail^ := MakeBlankCell;
      Trail^.CodePoint := 0;
      Trail^.Cluster := '';
      SetLength(Trail^.Combining, 0);
      Include(Trail^.Attrs, tafWideTrail);
      Include(Trail^.Attrs, tafDirty);
    end;
    InvalidateRect(FCursor.Col, FCursor.Row, Min(FCursor.Col + 1, FCols - 1), FCursor.Row);
    if FCursor.Col < FCols - 2 then
      Inc(FCursor.Col, 2)
    else if FAutoWrap then
    begin
      FCursor.Col := 0;
      if FCursor.Row = FBottomMargin then
        InternalLineFeed(False)
      else
        Inc(FCursor.Row);
    end
    else
      FCursor.Col := FCols - 1;
    ClampCursor;
  end;
end;

procedure TTerminalCore.WriteUTF8(const AUTF8: RawByteString);
var
  Index: Integer;
  CodePoint: Cardinal;
begin
  Index := 1;
  while Index <= Length(AUTF8) do
  begin
    if not terminal.unicode.DecodeUTF8CodePoint(AUTF8, Index, CodePoint) then
    begin
      PutCodePoint($FFFD);
      Inc(Index);
      Continue;
    end;

    case CodePoint of
      8: Backspace;
      9: HorizontalTab;
      10, 11, 12: LineFeed;
      13: CarriageReturn;
    else
      if CodePoint >= 32 then
        PutCodePoint(CodePoint);
    end;
  end;
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
    Result := MakeBlankCell;
end;

function TTerminalCore.GetLine(ARow: Integer): TTermCellLine;
begin
  Result := ActiveBuffer.GetLine(ARow);
end;

function TTerminalCore.GetHistoryLine(AIndex: Integer): TTermCellLine;
begin
  Result := FMainBuffer.GetHistoryLine(AIndex);
end;

function TTerminalCore.HistoryCount: Integer;
begin
  Result := FMainBuffer.HistoryCount;
end;

function TTerminalCore.IsUsingAltBuffer: Boolean;
begin
  Result := FUseAltBuffer;
end;

end.
