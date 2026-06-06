unit Terminal.Parser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, terminal.core, terminal.unicode;

const
  TERM_PARSER_MAX_PARAMS = 16;
  TERM_PARSER_MAX_INTERMEDIATES = 4;

type
  TTermParserState = (
    tpsGround,
    tpsEscape,
    tpsEscapeIntermediate,
    tpsCSIEntry,
    tpsCSIParam,
    tpsCSIIntermediate,
    tpsCSIIgnore,
    tpsOSCString,
    tpsSOSPMAPCString,
    tpsDCSEntry,
    tpsDCSParam,
    tpsDCSIntermediate,
    tpsDCSPassthrough,
    tpsDCSIgnore
  );

  TIntegerArray = array of Integer;

  TTermDCSHandler = procedure(Sender: TObject; const AData: RawByteString; const AFinal: AnsiChar;
    const APrivateMarker: AnsiChar; const AIntermediates: string; const AParams: TIntegerArray) of object;
  TTermUnknownCSIEvent = procedure(Sender: TObject; const APrivateMarker: AnsiChar;
    const AIntermediates: string; const AFinal: AnsiChar; const AParams: TIntegerArray) of object;
  TTermUnknownESCEvent = procedure(Sender: TObject; const AIntermediates: string; const AFinal: AnsiChar) of object;

  TTerminalParser = class
  private
    FCore: TTerminalCore;
    FState: TTermParserState;
    FIntermediates: string;
    FPrivateMarker: AnsiChar;
    FFinalByte: AnsiChar;
    FParams: array[0..TERM_PARSER_MAX_PARAMS - 1] of Integer;
    FParamSpecified: array[0..TERM_PARSER_MAX_PARAMS - 1] of Boolean;
    FParamCount: Integer;
    FCurrentParam: Integer;
    FOSCBuffer: RawByteString;
    FDCSBuffer: RawByteString;
    FEscapePendingInString: Boolean;
    FUTF8Pending: RawByteString;
    FNeededUTF8Bytes: Integer;
    FOnDCS: TTermDCSHandler;
    FOnUnknownCSI: TTermUnknownCSIEvent;
    FOnUnknownESC: TTermUnknownESCEvent;
    procedure EnterGround;
    procedure ClearSequenceState;
    procedure CollectIntermediate(B: Byte);
    procedure ParamStartIfNeeded;
    procedure ParamDigit(B: Byte);
    procedure ParamSeparator;
    function ParamValue(AIndex: Integer; ADefault: Integer): Integer;
    function ParamIsDefault(AIndex: Integer): Boolean;
    function EffectiveParamCount: Integer;
    function ByteToChar(B: Byte): AnsiChar;
    function IsC0(B: Byte): Boolean;
    function IsC1(B: Byte): Boolean;
    function IsPrint(B: Byte): Boolean;
    procedure ExecuteC0(B: Byte);
    procedure ExecuteC1(B: Byte);
    procedure HandlePrintable(B: Byte);
    procedure DispatchESC(AFinal: AnsiChar);
    procedure DispatchCSI(AFinal: AnsiChar);
    procedure DispatchSGR;
    procedure DispatchOSC(const AText: RawByteString);
    procedure HandleOSC52(const APayload: RawByteString);
    procedure DispatchDCS;
    procedure AppendOSCByte(B: Byte);
    procedure AppendDCSByte(B: Byte);
    procedure OSCFinish;
    procedure DCSFinish;
    procedure CSISetMode(AEnable: Boolean);
    procedure ResetSoft;
    procedure EmitCPR;
    procedure EmitPrimaryDA;
    function BuildParamArray: TIntegerArray;
    procedure FlushPendingUTF8(ForceReplacement: Boolean);
  public
    constructor Create(ACore: TTerminalCore);
    procedure Reset;
    procedure FeedByte(B: Byte);
    procedure FeedBytes(const AData: RawByteString);
    procedure FeedBuffer(const ABuffer; ASize: Integer);
    property Core: TTerminalCore read FCore;
    property State: TTermParserState read FState;
    property OnDCS: TTermDCSHandler read FOnDCS write FOnDCS;
    property OnUnknownCSI: TTermUnknownCSIEvent read FOnUnknownCSI write FOnUnknownCSI;
    property OnUnknownESC: TTermUnknownESCEvent read FOnUnknownESC write FOnUnknownESC;
  end;

