unit Terminal.View.fpGUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  fpg_base, fpg_main, fpg_widget, fpg_form, fpg_scrollbar, fpg_menu,
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
    FCharWidth: Integer;
    FCharHeight: Integer;
    FTopRow: Integer;
    FCursorBlinkVisible: Boolean;
    FDefaultFGColor: TfpgColor;
    FSelection: TTermSelection;
    FSelectionFGColor: TfpgColor;
    FSelectionBGColor: TfpgColor;
    function CellSelected(AVirtualRow, ACol: Integer): Boolean;
    procedure ContextMenuItemClick(Sender: TObject);
    procedure ContextPopupShow(Sender: TObject);
    function GetSelectedTextUTF8: RawByteString;
    function GetVirtualLine(AVirtualRow: Integer): TTermCellLine;
    procedure HandleScrollBarScroll(Sender: TObject; position: integer);
    procedure TimerFired(Sender: TObject);
    procedure CursorTimerFired(Sender: TObject);
    procedure CoreInvalidate(Sender: TObject; const ARect: TTermRect);
    procedure CoreBell(Sender: TObject);
    procedure CoreTitle(Sender: TObject; const ATitle: string);
    procedure UpdateMetrics;
    procedure SyncSizeToController;
    function RowsVisible: Integer;
    function ColsVisible: Integer;
    function ClientWidth: Integer;
    function CellRect(ACol, ARow: Integer): TfpgRect;
    function MapColor(const AColor: TTermColor; IsBackground: Boolean): TfpgColor;
    function CellText(const ACell: TTermCell): string;
    procedure PaintCell(const ACanvas: TfpgCanvas; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
    function PixelToCell(X, Y: Integer): TTermCellPos;
    procedure UpdateScrollBarCoords;
    procedure UpdateScrollBar;
    procedure CreatePopupMenu;
    procedure DoCopy;
    procedure DoPaste;
  protected
    procedure HandlePaint; override;
    procedure HandleResize(AWidth, AHeight: TfpgCoord); override;
    procedure HandleKeyPress(var keycode: word; var shiftstate: TShiftState; var consumed: boolean); override;
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
    property CursorStyle: TCursorStyle read FCursorStyle write FCursorStyle;
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

  CONTEXT_COPY = 0;
  CONTEXT_PASTE = 1;


constructor TTerminalFPGUIView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Focusable := True;
  //TabStop := True;
  //FFontDesc := FPG_DEFAULT_FIXED_FONT_DESC;
  //FFontDesc :=  'DejaVu Sans Mono-13';
  FFontDesc :=  'Monospace-12';
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
    SyncSizeToController;
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

procedure TTerminalFPGUIView.TimerFired(Sender: TObject);
begin
  if FController <> nil then
  begin
    if FController.Pump > 0 then
    begin
      FCursorBlinkVisible := True;
      FCursorTimer.Reset;
      FCursorTimer.Enabled := True;
      FScrollbar.Position:=FScrollbar.Max;
      Repaint;
    end;
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
begin
  UpdateMetrics;

  L := ARect.Left * FCharWidth;
  T := (ARect.Top - FTopRow) * FCharHeight;
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
    InvalidateRect(fpgRect(L, T, W, H));
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
        Result := RGB;
      end;
  else
    if IsBackground then
      Result := FBackgroundColor
    else
      Result := FDefaultFGColor;
  end;
end;

function TTerminalFPGUIView.CellText(const ACell: TTermCell): string;
begin
  if ACell.Cluster <> '' then
    Result := string(AnsiToUtf8(ACell.Cluster))
  else
    Result := ' ';
end;

procedure TTerminalFPGUIView.PaintCell(const ACanvas: TfpgCanvas; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
var
  R: TfpgRect;
  FG, BG: TfpgColor;
  S: string;
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

  if tafInverse in ACell.Attrs then
    specialize Swap<TfpgColor>(FG, BG);

  if IsSelected then
  begin
    BG := FSelectionBGColor;
    FG := FSelectionFGColor;
  end;

  if AHasCursor and (FCursorBlinkVisible) then
    specialize Swap<TfpgColor>(FG, BG);

  ACanvas.Color := BG;
  ACanvas.FillRectangle(R);

  if ACell.isBlank then
    Exit;

  S := CellText(ACell);
  ACanvas.TextColor := FG;
  ACanvas.DrawString(R.Left, R.Top, S);
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
  end;
end;

procedure TTerminalFPGUIView.ContextPopupShow(Sender: TObject);
begin
  FContextMenu.MenuItemByName('Copy').Enabled:=FSelection.Active;
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

  WriteLn(Format('Page = %d ; Max = %d ; Position = %d ; History = %d ; Top = %d', [RowsVisible, FScrollbar.Max, FScrollbar.Position, FController.Core.HistoryCount, FTopRow]));
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
begin
  inherited HandleResize(AWidth, AHeight);
  SyncSizeToController;
  UpdateScrollBarCoords;
end;

procedure TTerminalFPGUIView.HandleKeyPress(var keycode: word; var shiftstate: TShiftState; var consumed: boolean);
var
  Ch: AnsiChar;
begin
  inherited HandleKeyPress(keycode, shiftstate, consumed);
  if FController = nil then
    Exit;

  case keycode of
    keyReturn:
      begin FController.SendKeyEnter; consumed := True; end;
    keyBackSpace:
      begin FController.SendKeyBackspace; consumed := True; end;
    keyTab:
      begin FController.SendKeyTab; consumed := True; end;
    keyEscape:
      begin FController.SendKeyEscape; consumed := True; end;
    keyUp:
      begin FController.SendArrowUp(ssCtrl in shiftstate); consumed := True; end;
    keyDown:
      begin FController.SendArrowDown(ssCtrl in shiftstate); consumed := True; end;
    keyLeft:
      begin FController.SendArrowLeft(ssCtrl in shiftstate); consumed := True; end;
    keyRight:
      begin FController.SendArrowRight(ssCtrl in shiftstate); consumed := True; end;
  else
    // Ctrl codes Ctrl+c etc
    if ([ssCtrl] = shiftstate) then
    begin
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
      repeat
        case keycode of
          Ord('C'): DoCopy;
          Ord('V'): DoPaste;
        else
          break;
        end;
        consumed:=True;
        Exit;
      until True;
    end;

    // Shift+Insert (paste)
    if ([ssShift] = shiftstate) and (keycode = keyInsert) then
    begin
      DoPaste;
      consumed := True;
      Exit;
    end;


    if (keycode >= 32) and (keycode <= 255) then
    begin
      Ch := AnsiChar(keycode);
      if not (ssShift in shiftstate) then
        Ch := LowerCase(Ch);
      FController.SendInput(RawByteString(Ch));
      consumed := True;
      FScrollbar.Position:=FScrollbar.Max;
    end;
  end;
end;

procedure TTerminalFPGUIView.HandleLMouseDown(x, y: integer;
  shiftstate: TShiftState);
begin
  FSelection.Active := True;
  //FSelection.Selecting := True; // only true after the cell changes
  FSelection.Mode := tsmLinear;
  FSelection.Anchor := PixelToCell(x, y);
  FSelection.Focus := FSelection.Anchor;
  Repaint;
end;

procedure TTerminalFPGUIView.HandleMouseMove(x, y: integer; btnstate: word;
  shiftstate: TShiftState);
var
  Cell: TTermCellPos;
begin
  inherited HandleMouseMove(x, y, btnstate, shiftstate);

  if (btnstate and MOUSE_LEFT) = 0 then
    Exit;

  Cell := PixelToCell(x, y);

  if FSelection.Active and not FSelection.Selecting and
     ((Cell.Row <> FSelection.Anchor.Row) or (Cell.Col <> FSelection.Anchor.Col)) then
    FSelection.Selecting := True;

  if FSelection.Active and FSelection.Selecting then
  begin
    FSelection.Focus := Cell;
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.HandleLMouseUp(x, y: integer;
  shiftstate: TShiftState);
begin
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
begin
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

