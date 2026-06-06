{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.View.LCL;

{$mode objfpc}{$H+}

interface

uses
  Interfaces, { selects the LCL widgetset — required for any binary using this unit }
  Classes, SysUtils, Types, LCLType, LCLIntf,
  Graphics, Controls, Forms, StdCtrls, ExtCtrls, Menus, Dialogs, Clipbrd,
  Terminal.Controller, Terminal.Core;

type

  { TTerminalLCLView }

  TTerminalLCLView = class(TCustomControl)
  public type
    TCursorStyle = (csBlock, csUnderscore);
  private
    FContextMenu: TPopupMenu;
    FScrollbar: TScrollBar;
    FController: TTerminalController;
    FTimer: TTimer;
    FCursorTimer: TTimer;
    FCursorStyle: TCursorStyle;
    FFontName: string;
    FFontSize: Integer;
    FEmojiFontName: string;
    FEmojiFontSize: Integer;
    FCharWidth: Integer;
    FCharHeight: Integer;
    FTopRow: Integer;
    FCursorBlinkVisible: Boolean;
    FBackgroundColor: TColor;
    FDefaultFGColor: TColor;
    FSelection: TTermSelection;
    FSelectionFGColor: TColor;
    FSelectionBGColor: TColor;
    FOnFontChanged: TNotifyEvent;
    FOnShellExit: TNotifyEvent;
    FYieldRightClickToApp: Boolean;
    FLastMouseReportCol: Integer;
    FLastMouseReportRow: Integer;
    FShellExited: Boolean;
    FMouseDownPending: Boolean;
    FMouseDownX: Integer;
    FMouseDownY: Integer;
    FMouseDownAnchor: TTermCellPos;
    FMiCopy, FMiPaste, FMiFont, FMiEmoji: TMenuItem;
    function CellSelected(AVirtualRow, ACol: Integer): Boolean;
    procedure ContextCopyClick(Sender: TObject);
    procedure ContextPasteClick(Sender: TObject);
    procedure ContextFontClick(Sender: TObject);
    procedure ContextEmojiFontClick(Sender: TObject);
    procedure ContextPopupShow(Sender: TObject);
    function GetSelectedTextUTF8: RawByteString;
    function GetVirtualLine(AVirtualRow: Integer): TTermCellLine;
    procedure HandleScrollBarChange(Sender: TObject);
    procedure TimerFired(Sender: TObject);
    procedure CursorTimerFired(Sender: TObject);
    procedure CoreInvalidate(Sender: TObject; const ARect: TTermRect);
    procedure CoreBell(Sender: TObject);
    procedure CoreTitle(Sender: TObject; const ATitle: string);
    procedure CoreClipboardSet(Sender: TObject; const ATargets: string; const AText: RawByteString);
    procedure CoreClipboardGet(Sender: TObject; const ATargets: string; out AText: RawByteString);
    procedure UpdateMetrics;
    procedure SyncSizeToController;
    function RowsVisible: Integer;
    function ColsVisible: Integer;
    function GridWidth: Integer;
    function GridHeight: Integer;
    function CellRect(ACol, ARow: Integer): TRect;
    function MapColor(const AColor: TTermColor; IsBackground: Boolean): TColor;
    procedure ApplyFontForCell(const AAttrs: TTermAttrFlags; ACodePoint: Cardinal);
    procedure PaintCell(ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
    function PixelToCell(X, Y: Integer): TTermCellPos;
    function TryMouseReport(X, Y: Integer; Shift: TShiftState;
      AButton: TTermMouseButton; APressed, AMotion: Boolean): Boolean;
    procedure UpdateScrollBar;
    procedure CreatePopupMenu;
    procedure DoCopy;
    procedure DoPaste;
    procedure DoChangeFont;
    procedure DoChangeEmojiFont;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure DoOnResize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AttachController(AController: TTerminalController);
    procedure DetachController;
    procedure StartShell(const AShell: string = '');
    procedure ScrollBy(ADeltaRows: Integer); reintroduce;
    procedure WriteExitBanner;

    property Controller: TTerminalController read FController;
    property FontName: string read FFontName write FFontName;
    property FontSize: Integer read FFontSize write FFontSize;
    property EmojiFontName: string read FEmojiFontName write FEmojiFontName;
    property EmojiFontSize: Integer read FEmojiFontSize write FEmojiFontSize;
    property CursorStyle: TCursorStyle read FCursorStyle write FCursorStyle;
    property BackgroundColor: TColor read FBackgroundColor write FBackgroundColor;
    property DefaultFGColor: TColor read FDefaultFGColor write FDefaultFGColor;
    property SelectionFGColor: TColor read FSelectionFGColor write FSelectionFGColor;
    property SelectionBGColor: TColor read FSelectionBGColor write FSelectionBGColor;
    { When True, right-click is forwarded to a mouse-capturing app (?1000/?1003)
      instead of opening the context menu. When False (default) the context
      menu always opens on right-click, even in fullscreen TUIs. }
    property YieldRightClickToApp: Boolean read FYieldRightClickToApp write FYieldRightClickToApp default False;
    property OnFontChanged: TNotifyEvent read FOnFontChanged write FOnFontChanged;
    { Fired once, in the pump-timer context, when the child process exits.
      If unset, the view writes a default banner into the buffer; assigning a
      handler suppresses the default. }
    property OnShellExit: TNotifyEvent read FOnShellExit write FOnShellExit;
  published
    property Align;
    property Anchors;
    property TabStop default True;
    property TabOrder;
    property PopupMenu;
    property OnEnter;
    property OnExit;
  end;

  TTerminalLCLForm = class(TForm)
  private
    FTerminalView: TTerminalLCLView;
  public
    constructor Create(AOwner: TComponent); override;
    property TerminalView: TTerminalLCLView read FTerminalView;
  end;

implementation

uses
  Math;

const
  CURSOR_BLINK_MS = 750;
  PUMP_MS = 20;
  SELECTION_DRAG_THRESHOLD = 3;

function RGBToLCLColor(ARGB: Cardinal): TColor; inline;
begin
  { TermColorToRGB returns $00RRGGBB; TColor is $00BBGGRR. }
  Result := TColor(((ARGB and $FF) shl 16) or (ARGB and $00FF00) or ((ARGB and $FF0000) shr 16));
end;

procedure SwapColor(var A, B: TColor); inline;
var T: TColor;
begin T := A; A := B; B := T; end;

{ TTerminalLCLView }

constructor TTerminalLCLView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque, csCaptureMouse, csClickEvents, csDoubleClicks];
  TabStop := True;
  DoubleBuffered := False;

  FFontName := 'Monospace';
  FFontSize := 10;
  FEmojiFontName := '';
  FEmojiFontSize := 10;
  FBackgroundColor := clBlack;
  Color := clBlack;
  FDefaultFGColor := clWhite;
  FSelectionFGColor := clBlack;
  FSelectionBGColor := TColor($00FFD700); { gold-ish — note BGR layout }
  FCursorBlinkVisible := True;

  Width := 800;
  Height := 500;

  FScrollbar := TScrollBar.Create(Self);
  FScrollbar.Parent := Self;
  FScrollbar.Kind := sbVertical;
  FScrollbar.Align := alRight;
  FScrollbar.OnChange := @HandleScrollBarChange;
  FTopRow := 0;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := PUMP_MS;
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerFired;

  FCursorTimer := TTimer.Create(Self);
  FCursorTimer.Interval := CURSOR_BLINK_MS;
  FCursorTimer.Enabled := True;
  FCursorTimer.OnTimer := @CursorTimerFired;

  CreatePopupMenu;
end;

destructor TTerminalLCLView.Destroy;
begin
  DetachController;
  inherited Destroy;
end;

procedure TTerminalLCLView.AttachController(AController: TTerminalController);
begin
  if FController = AController then Exit;
  DetachController;
  FController := AController;
  if FController <> nil then
  begin
    FController.Core.OnInvalidate := @CoreInvalidate;
    FController.Core.OnBell := @CoreBell;
    FController.Core.OnTitle := @CoreTitle;
    FController.Core.OnClipboardSet := @CoreClipboardSet;
    FController.Core.OnClipboardGet := @CoreClipboardGet;
    SyncSizeToController;
    FShellExited := False;
    FTimer.Enabled := True;
  end;
  Invalidate;
end;

procedure TTerminalLCLView.DetachController;
begin
  if FController <> nil then
  begin
    FController.Core.OnInvalidate := nil;
    FController.Core.OnBell := nil;
    FController.Core.OnTitle := nil;
    FController.Core.OnClipboardSet := nil;
    FController.Core.OnClipboardGet := nil;
    FController.Stop;
    FController := nil;
  end;
  if FTimer <> nil then
    FTimer.Enabled := False;
end;

procedure TTerminalLCLView.StartShell(const AShell: string);
begin
  if FController <> nil then
  begin
    SyncSizeToController;
    FController.StartShell(AShell, []);
    SyncSizeToController;
  end;
end;

procedure TTerminalLCLView.ScrollBy(ADeltaRows: Integer);
begin
  if FController = nil then Exit;
  FScrollbar.Position := EnsureRange(FScrollbar.Position + ADeltaRows,
                                     FScrollbar.Min, FScrollbar.Max);
end;

procedure TTerminalLCLView.WriteExitBanner;
const
  EXIT_BANNER: RawByteString =
    #27'[0m'#13#10#27'[7m[ process exited - close window ]'#27'[0m'#13#10;
begin
  if FController = nil then Exit;
  FController.Parser.FeedBytes(EXIT_BANNER);
  if (Parent <> nil) and (Parent is TTerminalLCLForm)
     and (TTerminalLCLForm(Parent).Caption <> '') then
    TTerminalLCLForm(Parent).Caption := TTerminalLCLForm(Parent).Caption + ' [exited]';
end;

procedure TTerminalLCLView.TimerFired(Sender: TObject);
var N: Integer;
begin
  if FController = nil then Exit;

  N := FController.Pump;
  if N > 0 then
  begin
    FCursorBlinkVisible := True;
    FCursorTimer.Enabled := False;
    FCursorTimer.Enabled := True;
    UpdateScrollBar;
    FScrollbar.Position := FScrollbar.Max;
    FTopRow := FScrollbar.Position;
    if not FController.Core.InSyncUpdate then
      Invalidate;
  end;

  if (not FShellExited) and (FController.Backend <> nil)
     and (not FController.Backend.IsRunning) then
  begin
    FShellExited := True;
    FCursorBlinkVisible := False;
    FCursorTimer.Enabled := False;
    FTimer.Enabled := False;
    if Assigned(FOnShellExit) then
      FOnShellExit(Self)
    else
      WriteExitBanner;
    UpdateScrollBar;
    Invalidate;
  end;
end;

procedure TTerminalLCLView.CursorTimerFired(Sender: TObject);
begin
  if FController <> nil then
  begin
    FCursorBlinkVisible := not FCursorBlinkVisible;
    Invalidate;
  end;
end;

procedure TTerminalLCLView.CoreInvalidate(Sender: TObject; const ARect: TTermRect);
var
  HistCount: Integer;
  SelMinVRow, SelMaxVRow: Integer;
begin
  HistCount := 0;
  if FController <> nil then
    HistCount := FController.Core.HistoryCount;

  if FSelection.Active then
  begin
    if FSelection.Anchor.Row <= FSelection.Focus.Row then
    begin
      SelMinVRow := FSelection.Anchor.Row;
      SelMaxVRow := FSelection.Focus.Row;
    end
    else
    begin
      SelMinVRow := FSelection.Focus.Row;
      SelMaxVRow := FSelection.Anchor.Row;
    end;
    if (SelMaxVRow >= HistCount + ARect.Top)
       and (SelMinVRow <= HistCount + ARect.Bottom) then
    begin
      FSelection.Active := False;
      FSelection.Selecting := False;
    end;
  end;

  { Like the fpGUI view: do a whole-client invalidate; partial invalidates would
    let stale cells outside the rect linger because Paint repaints everything. }
  Invalidate;
end;

procedure TTerminalLCLView.CoreBell(Sender: TObject);
begin
  // ding :)
end;

procedure TTerminalLCLView.CoreTitle(Sender: TObject; const ATitle: string);
begin
  if (Parent <> nil) and (Parent is TTerminalLCLForm)
     and (TTerminalLCLForm(Parent).Caption <> '') then
    TTerminalLCLForm(Parent).Caption := ATitle;
end;

procedure TTerminalLCLView.CoreClipboardSet(Sender: TObject;
  const ATargets: string; const AText: RawByteString);
begin
  Clipboard.AsText := UTF8String(AText);
end;

procedure TTerminalLCLView.CoreClipboardGet(Sender: TObject;
  const ATargets: string; out AText: RawByteString);
begin
  AText := RawByteString(Clipboard.AsText);
end;

procedure TTerminalLCLView.UpdateMetrics;
begin
  Canvas.Font.Name := FFontName;
  Canvas.Font.Size := FFontSize;
  Canvas.Font.Style := [];
  FCharHeight := Max(1, Canvas.TextHeight('Mg'));
  FCharWidth := Max(1, Canvas.TextWidth('M'));
  UpdateScrollBar;
end;

procedure TTerminalLCLView.UpdateScrollBar;
var
  TotalRows, VisibleCount: Integer;
begin
  if FController = nil then Exit;
  VisibleCount := Max(1, RowsVisible);
  TotalRows := FController.Core.HistoryCount + FController.Core.Rows;
  FScrollbar.Min := 0;
  FScrollbar.PageSize := VisibleCount;
  FScrollbar.LargeChange := VisibleCount;
  FScrollbar.SmallChange := 1;
  FScrollbar.Max := Max(0, TotalRows - 1);
  if FScrollbar.Position > FScrollbar.Max - VisibleCount + 1 then
    FScrollbar.Position := Max(0, FScrollbar.Max - VisibleCount + 1);
  FTopRow := FScrollbar.Position;
end;

procedure TTerminalLCLView.CreatePopupMenu;
begin
  FContextMenu := TPopupMenu.Create(Self);
  FContextMenu.OnPopup := @ContextPopupShow;

  FMiCopy := TMenuItem.Create(FContextMenu);
  FMiCopy.Caption := 'Copy';
  FMiCopy.ShortCut := ShortCut(Ord('C'), [ssCtrl, ssShift]);
  FMiCopy.OnClick := @ContextCopyClick;
  FContextMenu.Items.Add(FMiCopy);

  FMiPaste := TMenuItem.Create(FContextMenu);
  FMiPaste.Caption := 'Paste';
  FMiPaste.ShortCut := ShortCut(VK_INSERT, [ssShift]);
  FMiPaste.OnClick := @ContextPasteClick;
  FContextMenu.Items.Add(FMiPaste);

  FContextMenu.Items.AddSeparator;

  FMiFont := TMenuItem.Create(FContextMenu);
  FMiFont.Caption := 'Font...';
  FMiFont.OnClick := @ContextFontClick;
  FContextMenu.Items.Add(FMiFont);

  FMiEmoji := TMenuItem.Create(FContextMenu);
  FMiEmoji.Caption := 'Emoji Font...';
  FMiEmoji.OnClick := @ContextEmojiFontClick;
  FContextMenu.Items.Add(FMiEmoji);
  { Intentionally do NOT assign Self.PopupMenu — MouseDown calls PopUp manually
    so we can suppress it when the app has captured mouse via mouse-reporting. }
end;

procedure TTerminalLCLView.DoCopy;
begin
  if FController = nil then Exit;
  { When the app supports bracketed commands (?2004), it likely manages its own
    selection — forward Ctrl+Shift+C so it can copy what *it* considers selected
    (typically via OSC 52 back to us). If we have our own visual selection,
    prefer that and copy locally. }
  if FSelection.Active then
    Clipboard.AsText := GetSelectedTextUTF8
  else if FController.Core.BracketedPasteMode then
    FController.SendInput(#27'[99;6u');
end;

procedure TTerminalLCLView.DoPaste;
var
  S: string;
begin
  if FController = nil then Exit;
  { When the app has opted into bracketed paste (?2004) it's telling us it
    handles paste blocks itself — send the clipboard wrapped in 200~/201~.
    Otherwise, don't dump bytes into a TUI that isn't expecting them; instead
    forward Ctrl+Shift+V as a CSI u "modifyOtherKeys" sequence so the app can
    bind its own paste handler (mirrors the fpGUI Ctrl+Shift+C fallback). }
  if FController.Core.BracketedPasteMode then
  begin
    if Clipboard.AsText = '' then Exit;
    S := Clipboard.AsText;
    S := StringReplace(S, #13#10, #10, [rfReplaceAll]);
    S := StringReplace(S, #13, #10, [rfReplaceAll]);
    FController.SendInput(#27'[200~' + S + #27'[201~');
  end
  else
    FController.SendInput(#27'[86;6u');
end;

procedure TTerminalLCLView.DoChangeFont;
var
  Dlg: TFontDialog;
begin
  Dlg := TFontDialog.Create(nil);
  try
    Dlg.Font.Name := FFontName;
    Dlg.Font.Size := FFontSize;
    if Dlg.Execute then
    begin
      FFontName := Dlg.Font.Name;
      FFontSize := Dlg.Font.Size;
          UpdateMetrics;
      SyncSizeToController;
      if Assigned(FOnFontChanged) then FOnFontChanged(Self);
      Invalidate;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TTerminalLCLView.DoChangeEmojiFont;
var
  Dlg: TFontDialog;
begin
  Dlg := TFontDialog.Create(nil);
  try
    if FEmojiFontName <> '' then Dlg.Font.Name := FEmojiFontName;
    Dlg.Font.Size := FEmojiFontSize;
    if Dlg.Execute then
    begin
      FEmojiFontName := Dlg.Font.Name;
      FEmojiFontSize := Dlg.Font.Size;
      if Assigned(FOnFontChanged) then FOnFontChanged(Self);
      Invalidate;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TTerminalLCLView.SyncSizeToController;
var
  Cols, Rows: Integer;
begin
  if FController = nil then Exit;
  UpdateMetrics;
  Cols := Max(1, GridWidth div FCharWidth);
  Rows := Max(1, GridHeight div FCharHeight);
  FController.Resize(Cols, Rows);
end;

function TTerminalLCLView.RowsVisible: Integer;
begin
  Result := Max(1, GridHeight div Max(1, FCharHeight));
end;

function TTerminalLCLView.ColsVisible: Integer;
begin
  Result := Max(1, GridWidth div Max(1, FCharWidth));
end;

function TTerminalLCLView.GridWidth: Integer;
begin
  Result := ClientWidth - FScrollbar.Width;
  if Result < 0 then Result := 0;
end;

function TTerminalLCLView.GridHeight: Integer;
begin
  Result := ClientHeight;
end;

function TTerminalLCLView.CellRect(ACol, ARow: Integer): TRect;
begin
  Result := Rect(ACol * FCharWidth, ARow * FCharHeight,
                 ACol * FCharWidth + FCharWidth,
                 ARow * FCharHeight + FCharHeight);
end;

function TTerminalLCLView.MapColor(const AColor: TTermColor; IsBackground: Boolean): TColor;
begin
  case AColor.Mode of
    tcmIndexed, tcmRGB: Result := RGBToLCLColor(TermColorToRGB(AColor));
  else
    if IsBackground then Result := FBackgroundColor
    else Result := FDefaultFGColor;
  end;
end;

function IsEmojiCodePoint(CP: Cardinal): Boolean; inline;
begin
  Result :=
    ((CP >= $2600)  and (CP <= $27BF))  or
    ((CP >= $1F300) and (CP <= $1F6FF)) or
    ((CP >= $1F900) and (CP <= $1F9FF)) or
    ((CP >= $1FA70) and (CP <= $1FAFF));
end;

procedure TTerminalLCLView.ApplyFontForCell(const AAttrs: TTermAttrFlags; ACodePoint: Cardinal);
var
  Style: TFontStyles;
begin
  Style := [];
  if tafBold      in AAttrs then Include(Style, fsBold);
  if tafItalic    in AAttrs then Include(Style, fsItalic);
  if tafUnderline in AAttrs then Include(Style, fsUnderline);
  if tafStrike    in AAttrs then Include(Style, fsStrikeOut);

  if (FEmojiFontName <> '') and IsEmojiCodePoint(ACodePoint) then
  begin
    Canvas.Font.Name := FEmojiFontName;
    Canvas.Font.Size := FEmojiFontSize;
  end
  else
  begin
    Canvas.Font.Name := FFontName;
    Canvas.Font.Size := FFontSize;
  end;
  Canvas.Font.Style := Style;
end;

procedure TTerminalLCLView.PaintCell(ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean);
var
  R: TRect;
  FG, BG: TColor;
  S: string;
  VirtualRow: Integer;
  IsSelected: Boolean;
begin
  if tafWideTrail in ACell.Attrs then Exit;

  VirtualRow := FTopRow + AViewRow;
  IsSelected := CellSelected(VirtualRow, ACol);

  R := CellRect(ACol, AViewRow);
  BG := MapColor(ACell.BG, True);
  FG := MapColor(ACell.FG, False);

  if tafFaint in ACell.Attrs then
    FG := TColor(((FG and $FE) shr 1)
              or ((FG and $FE00) shr 1)
              or ((FG and $FE0000) shr 1));

  if tafInverse in ACell.Attrs then SwapColor(FG, BG);
  if tafHidden in ACell.Attrs then FG := BG;

  if IsSelected then
  begin
    BG := FSelectionBGColor;
    FG := FSelectionFGColor;
  end;

  if AHasCursor and FCursorBlinkVisible then SwapColor(FG, BG);

  if tafWideLead in ACell.Attrs then
    R.Right := R.Left + FCharWidth * 2;

  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := BG;
  Canvas.FillRect(R);

  if (tafBlink in ACell.Attrs) and (not FCursorBlinkVisible) then Exit;

  if not ACell.isBlank then
  begin
    if ACell.Cluster <> '' then S := ACell.Cluster
    else S := ' ';
    ApplyFontForCell(ACell.Attrs, ACell.CodePoint);
    Canvas.Font.Color := FG;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(R.Left, R.Top, S);
    Canvas.Brush.Style := bsSolid;
  end;
end;

function TTerminalLCLView.PixelToCell(X, Y: Integer): TTermCellPos;
begin
  if FCharWidth <= 0 then FCharWidth := 1;
  if FCharHeight <= 0 then FCharHeight := 1;
  Result.Col := EnsureRange(X div FCharWidth, 0, ColsVisible - 1);
  Result.Row := FTopRow + EnsureRange(Y div FCharHeight, 0, RowsVisible - 1);
end;

function TTerminalLCLView.CellSelected(AVirtualRow, ACol: Integer): Boolean;
var S, E: TTermCellPos;
begin
  Result := False;
  if not FSelection.Active then Exit;
  S := FSelection.Anchor;
  E := FSelection.Focus;
  if (S.Row > E.Row) or ((S.Row = E.Row) and (S.Col > E.Col)) then
  begin
    S := FSelection.Focus;
    E := FSelection.Anchor;
  end;
  if (AVirtualRow < S.Row) or (AVirtualRow > E.Row) then Exit(False);
  if S.Row = E.Row then
    Exit((AVirtualRow = S.Row) and (ACol >= S.Col) and (ACol <= E.Col));
  if AVirtualRow = S.Row then Exit(ACol >= S.Col);
  if AVirtualRow = E.Row then Exit(ACol <= E.Col);
  Result := True;
end;

procedure TTerminalLCLView.ContextCopyClick(Sender: TObject); begin DoCopy; end;
procedure TTerminalLCLView.ContextPasteClick(Sender: TObject); begin DoPaste; end;
procedure TTerminalLCLView.ContextFontClick(Sender: TObject); begin DoChangeFont; end;
procedure TTerminalLCLView.ContextEmojiFontClick(Sender: TObject); begin DoChangeEmojiFont; end;

procedure TTerminalLCLView.ContextPopupShow(Sender: TObject);
var
  AppOwnsClipboard, HasPasteable: Boolean;
begin
  AppOwnsClipboard := (FController <> nil) and FController.Core.BracketedPasteMode;
  { Copy: enabled when we have a selection (local copy) OR when the app owns
    the clipboard (we forward Ctrl+Shift+C and let the app decide). }
  FMiCopy.Enabled := FSelection.Active or AppOwnsClipboard;
  { Paste: enabled when the clipboard holds text — or, for bracketed-paste
    apps that we forward Ctrl+Shift+V to, even an image (the app may want to
    handle it, e.g. attach via OSC 52 or a custom path). }
  HasPasteable := Clipboard.HasFormat(CF_TEXT)
               or Clipboard.HasFormat(CF_PICTURE)
               or Clipboard.HasFormat(CF_BITMAP);
  FMiPaste.Enabled := HasPasteable;
end;

function TTerminalLCLView.GetVirtualLine(AVirtualRow: Integer): TTermCellLine;
var HistCount: Integer;
begin
  HistCount := 0;
  if FController <> nil then HistCount := FController.Core.HistoryCount;
  if (FController = nil) or (AVirtualRow < 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  if AVirtualRow < HistCount then
    Result := FController.Core.GetHistoryLine(AVirtualRow)
  else
    Result := FController.Core.GetLine(AVirtualRow - HistCount);
end;

procedure TTerminalLCLView.HandleScrollBarChange(Sender: TObject);
begin
  FTopRow := FScrollbar.Position;
  Invalidate;
end;

function TTerminalLCLView.GetSelectedTextUTF8: RawByteString;
var
  S, E: TTermCellPos;
  Row, Col: Integer;
  Line: TTermCellLine;
  Cell: TTermCell;
  HistCount, ScreenRows, AllRows: Integer;
  RowStartCol, RowEndCol: Integer;
  LastNonBlank: Integer;
begin
  Result := '';
  if (FController = nil) or not FSelection.Active then Exit;
  S := FSelection.Anchor; E := FSelection.Focus;
  if (S.Row > E.Row) or ((S.Row = E.Row) and (S.Col > E.Col)) then
  begin
    S := FSelection.Focus; E := FSelection.Anchor;
  end;
  HistCount := FController.Core.HistoryCount;
  ScreenRows := FController.Core.Rows;
  AllRows := HistCount + ScreenRows;
  if AllRows <= 0 then Exit;
  S.Row := EnsureRange(S.Row, 0, AllRows - 1);
  E.Row := EnsureRange(E.Row, 0, AllRows - 1);

  for Row := S.Row to E.Row do
  begin
    Line := GetVirtualLine(Row);
    if Length(Line) = 0 then
    begin
      if Row <> E.Row then Result := Result + LineEnding;
      Continue;
    end;
    if Row = S.Row then RowStartCol := EnsureRange(S.Col, 0, High(Line))
    else RowStartCol := 0;
    if Row = E.Row then RowEndCol := EnsureRange(E.Col, 0, High(Line))
    else RowEndCol := High(Line);
    if RowEndCol < RowStartCol then Continue;

    if Row <> E.Row then
    begin
      LastNonBlank := RowEndCol;
      while LastNonBlank >= RowStartCol do
      begin
        Cell := Line[LastNonBlank];
        if tafWideTrail in Cell.Attrs then begin Dec(LastNonBlank); Continue; end;
        if (Cell.Cluster <> '') and (Cell.Cluster <> ' ') then Break;
        Dec(LastNonBlank);
      end;
    end
    else
      LastNonBlank := RowEndCol;

    for Col := RowStartCol to LastNonBlank do
    begin
      Cell := Line[Col];
      if tafWideTrail in Cell.Attrs then Continue;
      if Cell.Cluster <> '' then Result := Result + Cell.Cluster
      else Result := Result + ' ';
    end;

    if Row <> E.Row then Result := Result + LineEnding;
  end;
end;

procedure TTerminalLCLView.Paint;
var
  Row, Col, ViewRows, StartRow: Integer;
  Line: TTermCellLine;
  Cell: TTermCell;
  CursorRect: TRect;
  CursorViewRow: Integer;
  CursorVirtualRow: Integer;
  HostsCursor: Boolean;
begin
  UpdateMetrics;

  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FBackgroundColor;
  Canvas.FillRect(Rect(0, 0, GridWidth, GridHeight));

  if FController = nil then Exit;

  if FController.Core.InAltBuffer then
    FTopRow := FController.Core.HistoryCount;
  ViewRows := RowsVisible;
  StartRow := FTopRow;

  CursorVirtualRow := FController.Core.HistoryCount + FController.Core.Cursor.Row;
  CursorViewRow := CursorVirtualRow - FTopRow;

  for Row := 0 to ViewRows - 1 do
  begin
    Line := GetVirtualLine(StartRow + Row);
    if Length(Line) = 0 then Continue;
    for Col := 0 to Min(High(Line), ColsVisible - 1) do
    begin
      HostsCursor := FController.Core.Cursor.Visible
                 and (FCursorStyle = csBlock)
                 and (FController.Core.Cursor.Col = Col)
                 and (StartRow + Row = CursorVirtualRow);
      Cell := Line[Col];
      PaintCell(Col, Row, Cell, HostsCursor);
    end;
  end;

  if FController.Core.Cursor.Visible and FCursorBlinkVisible
     and (FCursorStyle = csUnderscore)
     and (CursorViewRow >= 0) and (CursorViewRow < ViewRows) then
  begin
    CursorRect := CellRect(FController.Core.Cursor.Col, CursorViewRow);
    Canvas.Brush.Color := TColor($00A0A0A0);
    Canvas.FillRect(Rect(CursorRect.Left, CursorRect.Top + FCharHeight - 2,
                         CursorRect.Left + FCharWidth, CursorRect.Top + FCharHeight));
  end;
end;

procedure TTerminalLCLView.Resize;
begin
  inherited Resize;
end;

procedure TTerminalLCLView.DoOnResize;
var
  WasAtBottom: Boolean;
begin
  inherited DoOnResize;
  if (FController = nil) or (FCharHeight = 0) then Exit;
  WasAtBottom := (FScrollbar.Position >= FScrollbar.Max);
  SyncSizeToController;
  UpdateScrollBar;
  if WasAtBottom then
  begin
    FScrollbar.Position := FScrollbar.Max;
    FTopRow := FScrollbar.Position;
  end;
  Invalidate;
end;

procedure TTerminalLCLView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if FController = nil then Exit;

  case Key of
    VK_RETURN: begin FController.SendKeyEnter; Key := 0; Exit; end;
    VK_HOME:   begin FController.SendInput(#27'[H'); Key := 0; Exit; end;
    VK_END:    begin FController.SendInput(#27'[F'); Key := 0; Exit; end;
    VK_BACK:   begin FController.SendKeyBackspace; Key := 0; Exit; end;
    VK_TAB:    begin FController.SendKeyTab(ssShift in Shift); Key := 0; Exit; end;
    VK_ESCAPE: begin FController.SendKeyEscape; Key := 0; Exit; end;
    VK_UP:     begin FController.SendArrowUp(ssCtrl in Shift); Key := 0; Exit; end;
    VK_DOWN:   begin FController.SendArrowDown(ssCtrl in Shift); Key := 0; Exit; end;
    VK_LEFT:   begin FController.SendArrowLeft(ssCtrl in Shift); Key := 0; Exit; end;
    VK_RIGHT:  begin FController.SendArrowRight(ssCtrl in Shift); Key := 0; Exit; end;
  end;

  { Ctrl+Shift shortcuts. }
  if (Shift = [ssCtrl, ssShift]) then
  begin
    case Key of
      Ord('C'):
        begin
          if FSelection.Active and (not FSelection.Selecting) then
            DoCopy
          else if FSelection.Active and FSelection.Selecting then
            DoCopy
          else
            FController.SendInput(#27'[99;6u');
          Key := 0; Exit;
        end;
      Ord('V'): begin DoPaste; Key := 0; Exit; end;
    end;
  end;

  { Shift+Insert paste. }
  if (Shift = [ssShift]) and (Key = VK_INSERT) then
  begin
    DoPaste; Key := 0; Exit;
  end;

  { Plain Ctrl+letter. }
  if (Shift = [ssCtrl]) then
  begin
    if (Key = Ord('V'))
       and (Clipboard.AsText <> '')
       and FController.Core.BracketedPasteMode then
    begin
      DoPaste; Key := 0; Exit;
    end;
    case Key of
      Ord('A')..Ord('Z'):
        begin
          FController.SendInput(RawByteString(AnsiChar(Key and $1F)));
          Key := 0; Exit;
        end;
      Ord('['): begin FController.SendInput(#27); Key := 0; Exit; end;
      Ord('\'): begin FController.SendInput(#28); Key := 0; Exit; end;
      Ord(']'): begin FController.SendInput(#29); Key := 0; Exit; end;
      Ord('^'): begin FController.SendInput(#30); Key := 0; Exit; end;
      Ord('_'): begin FController.SendInput(#31); Key := 0; Exit; end;
    end;
  end;
end;

procedure TTerminalLCLView.UTF8KeyPress(var UTF8Key: TUTF8Char);
begin
  inherited UTF8KeyPress(UTF8Key);
  if FController = nil then Exit;
  if UTF8Key = '' then Exit;
  if (Length(UTF8Key) = 1) and (UTF8Key[1] < #32) then Exit;
  FController.SendInput(RawByteString(UTF8Key));
  FScrollbar.Position := FScrollbar.Max;
  UTF8Key := '';
end;

function TTerminalLCLView.TryMouseReport(X, Y: Integer; Shift: TShiftState;
  AButton: TTermMouseButton; APressed, AMotion: Boolean): Boolean;
var
  Col, Row: Integer;
  Core: TTerminalCore;
begin
  Result := False;
  if FController = nil then Exit;
  Core := FController.Core;
  if Core.MouseProtocol = tmpNone then Exit;
  if ssShift in Shift then Exit;
  if (FCharWidth <= 0) or (FCharHeight <= 0) then Exit;

  Col := X div FCharWidth;
  Row := Y div FCharHeight;
  if Col < 0 then Col := 0;
  if Row < 0 then Row := 0;
  if Col >= Core.Cols then Col := Core.Cols - 1;
  if Row >= Core.Rows then Row := Core.Rows - 1;

  if AMotion then
  begin
    if (Col = FLastMouseReportCol) and (Row = FLastMouseReportRow) then
      Exit(True);
  end;
  FLastMouseReportCol := Col;
  FLastMouseReportRow := Row;

  Core.SendMouse(AButton, Col, Row, APressed, AMotion,
    ssShift in Shift, ssAlt in Shift, ssCtrl in Shift);
  Result := True;
end;

procedure TTerminalLCLView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  HadSelection: Boolean;
  TermBtn: TTermMouseButton;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus and (not Focused) then SetFocus;

  case Button of
    mbLeft:   TermBtn := tmbLeft;
    mbMiddle: TermBtn := tmbMiddle;
    mbRight:  TermBtn := tmbRight;
  else        TermBtn := tmbLeft;
  end;

  { Right-click default: show the context menu, even when the app has captured
    mouse. Only forward the right-click to the app when YieldRightClickToApp
    is enabled. Other buttons always go through TryMouseReport first. }
  if Button = mbRight then
  begin
    if FYieldRightClickToApp
       and TryMouseReport(X, Y, Shift, TermBtn, True, False) then
      Exit;
    with ClientToScreen(Point(X, Y)) do
      FContextMenu.PopUp(X, Y);
    Exit;
  end;

  if TryMouseReport(X, Y, Shift, TermBtn, True, False) then Exit;

  if Button <> mbLeft then Exit;

  HadSelection := FSelection.Active;
  FSelection.Active := False;
  FSelection.Selecting := False;
  FMouseDownPending := True;
  FMouseDownX := X;
  FMouseDownY := Y;
  FMouseDownAnchor := PixelToCell(X, Y);
  if HadSelection then Invalidate;
end;

procedure TTerminalLCLView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Cell: TTermCellPos;
  Btn: TTermMouseButton;
  HasButton: Boolean;
begin
  inherited MouseMove(Shift, X, Y);

  if (FController <> nil) and (FController.Core.MouseProtocol <> tmpNone)
     and not (ssShift in Shift) then
  begin
    HasButton := True;
    if ssLeft in Shift then Btn := tmbLeft
    else if ssMiddle in Shift then Btn := tmbMiddle
    else if ssRight in Shift then Btn := tmbRight
    else
    begin
      HasButton := False;
      Btn := tmbRelease;
    end;
    if HasButton or (FController.Core.MouseProtocol = tmpAnyEvent) then
      TryMouseReport(X, Y, Shift, Btn, HasButton, True);
    Exit;
  end;

  if not (ssLeft in Shift) then Exit;

  if FMouseDownPending and not FSelection.Selecting then
  begin
    if (Abs(X - FMouseDownX) < SELECTION_DRAG_THRESHOLD)
       and (Abs(Y - FMouseDownY) < SELECTION_DRAG_THRESHOLD) then Exit;
    FSelection.Active := True;
    FSelection.Selecting := True;
    FSelection.Mode := tsmLinear;
    FSelection.Anchor := FMouseDownAnchor;
    FSelection.Focus := FMouseDownAnchor;
    FMouseDownPending := False;
  end;

  if FSelection.Active and FSelection.Selecting then
  begin
    Cell := PixelToCell(X, Y);
    FSelection.Focus := Cell;
    Invalidate;
  end;
end;

procedure TTerminalLCLView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var TermBtn: TTermMouseButton;
begin
  inherited MouseUp(Button, Shift, X, Y);
  case Button of
    mbLeft:   TermBtn := tmbLeft;
    mbMiddle: TermBtn := tmbMiddle;
    mbRight:  TermBtn := tmbRight;
  else        TermBtn := tmbLeft;
  end;
  { Mirror the gate in MouseDown: skip reporting a right-up when we swallowed
    the right-down to show the menu, otherwise the app sees an unbalanced
    release. }
  if (Button = mbRight) and not FYieldRightClickToApp then Exit;
  if TryMouseReport(X, Y, Shift, TermBtn, False, False) then Exit;
  if Button <> mbLeft then Exit;

  FMouseDownPending := False;
  if FSelection.Active and FSelection.Selecting then
  begin
    FSelection.Focus := PixelToCell(X, Y);
    FSelection.Selecting := False;
    Invalidate;
  end;
end;

function TTerminalLCLView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  Pt: TPoint;
  Btn: TTermMouseButton;
  Steps, I, Delta: Integer;
begin
  Pt := ScreenToClient(MousePos);
  if (FController <> nil) and (FController.Core.MouseProtocol <> tmpNone)
     and not (ssShift in Shift) then
  begin
    if WheelDelta > 0 then Btn := tmbWheelUp else Btn := tmbWheelDown;
    Steps := Max(1, Abs(WheelDelta) div 120);
    for I := 1 to Steps do
      TryMouseReport(Pt.X, Pt.Y, Shift, Btn, True, False);
    Exit(True);
  end;
  { LCL wheel: positive = up. Map to scroll-by-rows (3 rows per notch). }
  Delta := -((WheelDelta * 3) div 120);
  if Delta = 0 then
    if WheelDelta > 0 then Delta := -1 else Delta := 1;
  ScrollBy(Delta);
  Result := True;
end;

{ TTerminalLCLForm }

constructor TTerminalLCLForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  SetBounds(100, 100, 900, 600);
  Caption := 'LCL Terminal';
  FTerminalView := TTerminalLCLView.Create(Self);
  FTerminalView.Parent := Self;
  FTerminalView.Align := alClient;
end;

end.
