unit Terminal.Unicode;


{
  Terminal.Unicode.pas is a UTF-8-focused helper unit with codepoint
  decode/encode functions plus terminal-style width helpers for combining,
  zero-width, ambiguous-width, and wide characters. The width logic follows
  the usual terminal model where combining marks have zero advance width and
  East Asian wide/fullwidth-style characters occupy two cells, which is the
  same basic problem solved by wcwidth-style implementations.

= Included

The unit provides:

- DecodeUTF8CodePoint
- EncodeUTF8CodePoint
- IsValidUnicodeCodePoint
- IsCombiningCodePoint
- IsVariationSelector
- IsZeroWidthCodePoint
- IsWideCodePoint
- CodePointCellWidth
- UTF8CellWidth
- NextUTF8CodePoint

  It is intentionally byte/UTF-8 centered, to avoid legacy codepages and
  WideChar-style processing.

}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TUnicodeWidthPolicy = (uwpNarrow, uwpWide);

  TUnicodeInterval = record
    First: Cardinal;
    Last: Cardinal;
  end;

function DecodeUTF8CodePoint(const S: RawByteString; var AByteIndex: Integer; out ACodePoint: Cardinal): Boolean;
function EncodeUTF8CodePoint(ACodePoint: Cardinal): RawByteString;
function IsValidUnicodeCodePoint(ACodePoint: Cardinal): Boolean;
function IsCombiningCodePoint(ACodePoint: Cardinal): Boolean;
function IsVariationSelector(ACodePoint: Cardinal): Boolean;
function IsZeroWidthCodePoint(ACodePoint: Cardinal): Boolean;
function IsWideCodePoint(ACodePoint: Cardinal; AAmbiguousIsWide: Boolean = False): Boolean;
function CodePointCellWidth(ACodePoint: Cardinal; AAmbiguousIsWide: Boolean = False): Integer;
function UTF8CellWidth(const S: RawByteString; AAmbiguousIsWide: Boolean = False): Integer;
function NextUTF8CodePoint(const S: RawByteString; var AByteIndex: Integer; out ACodePoint: Cardinal): Boolean;

implementation

