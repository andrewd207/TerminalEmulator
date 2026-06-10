{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

unit Terminal.View.fpGUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  fpg_base, fpg_main, fpg_widget, fpg_form, fpg_scrollbar, fpg_menu, fpg_dialogs,
  Terminal.Controller, Terminal.Core;

type

  { TTerminalFPGUIView }

  TTerminalFPGUIView = class(TfpgWidget)
  public type
    TCursorStyle = (csBlock, csUnderscore);
  private
    FContextMenu: TfpgPopupMenu;
    FScrollbar: TfpgScrollBar;
    FController: TTerminalController;
    FTimer: TfpgTimer;
    FCursorTimer: TfpgTimer;
    FCursorStyle: TCursorStyle;
    FFontDesc: string;
    FEmojiFontDesc: string;
    FCharWidth: Integer;
    FCharHeight: Integer;
    FTopRow: Integer;
    FCursorBlinkVisible: Boolean;
    FDefaultFGColor: TfpgColor;
    FSelection: TTermSelection;
    FSelectionFGColor: TfpgColor;
    FSelectionBGColor: TfpgColor;
    FOnFontChanged: TNotifyEvent;
    FOnShellExit: TNotifyEvent;
    FYieldRightClickToApp: Boolean;
    FLastMouseReportCol: Integer;
    FLastMouseReportRow: Integer;
    FShellExited: Boolean;
    { Pending mouse-down state: don't begin a selection until the user has
      actually dragged past SELECTION_DRAG_THRESHOLD pixels. Bare clicks do
      not select anything (and clear any prior selection). }
    FMouseDownPending: Boolean;
    FMouseDownX: Integer;
    FMouseDownY: Integer;
    FMouseDownAnchor: TTermCellPos;
    function CellSelected(AVirtualRow, ACol: Integer): Boolean;
    procedure ContextMenuItemClick(Sender: TObject);
    procedure ContextPopupShow(Sender: TObject);
    function SnapshotTitle: string;
    function GetSelectedTextUTF8: RawByteString;
    function GetVirtualLine(AVirtualRow: Integer): TTermCellLine;
    procedure HandleScrollBarScroll(Sender: TObject; position: integer);
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
    function ClientWidth: Integer;
    function CellRect(ACol, ARow: Integer): TfpgRect;
    function MapColor(const AColor: TTermColor; IsBackground: Boolean): TfpgColor;
    function CellText(const ACell: TTermCell): Utf8String;
    function PickFont(const AAttrs: TTermAttrFlags; ACodePoint: Cardinal): TfpgFontResourceBase;
    procedure PaintCell(const ACanvas: TfpgCanvas; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
    function PixelToCell(X, Y: Integer): TTermCellPos;
    function TryMouseReport(x, y: Integer; shiftstate: TShiftState;
      AButton: TTermMouseButton; APressed, AMotion: Boolean): Boolean;
    procedure UpdateScrollBarCoords;
    procedure UpdateScrollBar;
    procedure CreatePopupMenu;
    procedure DoCopy;
    procedure DoPaste;
    procedure DoChangeFont;
    procedure DoChangeEmojiFont;
  protected
    procedure HandlePaint; override;
    procedure HandleResize(AWidth, AHeight: TfpgCoord); override;
    procedure HandleKeyPress(var keycode: word; var shiftstate: TShiftState; var consumed: boolean); override;
    procedure HandleKeyChar(var AText: TfpgChar; var shiftstate: TShiftState; var consumed: boolean); override;
    procedure HandleLMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleMouseMove(x, y: integer; btnstate: word; shiftstate: TShiftState);  override;
    procedure HandleLMouseUp(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleRMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleShow; override;
    procedure HandleMouseScroll(x, y: integer; shiftstate: TShiftState; delta: smallint); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AttachController(AController: TTerminalController);
    procedure DetachController;
    procedure StartShell(const AShell: string = '');
    procedure ScrollBy(ADeltaRows: Integer);

    property Controller: TTerminalController read FController;
    property FontDesc: string read FFontDesc write FFontDesc;
    property EmojiFontDesc: string read FEmojiFontDesc write FEmojiFontDesc;
    property CursorStyle: TCursorStyle read FCursorStyle write FCursorStyle;
    { When True, right-click is forwarded to a mouse-capturing app (?1000/?1003)
      instead of opening the context menu. When False (default) the context
      menu always opens on right-click, even in fullscreen TUIs. }
    property YieldRightClickToApp: Boolean read FYieldRightClickToApp write FYieldRightClickToApp default False;
    property OnFontChanged: TNotifyEvent read FOnFontChanged write FOnFontChanged;
    { Fired once, in the pump-timer context, when the child process exits.
      If unset, the view writes a default banner into the buffer; assigning a
      handler suppresses the default. Handlers may e.g. close the parent form. }
    property OnShellExit: TNotifyEvent read FOnShellExit write FOnShellExit;
    procedure WriteExitBanner;
  end;

  TTerminalFPGUIForm = class(TfpgForm)
  private
    FTerminalView: TTerminalFPGUIView;
  public
    procedure AfterCreate; override;
    property TerminalView: TTerminalFPGUIView read FTerminalView;
  end;

implementation

uses
  Math;


const
  CURSOR_BLINK_MS = 750;
  PUMP_MS = 20;
  SELECTION_DRAG_THRESHOLD = 3; { pixels before mouse-down -> selection }

  CONTEXT_COPY = 0;
  CONTEXT_PASTE = 1;
  CONTEXT_FONT = 2;
  CONTEXT_EMOJI_FONT = 3;
  CONTEXT_COPY_HTML_SEL = 4;
  CONTEXT_COPY_HTML_SCREEN = 5;
  CONTEXT_COPY_HTML_ALL = 6;


constructor TTerminalFPGUIView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Focusable := True;
  //TabStop := True;
  FFontDesc := FPG_DEFAULT_FIXED_FONT_DESC;
  //FFontDesc :=  'DejaVu Sans Mono-13';
  //FFontDesc :=  'Noto Sans Symbols-12';
  FBackgroundColor := clBlack;
  FDefaultFGColor := clWhite;
  FSelectionFGColor := clBlack;
  FSelectionBGColor := $00D7FF;
  FCursorBlinkVisible := True;
  // Created scrollbar before Width is set
  FScrollbar := TfpgScrollBar.Create(Self);
  FScrollbar.Parent := Self;
  FScrollbar.Orientation := orVertical;
  FScrollbar.Align:=alRight;
  FScrollbar.OnScroll:=@HandleScrollBarScroll;
  FTopRow := 0;
  Width := 800;
  Height := 500;
  FTimer := TfpgTimer.Create(PUMP_MS);
  FTimer.Interval := PUMP_MS;
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerFired;
  FCursorTimer := TfpgTimer.Create(CURSOR_BLINK_MS);
  FCursorTimer.Interval := CURSOR_BLINK_MS;
  FCursorTimer.Enabled := True;
  FCursorTimer.OnTimer := @CursorTimerFired;

  CreatePopupMenu;
  UpdateMetrics;
end;

destructor TTerminalFPGUIView.Destroy;
begin
  DetachController;
  FreeAndNil(FTimer);
  FreeAndNil(FCursorTimer);
  inherited Destroy;
end;

procedure TTerminalFPGUIView.AttachController(AController: TTerminalController);
begin
  if FController = AController then
    Exit;

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
  Repaint;
end;

procedure TTerminalFPGUIView.DetachController;
begin
  if FController <> nil then
  begin
    FController.Core.OnInvalidate := nil;
    FController.Core.OnBell := nil;
    FController.Core.OnTitle := nil;
    FController.Core.OnClipboardSet := nil;
    FController.Core.OnClipboardGet := nil;
    FController.Stop;
    FController := nil; // Not managed by the view. it's 'attached' here. So don't free.
  end;
  FTimer.Enabled := False;
end;

procedure TTerminalFPGUIView.StartShell(const AShell: string);
begin
  if FController <> nil then
  begin
    SyncSizeToController;
    FController.StartShell(AShell, []);
    { PTY fd is now open — send TIOCSWINSZ with the view's actual current
      dimensions.  All earlier Resize calls silently failed because FMasterFD
      was -1; this is the first one that reaches the kernel. }
    SyncSizeToController;
  end;
end;

procedure TTerminalFPGUIView.ScrollBy(ADeltaRows: Integer);
var
  MaxTop: Integer;
begin
  if FController = nil then
    Exit;
  {MaxTop := Max(0, FController.Core.Rows - RowsVisible);
  FScrollbar.Position := EnsureRange(FTopRow + ADeltaRows, 0, MaxTop);
  FTopRow := FScrollbar.Position;}
  FScrollbar.Position := FScrollbar.Position+ADeltaRows;
  Repaint;
end;

procedure TTerminalFPGUIView.WriteExitBanner;
const
  EXIT_BANNER: RawByteString =
    #27'[0m'#13#10#27'[7m[ process exited - close window ]'#27'[0m'#13#10;
begin
  if FController = nil then Exit;
  FController.Parser.FeedBytes(EXIT_BANNER);
  if (Parent <> nil) and (Parent is TTerminalFPGUIForm)
     and (TTerminalFPGUIForm(Parent).WindowTitle <> '') then
    TTerminalFPGUIForm(Parent).WindowTitle :=
      TTerminalFPGUIForm(Parent).WindowTitle + ' [exited]';
end;

procedure TTerminalFPGUIView.TimerFired(Sender: TObject);
begin
  if FController = nil then Exit;

  if FController.Pump > 0 then
  begin
    FCursorBlinkVisible := True;
    FCursorTimer.Reset;
    FCursorTimer.Enabled := True;
    UpdateScrollBar;
    FScrollbar.Position := FScrollbar.Max;
    FTopRow := FScrollbar.Position;
    if not FController.Core.InSyncUpdate then
      Repaint;
  end;

  { Detect child exit. Pump's IsRunning check reaps the process; once it
    returns False, drain any remaining bytes, fire OnShellExit, stop polling.
    If no handler is wired, write the default banner so the user sees
    *something*. The handler may e.g. close the parent form instead. }
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
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.CursorTimerFired(Sender: TObject);
begin
  if FController <> nil then
  begin
    FCursorBlinkVisible := not FCursorBlinkVisible;
    Repaint;
  end;
end;


procedure TTerminalFPGUIView.CoreInvalidate(Sender: TObject; const ARect: TTermRect);
var
  L, T, W, H: Integer;
  HistCount: Integer;
  SelMinVRow, SelMaxVRow: Integer;
begin
  UpdateMetrics;

  HistCount := 0;
  if FController <> nil then
    HistCount := FController.Core.HistoryCount;

  { Drop the entire selection if the invalidated region overlaps any cell of
    it. ARect is in screen-relative rows (0..Rows-1); selection rows are
    virtual (history + screen), so map by adding HistCount. We only need
    row-overlap because new writes touch whole columns conservatively
    enough that any row-overlap is "part of the selection got overwritten". }
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

  L := ARect.Left * FCharWidth;
  T := (HistCount + ARect.Top - FTopRow) * FCharHeight;
  W := (ARect.Right - ARect.Left + 1) * FCharWidth;
  H := (ARect.Bottom - ARect.Top + 1) * FCharHeight;

  if (W <= 0) or (H <= 0) then
    Exit;

  if T + H <= 0 then
    Exit;

  if T >= ActualHeight then
    Exit;

  if L < 0 then
  begin
    W := W + L;
    L := 0;
  end;

  if T < 0 then
  begin
    H := H + T;
    T := 0;
  end;

  if L + W > ClientWidth then
    W := ClientWidth - L;

  if T + H > ActualHeight then
    H := ActualHeight - T;

  if (W > 0) and (H > 0) then
    { HandlePaint repaints every visible cell in one pass; if we only invalidate
      the changed rect, fpGUI clips the rest away and the prior contents of those
      cells stay on screen.  Invalidate the entire client area so the full grid
      gets repainted.  (Resize works precisely because it triggers a full
      invalidate.) }
    Invalidate;
end;

procedure TTerminalFPGUIView.CoreBell(Sender: TObject);
begin
  // ding :)
end;

procedure TTerminalFPGUIView.CoreTitle(Sender: TObject; const ATitle: string);
begin
  if (Parent <> nil)
  and (Parent is TTerminalFPGUIForm)
  and (TTerminalFPGUIForm(Parent).WindowTitle <> '') then
    TTerminalFPGUIForm(Parent).WindowTitle := ATitle;
end;

procedure TTerminalFPGUIView.CoreClipboardSet(Sender: TObject;
  const ATargets: string; const AText: RawByteString);
begin
  { OSC 52 write from the app (e.g. Claude Code's Ctrl+Shift+C). }
  fpgClipboard.Text := UTF8String(AText);
end;

procedure TTerminalFPGUIView.CoreClipboardGet(Sender: TObject;
  const ATargets: string; out AText: RawByteString);
begin
  AText := RawByteString(fpgClipboard.Text);
end;

procedure TTerminalFPGUIView.UpdateMetrics;
var
  RowsPerPage: Integer;
begin
  Canvas.SetFont(fpgApplication.FontManager.GetFont(FFontDesc));
  FCharHeight := Max(1, Canvas.Font.GetHeight);
  FCharWidth := Max(1, Canvas.Font.GetTextWidth('M'));

  RowsPerPage := Max(1, ActualHeight div FCharHeight);
  UpdateScrollBar;
  UpdateScrollBarCoords;
end;


procedure TTerminalFPGUIView.UpdateScrollBarCoords;
var
  VHeight: Integer;
begin
  VHeight := ActualHeight;
  FScrollBar.Top     := 0;
  FScrollBar.Left    := ActualWidth - FScrollBar.ActualWidth;
  FScrollBar.Height  := VHeight;
  FScrollBar.UpdatePosition;
end;

procedure TTerminalFPGUIView.UpdateScrollBar;
var
  TotalRows: Integer;
  VisibleCount: Integer;
begin
  if FController = nil then
    Exit;

  VisibleCount := Max(1, RowsVisible);
  TotalRows := FController.Core.HistoryCount + FController.Core.Rows;

  FScrollBar.Min := 0;
  FScrollBar.PageSize := VisibleCount;
  FScrollBar.Max := Max(0, TotalRows - VisibleCount);

  if FScrollBar.Position > FScrollBar.Max then
    FScrollBar.Position := FScrollBar.Max;

  FTopRow := FScrollBar.Position;
end;

procedure TTerminalFPGUIView.CreatePopupMenu;
begin
  FContextMenu := TfpgPopupMenu.Create(Self);
  FContextMenu.AddMenuItem('Copy', 'Ctrl+Shift+C', @ContextMenuItemClick).Tag:=CONTEXT_COPY;
  FContextMenu.AddMenuItem('Paste', 'Shift+Ins', @ContextMenuItemClick).Tag:=CONTEXT_PASTE;
  FContextMenu.AddSeparator;
  FContextMenu.AddMenuItem('Font', '', @ContextMenuItemClick).Tag:=CONTEXT_FONT;
  FContextMenu.AddMenuItem('Emoji Font', '', @ContextMenuItemClick).Tag:=CONTEXT_EMOJI_FONT;
  FContextMenu.AddSeparator;
  FContextMenu.AddMenuItem('Copy Selection as HTML', '', @ContextMenuItemClick).Tag:=CONTEXT_COPY_HTML_SEL;
  FContextMenu.AddMenuItem('Copy Screen as HTML', '', @ContextMenuItemClick).Tag:=CONTEXT_COPY_HTML_SCREEN;
  FContextMenu.AddMenuItem('Copy Everything (incl. scrollback) as HTML', '', @ContextMenuItemClick).Tag:=CONTEXT_COPY_HTML_ALL;
  FContextMenu.OnShow:=@ContextPopupShow;
end;

procedure TTerminalFPGUIView.DoCopy;
begin
  fpgClipboard.Text:= GetSelectedTextUTF8;
end;

procedure TTerminalFPGUIView.DoPaste;
var
  Text: TfpgString;
begin
  if (FController = nil) or (fpgClipboard.Text = '') then
    Exit;

  Text := fpgClipboard.Text;
  Text :=StringReplace(Text, #13#10, #10, [rfReplaceAll]);
  Text :=StringReplace(Text, #13, #10, [rfReplaceAll]);

  if Controller.Core.BracketedPasteMode then // so a program handles it as a block not a string of input
    Text := #27'[200~' + Text + #27'[201~';



  FController.SendInput(Text);
end;

procedure TTerminalFPGUIView.DoChangeFont;
var
  S: String;
begin
  S := FFontDesc;
  if SelectFontDialog(S) then
  begin
     FontDesc:=S;
     if Assigned(FOnFontChanged) then
       FOnFontChanged(Self);
  end;
  UpdateMetrics;
  SyncSizeToController;
end;

procedure TTerminalFPGUIView.DoChangeEmojiFont;
var
  S: String;
begin
  S := FEmojiFontDesc;
  if SelectFontDialog(S) then
  begin
    FEmojiFontDesc := S;
    if Assigned(FOnFontChanged) then
      FOnFontChanged(Self);
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.SyncSizeToController;
var
  Cols, Rows: Integer;
begin
  if FController = nil then
    Exit;
  UpdateMetrics;
  Cols := Max(1, ClientWidth div FCharWidth);
  Rows := Max(1, ActualHeight div FCharHeight);
  FController.Resize(Cols, Rows);
end;

function TTerminalFPGUIView.RowsVisible: Integer;
begin
  Result := Max(1, ActualHeight div FCharHeight);
end;

function TTerminalFPGUIView.ColsVisible: Integer;
begin
  Result := Max(1, ClientWidth div FCharWidth);
end;

function TTerminalFPGUIView.ClientWidth: Integer;
begin
  Result:= ActualWidth - FScrollbar.ActualWidth;
end;

function TTerminalFPGUIView.CellRect(ACol, ARow: Integer): TfpgRect;
begin
  Result.SetRect(ACol * FCharWidth, ARow * FCharHeight, FCharWidth, FCharHeight);
end;

function TTerminalFPGUIView.MapColor(const AColor: TTermColor; IsBackground: Boolean): TfpgColor;
var
  RGB: Cardinal;
begin
  case AColor.Mode of
    tcmIndexed, tcmRGB:
      begin
        RGB := TermColorToRGB(AColor);
        Result := TfpgColor($FF000000) or TfpgColor(RGB);
      end;
  else
    if IsBackground then
      Result := FBackgroundColor
    else
      Result := FDefaultFGColor;
  end;
end;

function IsEmojiCodePoint(CP: Cardinal): Boolean; inline;
begin
  Result :=
    ((CP >= $2600)  and (CP <= $27BF))  or  // misc symbols + dingbats
    ((CP >= $1F300) and (CP <= $1F6FF)) or  // pictographs/transport
    ((CP >= $1F900) and (CP <= $1F9FF)) or  // supplemental symbols/emoji
    ((CP >= $1FA70) and (CP <= $1FAFF));    // symbols & pictographs ext-A
end;

function TTerminalFPGUIView.PickFont(const AAttrs: TTermAttrFlags; ACodePoint: Cardinal): TfpgFontResourceBase;
var
  Desc: string;
begin
  if (FEmojiFontDesc <> '') and IsEmojiCodePoint(ACodePoint) then
  begin
    Result := fpgApplication.FontManager.GetFont(FEmojiFontDesc);
    if Result <> nil then Exit;
  end;
  Desc := FFontDesc;
  if tafBold in AAttrs then Desc := Desc + ':bold';
  if tafItalic in AAttrs then Desc := Desc + ':italic';
  Result := fpgApplication.FontManager.GetFont(Desc);
  if Result = nil then
    Result := fpgApplication.FontManager.GetFont(FFontDesc);
end;

function TTerminalFPGUIView.CellText(const ACell: TTermCell): utf8string;
begin
  if ACell.Cluster <> '' then
    Result := ACell.Cluster
  else
    Result := ' ';
end;

procedure TTerminalFPGUIView.PaintCell(const ACanvas: TfpgCanvas; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
var
  R: TfpgRect;
  FG, BG: TfpgColor;
  S: utf8string;
  VirtualRow: Integer;
  IsSelected: Boolean;
begin
  if tafWideTrail in ACell.Attrs then
    Exit;

  VirtualRow := FTopRow + AViewRow;
  IsSelected := CellSelected(VirtualRow, ACol);

  R := CellRect(ACol, AViewRow);
  BG := MapColor(ACell.BG, True);
  FG := MapColor(ACell.FG, False);

  if tafFaint in ACell.Attrs then
    FG := TfpgColor($FF000000)
       or ((FG and $FE0000) shr 1)
       or ((FG and $00FE00) shr 1)
       or ((FG and $0000FE) shr 1);

  if tafInverse in ACell.Attrs then
    specialize Swap<TfpgColor>(FG, BG);

  if tafHidden in ACell.Attrs then
    FG := BG;

  if IsSelected then
  begin
    BG := FSelectionBGColor;
    FG := FSelectionFGColor;
  end;

  if AHasCursor and (FCursorBlinkVisible) then
    specialize Swap<TfpgColor>(FG, BG);

  if tafWideLead in ACell.Attrs then
    R.Width := FCharWidth * 2;

  ACanvas.Color := BG;
  ACanvas.FillRectangle(R);

  // Blink: hide glyph (and decorations) during off phase.
  if (tafBlink in ACell.Attrs) and (not FCursorBlinkVisible) then
    Exit;

  if not ACell.isBlank then
  begin
    S := CellText(ACell);
    ACanvas.SetFont(PickFont(ACell.Attrs, ACell.CodePoint));
    ACanvas.TextColor := FG;
    ACanvas.DrawString(R.Left, R.Top, S);
  end;

  if (tafUnderline in ACell.Attrs) or (tafStrike in ACell.Attrs) then
  begin
    ACanvas.Color := FG;
    if tafUnderline in ACell.Attrs then
      ACanvas.DrawLine(R.Left, R.Bottom, R.Right, R.Bottom);
    if tafStrike in ACell.Attrs then
      ACanvas.DrawLine(R.Left, R.Top + R.Height div 2,
                       R.Right, R.Top + R.Height div 2);
  end;
end;

function TTerminalFPGUIView.PixelToCell(X, Y: Integer): TTermCellPos;
begin
  Result.Col := EnsureRange(X div FCharWidth, 0, ColsVisible - 1);
  Result.Row := FTopRow + EnsureRange(Y div FCharHeight, 0, RowsVisible - 1);
end;

function TTerminalFPGUIView.CellSelected(AVirtualRow, ACol: Integer): Boolean;
var
  S, E: TTermCellPos;
begin
  Result := False;
  if not FSelection.Active then
    Exit;

  S := FSelection.Anchor;
  E := FSelection.Focus;

  if (S.Row > E.Row) or ((S.Row = E.Row) and (S.Col > E.Col)) then
  begin
    S := FSelection.Focus;
    E := FSelection.Anchor;
  end;

  if (AVirtualRow < S.Row) or (AVirtualRow > E.Row) then
    Exit(False);

  if S.Row = E.Row then
    Exit((AVirtualRow = S.Row) and (ACol >= S.Col) and (ACol <= E.Col));

  if AVirtualRow = S.Row then
    Exit(ACol >= S.Col);

  if AVirtualRow = E.Row then
    Exit(ACol <= E.Col);

  Result := True;
end;

procedure TTerminalFPGUIView.ContextMenuItemClick(Sender: TObject);
begin
  case (Sender as TfpgMenuItem).Tag of
    CONTEXT_COPY: DoCopy;
    CONTEXT_PASTE: DoPaste;
    CONTEXT_FONT: DoChangeFont;
    CONTEXT_EMOJI_FONT: DoChangeEmojiFont;
    CONTEXT_COPY_HTML_SEL:
      if (FController <> nil) and FSelection.Active then
        fpgClipboard.Text := FController.Core.GetHtmlSelection(FSelection, SnapshotTitle);
    CONTEXT_COPY_HTML_SCREEN:
      if FController <> nil then
        fpgClipboard.Text := FController.Core.GetHtmlScreen(SnapshotTitle);
    CONTEXT_COPY_HTML_ALL:
      if FController <> nil then
        fpgClipboard.Text := FController.Core.GetHtmlAll(SnapshotTitle);
  end;
end;

procedure TTerminalFPGUIView.ContextPopupShow(Sender: TObject);
begin
  FContextMenu.MenuItemByName('Copy').Enabled:=FSelection.Active;
  FContextMenu.MenuItemByName('Paste').Enabled:=fpgClipboard.Text <> '';
  FContextMenu.MenuItemByName('Copy Selection as HTML').Enabled:=FSelection.Active;
end;

function TTerminalFPGUIView.SnapshotTitle: string;
begin
  if (Parent <> nil) and (Parent is TTerminalFPGUIForm) then
    Result := TTerminalFPGUIForm(Parent).WindowTitle
  else
    Result := '';
end;

function TTerminalFPGUIView.GetVirtualLine(AVirtualRow: Integer): TTermCellLine;
var
  HistCount: Integer;
begin
  HistCount := 0;
  if FController <> nil then
    HistCount := FController.Core.HistoryCount;

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

procedure TTerminalFPGUIView.HandleScrollBarScroll(Sender: TObject;
  position: integer);
begin
  FTopRow:=FScrollbar.Position;
  Repaint;

  //WriteLn(Format('Page = %d ; Max = %d ; Position = %d ; History = %d ; Top = %d', [RowsVisible, FScrollbar.Max, FScrollbar.Position, FController.Core.HistoryCount, FTopRow]));
end;


function TTerminalFPGUIView.GetSelectedTextUTF8: RawByteString;
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
  if (FController = nil) or not FSelection.Active then
    Exit;

  S := FSelection.Anchor;
  E := FSelection.Focus;

  if (S.Row > E.Row) or ((S.Row = E.Row) and (S.Col > E.Col)) then
  begin
    S := FSelection.Focus;
    E := FSelection.Anchor;
  end;

  HistCount := FController.Core.HistoryCount;
  ScreenRows := FController.Core.Rows;
  AllRows := HistCount + ScreenRows;

  if AllRows <= 0 then
    Exit;

  S.Row := EnsureRange(S.Row, 0, AllRows - 1);
  E.Row := EnsureRange(E.Row, 0, AllRows - 1);

  for Row := S.Row to E.Row do
  begin
    Line := GetVirtualLine(Row);
    if Length(Line) = 0 then
    begin
      if Row <> E.Row then
        Result := Result + LineEnding;
      Continue;
    end;

    if Row = S.Row then
      RowStartCol := EnsureRange(S.Col, 0, High(Line))
    else
      RowStartCol := 0;

    if Row = E.Row then
      RowEndCol := EnsureRange(E.Col, 0, High(Line))
    else
      RowEndCol := High(Line);

    if RowEndCol < RowStartCol then
      Continue;

    if Row <> E.Row then
    begin
      LastNonBlank := RowEndCol;
      while LastNonBlank >= RowStartCol do
      begin
        Cell := Line[LastNonBlank];
        if (tafWideTrail in Cell.Attrs) then
        begin
          Dec(LastNonBlank);
          Continue;
        end;
        if (Cell.Cluster <> '') and (Cell.Cluster <> ' ') then
          Break;
        Dec(LastNonBlank);
      end;
    end
    else
      LastNonBlank := RowEndCol;

    for Col := RowStartCol to LastNonBlank do
    begin
      Cell := Line[Col];
      if tafWideTrail in Cell.Attrs then
        Continue;

      if Cell.Cluster <> '' then
        Result := Result + Cell.Cluster
      else
        Result := Result + ' ';
    end;

    if Row <> E.Row then
      Result := Result + LineEnding;
  end;
end;

procedure TTerminalFPGUIView.HandlePaint;
var
  Row, Col, ViewRows, StartRow: Integer;
  Line: TTermCellLine;
  Cell: TTermCell;
  CursorRect: TfpgRect;
  CursorViewRow: Integer;
  CursorVirtualRow: Integer;
  HostsCursor: Boolean;
begin
  inherited HandlePaint;
  UpdateMetrics;

  Canvas.BeginDraw;
  try
    Canvas.Color := FBackgroundColor;
    Canvas.FillRectangle(0, 0, ClientWidth, ActualHeight);
    Canvas.SetFont(fpgApplication.FontManager.GetFont(FFontDesc));

    if FController <> nil then
    begin
      if FController.Core.InAltBuffer then
        FTopRow := FController.Core.HistoryCount;
      ViewRows := RowsVisible;
      StartRow := FTopRow;

      CursorVirtualRow := FController.Core.HistoryCount + FController.Core.Cursor.Row;
      CursorViewRow := CursorVirtualRow - FTopRow;

      for Row := 0 to ViewRows - 1 do
      begin
        Line := GetVirtualLine(StartRow + Row);
        if Length(Line) = 0 then
          Continue;

        for Col := 0 to Min(High(Line), ColsVisible - 1) do
        begin
          HostsCursor := FController.Core.Cursor.Visible
                    and (FCursorStyle = csBlock)
                    and (FController.Core.Cursor.Col = Col)
                    and (StartRow+Row = CursorVirtualRow);
          Cell := Line[Col];
          PaintCell(Canvas, Col, Row, Cell, HostsCursor);
        end;
      end;

      if FController.Core.Cursor.Visible and FCursorBlinkVisible then
      begin
        // Set Above
        //CursorVirtualRow := FController.Core.HistoryCount + FController.Core.Cursor.Row;
        //CursorViewRow := CursorVirtualRow - FTopRow;

        if (CursorViewRow >= 0) and (CursorViewRow < ViewRows) then
        begin
          CursorRect := CellRect(FController.Core.Cursor.Col, CursorViewRow);
          Canvas.Color := $00A0A0A0;
          case FCursorStyle of
            csUnderscore:
              Canvas.FillRectangle(CursorRect.Left, CursorRect.Top + FCharHeight - 2, FCharWidth, 2);
            csBlock:
              begin
                //Canvas.FillRectangle(CursorRect.Left, CursorRect.Top, FCharWidth, FCharHeight);
              end;
          end;
        end;
      end;
    end;
  finally
    Canvas.EndDraw;
  end;
end;

procedure TTerminalFPGUIView.HandleResize(AWidth, AHeight: TfpgCoord);
var
  WasAtBottom: Boolean;
begin
  inherited HandleResize(AWidth, AHeight);
  if FController = nil then Exit;
  WasAtBottom := (FScrollBar.Position >= FScrollBar.Max);
  SyncSizeToController;
  UpdateScrollBarCoords;
  UpdateScrollBar;
  if WasAtBottom then
  begin
    FScrollBar.Position := FScrollBar.Max;
    FTopRow := FScrollBar.Position;
  end;
  Repaint;
end;

{ Encode shift/alt/ctrl as the xterm modifyOtherKeys parameter (1..8).
  Bit 0 = Shift, bit 1 = Alt, bit 2 = Ctrl, then +1. }
function XtermModParam(shiftstate: TShiftState): Integer;
begin
  Result := 1;
  if ssShift in shiftstate then Inc(Result, 1);
  if ssAlt   in shiftstate then Inc(Result, 2);
  if ssCtrl  in shiftstate then Inc(Result, 4);
end;

function HasMod(shiftstate: TShiftState): Boolean; inline;
begin
  Result := [ssCtrl, ssShift, ssAlt] * shiftstate <> [];
end;

{ Cursor / Home / End / F1-F4 style: CSI <final> or CSI 1;<mod> <final>.
  F1-F4 normally use SS3 (ESC O P/Q/R/S); with a modifier xterm switches
  to the CSI form (ESC [1;<mod>P). Pass AUseSS3=True for F1-F4. }
procedure SendCSIFinal(ACtrl: TTerminalController; AFinal: AnsiChar;
  shiftstate: TShiftState; AUseSS3: Boolean = False);
begin
  if HasMod(shiftstate) then
    ACtrl.SendInput(#27'[1;' + IntToStr(XtermModParam(shiftstate)) + AFinal)
  else if AUseSS3 then
    ACtrl.SendInput(#27'O' + AFinal)
  else
    ACtrl.SendInput(#27'[' + AFinal);
end;

{ Tilde-terminated CSI: CSI <n> ~ or CSI <n> ; <mod> ~. Used for
  Insert(2), Delete(3), PageUp(5), PageDown(6), F5(15), F6-F12(17-24). }
procedure SendCSITilde(ACtrl: TTerminalController; N: Integer;
  shiftstate: TShiftState);
begin
  if HasMod(shiftstate) then
    ACtrl.SendInput(#27'[' + IntToStr(N) + ';'
      + IntToStr(XtermModParam(shiftstate)) + '~')
  else
    ACtrl.SendInput(#27'[' + IntToStr(N) + '~');
end;

procedure TTerminalFPGUIView.HandleKeyPress(var keycode: word; var shiftstate: TShiftState; var consumed: boolean);
begin
  inherited HandleKeyPress(keycode, shiftstate, consumed);
  if FController = nil then
    Exit;

  { Shift+Insert is the unconditional paste escape hatch — check before
    routing Insert to the PTY. Ctrl+Shift+V is handled further down. }
  if (keycode = keyInsert) and (shiftstate = [ssShift]) then
  begin
    DoPaste;
    consumed := True;
    Exit;
  end;

  case keycode of
    keyReturn, keyPEnter:
      begin FController.SendKeyEnter; consumed := True; end;
    keyBackSpace:
      begin FController.SendKeyBackspace; consumed := True; end;
    keyTab:
      begin FController.SendKeyTab(ssShift in shiftstate); consumed := True; end;
    keyEscape:
      begin FController.SendKeyEscape; consumed := True; end;

    keyUp:       begin SendCSIFinal(FController, 'A', shiftstate); consumed := True; end;
    keyDown:     begin SendCSIFinal(FController, 'B', shiftstate); consumed := True; end;
    keyRight:    begin SendCSIFinal(FController, 'C', shiftstate); consumed := True; end;
    keyLeft:     begin SendCSIFinal(FController, 'D', shiftstate); consumed := True; end;
    keyHome:     begin SendCSIFinal(FController, 'H', shiftstate); consumed := True; end;
    keyEnd:      begin SendCSIFinal(FController, 'F', shiftstate); consumed := True; end;

    keyInsert:   begin SendCSITilde(FController, 2, shiftstate); consumed := True; end;
    keyDelete:   begin SendCSITilde(FController, 3, shiftstate); consumed := True; end;
    keyPageUp:   begin SendCSITilde(FController, 5, shiftstate); consumed := True; end;
    keyPageDown: begin SendCSITilde(FController, 6, shiftstate); consumed := True; end;

    keyF1: begin SendCSIFinal(FController, 'P', shiftstate, True); consumed := True; end;
    keyF2: begin SendCSIFinal(FController, 'Q', shiftstate, True); consumed := True; end;
    keyF3: begin SendCSIFinal(FController, 'R', shiftstate, True); consumed := True; end;
    keyF4: begin SendCSIFinal(FController, 'S', shiftstate, True); consumed := True; end;
    keyF5:  begin SendCSITilde(FController, 15, shiftstate); consumed := True; end;
    keyF6:  begin SendCSITilde(FController, 17, shiftstate); consumed := True; end;
    keyF7:  begin SendCSITilde(FController, 18, shiftstate); consumed := True; end;
    keyF8:  begin SendCSITilde(FController, 19, shiftstate); consumed := True; end;
    keyF9:  begin SendCSITilde(FController, 20, shiftstate); consumed := True; end;
    keyF10: begin SendCSITilde(FController, 21, shiftstate); consumed := True; end;
    keyF11: begin SendCSITilde(FController, 23, shiftstate); consumed := True; end;
    keyF12: begin SendCSITilde(FController, 24, shiftstate); consumed := True; end;
  else
    // Ctrl codes Ctrl+c etc
    if ([ssCtrl] = shiftstate) then
    begin
      { Convenience: Ctrl+V pastes when the clipboard holds text AND the
        app has opted into bracketed paste (?2004). That mode is the app
        explicitly saying "I handle paste blocks", so it's safe to route
        Ctrl+V there. Apps that don't enable it (rare full-screen TUIs
        without paste awareness) still see the raw ^V byte.
        Shift+Insert is always an unconditional paste escape hatch. }
      if (keycode = Ord('V'))
         and (fpgClipboard.Text <> '')
         and FController.Core.BracketedPasteMode then
      begin
        DoPaste;
        consumed := True;
        Exit;
      end;
      consumed:=True;
      case keycode of
        keyA..keyZ: FController.SendInput(RawByteString(AnsiChar(keycode and $1F)));
        Ord('['): FController.SendInput(RawByteString(AnsiChar(#27)));
        Ord('\'): FController.SendInput(RawByteString(AnsiChar(#28)));
        Ord(']'): FController.SendInput(RawByteString(AnsiChar(#29)));
        Ord('^'): FController.SendInput(RawByteString(AnsiChar(#30)));
        Ord('_'): FController.SendInput(RawByteString(AnsiChar(#31)));
      else
        consumed:=False;
      end;
      Exit;
    end;

    // Ctrl+Shift shortcuts (copy/paste)
    if [ssShift, ssCtrl] = shiftstate then
    begin
      case keycode of
        Ord('C'):
          begin
            { Only intercept Ctrl+Shift+C when we have a terminal selection.
              Otherwise forward to the PTY (as a CSI u "modifyOtherKeys"
              sequence) so apps like Claude Code can grab their own selection
              and ship it via OSC 52. }
            if FSelection.Active and FSelection.Selecting then
              DoCopy
            else
              FController.SendInput(#27'[99;6u');
            consumed := True;
            Exit;
          end;
        Ord('V'):
          begin
            DoPaste;
            consumed := True;
            Exit;
          end;
      end;
    end;

    { Printable characters are dispatched via HandleKeyChar, which gives us
      the layout-translated character; we don't synthesise from keycode. }
  end;
end;

procedure TTerminalFPGUIView.HandleKeyChar(var AText: TfpgChar;
  var shiftstate: TShiftState; var consumed: boolean);
begin
  if FController = nil then Exit;
  if AText = '' then Exit;
  { Drop control-code byte 0..31 — those are handled in HandleKeyPress so
    Ctrl+letter combinations don't double-fire. }
  if (Length(AText) = 1) and (AText[1] < #32) then Exit;
  FController.SendInput(RawByteString(AText));
  FScrollbar.Position := FScrollbar.Max;
  consumed := True;
end;

function TTerminalFPGUIView.TryMouseReport(x, y: Integer; shiftstate: TShiftState;
  AButton: TTermMouseButton; APressed, AMotion: Boolean): Boolean;
var
  Col, Row: Integer;
  Core: TTerminalCore;
begin
  Result := False;
  if FController = nil then Exit;
  Core := FController.Core;
  if Core.MouseProtocol = tmpNone then Exit;
  { Shift bypasses mouse reporting so the user can select/right-click as usual. }
  if ssShift in shiftstate then Exit;
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
    begin
      Result := True;
      Exit;
    end;
  end;
  FLastMouseReportCol := Col;
  FLastMouseReportRow := Row;

  Core.SendMouse(AButton, Col, Row, APressed, AMotion,
    ssShift in shiftstate, ssAlt in shiftstate, ssCtrl in shiftstate);
  Result := True;
end;

procedure TTerminalFPGUIView.HandleLMouseDown(x, y: integer;
  shiftstate: TShiftState);
var
  HadSelection: Boolean;
begin
  { Close any open context menu first. fpGUI on Windows doesn't always
    dismiss popups on a click into the owning widget. }
  if (FContextMenu <> nil) and (FContextMenu.Window <> nil)
     and FContextMenu.Window.HasHandle then
    FContextMenu.Close;
  if TryMouseReport(x, y, shiftstate, tmbLeft, True, False) then Exit;
  { Clear any prior selection on a fresh click. We don't activate a new
    selection here -- that waits until the mouse has actually moved past
    SELECTION_DRAG_THRESHOLD pixels (see HandleMouseMove). }
  HadSelection := FSelection.Active;
  FSelection.Active := False;
  FSelection.Selecting := False;
  FMouseDownPending := True;
  FMouseDownX := X;
  FMouseDownY := Y;
  FMouseDownAnchor := PixelToCell(x, y);
  if HadSelection then
    Repaint;
end;

procedure TTerminalFPGUIView.HandleMouseMove(x, y: integer; btnstate: word;
  shiftstate: TShiftState);
var
  Cell: TTermCellPos;
  Btn: TTermMouseButton;
  HasButton: Boolean;
begin
  inherited HandleMouseMove(x, y, btnstate, shiftstate);

  if (FController <> nil) and (FController.Core.MouseProtocol <> tmpNone)
     and not (ssShift in shiftstate) then
  begin
    HasButton := True;
    if (btnstate and MOUSE_LEFT) <> 0 then
      Btn := tmbLeft
    else if (btnstate and MOUSE_MIDDLE) <> 0 then
      Btn := tmbMiddle
    else if (btnstate and MOUSE_RIGHT) <> 0 then
      Btn := tmbRight
    else
    begin
      HasButton := False;
      Btn := tmbRelease; { motion-without-button is encoded as button 3 |32 }
    end;
    if HasButton or (FController.Core.MouseProtocol = tmpAnyEvent) then
      TryMouseReport(x, y, shiftstate, Btn, HasButton, True);
    Exit;
  end;

  if (btnstate and MOUSE_LEFT) = 0 then
    Exit;

  { Latch from pending into an active drag-selection once the mouse moves
    past the threshold. }
  if FMouseDownPending and not FSelection.Selecting then
  begin
    if (Abs(X - FMouseDownX) < SELECTION_DRAG_THRESHOLD)
       and (Abs(Y - FMouseDownY) < SELECTION_DRAG_THRESHOLD) then
      Exit;
    FSelection.Active := True;
    FSelection.Selecting := True;
    FSelection.Mode := tsmLinear;
    FSelection.Anchor := FMouseDownAnchor;
    FSelection.Focus := FMouseDownAnchor;
    FMouseDownPending := False;
  end;

  if FSelection.Active and FSelection.Selecting then
  begin
    Cell := PixelToCell(x, y);
    FSelection.Focus := Cell;
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.HandleLMouseUp(x, y: integer;
  shiftstate: TShiftState);
begin
  if TryMouseReport(x, y, shiftstate, tmbLeft, False, False) then Exit;
  FMouseDownPending := False;
  if FSelection.Active and FSelection.Selecting then
  begin
    FSelection.Focus := PixelToCell(x, y);
    FSelection.Selecting := False;
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.HandleRMouseDown(x, y: integer;
  shiftstate: TShiftState);
begin
  inherited HandleRMouseDown(x, y, shiftstate);
  { Default: show the context menu, even when the app has captured mouse.
    Only forward the right-click to the app when YieldRightClickToApp is set. }
  if FYieldRightClickToApp
     and TryMouseReport(x, y, shiftstate, tmbRight, True, False) then
    Exit;
  FContextMenu.ShowAt(Self, x,y, True);
end;

procedure TTerminalFPGUIView.HandleShow;
begin
  inherited HandleShow;
  UpdateMetrics;
  SyncSizeToController;
end;

procedure TTerminalFPGUIView.HandleMouseScroll(x, y: integer;
  shiftstate: TShiftState; delta: smallint);
var
  Btn: TTermMouseButton;
  I, Steps: Integer;
begin
  if (FController <> nil) and (FController.Core.MouseProtocol <> tmpNone)
     and not (ssShift in shiftstate) then
  begin
    if delta < 0 then Btn := tmbWheelUp else Btn := tmbWheelDown;
    Steps := Abs(delta);
    if Steps < 1 then Steps := 1;
    for I := 1 to Steps do
      TryMouseReport(x, y, shiftstate, Btn, True, False);
    Exit;
  end;
  ScrollBy(delta);
end;

procedure TTerminalFPGUIForm.AfterCreate;
begin
  inherited AfterCreate;
  SetPosition(100, 100, 900, 600);
  WindowTitle := 'fpGUI Terminal';
  FTerminalView := TTerminalFPGUIView.Create(self);
  FTerminalView.SetPosition(0, 0, Width, Height);
  FTerminalView.Anchors := [anLeft, anTop, anRight, anBottom];
end;

end.

