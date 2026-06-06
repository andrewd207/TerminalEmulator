program Replay;
{$mode objfpc}{$H+}

{ Headless replay harness.

  Reads /tmp/term-raw.log (or argv[1]) — the chunk-framed hex dump produced by
  Terminal.Backend.Unix.DumpRawBytes — parses it back into raw bytes, feeds
  each byte through TTerminalParser + TTerminalCore, and dumps a plain-text
  snapshot of the alt buffer at every ESU (?2026l) and at end-of-stream.

  Snapshots go to /tmp/term-replay.txt with frame numbers, so you can diff
  against the same /tmp/term-raw.log replayed through xterm (capture with
  e.g. `cat /tmp/term-raw.log.bin | xterm -into ... ; scrape via tmux capture`).

  Use:  ./replay [path-to-raw-log] [cols] [rows]
  Default geometry: 80x40 (matches the bug repro).
}

uses
  SysUtils, Classes, Math,
  Terminal.Core, Terminal.Parser;

var
  GFrame: Integer = 0;
  GCore: TTerminalCore;
  GParser: TTerminalParser;
  GLastSync: Boolean = False;
  GOut: TextFile;
  GTotalBytes: Integer = 0;

function HexDigit(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function ParseHexLine(const ALine: string; out ABytes: RawByteString): Boolean;
var
  I, Hi, Lo: Integer;
begin
  ABytes := '';
  I := 1;
  while I <= Length(ALine) do
  begin
    while (I <= Length(ALine)) and (ALine[I] = ' ') do Inc(I);
    if I > Length(ALine) then Break;
    if I + 1 > Length(ALine) then Exit(False);
    Hi := HexDigit(ALine[I]);
    Lo := HexDigit(ALine[I + 1]);
    if (Hi < 0) or (Lo < 0) then Exit(False);
    ABytes := ABytes + Chr((Hi shl 4) or Lo);
    Inc(I, 2);
  end;
  Result := True;
end;

procedure DumpBuffer(const ATag: string);
var
  R, C: Integer;
  Line: string;
  Cell: PTermCell;
  Ch: string;
begin
  Inc(GFrame);
  WriteLn(GOut, '');
  WriteLn(GOut, '===== frame ', GFrame, '  ', ATag,
    '  bytes-consumed=', GTotalBytes,
    '  alt=', GCore.InAltBuffer,
    '  cursor=(', GCore.Cursor.Row, ',', GCore.Cursor.Col, ')',
    ' =====');
  for R := 0 to GCore.Rows - 1 do
  begin
    Line := Format('%2d| ', [R]);
    for C := 0 to GCore.Cols - 1 do
    begin
      Cell := GCore.CellAt(C, R);
      if (Cell = nil) or (Cell^.CodePoint = 0) or (Cell^.CodePoint = 32) then
        Ch := ' '
      else if Cell^.Cluster <> '' then
        Ch := string(Cell^.Cluster)
      else
        Ch := UTF8Encode(WideChar(Cell^.CodePoint));
      Line := Line + Ch;
    end;
    WriteLn(GOut, Line, '|');
  end;
  Flush(GOut);
end;

procedure FeedAndMaybeDump(const AChunk: RawByteString);
var
  I: Integer;
  WasSync: Boolean;
begin
  for I := 1 to Length(AChunk) do
  begin
    WasSync := GCore.InSyncUpdate;
    GParser.FeedByte(Byte(AChunk[I]));
    Inc(GTotalBytes);
    if WasSync and (not GCore.InSyncUpdate) then
      DumpBuffer('ESU');
    GLastSync := GCore.InSyncUpdate;
  end;
end;

var
  LogPath: string = '/tmp/term-raw.log';
  Cols: Integer = 80;
  Rows: Integer = 40;
  F: TextFile;
  Ln: string;
  ChunkLen: Integer;
  Bytes: RawByteString;
  Mode: (mWantHeader, mWantHex, mWantAscii);
begin
  if ParamCount >= 1 then LogPath := ParamStr(1);
  if ParamCount >= 2 then Cols := StrToInt(ParamStr(2));
  if ParamCount >= 3 then Rows := StrToInt(ParamStr(3));

  WriteLn('replay: log=', LogPath, ' geom=', Cols, 'x', Rows);

  AssignFile(GOut, '/tmp/term-replay.txt');
  Rewrite(GOut);

  GCore := TTerminalCore.Create(Cols, Rows);
  GParser := TTerminalParser.Create(GCore);

  AssignFile(F, LogPath);
  Reset(F);
  Mode := mWantHeader;
  ChunkLen := 0;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Ln);
      case Mode of
        mWantHeader:
          if (Pos('--- chunk len=', Ln) = 1) then
          begin
            ChunkLen := StrToIntDef(
              Copy(Ln, Length('--- chunk len=') + 1,
                   Pos(' ---', Ln) - Length('--- chunk len=') - 1), 0);
            Mode := mWantHex;
          end
          else if (Pos('--- resize cols=', Ln) = 1) then
          begin
            DumpBuffer('PRE-RESIZE');
            Cols := StrToIntDef(Copy(Ln, Length('--- resize cols=') + 1,
                Pos(' rows=', Ln) - Length('--- resize cols=') - 1), Cols);
            Rows := StrToIntDef(Copy(Ln, Pos('rows=', Ln) + 5,
                Pos(' ---', Ln) - Pos('rows=', Ln) - 5), Rows);
            GCore.Resize(Cols, Rows);
            DumpBuffer(Format('POST-RESIZE %dx%d', [Cols, Rows]));
          end;
        mWantHex:
          begin
            if not ParseHexLine(Ln, Bytes) then
            begin
              WriteLn('parse error at chunk before byte ', GTotalBytes);
              Break;
            end;
            if Length(Bytes) <> ChunkLen then
              WriteLn('warn: declared len=', ChunkLen, ' actual=', Length(Bytes));
            FeedAndMaybeDump(Bytes);
            Mode := mWantAscii;
          end;
        mWantAscii:
          Mode := mWantHeader;
      end;
    end;
  finally
    CloseFile(F);
  end;

  DumpBuffer('EOF');
  WriteLn('replay done: ', GTotalBytes, ' bytes, ', GFrame, ' frames');
  WriteLn('snapshots -> /tmp/term-replay.txt');

  CloseFile(GOut);
  GParser.Free;
  GCore.Free;
end.