const
  COMBINING_INTERVALS: array[0..113] of TUnicodeInterval = (
    (First:$0300; Last:$036F), (First:$0483; Last:$0489), (First:$0591; Last:$05BD),
    (First:$05BF; Last:$05BF), (First:$05C1; Last:$05C2), (First:$05C4; Last:$05C5),
    (First:$05C7; Last:$05C7), (First:$0610; Last:$061A), (First:$064B; Last:$065F),
    (First:$0670; Last:$0670), (First:$06D6; Last:$06DC), (First:$06DF; Last:$06E4),
    (First:$06E7; Last:$06E8), (First:$06EA; Last:$06ED), (First:$0711; Last:$0711),
    (First:$0730; Last:$074A), (First:$07A6; Last:$07B0), (First:$07EB; Last:$07F3),
    (First:$07FD; Last:$07FD), (First:$0816; Last:$0819), (First:$081B; Last:$0823),
    (First:$0825; Last:$0827), (First:$0829; Last:$082D), (First:$0859; Last:$085B),
    (First:$0898; Last:$089F), (First:$08CA; Last:$0902), (First:$093A; Last:$093A),
    (First:$093C; Last:$093C), (First:$0941; Last:$0948), (First:$094D; Last:$094D),
    (First:$0951; Last:$0957), (First:$0962; Last:$0963), (First:$0981; Last:$0981),
    (First:$09BC; Last:$09BC), (First:$09C1; Last:$09C4), (First:$09CD; Last:$09CD),
    (First:$09E2; Last:$09E3), (First:$0A01; Last:$0A02), (First:$0A3C; Last:$0A3C),
    (First:$0A41; Last:$0A42), (First:$0A47; Last:$0A48), (First:$0A4B; Last:$0A4D),
    (First:$0A51; Last:$0A51), (First:$0A70; Last:$0A71), (First:$0A75; Last:$0A75),
    (First:$0A81; Last:$0A82), (First:$0ABC; Last:$0ABC), (First:$0AC1; Last:$0AC5),
    (First:$0AC7; Last:$0AC8), (First:$0ACD; Last:$0ACD), (First:$0AE2; Last:$0AE3),
    (First:$0AFA; Last:$0AFF), (First:$0B01; Last:$0B01), (First:$0B3C; Last:$0B3C),
    (First:$0B3F; Last:$0B3F), (First:$0B41; Last:$0B44), (First:$0B4D; Last:$0B4D),
    (First:$0B55; Last:$0B56), (First:$0B62; Last:$0B63), (First:$0B82; Last:$0B82),
    (First:$0BC0; Last:$0BC0), (First:$0BCD; Last:$0BCD), (First:$0C00; Last:$0C00),
    (First:$0C04; Last:$0C04), (First:$0C3E; Last:$0C40), (First:$0C46; Last:$0C48),
    (First:$0C4A; Last:$0C4D), (First:$0C55; Last:$0C56), (First:$0C62; Last:$0C63),
    (First:$0C81; Last:$0C81), (First:$0CBC; Last:$0CBC), (First:$0CBF; Last:$0CBF),
    (First:$0CC6; Last:$0CC6), (First:$0CCC; Last:$0CCD), (First:$0CE2; Last:$0CE3),
    (First:$0D00; Last:$0D01), (First:$0D3B; Last:$0D3C), (First:$0D41; Last:$0D44),
    (First:$0D4D; Last:$0D4D), (First:$0D62; Last:$0D63), (First:$0D81; Last:$0D81),
    (First:$0DCA; Last:$0DCA), (First:$0DD2; Last:$0DD4), (First:$0DD6; Last:$0DD6),
    (First:$0E31; Last:$0E31), (First:$0E34; Last:$0E3A), (First:$0E47; Last:$0E4E),
    (First:$0EB1; Last:$0EB1), (First:$0EB4; Last:$0EBC), (First:$0EC8; Last:$0ECD),
    (First:$0F18; Last:$0F19), (First:$0F35; Last:$0F35), (First:$0F37; Last:$0F37),
    (First:$0F39; Last:$0F39), (First:$0F71; Last:$0F7E), (First:$0F80; Last:$0F84),
    (First:$0F86; Last:$0F87), (First:$0F8D; Last:$0F97), (First:$0F99; Last:$0FBC),
    (First:$0FC6; Last:$0FC6), (First:$102D; Last:$1030), (First:$1032; Last:$1037),
    (First:$1039; Last:$103A), (First:$103D; Last:$103E), (First:$1058; Last:$1059),
    (First:$105E; Last:$1060), (First:$1071; Last:$1074), (First:$1082; Last:$1082),
    (First:$1085; Last:$1086), (First:$108D; Last:$108D), (First:$109D; Last:$109D),
    (First:$135D; Last:$135F), (First:$1712; Last:$1714), (First:$1732; Last:$1734)
  );

  WIDE_INTERVALS: array[0..116] of TUnicodeInterval = (
    (First:$1100; Last:$115F), (First:$231A; Last:$231B), (First:$2329; Last:$232A),
    (First:$23E9; Last:$23EC), (First:$23F0; Last:$23F0), (First:$23F3; Last:$23F3),
    (First:$25FD; Last:$25FE), (First:$2614; Last:$2615), (First:$2648; Last:$2653),
    (First:$267F; Last:$267F), (First:$2693; Last:$2693), (First:$26A1; Last:$26A1),
    (First:$26AA; Last:$26AB), (First:$26BD; Last:$26BE), (First:$26C4; Last:$26C5),
    (First:$26CE; Last:$26CE), (First:$26D4; Last:$26D4), (First:$26EA; Last:$26EA),
    (First:$26F2; Last:$26F3), (First:$26F5; Last:$26F5), (First:$26FA; Last:$26FA),
    (First:$26FD; Last:$26FD), (First:$2705; Last:$2705), (First:$270A; Last:$270B),
    (First:$2728; Last:$2728), (First:$274C; Last:$274C), (First:$274E; Last:$274E),
    (First:$2753; Last:$2755), (First:$2757; Last:$2757), (First:$2795; Last:$2797),
    (First:$27B0; Last:$27B0), (First:$27BF; Last:$27BF), (First:$2B1B; Last:$2B1C),
    (First:$2B50; Last:$2B50), (First:$2B55; Last:$2B55), (First:$2E80; Last:$2FFB),
    (First:$3000; Last:$303E), (First:$3041; Last:$33FF), (First:$3400; Last:$4DBF),
    (First:$4E00; Last:$A4C6), (First:$A960; Last:$A97C), (First:$AC00; Last:$D7A3),
    (First:$F900; Last:$FAFF), (First:$FE10; Last:$FE19), (First:$FE30; Last:$FE6B),
    (First:$FF01; Last:$FF60), (First:$FFE0; Last:$FFE6), (First:$16FE0; Last:$16FE4),
    (First:$16FF0; Last:$16FF1), (First:$17000; Last:$187F7), (First:$18800; Last:$18CD5),
    (First:$18D00; Last:$18D08), (First:$1AFF0; Last:$1AFFF), (First:$1B000; Last:$1B122),
    (First:$1B132; Last:$1B132), (First:$1B150; Last:$1B152), (First:$1B155; Last:$1B155),
    (First:$1B164; Last:$1B167), (First:$1B170; Last:$1B2FB), (First:$1F004; Last:$1F004),
    (First:$1F0CF; Last:$1F0CF), (First:$1F18E; Last:$1F18E), (First:$1F191; Last:$1F19A),
    (First:$1F200; Last:$1F202), (First:$1F210; Last:$1F23B), (First:$1F240; Last:$1F248),
    (First:$1F250; Last:$1F251), (First:$1F260; Last:$1F265), (First:$1F300; Last:$1F320),
    (First:$1F32D; Last:$1F335), (First:$1F337; Last:$1F37C), (First:$1F37E; Last:$1F393),
    (First:$1F3A0; Last:$1F3CA), (First:$1F3CF; Last:$1F3D3), (First:$1F3E0; Last:$1F3F0),
    (First:$1F3F4; Last:$1F3F4), (First:$1F3F8; Last:$1F43E), (First:$1F440; Last:$1F440),
    (First:$1F442; Last:$1F4FC), (First:$1F4FF; Last:$1F53D), (First:$1F54B; Last:$1F54E),
    (First:$1F550; Last:$1F567), (First:$1F57A; Last:$1F57A), (First:$1F595; Last:$1F596),
    (First:$1F5A4; Last:$1F5A4), (First:$1F5FB; Last:$1F64F), (First:$1F680; Last:$1F6C5),
    (First:$1F6CC; Last:$1F6CC), (First:$1F6D0; Last:$1F6D2), (First:$1F6D5; Last:$1F6D7),
    (First:$1F6DC; Last:$1F6DF), (First:$1F6EB; Last:$1F6EC), (First:$1F6F4; Last:$1F6FC),
    (First:$1F7E0; Last:$1F7EB), (First:$1F7F0; Last:$1F7F0), (First:$1F90C; Last:$1F93A),
    (First:$1F93C; Last:$1F945), (First:$1F947; Last:$1F9FF), (First:$1FA70; Last:$1FA7C),
    (First:$1FA80; Last:$1FA89), (First:$1FA8F; Last:$1FAC6), (First:$1FACE; Last:$1FADC),
    (First:$1FADF; Last:$1FAE9), (First:$1FAF0; Last:$1FAF8), (First:$20000; Last:$2FFFD),
    (First:$30000; Last:$3FFFD), (First:$E0100; Last:$E01EF), (First:$1F1E6; Last:$1F1FF),
    (First:$1F926; Last:$1F937), (First:$1F1E6; Last:$1F1FF), (First:$1F9D0; Last:$1F9E6),
    (First:$1FAE0; Last:$1FAE8), (First:$1FAF0; Last:$1FAF6), (First:$1FABF; Last:$1FABF),
    (First:$1F7F0; Last:$1F7F0), (First:$1FA75; Last:$1FA77), (First:$1FA87; Last:$1FA88)
  );

  AMBIGUOUS_INTERVALS: array[0..55] of TUnicodeInterval = (
    (First:$00A1; Last:$00A1), (First:$00A4; Last:$00A4), (First:$00A7; Last:$00A8),
    (First:$00AA; Last:$00AA), (First:$00AE; Last:$00AE), (First:$00B0; Last:$00B4),
    (First:$00B6; Last:$00BA), (First:$00BC; Last:$00BF), (First:$00C6; Last:$00C6),
    (First:$00D0; Last:$00D0), (First:$00D7; Last:$00D8), (First:$00DE; Last:$00E1),
    (First:$00E6; Last:$00E6), (First:$00E8; Last:$00EA), (First:$00EC; Last:$00ED),
    (First:$00F0; Last:$00F0), (First:$00F2; Last:$00F3), (First:$00F7; Last:$00FA),
    (First:$00FC; Last:$00FC), (First:$00FE; Last:$00FE), (First:$0101; Last:$0101),
    (First:$0111; Last:$0111), (First:$0113; Last:$0113), (First:$011B; Last:$011B),
    (First:$0126; Last:$0127), (First:$012B; Last:$012B), (First:$0131; Last:$0133),
    (First:$0138; Last:$0138), (First:$013F; Last:$0142), (First:$0144; Last:$0144),
    (First:$0148; Last:$014B), (First:$014D; Last:$014D), (First:$0152; Last:$0153),
    (First:$0166; Last:$0167), (First:$016B; Last:$016B), (First:$01CE; Last:$01CE),
    (First:$01D0; Last:$01D0), (First:$01D2; Last:$01D2), (First:$01D4; Last:$01D4),
    (First:$01D6; Last:$01D6), (First:$01D8; Last:$01D8), (First:$01DA; Last:$01DA),
    (First:$01DC; Last:$01DC), (First:$0251; Last:$0251), (First:$0261; Last:$0261),
    (First:$02C4; Last:$02C4), (First:$02C7; Last:$02C7), (First:$02C9; Last:$02CB),
    (First:$02CD; Last:$02CD), (First:$02D0; Last:$02D0), (First:$02D8; Last:$02DB),
    (First:$02DD; Last:$02DD), (First:$0391; Last:$03A1), (First:$03A3; Last:$03A9),
    (First:$03B1; Last:$03C1), (First:$03C3; Last:$03C9)
  );

