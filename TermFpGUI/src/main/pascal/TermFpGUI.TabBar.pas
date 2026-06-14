{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  TTermTabBar — custom tab strip with an integrated hamburger button.

  Layout:  [ ... tabs ... ][ ☰ ]
  The hamburger always owns HAMBURGER_W on the far right.  Tabs are laid out
  only within the remaining width, so they can never cross under the button.
  When the tabs do not fit, they shrink uniformly and their titles are elided
  with "…"; the full title is shown as a hover hint.  No scroll arrows.
}
unit TermFpGUI.TabBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_base, fpg_main, fpg_widget;

type
  TTabIndexEvent = procedure(AIndex: Integer) of object;
  TTabRightClickEvent = procedure(AIndex, AX, AY: Integer) of object;

  TTermTabBar = class(TfpgWidget)
  private
    FTitles: TStringList;
    FActive: Integer;
    FHamburgerW: Integer;
    FOnSelect: TTabIndexEvent;
    FOnMenu: TNotifyEvent;
    FOnTabRightClick: TTabRightClickEvent;
    function  AvailW: Integer;
    function  SlotWidth(I: Integer): Integer;
    function  Elide(const S: string; AMaxPx: Integer): string;
    procedure DrawHamburger(AZoneLeft: Integer);
    function  TabAtX(AX: Integer): Integer;
    procedure SetActiveIndex(AValue: Integer);
  protected
    procedure HandlePaint; override;
    procedure HandleResize(awidth, aheight: TfpgCoord); override;
    procedure HandleLMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleRMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleMouseMove(x, y: integer; btnstate: word; shiftstate: TShiftState); override;
    procedure HandleMouseExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function  AddTab(const ATitle: string): Integer;
    procedure RemoveTab(AIndex: Integer);
    procedure SetTitle(AIndex: Integer; const ATitle: string);
    function  Count: Integer;
    function  TitleOf(AIndex: Integer): string;
    property  ActiveIndex: Integer read FActive write SetActiveIndex;
    property  HamburgerWidth: Integer read FHamburgerW write FHamburgerW;
    property  OnSelect: TTabIndexEvent read FOnSelect write FOnSelect;
    property  OnMenu: TNotifyEvent read FOnMenu write FOnMenu;
    property  OnTabRightClick: TTabRightClickEvent read FOnTabRightClick write FOnTabRightClick;
  end;

implementation

const
  ELLIPSIS   = #$E2#$80#$A6;    // U+2026 …
  DEFAULT_H  = 26;             // strip height
  PAD        = 10;
  MIN_SLOT   = 60;             // smallest tab width before titles just elide

  { $00RRGGBB, opaque per fpGUI. Dark strip to sit above a dark terminal. }
  C_BAR_BG       = TfpgColor($00303030);
  C_TAB_ACTIVE   = TfpgColor($00202020);
  C_TAB_INACTIVE = TfpgColor($00404040);
  C_ACCENT       = TfpgColor($003DA0FF);
  C_SEP          = TfpgColor($00585858);
  C_TEXT_ACTIVE  = TfpgColor($00F0F0F0);
  C_TEXT_INACT   = TfpgColor($00B0B0B0);

{ Drop one whole UTF-8 codepoint from the end of S. }
procedure TrimLastCodepoint(var S: string);
begin
  while (S <> '') and ((Ord(S[Length(S)]) and $C0) = $80) do
    Delete(S, Length(S), 1);                       // continuation bytes
  if S <> '' then
    Delete(S, Length(S), 1);                        // lead / single byte
end;

constructor TTermTabBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTitles := TStringList.Create;
  FActive := -1;
  FHamburgerW := 28;
  ShowHint := True;                                  // full title on hover
  Height := DEFAULT_H;
end;

procedure TTermTabBar.HandleResize(awidth, aheight: TfpgCoord);
begin
  inherited HandleResize(awidth, aheight);
  Invalidate;                                        // repaint the new width
end;

destructor TTermTabBar.Destroy;
begin
  FTitles.Free;
  inherited Destroy;
end;

function TTermTabBar.AvailW: Integer;
begin
  Result := Width - FHamburgerW;
  if Result < 0 then Result := 0;
end;

{ Tabs fill the bar equally — as big as possible — and only shrink (smaller
  equal share) as more tabs are added, down to a clickable floor. }
function TTermTabBar.SlotWidth(I: Integer): Integer;
begin
  if FTitles.Count = 0 then Exit(MIN_SLOT);
  Result := AvailW div FTitles.Count;
  if Result < MIN_SLOT then Result := MIN_SLOT;
end;

{ Shorten S with a trailing ellipsis so it fits within AMaxPx pixels. }
function TTermTabBar.Elide(const S: string; AMaxPx: Integer): string;
begin
  if (AMaxPx <= 0) then Exit('');
  if Canvas.Font.GetTextWidth(S) <= AMaxPx then Exit(S);
  Result := S;
  repeat
    TrimLastCodepoint(Result);
  until (Result = '') or (Canvas.Font.GetTextWidth(Result + ELLIPSIS) <= AMaxPx);
  Result := Result + ELLIPSIS;
end;

procedure TTermTabBar.DrawHamburger(AZoneLeft: Integer);
const
  BAR_W = 14;
  BAR_H = 2;
  GAP   = 3;
var
  cx, cy, k: Integer;
