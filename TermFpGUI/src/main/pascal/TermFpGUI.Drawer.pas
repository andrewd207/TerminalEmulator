{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  Hover drawer: a per-tab slide-out side panel hosting a second terminal (or a
  custom app).  It is configured by the active profile (gravity edge, label,
  command, size fraction, reveal animation, launch timing).

  Composition (all children of the content bevel, painting over the main view):
    * FView      - a TTerminalFPGUIView running the drawer's own controller, so
                   each tab gets an independent program instance.
    * FHandle    - a thin tab on the gravity edge; fades in on hover, click
                   toggles the drawer.
    * FAnim      - an overlay that paints the fade / assemble reveal by blending
                   two captured images (terminal background <-> drawer content).
    * FSplitter  - a grip on the panel's inner edge; drag resizes the fraction.

  The main view is told to leave a reserved rectangle (SetReservedRect) wherever
  the drawer currently occupies, so its direct grid blit does not clobber us.
}
unit TermFpGUI.Drawer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_base, fpg_main, fpg_widget,
  Terminal.Controller, Terminal.View.fpGUI, TermFpGUI.Config;

type
  TNotifyMethod = procedure of object;

  { Thin hover tab carrying the configured tool name. }
  TDrawerHandle = class(TfpgWidget)
  private
    FCaption: string;
    FBaseColor: TfpgColor;
    FAccentColor: TfpgColor;
    FReveal: Double;            { 0 = hidden look, 1 = full accent }
    FOnClick: TNotifyMethod;
    FOnEnter: TNotifyMethod;
    FOnLeave: TNotifyMethod;
  protected
    procedure HandlePaint; override;
    procedure HandleLMouseUp(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleMouseEnter; override;
    procedure HandleMouseExit; override;
  public
    property Caption: string read FCaption write FCaption;
    property BaseColor: TfpgColor read FBaseColor write FBaseColor;
    property AccentColor: TfpgColor read FAccentColor write FAccentColor;
    property Reveal: Double read FReveal write FReveal;
    property OnClick: TNotifyMethod read FOnClick write FOnClick;
    property OnHandleEnter: TNotifyMethod read FOnEnter write FOnEnter;
    property OnHandleLeave: TNotifyMethod read FOnLeave write FOnLeave;
  end;

  TDrawerAnimStyle = (dasFade, dasAssemble);

  { Overlay that reveals the drawer by stepping between two captured images. }
  TDrawerAnim = class(TfpgWidget)
  private
    FBg: TfpgImage;            { terminal behind the panel }
    FContent: TfpgImage;       { the drawer's rendered content }
    FWork: TfpgImage;          { per-frame blended result }
    FStyle: TDrawerAnimStyle;
    FProgress: Double;         { 0..1, fraction of content revealed }
    FStep: Double;             { +/- per tick }
    FTimer: TfpgTimer;
    FOnDone: TNotifyMethod;
    FTiles: array of Integer;  { shuffled tile order for assemble }
    FTileCols, FTileRows: Integer;
    procedure BuildTiles;
    procedure Compose;
    procedure Tick(Sender: TObject);
  protected
    procedure HandlePaint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Take ownership of ABg/AContent (freed here).  AForward: bg->content. }
    procedure Run(ABg, AContent: TfpgImage; AStyle: TDrawerAnimStyle;
                  AForward: Boolean; AOnDone: TNotifyMethod);
    { Halt any running animation and drop the completion callback. }
    procedure Stop;
  end;

  { Drag grip on the panel's inner edge. }
  TDrawerSplitter = class(TfpgWidget)
  private
    FVertical: Boolean;        { True = grip runs vertically (left/right gravity) }
    FColor: TfpgColor;
    FDragging: Boolean;
    FOnDrag: TNotifyEvent;     { Tag carries the signed pixel delta }
    FDelta: Integer;
  protected
    procedure HandlePaint; override;
    procedure HandleLMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleLMouseUp(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleMouseMove(x, y: integer; btnstate: word; shiftstate: TShiftState); override;
  public
    property Vertical: Boolean read FVertical write FVertical;
    property Color: TfpgColor read FColor write FColor;
    property Delta: Integer read FDelta;
    property OnDrag: TNotifyEvent read FOnDrag write FOnDrag;
  end;

  TTermDrawerState = (tdsClosed, tdsOpening, tdsOpen, tdsClosing);

  { Coordinator. Not a widget; owns the widgets above plus the controller. }
  TTermDrawer = class
  private
    FParent: TfpgWidget;            { the content bevel }
    FMainView: TTerminalFPGUIView;  { the tab's primary view (not owned) }
    FProfile: TTermProfile;         { shared, not owned — font + fallback colours }
    FColorProfile: TTermProfile;    { optional, not owned — overrides fg/bg only }
    FColorFG, FColorBG: TfpgColor;  { resolved drawer colours }
    FController: TTerminalController;
    FView: TTerminalFPGUIView;
    FHandle: TDrawerHandle;
    FAnim: TDrawerAnim;
    FSplitter: TDrawerSplitter;
    FState: TTermDrawerState;
    FArmed: Boolean;                { handle currently revealed }
    FActive: Boolean;               { this drawer's tab is the visible one }
    FStarted: Boolean;              { program has been launched }
    FExited: Boolean;               { hosted program has died, awaiting relaunch }
    FFrac: Double;
    FHandleTimer: TfpgTimer;
    FHandleTarget: Double;
    FOnPersist: TNotifyMethod;
    FOnHostKey: TTermViewKeyEvent;
    procedure ApplyLook(AView: TTerminalFPGUIView);
    procedure EnsureView;
    procedure StartProgramIfNeeded;
    function  PanelRect: TfpgRect;
    function  HandleRect(AAtInnerEdge: Boolean): TfpgRect;
    procedure ApplyReserved;
    procedure LayoutWidgets;
    procedure ShowHandle(AOn: Boolean);
    procedure HandleTick(Sender: TObject);
    procedure DoHandleClick;
    procedure DoHandleEnter;
    procedure DoHandleLeave;
    procedure DoSplitterDrag(Sender: TObject);
    procedure AnimDone;
    procedure DrawerViewExit(Sender: TObject);
    procedure DrawerViewKey(Sender: TObject; AKeyCode: Word;
      AShift: TShiftState; var AHandled: Boolean);
    procedure Relaunch;
  public
    constructor Create(AParent: TfpgWidget; AMainView: TTerminalFPGUIView;
                       AProfile: TTermProfile; AColorProfile: TTermProfile = nil);
    destructor Destroy; override;
    procedure Layout;                 { call on host resize }
    procedure Arm;                    { pointer reached the gravity edge }
    procedure Disarm;                 { pointer left the edge }
    procedure Toggle;
    procedure OpenDrawer;
    procedure CloseDrawer;
    procedure SetActive(AOn: Boolean);{ tab shown / hidden }
    { Honour a launch-on-profile-start drawer: create and start it without
      opening, so its program is already running by the time it is revealed. }
    procedure PrimeIfEager;
    { Re-read appearance from the (already-updated) profile + colour profile and
      apply it live — colours, handle label/accent, size, gravity — without
      restarting the hosted program. }
    procedure RefreshLook(AColorProfile: TTermProfile);
    function  IsOpen: Boolean;
    function  Gravity: TTermViewEdge;
    { The drawer's own terminal view (nil until first opened/primed). }
    property  InnerView: TTerminalFPGUIView read FView;
    { Called when the user drags the splitter (size changed) so the host can
      persist the new fraction. }
    property OnPersist: TNotifyMethod read FOnPersist write FOnPersist;
    { Lets the host resolve global keybindings (e.g. ToggleDrawer, copy) while
      the drawer's view is focused.  Sender is this drawer. }
    property OnHostKey: TTermViewKeyEvent read FOnHostKey write FOnHostKey;
  end;

implementation

uses
  Math;

const
  HANDLE_THICK = 22;          { tab depth (perpendicular to the edge) }
  SPLIT_THICK  = 5;
  ANIM_FRAMES  = 8;
  ANIM_MS      = 15;          { ~30% faster reveal than the original 22ms/frame }
  HANDLE_MS    = 30;
  TILE_PX      = 28;

{ ---- small colour helpers ---- }

function Lerp8(a, b: Byte; t: Double): Byte; inline;
begin
  Result := Byte(Round(a + (b - a) * t));
end;

function BlendColor(c1, c2: TfpgColor; t: Double): TfpgColor;
var
  r1, g1, b1, r2, g2, b2: Byte;
begin
  r1 := (c1 shr 16) and $FF; g1 := (c1 shr 8) and $FF; b1 := c1 and $FF;
  r2 := (c2 shr 16) and $FF; g2 := (c2 shr 8) and $FF; b2 := c2 and $FF;
  Result := (TfpgColor(Lerp8(r1, r2, t)) shl 16)
         or (TfpgColor(Lerp8(g1, g2, t)) shl 8)
         or  TfpgColor(Lerp8(b1, b2, t));
end;

{ ===================== TDrawerHandle ===================== }

procedure TDrawerHandle.HandlePaint;
var
  fill: TfpgColor;
  ty: Integer;
begin
  Canvas.BeginDraw;
  try
    fill := BlendColor(FBaseColor, FAccentColor, FReveal);
    Canvas.Color := fill;
    Canvas.FillRectangle(0, 0, Width, Height);
    { a brighter lip so the tab reads as raised }
    Canvas.Color := BlendColor(fill, TextColor, 0.25);
    Canvas.DrawLine(0, 0, Width, 0);
    Canvas.SetTextColor(TextColor);
    ty := (Height - Canvas.Font.GetHeight) div 2;
    if ty < 0 then ty := 0;
    Canvas.DrawString(6, ty, FCaption);
  finally
    Canvas.EndDraw;
  end;
end;

procedure TDrawerHandle.HandleLMouseUp(x, y: integer; shiftstate: TShiftState);
begin
  inherited HandleLMouseUp(x, y, shiftstate);
  if Assigned(FOnClick) then FOnClick;
end;

procedure TDrawerHandle.HandleMouseEnter;
begin
  inherited HandleMouseEnter;
  if Assigned(FOnEnter) then FOnEnter;
end;

procedure TDrawerHandle.HandleMouseExit;
begin
  inherited HandleMouseExit;
  if Assigned(FOnLeave) then FOnLeave;
end;

{ ===================== TDrawerAnim ===================== }

constructor TDrawerAnim.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTimer := TfpgTimer.Create(ANIM_MS);
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := False;
  Randomize;
end;

destructor TDrawerAnim.Destroy;
begin
  FreeAndNil(FTimer);
  FreeAndNil(FBg);
  FreeAndNil(FContent);
  FreeAndNil(FWork);
  inherited Destroy;
end;

procedure TDrawerAnim.BuildTiles;
var
  n, i, j, tmp: Integer;
begin
  FTileCols := Max(1, (Width + TILE_PX - 1) div TILE_PX);
  FTileRows := Max(1, (Height + TILE_PX - 1) div TILE_PX);
  n := FTileCols * FTileRows;
  SetLength(FTiles, n);
  for i := 0 to n - 1 do FTiles[i] := i;
  for i := n - 1 downto 1 do          { Fisher-Yates }
  begin
    j := Random(i + 1);
    tmp := FTiles[i]; FTiles[i] := FTiles[j]; FTiles[j] := tmp;
  end;
end;

{ Build FWork for the current FProgress into FWork.ImageData. }
procedure TDrawerAnim.Compose;
var
  w, h, stride, y, x, i, revealed, t, tc, tr, x0, y0, x1, y1: Integer;
  pBg, pCt, pWk: PByte;
begin
  if (FBg = nil) or (FContent = nil) then Exit;
  w := Width; h := Height;
  if (FWork = nil) or (FWork.Width <> w) or (FWork.Height <> h) then
  begin
    FreeAndNil(FWork);
    FWork := TfpgImage.Create;
    FWork.AllocateImage(32, w, h);
  end;
  stride := w * 4;
  if FStyle = dasFade then
  begin
    for y := 0 to h - 1 do
    begin
      pBg := PByte(FBg.ImageData) + y * stride;
      pCt := PByte(FContent.ImageData) + y * stride;
      pWk := PByte(FWork.ImageData) + y * stride;
      for x := 0 to stride - 1 do
      begin
        pWk^ := Byte(Round(pBg^ + (pCt^ - pBg^) * FProgress));
        Inc(pBg); Inc(pCt); Inc(pWk);
      end;
    end;
  end
  else
  begin
    { assemble: start from bg, paint revealed tiles from content }
    Move(FBg.ImageData^, FWork.ImageData^, stride * h);
    revealed := Round(FProgress * Length(FTiles));
    for i := 0 to revealed - 1 do
    begin
      t := FTiles[i];
      tc := t mod FTileCols; tr := t div FTileCols;
      x0 := tc * TILE_PX; y0 := tr * TILE_PX;
      x1 := Min(w, x0 + TILE_PX); y1 := Min(h, y0 + TILE_PX);
      for y := y0 to y1 - 1 do
      begin
        pCt := PByte(FContent.ImageData) + y * stride + x0 * 4;
        pWk := PByte(FWork.ImageData) + y * stride + x0 * 4;
        Move(pCt^, pWk^, (x1 - x0) * 4);
      end;
    end;
  end;
  FWork.UpdateImage;
end;

procedure TDrawerAnim.Tick(Sender: TObject);
begin
  FProgress := FProgress + FStep;
  if FProgress >= 1.0 then begin FProgress := 1.0; FTimer.Enabled := False; end
  else if FProgress <= 0.0 then begin FProgress := 0.0; FTimer.Enabled := False; end;
  Compose;
  Repaint;
  if not FTimer.Enabled and Assigned(FOnDone) then
    FOnDone;
end;

procedure TDrawerAnim.HandlePaint;
begin
  Canvas.BeginDraw;
  try
    if FWork <> nil then
      { Direct memory blit (no AggPas transformImage / alpha blend) — the frame
        is opaque, so a raw row Move straight into the window buffer is far
        cheaper than DrawImagePart's per-pixel span transform. }
      BlitImageDirectToCanvas(Canvas, FWork, Width, Height);
  finally
    Canvas.EndDraw;
  end;
end;

procedure TDrawerAnim.Run(ABg, AContent: TfpgImage; AStyle: TDrawerAnimStyle;
  AForward: Boolean; AOnDone: TNotifyMethod);
begin
  FreeAndNil(FBg);
  FreeAndNil(FContent);
  FBg := ABg;
  FContent := AContent;
  FStyle := AStyle;
  FOnDone := AOnDone;
  if AStyle = dasAssemble then BuildTiles;
  if AForward then begin FProgress := 0.0; FStep := 1.0 / ANIM_FRAMES; end
  else            begin FProgress := 1.0; FStep := -1.0 / ANIM_FRAMES; end;
  Compose;
  Repaint;
  FTimer.Enabled := True;
end;

procedure TDrawerAnim.Stop;
begin
  if FTimer <> nil then FTimer.Enabled := False;
  FOnDone := nil;
end;

{ ===================== TDrawerSplitter ===================== }

procedure TDrawerSplitter.HandlePaint;
begin
  Canvas.BeginDraw;
  try
    Canvas.Color := FColor;
    Canvas.FillRectangle(0, 0, Width, Height);
  finally
    Canvas.EndDraw;
  end;
end;

procedure TDrawerSplitter.HandleLMouseDown(x, y: integer; shiftstate: TShiftState);
begin
  inherited HandleLMouseDown(x, y, shiftstate);
  FDragging := True;
end;

procedure TDrawerSplitter.HandleLMouseUp(x, y: integer; shiftstate: TShiftState);
begin
  inherited HandleLMouseUp(x, y, shiftstate);
  FDragging := False;
end;

procedure TDrawerSplitter.HandleMouseMove(x, y: integer; btnstate: word;
  shiftstate: TShiftState);
begin
  inherited HandleMouseMove(x, y, btnstate, shiftstate);
  if not FDragging then Exit;
  if FVertical then FDelta := x - (Width div 2)
  else FDelta := y - (Height div 2);
  if (FDelta <> 0) and Assigned(FOnDrag) then
    FOnDrag(Self);
end;

{ ===================== TTermDrawer ===================== }

constructor TTermDrawer.Create(AParent: TfpgWidget;
  AMainView: TTerminalFPGUIView; AProfile: TTermProfile;
  AColorProfile: TTermProfile);
begin
  inherited Create;
  FParent := AParent;
  FMainView := AMainView;
  FProfile := AProfile;
  FColorProfile := AColorProfile;
  { Colours come from the colour profile when set, else from the owning profile;
    the font always comes from the owning profile. }
  if FColorProfile <> nil then
  begin
    FColorFG := FColorProfile.FGColor;
    FColorBG := FColorProfile.BGColor;
  end
  else
  begin
    FColorFG := AProfile.FGColor;
    FColorBG := AProfile.BGColor;
  end;
  FState := tdsClosed;
  FActive := True;
  FFrac := AProfile.DrawerSizeFrac;
  if (FFrac < 0.1) or (FFrac > 0.9) then FFrac := 0.33;

  FHandle := TDrawerHandle.Create(FParent);
  FHandle.Parent := FParent;
  FHandle.Caption := AProfile.DrawerName;
  FHandle.BaseColor := FColorBG;
  FHandle.AccentColor := BlendColor(FColorBG, FColorFG, 0.5);
  FHandle.TextColor := FColorFG;
  FHandle.OnClick := @DoHandleClick;
  FHandle.OnHandleEnter := @DoHandleEnter;
  FHandle.OnHandleLeave := @DoHandleLeave;
  FHandle.Visible := False;

  FHandleTimer := TfpgTimer.Create(HANDLE_MS);
  FHandleTimer.OnTimer := @HandleTick;
  FHandleTimer.Enabled := False;
end;

destructor TTermDrawer.Destroy;
begin
  { Silence everything that could re-enter mid-teardown: stop our timers, drop
    host callbacks, and disarm the view's exit/key handlers (they point at this
    drawer, which is going away).  Cheap insurance against an in-flight tick or
    event firing into half-freed state during an async window close. }
  FOnPersist := nil;
  FOnHostKey := nil;
  if FHandleTimer <> nil then FHandleTimer.Enabled := False;
  if FAnim <> nil then FAnim.Stop;
  if FView <> nil then
  begin
    FView.OnShellExit := nil;
    FView.OnKeyAction := nil;
  end;
  { Release any hole we reserved in the main view so it repaints fully. }
  if FMainView <> nil then
    FMainView.ClearReservedRect;
  FreeAndNil(FHandleTimer);
  if FView <> nil then
    FView.DetachController(True);
  FreeAndNil(FView);
  FreeAndNil(FController);
  FreeAndNil(FAnim);
  FreeAndNil(FSplitter);
  FreeAndNil(FHandle);
  inherited Destroy;
end;

function TTermDrawer.Gravity: TTermViewEdge;
begin
  Result := FProfile.DrawerGravity;
  if Result = veNone then Result := veRight;
end;

function TTermDrawer.IsOpen: Boolean;
begin
  Result := FState in [tdsOpen, tdsOpening];
end;

function TTermDrawer.PanelRect: TfpgRect;
var
  W, H, pw, ph: Integer;
begin
  W := FParent.Width; H := FParent.Height;
  case Gravity of
    veLeft, veRight:
      begin
        pw := Round(W * FFrac);
        if pw < HANDLE_THICK * 2 then pw := HANDLE_THICK * 2;
        if Gravity = veRight then Result.SetRect(W - pw, 0, pw, H)
        else Result.SetRect(0, 0, pw, H);
      end;
    else
      begin
        ph := Round(H * FFrac);
        if ph < HANDLE_THICK * 2 then ph := HANDLE_THICK * 2;
        if Gravity = veBottom then Result.SetRect(0, H - ph, W, ph)
        else Result.SetRect(0, 0, W, ph);
      end;
  end;
end;

{ Tab rectangle.  Closed: flush with the content edge.  Open (AAtInnerEdge):
  on the panel's inner edge so it doubles as a close button. }
function TTermDrawer.HandleRect(AAtInnerEdge: Boolean): TfpgRect;
var
  W, H, L, T, cx, cy: Integer;
  pr: TfpgRect;
begin
  W := FParent.Width; H := FParent.Height;
  L := 20 + Length(FProfile.DrawerName) * 8;   { rough text width }
  T := HANDLE_THICK;
  case Gravity of
    veLeft, veRight:
      begin
        cy := (H - T) div 2;
        if not AAtInnerEdge then
        begin
          if Gravity = veRight then Result.SetRect(W - L, cy, L, T)
          else Result.SetRect(0, cy, L, T);
        end
        else
        begin
          pr := PanelRect;
          if Gravity = veRight then Result.SetRect(pr.Left, cy, L, T)
          else Result.SetRect(pr.Right - L, cy, L, T);
        end;
      end;
    else
      begin
        cx := (W - L) div 2;
        if not AAtInnerEdge then
        begin
          if Gravity = veBottom then Result.SetRect(cx, H - T, L, T)
          else Result.SetRect(cx, 0, L, T);
        end
        else
        begin
          pr := PanelRect;
          if Gravity = veBottom then Result.SetRect(cx, pr.Top, L, T)
          else Result.SetRect(cx, pr.Bottom - T, L, T);
        end;
      end;
  end;
end;

procedure TTermDrawer.ApplyReserved;
var
  r: TfpgRect;
begin
  if not FActive then Exit;
  if FState in [tdsOpen, tdsOpening, tdsClosing] then
  begin
    r := PanelRect;
    FMainView.SetReservedRect(r.Left, r.Top, r.Right, r.Bottom);
  end
  else if FArmed then
  begin
    r := HandleRect(False);
    FMainView.SetReservedRect(r.Left, r.Top, r.Right, r.Bottom);
  end
  else
    FMainView.ClearReservedRect;
end;

{ Font from the owning profile; fg/bg from the colour profile when set. }
procedure TTermDrawer.ApplyLook(AView: TTerminalFPGUIView);
begin
  if AView = nil then Exit;
  FProfile.ApplyTo(AView);              { font + the owning profile's colours }
  if FColorProfile <> nil then
  begin
    AView.DefaultFGColor := FColorFG;   { override colours only }
    AView.DefaultBGColor := FColorBG;
    AView.Invalidate;
  end;
end;

procedure TTermDrawer.EnsureView;
begin
  if FView <> nil then Exit;
  FController := TTerminalController.Create(80, 25, 2000);
  FView := TTerminalFPGUIView.Create(FParent);
  FView.Parent := FParent;
  FView.AttachController(FController);
  ApplyLook(FView);
  FView.OnShellExit := @DrawerViewExit;   { show a relaunch prompt instead of dying }
  FView.OnKeyAction := @DrawerViewKey;     { any key relaunches once exited }
  FView.Visible := False;

  FSplitter := TDrawerSplitter.Create(FParent);
  FSplitter.Parent := FParent;
  FSplitter.Vertical := Gravity in [veLeft, veRight];
  FSplitter.Color := FHandle.AccentColor;
  FSplitter.OnDrag := @DoSplitterDrag;
  FSplitter.Visible := False;
  if FSplitter.Vertical then FSplitter.MouseCursor := mcSizeEW
  else FSplitter.MouseCursor := mcSizeNS;

  FAnim := TDrawerAnim.Create(FParent);
  FAnim.Parent := FParent;
  FAnim.Visible := False;
end;

procedure TTermDrawer.StartProgramIfNeeded;
begin
  if FStarted or (FView = nil) then Exit;
  FStarted := True;
  FView.StartProgram(FProfile.DrawerCommand);
end;

procedure TTermDrawer.LayoutWidgets;
var
  pr, hr, sr: TfpgRect;
begin
  if FView <> nil then
  begin
    pr := PanelRect;
    FView.SetPosition(pr.Left, pr.Top, pr.Width, pr.Height);
    FAnim.SetPosition(pr.Left, pr.Top, pr.Width, pr.Height);
    { splitter sits on the inner edge, inside the panel }
    case Gravity of
      veRight:  sr.SetRect(pr.Left, pr.Top, SPLIT_THICK, pr.Height);
      veLeft:   sr.SetRect(pr.Right - SPLIT_THICK, pr.Top, SPLIT_THICK, pr.Height);
      veBottom: sr.SetRect(pr.Left, pr.Top, pr.Width, SPLIT_THICK);
      else      sr.SetRect(pr.Left, pr.Bottom - SPLIT_THICK, pr.Width, SPLIT_THICK);
    end;
    FSplitter.SetPosition(sr.Left, sr.Top, sr.Width, sr.Height);
  end;
  hr := HandleRect(IsOpen);
  FHandle.SetPosition(hr.Left, hr.Top, hr.Width, hr.Height);
end;

procedure TTermDrawer.Layout;
begin
  LayoutWidgets;
  ApplyReserved;
end;

procedure TTermDrawer.ShowHandle(AOn: Boolean);
begin
  if AOn then
  begin
    LayoutWidgets;
    FHandle.Visible := True;
    FHandleTarget := 1.0;
    FHandleTimer.Enabled := True;
  end
  else
  begin
    FHandleTarget := 0.0;
    FHandleTimer.Enabled := True;
  end;
end;

procedure TTermDrawer.HandleTick(Sender: TObject);
var
  d: Double;
begin
  d := FHandleTarget - FHandle.Reveal;
  if Abs(d) <= 0.15 then
  begin
    FHandle.Reveal := FHandleTarget;
    FHandleTimer.Enabled := False;
    if (FHandleTarget = 0.0) and not IsOpen then
      FHandle.Visible := False;
  end
  else
    FHandle.Reveal := FHandle.Reveal + Sign(d) * 0.15;
  if FHandle.Visible then FHandle.Repaint;
end;

procedure TTermDrawer.Arm;
begin
  if not FActive then Exit;
  if IsOpen then Exit;
  FArmed := True;
  ShowHandle(True);
  ApplyReserved;
end;

procedure TTermDrawer.Disarm;
begin
  if IsOpen then Exit;
  FArmed := False;
  ShowHandle(False);
  { reserved is released when the fade-out finishes; do it now for simplicity }
  ApplyReserved;
end;

procedure TTermDrawer.DoHandleEnter;
begin
  { keep the handle alive while the pointer is on it }
  if not IsOpen then
  begin
    FArmed := True;
    FHandleTarget := 1.0;
    FHandle.Reveal := 1.0;
    FHandleTimer.Enabled := False;
  end;
end;

procedure TTermDrawer.DoHandleLeave;
begin
  if not IsOpen then
    ShowHandle(False);
end;

procedure TTermDrawer.DoHandleClick;
begin
  Toggle;
end;

procedure TTermDrawer.Toggle;
begin
  if IsOpen then CloseDrawer else OpenDrawer;
end;

procedure TTermDrawer.OpenDrawer;
var
  pr: TfpgRect;
  bg, content: TfpgImage;
begin
  if not FActive then Exit;
  if FState in [tdsOpen, tdsOpening] then Exit;
  EnsureView;
  LayoutWidgets;
  StartProgramIfNeeded;
  FArmed := False;

  { No animation: snap open. }
  if FProfile.DrawerAnim = tdaNone then
  begin
    FState := tdsOpen;
    FView.Visible := True;
    FSplitter.Visible := True;
    FHandle.Visible := True;
    FHandle.Reveal := 1.0;
    ApplyReserved;
    FView.SetFocus;
    Exit;
  end;

  FState := tdsOpening;
  ApplyReserved;

  pr := PanelRect;
  FView.SetPosition(pr.Left, pr.Top, pr.Width, pr.Height);
  FView.EnsureRendered;
  bg := FMainView.CaptureRegion(pr.Left, pr.Top, pr.Width, pr.Height);
  content := FView.CaptureRegion(0, 0, pr.Width, pr.Height);

  FView.Visible := False;
  FHandle.Visible := False;
  FSplitter.Visible := False;
  FAnim.SetPosition(pr.Left, pr.Top, pr.Width, pr.Height);
  FAnim.Visible := True;
  if FProfile.DrawerAnim = tdaAssemble then
    FAnim.Run(bg, content, dasAssemble, True, @AnimDone)
  else
    FAnim.Run(bg, content, dasFade, True, @AnimDone);
end;

procedure TTermDrawer.CloseDrawer;
var
  pr: TfpgRect;
  bg, content: TfpgImage;
begin
  if FState in [tdsClosed, tdsClosing] then Exit;

  { No animation: snap shut. }
  if FProfile.DrawerAnim = tdaNone then
  begin
    FState := tdsClosed;
    FView.Visible := False;
    FSplitter.Visible := False;
    FHandle.Visible := False;
    FArmed := False;
    ApplyReserved;
    FMainView.Invalidate;
    FMainView.SetFocus;
    Exit;
  end;

  pr := PanelRect;
  content := FView.CaptureRegion(0, 0, pr.Width, pr.Height);
  bg := FMainView.CaptureRegion(pr.Left, pr.Top, pr.Width, pr.Height);
  FState := tdsClosing;
  FView.Visible := False;
  FSplitter.Visible := False;
  FHandle.Visible := False;
  FAnim.SetPosition(pr.Left, pr.Top, pr.Width, pr.Height);
  FAnim.Visible := True;
  if FProfile.DrawerAnim = tdaAssemble then
    FAnim.Run(bg, content, dasAssemble, False, @AnimDone)
  else
    FAnim.Run(bg, content, dasFade, False, @AnimDone);
end;

procedure TTermDrawer.AnimDone;
begin
  FAnim.Visible := False;
  if FState = tdsOpening then
  begin
    FState := tdsOpen;
    LayoutWidgets;
    FView.Visible := True;
    FSplitter.Visible := True;
    FHandle.Visible := True;
    FHandle.Reveal := 1.0;
    FView.SetFocus;
    ApplyReserved;
  end
  else if FState = tdsClosing then
  begin
    FState := tdsClosed;
    FArmed := False;
    ApplyReserved;
    FMainView.Invalidate;
    FMainView.SetFocus;
  end;
end;

{ The hosted program died: print a relaunch prompt into the drawer's view and
  arm the next keypress to restart it.  Suppresses the view's default banner. }
procedure TTermDrawer.DrawerViewExit(Sender: TObject);
var
  Msg: RawByteString;
begin
  FExited := True;
  FStarted := False;
  if FController = nil then Exit;
  Msg := #27'[0m'#13#10 + #27'[7m[ ' + RawByteString(FProfile.DrawerName)
       + ' exited — press any key to relaunch ]' + #27'[0m'#13#10;
  FController.Parser.FeedBytes(Msg);
  if FView <> nil then FView.Invalidate;
end;

{ $E300..$E386 are the modifier / lock keys (keys.inc); ignore them so a bare
  Shift tap doesn't relaunch. }
function IsModifierKey(AKey: Word): Boolean; inline;
begin
  Result := (AKey >= $E300) and (AKey <= $E386);
end;

procedure TTermDrawer.DrawerViewKey(Sender: TObject; AKeyCode: Word;
  AShift: TShiftState; var AHandled: Boolean);
begin
  if FExited then
  begin
    if IsModifierKey(AKeyCode) then Exit;
    AHandled := True;      { eat the key — it triggers the relaunch, not the PTY }
    Relaunch;
    Exit;
  end;
  { Otherwise let the host resolve a global keybinding (toggle/copy/…) so chords
    work even while the drawer's view holds focus. }
  if Assigned(FOnHostKey) then
    FOnHostKey(Self, AKeyCode, AShift, AHandled);
end;

{ Restart the hosted program on a fresh controller (the old child is gone). }
procedure TTermDrawer.Relaunch;
begin
  if FView = nil then Exit;
  FView.DetachController(True);
  FreeAndNil(FController);
  FController := TTerminalController.Create(80, 25, 2000);
  FView.AttachController(FController);
  ApplyLook(FView);
  LayoutWidgets;
  { Wipe the dead session (output + the relaunch banner) before the new program
    starts, so it begins on a clean screen. }
  FController.Core.ClearScreen;
  FView.Invalidate;
  FExited := False;
  FStarted := True;
  FView.StartProgram(FProfile.DrawerCommand);
  if IsOpen and FActive then FView.SetFocus;
end;

procedure TTermDrawer.DoSplitterDrag(Sender: TObject);
var
  delta: Integer;
  W, H: Integer;
  newFrac: Double;
begin
  if FView = nil then Exit;
  delta := FSplitter.Delta;
  W := FParent.Width; H := FParent.Height;
  case Gravity of
    veRight:  newFrac := FFrac - delta / W;   { drag left edge left = wider }
    veLeft:   newFrac := FFrac + delta / W;
    veBottom: newFrac := FFrac - delta / H;
    else      newFrac := FFrac + delta / H;
  end;
  if newFrac < 0.1 then newFrac := 0.1;
  if newFrac > 0.9 then newFrac := 0.9;
  FFrac := newFrac;
  FProfile.DrawerSizeFrac := FFrac;
  LayoutWidgets;
  ApplyReserved;
  if Assigned(FOnPersist) then FOnPersist;
end;

procedure TTermDrawer.PrimeIfEager;
begin
  if FProfile.DrawerLaunch <> tdlOnStart then Exit;
  EnsureView;
  LayoutWidgets;
  StartProgramIfNeeded;
end;

procedure TTermDrawer.RefreshLook(AColorProfile: TTermProfile);
begin
  FColorProfile := AColorProfile;
  if FColorProfile <> nil then
  begin
    FColorFG := FColorProfile.FGColor;
    FColorBG := FColorProfile.BGColor;
  end
  else
  begin
    FColorFG := FProfile.FGColor;
    FColorBG := FProfile.BGColor;
  end;
  FHandle.Caption := FProfile.DrawerName;
  FHandle.BaseColor := FColorBG;
  FHandle.AccentColor := BlendColor(FColorBG, FColorFG, 0.5);
  FHandle.TextColor := FColorFG;
  FFrac := FProfile.DrawerSizeFrac;
  if (FFrac < 0.1) or (FFrac > 0.9) then FFrac := 0.33;
  if FSplitter <> nil then
  begin
    FSplitter.Color := FHandle.AccentColor;
    FSplitter.Vertical := Gravity in [veLeft, veRight];
    if FSplitter.Vertical then FSplitter.MouseCursor := mcSizeEW
    else FSplitter.MouseCursor := mcSizeNS;
  end;
  if FView <> nil then ApplyLook(FView);
  LayoutWidgets;
  ApplyReserved;
  if FHandle.Visible then FHandle.Repaint;
end;

procedure TTermDrawer.SetActive(AOn: Boolean);
begin
  FActive := AOn;
  if AOn then
  begin
    LayoutWidgets;
    { FView/FSplitter only exist once the drawer has been opened at least once
      (or primed eagerly); a never-opened drawer just shows its handle. }
    if FView <> nil then
      FView.Visible := IsOpen and (FState = tdsOpen);
    if FSplitter <> nil then
      FSplitter.Visible := IsOpen and (FState = tdsOpen);
    if FHandle <> nil then
      FHandle.Visible := IsOpen;
    ApplyReserved;
  end
  else
  begin
    if FHandle <> nil then FHandle.Visible := False;
    if FView <> nil then FView.Visible := False;
    if FSplitter <> nil then FSplitter.Visible := False;
    if FAnim <> nil then FAnim.Visible := False;
    FArmed := False;
    FHandleTimer.Enabled := False;
  end;
end;

end.