function InInterval(ACodePoint: Cardinal; const AIntervals: array of TUnicodeInterval): Boolean;
var
  L, H, M: Integer;
begin
  Result := False;
  if Length(AIntervals) = 0 then
    Exit;
  L := 0;
  H := High(AIntervals);
  while L <= H do
  begin
    M := (L + H) shr 1;
    if ACodePoint < AIntervals[M].First then
      H := M - 1
    else if ACodePoint > AIntervals[M].Last then
      L := M + 1
    else
      Exit(True);
  end;
end;

function IsValidUnicodeCodePoint(ACodePoint: Cardinal): Boolean;
begin
  Result := (ACodePoint <= $10FFFF) and not ((ACodePoint >= $D800) and (ACodePoint <= $DFFF));
end;

function DecodeUTF8CodePoint(const S: RawByteString; var AByteIndex: Integer; out ACodePoint: Cardinal): Boolean;
var
  B1, B2, B3, B4: Byte;
  L: Integer;
begin
  Result := False;
  ACodePoint := $FFFD;
  L := Length(S);
  if (AByteIndex < 1) or (AByteIndex > L) then
    Exit;

  B1 := Byte(S[AByteIndex]);
  if B1 < $80 then
  begin
    ACodePoint := B1;
    Inc(AByteIndex);
    Exit(True);
  end;

  if (B1 and $E0) = $C0 then
  begin
    if AByteIndex + 1 > L then Exit(False);
    B2 := Byte(S[AByteIndex + 1]);
    if (B2 and $C0) <> $80 then Exit(False);
    ACodePoint := ((B1 and $1F) shl 6) or (B2 and $3F);
    if ACodePoint < $80 then Exit(False);
    Inc(AByteIndex, 2);
    Exit(True);
  end;

  if (B1 and $F0) = $E0 then
  begin
    if AByteIndex + 2 > L then Exit(False);
    B2 := Byte(S[AByteIndex + 1]);
    B3 := Byte(S[AByteIndex + 2]);
    if ((B2 and $C0) <> $80) or ((B3 and $C0) <> $80) then Exit(False);
    ACodePoint := ((B1 and $0F) shl 12) or ((B2 and $3F) shl 6) or (B3 and $3F);
    if ACodePoint < $800 then Exit(False);
    if (ACodePoint >= $D800) and (ACodePoint <= $DFFF) then Exit(False);
    Inc(AByteIndex, 3);
    Exit(True);
  end;

  if (B1 and $F8) = $F0 then
  begin
    if AByteIndex + 3 > L then Exit(False);
    B2 := Byte(S[AByteIndex + 1]);
    B3 := Byte(S[AByteIndex + 2]);
    B4 := Byte(S[AByteIndex + 3]);
    if ((B2 and $C0) <> $80) or ((B3 and $C0) <> $80) or ((B4 and $C0) <> $80) then Exit(False);
    ACodePoint := ((B1 and $07) shl 18) or ((B2 and $3F) shl 12) or ((B3 and $3F) shl 6) or (B4 and $3F);
    if (ACodePoint < $10000) or (ACodePoint > $10FFFF) then Exit(False);
    Inc(AByteIndex, 4);
    Exit(True);
  end;