implementation

uses
  Math, StrUtils, base64;

constructor TTerminalParser.Create(ACore: TTerminalCore);
begin
  inherited Create;
  FCore := ACore;
  Reset;
end;

procedure TTerminalParser.Reset;
begin
  FState := tpsGround;
  ClearSequenceState;
end;

procedure TTerminalParser.EnterGround;
begin
  FlushPendingUTF8(True);
  FState := tpsGround;
  FEscapePendingInString := False;
  FIntermediates := '';
  FPrivateMarker := #0;
  FFinalByte := #0;
  FillChar(FParams, SizeOf(FParams), 0);
  FillChar(FParamSpecified, SizeOf(FParamSpecified), 0);
  FParamCount := 0;
  FCurrentParam := -1;
end;

procedure TTerminalParser.ClearSequenceState;
begin
  FIntermediates := '';
  FPrivateMarker := #0;
  FFinalByte := #0;
  FillChar(FParams, SizeOf(FParams), 0);
  FillChar(FParamSpecified, SizeOf(FParamSpecified), 0);
  FParamCount := 0;
  FCurrentParam := -1;
  FOSCBuffer := '';
  FDCSBuffer := '';
  FEscapePendingInString := False;
end;

procedure TTerminalParser.CollectIntermediate(B: Byte);
begin
  if Length(FIntermediates) < TERM_PARSER_MAX_INTERMEDIATES then
    FIntermediates := FIntermediates + ByteToChar(B);
end;

procedure TTerminalParser.ParamStartIfNeeded;
begin
  if FCurrentParam >= 0 then
    Exit;
  if FParamCount < TERM_PARSER_MAX_PARAMS then
  begin
    FCurrentParam := FParamCount;
    Inc(FParamCount);
  end
  else
    FCurrentParam := TERM_PARSER_MAX_PARAMS - 1;
end;

procedure TTerminalParser.ParamDigit(B: Byte);
begin
  ParamStartIfNeeded;
  if FCurrentParam < TERM_PARSER_MAX_PARAMS then
  begin
    FParamSpecified[FCurrentParam] := True;
    FParams[FCurrentParam] := Min(16383, FParams[FCurrentParam] * 10 + (B - Ord('0')));
  end;
end;

procedure TTerminalParser.ParamSeparator;
begin
  ParamStartIfNeeded;
  FCurrentParam := -1;
end;

function TTerminalParser.ParamValue(AIndex: Integer; ADefault: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex >= FParamCount) or (not FParamSpecified[AIndex]) or (FParams[AIndex] = 0) then
    Result := ADefault
  else
    Result := FParams[AIndex];
end;

function TTerminalParser.ParamIsDefault(AIndex: Integer): Boolean;
begin
  Result := (AIndex < 0) or (AIndex >= FParamCount) or (not FParamSpecified[AIndex]) or (FParams[AIndex] = 0);
end;

function TTerminalParser.EffectiveParamCount: Integer;
begin
  if FParamCount = 0 then
    Result := 0
  else
    Result := FParamCount;
end;

function TTerminalParser.ByteToChar(B: Byte): AnsiChar;
begin
  Result := AnsiChar(Chr(B));
end;

function TTerminalParser.IsC0(B: Byte): Boolean;
begin
  Result := (B <= $1F) or (B = $7F);
end;

function TTerminalParser.IsC1(B: Byte): Boolean;
begin
  Result := (B >= $80) and (B <= $9F);
end;

function TTerminalParser.IsPrint(B: Byte): Boolean;
begin
  Result := (B >= $20) and (B <> $7F);
end;

function TTerminalParser.BuildParamArray: TIntegerArray;
var
  I: Integer;
begin
  Result := Default(TIntegerArray);
  SetLength(Result, FParamCount);
  for I := 0 to FParamCount - 1 do
    if ParamIsDefault(I) then
      Result[I] := 0
    else
      Result[I] := FParams[I];
end;

procedure TTerminalParser.FlushPendingUTF8(ForceReplacement: Boolean);
var
  Index: Integer;
  CodePoint: Cardinal;