begin
  cx := AZoneLeft + (FHamburgerW - BAR_W) div 2;
  cy := (Height - (3 * BAR_H + 2 * GAP)) div 2;
  Canvas.Color := C_TEXT_ACTIVE;
  for k := 0 to 2 do
    Canvas.FillRectangle(cx, cy + k * (BAR_H + GAP), BAR_W, BAR_H);
end;

function TTermTabBar.TabAtX(AX: Integer): Integer;
var
  i, x0: Integer;
begin
  Result := -1;
  if AX >= AvailW then Exit;
  x0 := 0;
  for i := 0 to FTitles.Count - 1 do
  begin
    if (AX >= x0) and (AX < x0 + SlotWidth(i)) then Exit(i);
    x0 := x0 + SlotWidth(i);
    if x0 >= AvailW then Break;
  end;
end;

procedure TTermTabBar.HandlePaint;
var
  i, x, sw, drawW, av, textW: Integer;
begin
  Canvas.BeginDraw;
  try
    av := AvailW;
    Canvas.Color := C_BAR_BG;
    Canvas.FillRectangle(0, 0, Width, Height);

    x := 0;
    for i := 0 to FTitles.Count - 1 do
    begin
      if x >= av then Break;
      sw := SlotWidth(i);
      drawW := sw;
      if x + drawW > av then drawW := av - x;
      if drawW <= 0 then Break;

      if i = FActive then Canvas.Color := C_TAB_ACTIVE
      else Canvas.Color := C_TAB_INACTIVE;
      Canvas.FillRectangle(x, 0, drawW, Height);

      if i = FActive then
      begin
        Canvas.Color := C_ACCENT;
        Canvas.FillRectangle(x, 0, drawW, 2);
      end;

      Canvas.Color := C_SEP;
      Canvas.FillRectangle(x + drawW - 1, 0, 1, Height);

      if i = FActive then Canvas.TextColor := C_TEXT_ACTIVE
      else Canvas.TextColor := C_TEXT_INACT;
      textW := drawW - PAD - 2;
      if textW > 0 then
        Canvas.DrawText(x + PAD, 0, textW, Height, Elide(FTitles[i], textW),
          [txtLeft, txtVCenter]);

      x := x + sw;
    end;

    { Hamburger — always on the far right.  Drawn as three bars (font-
      independent; the ☰ codepoint is missing from many UI fonts). }
    Canvas.Color := C_BAR_BG;
    Canvas.FillRectangle(av, 0, FHamburgerW, Height);
    Canvas.Color := C_SEP;
    Canvas.FillRectangle(av, 0, 1, Height);
    DrawHamburger(av);
  finally
    Canvas.EndDraw;
  end;
end;

procedure TTermTabBar.HandleLMouseDown(x, y: integer; shiftstate: TShiftState);
var
  idx: Integer;
begin
  inherited HandleLMouseDown(x, y, shiftstate);
  if x >= AvailW then
  begin
    if Assigned(FOnMenu) then FOnMenu(Self);
    Exit;
  end;
  idx := TabAtX(x);
  if idx >= 0 then
  begin
    SetActiveIndex(idx);
    if Assigned(FOnSelect) then FOnSelect(idx);
  end;
end;

procedure TTermTabBar.HandleRMouseDown(x, y: integer; shiftstate: TShiftState);
var
  idx: Integer;
begin
  inherited HandleRMouseDown(x, y, shiftstate);
  if x >= AvailW then Exit;
  idx := TabAtX(x);
  if (idx >= 0) and Assigned(FOnTabRightClick) then
    FOnTabRightClick(idx, x, y);
end;

procedure TTermTabBar.HandleMouseMove(x, y: integer; btnstate: word; shiftstate: TShiftState);
var
  idx: Integer;
  Full: string;
begin
  inherited HandleMouseMove(x, y, btnstate, shiftstate);
  idx := TabAtX(x);
  if idx >= 0 then Full := FTitles[idx] else Full := '';
  if Hint <> Full then
    Hint := Full;                                     // full title tooltip
end;

procedure TTermTabBar.HandleMouseExit;
begin
  inherited HandleMouseExit;
  Hint := '';                                         // don't let it linger off-window
end;

procedure TTermTabBar.SetActiveIndex(AValue: Integer);
begin
  if (AValue < -1) or (AValue >= FTitles.Count) then Exit;
  if AValue = FActive then Exit;
  FActive := AValue;
  Invalidate;
end;

function TTermTabBar.AddTab(const ATitle: string): Integer;
begin
  Result := FTitles.Add(ATitle);
  if FActive < 0 then FActive := Result;
  Invalidate;
end;

procedure TTermTabBar.RemoveTab(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FTitles.Count) then Exit;
  FTitles.Delete(AIndex);
  if FActive >= FTitles.Count then FActive := FTitles.Count - 1
  else if FActive > AIndex then Dec(FActive);
  Invalidate;
end;

procedure TTermTabBar.SetTitle(AIndex: Integer; const ATitle: string);
begin
  if (AIndex < 0) or (AIndex >= FTitles.Count) then Exit;
  if FTitles[AIndex] = ATitle then Exit;
  FTitles[AIndex] := ATitle;
  Invalidate;
end;

function TTermTabBar.Count: Integer;
begin
  Result := FTitles.Count;
end;

function TTermTabBar.TitleOf(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < FTitles.Count) then
    Result := FTitles[AIndex]
  else
    Result := '';
end;

end.