end;

function EncodeUTF8CodePoint(ACodePoint: Cardinal): RawByteString;
begin
  if not IsValidUnicodeCodePoint(ACodePoint) then
    ACodePoint := $FFFD;

  case ACodePoint of
    $0000..$007F:
      Result := AnsiChar(Chr(ACodePoint));
    $0080..$07FF:
      Result := AnsiChar(Chr($C0 or (ACodePoint shr 6))) +
                AnsiChar(Chr($80 or (ACodePoint and $3F)));
    $0800..$FFFF:
      Result := AnsiChar(Chr($E0 or (ACodePoint shr 12))) +
                AnsiChar(Chr($80 or ((ACodePoint shr 6) and $3F))) +
                AnsiChar(Chr($80 or (ACodePoint and $3F)));
  else
      Result := AnsiChar(Chr($F0 or (ACodePoint shr 18))) +
                AnsiChar(Chr($80 or ((ACodePoint shr 12) and $3F))) +
                AnsiChar(Chr($80 or ((ACodePoint shr 6) and $3F))) +
                AnsiChar(Chr($80 or (ACodePoint and $3F)));
  end;
end;

function IsCombiningCodePoint(ACodePoint: Cardinal): Boolean;
begin
  Result := InInterval(ACodePoint, COMBINING_INTERVALS);