begin
  if FUTF8Pending = '' then
    Exit;
  Index := 1;
  while Index <= Length(FUTF8Pending) do
  begin
    if terminal.unicode.DecodeUTF8CodePoint(FUTF8Pending, Index, CodePoint) then
    begin
      FCore.PutCodePoint(CodePoint);
      //if CodePoint>255 then writeln(codepoint);
    end
    else
    begin
      if ForceReplacement then
      begin
        FCore.PutCodePoint($FFFD);
        Inc(Index);
      end
      else
        Break;
    end;
  end;
  if Index > Length(FUTF8Pending) then
  begin
    FUTF8Pending := '';
    FNeededUTF8Bytes := 0;
  end
  else if Index > 1 then
    Delete(FUTF8Pending, 1, Index - 1);
end;

procedure TTerminalParser.ExecuteC0(B: Byte);
begin
  FlushPendingUTF8(True);
  case B of
    $00: ;
    $07: FCore.Bell;
    $08: FCore.Backspace;
    $09: FCore.HorizontalTab;
    $0A, $0B, $0C: FCore.LineFeed;
    $0D: FCore.CarriageReturn;
    $18, $1A: EnterGround;
    $1B:
      begin
        ClearSequenceState;
        FState := tpsEscape;
      end;
  end;
end;

procedure TTerminalParser.ExecuteC1(B: Byte);
begin
  FlushPendingUTF8(True);
  case B of
    $84: FCore.LineFeed;
    $8D: FCore.ReverseIndex;
    $90:
      begin
        ClearSequenceState;
        FState := tpsDCSEntry;
      end;
    $9B:
      begin
        ClearSequenceState;
        FState := tpsCSIEntry;
      end;
    $9D:
      begin
        FOSCBuffer := '';
        FEscapePendingInString := False;
        FState := tpsOSCString;
      end;
    $98, $9E, $9F:
      begin
        FEscapePendingInString := False;
        FState := tpsSOSPMAPCString;
      end;
  else
    EnterGround;
  end;
end;

procedure TTerminalParser.HandlePrintable(B: Byte);
begin
  if (FNeededUTF8Bytes > 0) and ((B and $C0) <> $80) then
  begin
    FlushPendingUTF8(True);
    FNeededUTF8Bytes := 0;
  end;

  if (B and $80) = $00 then
    FNeededUTF8Bytes := 0
  else if (B and $C0) = $80 then
  begin
    if FNeededUTF8Bytes > 0 then
      Dec(FNeededUTF8Bytes);
  end
  else if (B and $E0) = $C0 then
  begin
    if FUTF8Pending <> '' then FlushPendingUTF8(True);
    FNeededUTF8Bytes := 1;
  end
  else if (B and $F0) = $E0 then
  begin
    if FUTF8Pending <> '' then FlushPendingUTF8(True);
    FNeededUTF8Bytes := 2;
  end
  else if (B and $F8) = $F0 then
  begin
    if FUTF8Pending <> '' then FlushPendingUTF8(True);
    FNeededUTF8Bytes := 3;
  end
  else
  begin
    if FUTF8Pending <> '' then FlushPendingUTF8(True);
    FNeededUTF8Bytes := 0;
  end;

  FUTF8Pending := FUTF8Pending + ByteToChar(B);
  FlushPendingUTF8(False);
end;

procedure TTerminalParser.DispatchESC(AFinal: AnsiChar);
begin
  case AFinal of
    '7': FCore.SaveCursor;
    '8': FCore.RestoreCursor;
    'D': FCore.LineFeed;
    'E': begin FCore.LineFeed; FCore.CarriageReturn; end;
    'H': FCore.TabSet;
    'M': FCore.ReverseIndex;
    'c': FCore.Reset;
    '=': ;
    '>': ;
    '(': ;
    ')': ;
    '\': ;
  else
    begin
      FCore.DbgRecord(Format('UNKNOWN ESC inter="%s" final="%s"', [FIntermediates, AFinal]));
      if Assigned(FOnUnknownESC) then
        FOnUnknownESC(Self, FIntermediates, AFinal);
    end;
  end;
end;

procedure TTerminalParser.DispatchSGR;
var
  I, P, Mode: Integer;