end;

function IsVariationSelector(ACodePoint: Cardinal): Boolean;
begin
  Result := ((ACodePoint >= $FE00) and (ACodePoint <= $FE0F)) or
            ((ACodePoint >= $E0100) and (ACodePoint <= $E01EF));
end;

function IsZeroWidthCodePoint(ACodePoint: Cardinal): Boolean;
begin
  Result := (ACodePoint = 0) or
            ((ACodePoint < 32) or ((ACodePoint >= $7F) and (ACodePoint < $A0))) or
            IsCombiningCodePoint(ACodePoint) or
            IsVariationSelector(ACodePoint) or
            (ACodePoint = $00AD) or
            (ACodePoint = $200B) or (ACodePoint = $200C) or (ACodePoint = $200D) or
            (ACodePoint = $2060) or
            ((ACodePoint >= $FEFF) and (ACodePoint <= $FEFF));
end;

function IsWideCodePoint(ACodePoint: Cardinal; AAmbiguousIsWide: Boolean): Boolean;
begin
  if InInterval(ACodePoint, WIDE_INTERVALS) then
    Exit(True);
  if AAmbiguousIsWide and InInterval(ACodePoint, AMBIGUOUS_INTERVALS) then
    Exit(True);
  Result := False;
end;

function CodePointCellWidth(ACodePoint: Cardinal; AAmbiguousIsWide: Boolean): Integer;
begin
  if not IsValidUnicodeCodePoint(ACodePoint) then
    Exit(1);
  if IsZeroWidthCodePoint(ACodePoint) then
    Exit(0);
  if IsWideCodePoint(ACodePoint, AAmbiguousIsWide) then
    Exit(2);
  Result := 1;
end;

function UTF8CellWidth(const S: RawByteString; AAmbiguousIsWide: Boolean): Integer;
var
  Index: Integer;
  CodePoint: Cardinal;
begin
  Result := 0;
  Index := 1;
  while Index <= Length(S) do
  begin
    if DecodeUTF8CodePoint(S, Index, CodePoint) then
      Inc(Result, CodePointCellWidth(CodePoint, AAmbiguousIsWide))
    else
    begin
      Inc(Result, 1);
      Inc(Index);
    end;
  end;
end;

function NextUTF8CodePoint(const S: RawByteString; var AByteIndex: Integer; out ACodePoint: Cardinal): Boolean;
begin
  Result := DecodeUTF8CodePoint(S, AByteIndex, ACodePoint);
end;

end.