begin
  if EffectiveParamCount = 0 then
  begin
    FCore.ResetPen;
    Exit;
  end;

  I := 0;
  while I < FParamCount do
  begin
    if ParamIsDefault(I) then
      P := 0
    else
      P := FParams[I];

    case P of
      0: FCore.ResetPen;
      1: FCore.SetBold(True);
      2: FCore.SetFaint(True);
      3: FCore.SetItalic(True);
      4: FCore.SetUnderline(True);
      5: FCore.SetBlink(True);
      7: FCore.SetInverse(True);
      8: FCore.SetHidden(True);
      9: FCore.SetStrike(True);
      22: begin FCore.SetBold(False); FCore.SetFaint(False); end;
      23: FCore.SetItalic(False);
      24: FCore.SetUnderline(False);
      25: FCore.SetBlink(False);
      27: FCore.SetInverse(False);
      28: FCore.SetHidden(False);
      29: FCore.SetStrike(False);
      30..37: FCore.SetFGIndexed(P - 30);
      39: FCore.SetFGDefault;
      40..47: FCore.SetBGIndexed(P - 40);
      49: FCore.SetBGDefault;
      90..97: FCore.SetFGIndexed(8 + (P - 90));
      100..107: FCore.SetBGIndexed(8 + (P - 100));
      38, 48:
        begin
          if I + 1 < FParamCount then
          begin
            Mode := FParams[I + 1];
            if (Mode = 5) and (I + 2 < FParamCount) then
            begin
              if P = 38 then
                FCore.SetFGIndexed(EnsureRange(FParams[I + 2], 0, 255))
              else
                FCore.SetBGIndexed(EnsureRange(FParams[I + 2], 0, 255));
              Inc(I, 2);
            end
            else if (Mode = 2) and (I + 4 < FParamCount) then
            begin
              if P = 38 then
                FCore.SetFGRGB(
                  EnsureRange(FParams[I + 2], 0, 255),
                  EnsureRange(FParams[I + 3], 0, 255),
                  EnsureRange(FParams[I + 4], 0, 255))
              else
                FCore.SetBGRGB(
                  EnsureRange(FParams[I + 2], 0, 255),
                  EnsureRange(FParams[I + 3], 0, 255),
                  EnsureRange(FParams[I + 4], 0, 255));
              Inc(I, 4);
            end;
          end;
        end;
    end;
    Inc(I);
  end;
end;

procedure TTerminalParser.DispatchOSC(const AText: RawByteString);
var
  SepPos: SizeInt;
  CodeText, Payload: RawByteString;
  Code: Integer;
begin
  SepPos := Pos(';', string(AText));
  if SepPos > 0 then
  begin
    CodeText := Copy(AText, 1, SepPos - 1);
    Payload := Copy(AText, SepPos + 1, Length(AText) - SepPos);
  end
  else
  begin
    CodeText := AText;
    Payload := '';
  end;

  Code := StrToIntDef(string(CodeText), -1);
  case Code of
    0, 2: FCore.SetWindowTitle(string(Payload));
    52:   HandleOSC52(Payload);
  end;
end;

procedure TTerminalParser.HandleOSC52(const APayload: RawByteString);
var
  SemiPos: SizeInt;
  Targets: string;
  Data: RawByteString;
  Decoded, Reply, Encoded: RawByteString;
begin
  { OSC 52 ; Pc ; Pd  -- Pc is selection target(s), Pd is base64 or '?' to query. }
  SemiPos := Pos(';', string(APayload));
  if SemiPos > 0 then
  begin
    Targets := string(Copy(APayload, 1, SemiPos - 1));
    Data := Copy(APayload, SemiPos + 1, Length(APayload) - SemiPos);
  end
  else
  begin
    Targets := string(APayload);
    Data := '';
  end;

  if Data = '?' then
  begin
    { Read request: ask host for current clipboard, base64-encode, reply with same shape. }
    if FCore.FireClipboardGet(Targets, Reply) then
    begin
      Encoded := EncodeStringBase64(Reply);
      FCore.WriteReply(#27']52;' + RawByteString(Targets) + ';' + Encoded + #27'\');
    end;
    Exit;
  end;

  try
    Decoded := DecodeStringBase64(Data);
  except
    Decoded := '';
  end;
  FCore.FireClipboardSet(Targets, Decoded);
end;

procedure TTerminalParser.DispatchDCS;
var
  LocalParams: TIntegerArray;
begin
  if Assigned(FOnDCS) then
  begin
    LocalParams := BuildParamArray;
    FOnDCS(Self, FDCSBuffer, FFinalByte, FPrivateMarker, FIntermediates, LocalParams);
  end;
end;

procedure TTerminalParser.AppendOSCByte(B: Byte);
begin
  FOSCBuffer := FOSCBuffer + ByteToChar(B);
end;

procedure TTerminalParser.AppendDCSByte(B: Byte);
begin
  FDCSBuffer := FDCSBuffer + ByteToChar(B);
end;

procedure TTerminalParser.OSCFinish;
begin
  DispatchOSC(FOSCBuffer);
  EnterGround;
end;

procedure TTerminalParser.DCSFinish;
begin
  DispatchDCS;
  EnterGround;
end;

procedure TTerminalParser.CSISetMode(AEnable: Boolean);
var
  I, P: Integer;
begin
  for I := 0 to Max(0, FParamCount - 1) do
  begin
    if ParamIsDefault(I) then
      Continue;
    P := FParams[I];
    if FPrivateMarker = '?' then
    begin
      case P of
        6: FCore.SetOriginMode(AEnable);
        7: FCore.SetAutoWrap(AEnable);
        9:  { X10 mouse tracking }
          if AEnable then FCore.SetMouseProtocol(tmpX10)
          else FCore.SetMouseProtocol(tmpNone);
        25: FCore.SetCursorVisible(AEnable);
        1000: { VT200 mouse tracking }
          if AEnable then FCore.SetMouseProtocol(tmpVT200)
          else FCore.SetMouseProtocol(tmpNone);
        1002: { Button-event tracking }
          if AEnable then FCore.SetMouseProtocol(tmpBtnEvent)
          else FCore.SetMouseProtocol(tmpNone);
        1003: { Any-event tracking }
          if AEnable then FCore.SetMouseProtocol(tmpAnyEvent)
          else FCore.SetMouseProtocol(tmpNone);
        1006: { SGR encoding }
          if AEnable then FCore.SetMouseEncoding(tmeSGR)
          else FCore.SetMouseEncoding(tmeDefault);
        2004: FCore.BracketedPasteMode := AEnable;
        47:
          if AEnable then
            FCore.SwitchToAltBuffer(False)
          else
            FCore.SwitchToMainBuffer;
        1047:
          begin
            if AEnable then
              FCore.SwitchToAltBuffer(False)
            else
            begin
              FCore.ClearAltBuffer;
              FCore.SwitchToMainBuffer;
            end;
          end;
        1048:
          if AEnable then
            FCore.SaveCursor
          else
            FCore.RestoreCursor;
        1049:
          if AEnable then
          begin
            FCore.SaveCursor; { saves into main buffer's slot }
            FCore.SwitchToAltBuffer(True);
          end
          else
          begin
            FCore.SwitchToMainBuffer;
            FCore.RestoreCursor; { restores from main buffer's slot }
          end;
        2026:
          if AEnable then
            FCore.BeginSyncUpdate
          else
            FCore.EndSyncUpdate;
      end;
    end
    else
    begin
      case P of
        4: FCore.SetInsertMode(AEnable);
      end;
    end;
  end;
end;

procedure TTerminalParser.ResetSoft;
begin
  FCore.SetCursorVisible(True);
  FCore.ResetScrollRegion;
  FCore.ResetPen;
  FCore.SetOriginMode(False);
  FCore.SetAutoWrap(True);
  FCore.SetInsertMode(False);
  FCore.CursorHome;
  FCore.SaveCursor;
end;

procedure TTerminalParser.EmitCPR;
var
  S: RawByteString;
begin
  S := #27'[' + RawByteString(IntToStr(FCore.Cursor.Row + 1)) + ';' +
    RawByteString(IntToStr(FCore.Cursor.Col + 1)) + 'R';
  FCore.WriteReply(S);
end;

procedure TTerminalParser.EmitPrimaryDA;
begin
  FCore.WriteReply(#27'[?6c');
end;

procedure TTerminalParser.DispatchCSI(AFinal: AnsiChar);
var
  N, TopRow, BottomRow, Row, Col: Integer;
  LocalParams: TIntegerArray;
begin
  FCore.DbgRecord(Format('CSI priv="%s" inter="%s" final="%s" pcount=%d p0=%d',
    [FPrivateMarker, FIntermediates, AFinal, FParamCount,
     IfThen(FParamCount > 0, FParams[0], 0)]));
  case AFinal of
    'A': FCore.CursorUp(ParamValue(0, 1));
    'B': FCore.CursorDown(ParamValue(0, 1));
    'C': FCore.CursorForward(ParamValue(0, 1));
    'D': FCore.CursorBackward(ParamValue(0, 1));
    'E': FCore.NextLine(ParamValue(0, 1));
    'F': FCore.PrevLine(ParamValue(0, 1));
    'G': FCore.SetCursorPos(ParamValue(0, 1) - 1, FCore.Cursor.Row);
    'H', 'f':
      begin
        Row := ParamValue(0, 1) - 1;
        Col := ParamValue(1, 1) - 1;
        FCore.SetCursorPos(Col, Row);
      end;
    'I':
      begin
        N := ParamValue(0, 1);
        while N > 0 do
        begin
          FCore.HorizontalTab;
          Dec(N);
        end;
      end;
    'J': FCore.EraseInDisplay(ParamValue(0, 0));
    'K': FCore.EraseInLine(ParamValue(0, 0));
    'L': FCore.InsertLines(ParamValue(0, 1));
    'M': FCore.DeleteLines(ParamValue(0, 1));
    'P': FCore.DeleteChars(ParamValue(0, 1));
    'S': FCore.ScrollUp(ParamValue(0, 1));
    'T': FCore.ScrollDown(ParamValue(0, 1));
    'X': FCore.EraseChars(ParamValue(0, 1));
    'Z': FCore.BackTab(ParamValue(0, 1));
    '@': FCore.InsertChars(ParamValue(0, 1));
    '`': FCore.SetCursorPos(ParamValue(0, 1) - 1, FCore.Cursor.Row);
    'a': FCore.CursorForward(ParamValue(0, 1));
    'c': EmitPrimaryDA;
    'd': FCore.SetCursorPos(FCore.Cursor.Col, ParamValue(0, 1) - 1);
    'g':
      case ParamValue(0, 0) of
        0: FCore.TabClear(False);
        3: FCore.TabClear(True);
      end;
    'h': CSISetMode(True);
    'l': CSISetMode(False);
    'm': DispatchSGR;
    'n':
      case ParamValue(0, 0) of
        6: EmitCPR;
      end;
    'p':
      if (FPrivateMarker = '!') then
        ResetSoft;
    'r':
      begin
        TopRow := ParamValue(0, 1) - 1;
        BottomRow := ParamValue(1, FCore.Rows) - 1;
        FCore.SetScrollRegion(TopRow, BottomRow);
      end;
    's': FCore.SaveCursor;
    'u': FCore.RestoreCursor;
  else
    begin
      FCore.DbgRecord(Format('UNKNOWN CSI priv="%s" inter="%s" final="%s"',
        [FPrivateMarker, FIntermediates, AFinal]));
      if Assigned(FOnUnknownCSI) then
      begin
        LocalParams := BuildParamArray;
        FOnUnknownCSI(Self, FPrivateMarker, FIntermediates, AFinal, LocalParams);
      end;
    end;
  end;
end;

procedure TTerminalParser.FeedByte(B: Byte);
begin
  if (FState = tpsGround) and (FNeededUTF8Bytes > 0) and ((B and $C0) = $80) then
  begin
    HandlePrintable(B);
    Exit;
  end;

  { C1 controls (0x80-0x9F) only execute when we're not inside a string-
    accumulating state. Inside OSC/DCS/SOS/PM/APC, the bytes are payload —
    notably UTF-8 continuation bytes of multibyte glyphs in the OSC title can
    legitimately land in the 0x80-0x9F range (e.g. 0x90 inside U+2810). }
  if (FState <> tpsOSCString) and (FState <> tpsDCSPassthrough)
     and (FState <> tpsDCSEntry) and (FState <> tpsDCSParam)
     and (FState <> tpsDCSIntermediate) and (FState <> tpsDCSIgnore)
     and (FState <> tpsSOSPMAPCString) and IsC1(B) then
  begin
    ExecuteC1(B);
    Exit;
  end;

  case FState of
    tpsGround:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if IsC0(B) then
          ExecuteC0(B)
        else if IsPrint(B) then
          HandlePrintable(B);
      end;

    tpsEscape:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $20) and (B <= $2F) then
        begin
          CollectIntermediate(B);
          FState := tpsEscapeIntermediate;
        end
        else if B = Ord('[') then
        begin
          ClearSequenceState;
          FState := tpsCSIEntry;
        end
        else if B = Ord(']') then
        begin
          FOSCBuffer := '';
          FEscapePendingInString := False;
          FState := tpsOSCString;
        end
        else if B = Ord('P') then
        begin
          ClearSequenceState;
          FState := tpsDCSEntry;
        end
        else if (B = Ord('X')) or (B = Ord('^')) or (B = Ord('_')) then
        begin
          FEscapePendingInString := False;
          FState := tpsSOSPMAPCString;
        end
        else if (B >= $30) and (B <= $7E) then
        begin
          DispatchESC(ByteToChar(B));
          EnterGround;
        end
        else if IsC0(B) then
          ExecuteC0(B)
        else
          EnterGround;
      end;

    tpsEscapeIntermediate:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $20) and (B <= $2F) then
          CollectIntermediate(B)
        else if (B >= $30) and (B <= $7E) then
        begin
          DispatchESC(ByteToChar(B));
          EnterGround;
        end
        else if IsC0(B) then
          ExecuteC0(B)
        else
          EnterGround;
      end;

    tpsCSIEntry:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $3C) and (B <= $3F) then
        begin
          FPrivateMarker := ByteToChar(B);
          FState := tpsCSIParam;
        end
        else if (B >= $30) and (B <= $39) then
        begin
          ParamDigit(B);
          FState := tpsCSIParam;
        end
        else if B = Ord(';') then
        begin
          ParamSeparator;
          FState := tpsCSIParam;
        end
        else if B = Ord(':') then
          FState := tpsCSIIgnore
        else if (B >= $20) and (B <= $2F) then
        begin
          CollectIntermediate(B);
          FState := tpsCSIIntermediate;
        end
        else if (B >= $40) and (B <= $7E) then
        begin
          DispatchCSI(ByteToChar(B));
          EnterGround;
        end
        else if IsC0(B) then
          ExecuteC0(B)
        else
          EnterGround;
      end;

    tpsCSIParam:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $30) and (B <= $39) then
          ParamDigit(B)
        else if B = Ord(';') then
          ParamSeparator
        else if B = Ord(':') then
          FState := tpsCSIIgnore
        else if (B >= $20) and (B <= $2F) then
        begin
          CollectIntermediate(B);
          FState := tpsCSIIntermediate;
        end
        else if (B >= $3C) and (B <= $3F) then
          FState := tpsCSIIgnore
        else if (B >= $40) and (B <= $7E) then
        begin
          DispatchCSI(ByteToChar(B));
          EnterGround;
        end
        else if IsC0(B) then
          ExecuteC0(B)
        else
          EnterGround;
      end;

    tpsCSIIntermediate:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $20) and (B <= $2F) then
          CollectIntermediate(B)
        else if (B >= $30) and (B <= $3F) then
          FState := tpsCSIIgnore
        else if (B >= $40) and (B <= $7E) then
        begin
          DispatchCSI(ByteToChar(B));
          EnterGround;
        end
        else if IsC0(B) then
          ExecuteC0(B)
        else
          EnterGround;
      end;

    tpsCSIIgnore:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $40) and (B <= $7E) then
          EnterGround
        else if IsC0(B) then
          ExecuteC0(B);
      end;

    tpsOSCString:
      begin
        if FEscapePendingInString then
        begin
          FEscapePendingInString := False;
          if B = Ord('\') then
            OSCFinish
          else
          begin
            ExecuteC0($1B);
            FeedByte(B);
          end;
        end
        else if B = $07 then
          OSCFinish
        else if B = $1B then
          FEscapePendingInString := True
        else if (B = $18) or (B = $1A) then
          EnterGround
        else if not IsC0(B) then
          AppendOSCByte(B);
      end;

    tpsSOSPMAPCString:
      begin
        if FEscapePendingInString then
        begin
          FEscapePendingInString := False;
          if B = Ord('\') then
            EnterGround
          else
          begin
            ExecuteC0($1B);
            FeedByte(B);
          end;
        end
        else if B = $1B then
          FEscapePendingInString := True
        else if (B = $18) or (B = $1A) then
          EnterGround;
      end;

    tpsDCSEntry:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $3C) and (B <= $3F) then
        begin
          FPrivateMarker := ByteToChar(B);
          FState := tpsDCSParam;
        end
        else if (B >= $30) and (B <= $39) then
        begin
          ParamDigit(B);
          FState := tpsDCSParam;
        end
        else if B = Ord(';') then
        begin
          ParamSeparator;
          FState := tpsDCSParam;
        end
        else if B = Ord(':') then
          FState := tpsDCSIgnore
        else if (B >= $20) and (B <= $2F) then
        begin
          CollectIntermediate(B);
          FState := tpsDCSIntermediate;
        end
        else if (B >= $40) and (B <= $7E) then
        begin
          FFinalByte := ByteToChar(B);
          FDCSBuffer := '';
          FEscapePendingInString := False;
          FState := tpsDCSPassthrough;
        end
        else if (B <> $18) and (B <> $1A) and (not IsC0(B)) then
          EnterGround;
      end;

    tpsDCSParam:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $30) and (B <= $39) then
          ParamDigit(B)
        else if B = Ord(';') then
          ParamSeparator
        else if B = Ord(':') then
          FState := tpsDCSIgnore
        else if (B >= $20) and (B <= $2F) then
        begin
          CollectIntermediate(B);
          FState := tpsDCSIntermediate;
        end
        else if (B >= $3C) and (B <= $3F) then
          FState := tpsDCSIgnore
        else if (B >= $40) and (B <= $7E) then
        begin
          FFinalByte := ByteToChar(B);
          FDCSBuffer := '';
          FEscapePendingInString := False;
          FState := tpsDCSPassthrough;
        end;
      end;

    tpsDCSIntermediate:
      begin
        if B = $1B then
          ExecuteC0(B)
        else if (B >= $20) and (B <= $2F) then
          CollectIntermediate(B)
        else if (B >= $30) and (B <= $3F) then
          FState := tpsDCSIgnore
        else if (B >= $40) and (B <= $7E) then
        begin
          FFinalByte := ByteToChar(B);
          FDCSBuffer := '';
          FEscapePendingInString := False;
          FState := tpsDCSPassthrough;
        end;
      end;

    tpsDCSPassthrough:
      begin
        if FEscapePendingInString then
        begin
          FEscapePendingInString := False;
          if B = Ord('\') then
            DCSFinish
          else
          begin
            AppendDCSByte($1B);
            FeedByte(B);
          end;
        end
        else if B = $1B then
          FEscapePendingInString := True
        else if (B = $18) or (B = $1A) then
          DCSFinish
        else
          AppendDCSByte(B);
      end;

    tpsDCSIgnore:
      begin
        if FEscapePendingInString then
        begin
          FEscapePendingInString := False;
          if B = Ord('\') then
            EnterGround
          else
          begin
            ExecuteC0($1B);
            FeedByte(B);
          end;
        end
        else if B = $1B then
          FEscapePendingInString := True
        else if (B = $18) or (B = $1A) then
          EnterGround;
      end;
  end;
end;

procedure TTerminalParser.FeedBytes(const AData: RawByteString);
var
  I: Integer;
begin
  FCore.DbgRecord(Format('FEED start len=%d', [Length(AData)]));
  for I := 1 to Length(AData) do
    FeedByte(Byte(AData[I]));
  FCore.DbgRecord(Format('FEED end', []));
end;

procedure TTerminalParser.FeedBuffer(const ABuffer; ASize: Integer);
var
  P: PByte;
  I: Integer;
begin
  P := @ABuffer;
  for I := 0 to ASize - 1 do
    FeedByte(P[I]);
end;

end.
