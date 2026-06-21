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

  { Lets an embedder claim a key chord before the view's built-in handling.
    Set AHandled := True to consume it (e.g. the app ran a bound action). }
  TTermViewKeyEvent = procedure(Sender: TObject; AKeyCode: Word;
    AShift: TShiftState; var AHandled: Boolean) of object;

  { OSC 8 hyperlink notifications.  The view fires OnLinkHover when the mouse
    enters a link's cells and OnLinkLeave when it leaves them (also on widget
    exit).  ALinkId is the internal id, AURI the resolved target. }
  TTermLinkEvent = procedure(Sender: TObject; ALinkId: Integer;
    const AURI: string) of object;

  { Fired on a bare left-click of a hyperlink.  Set AHandled := True to suppress
    the view's default behaviour (open via xdg-open) — e.g. the embedder/settings
    routed the click to a custom action. }
  TTermLinkClickEvent = procedure(Sender: TObject; ALinkId: Integer;
    const AURI: string; var AHandled: Boolean) of object;

  { Which window edge the pointer is currently hugging (within a few pixels).
    Used to reveal a hover drawer docked to that edge. veNone = no edge / exit. }
  TTermViewEdge = (veNone, veLeft, veRight, veTop, veBottom);

  { Fired (only when it changes) as the button-less pointer enters/leaves the
    margin of a window edge, so an embedder can fade in a docked side panel. }
  TTermEdgeEvent = procedure(Sender: TObject; AEdge: TTermViewEdge) of object;

  { Fired on a left-click into the view.  Set AHandled := True to consume the
    click entirely (no mouse-report, no selection) — e.g. a click that only
    dismissed an overlay. }
  TTermViewClickEvent = procedure(Sender: TObject; var AHandled: Boolean) of object;

  { Off-screen canvas that renders straight into a TfpgImage's 32-bit
    ImageData.  The view uses it to bake the cell grid into a privately-owned
    image that the parent window's full-buffer clear cannot touch; each paint
    then blits that image and draws only the cursor/hover as overlays.

    Backgrounds and lines are written as fully opaque BGRA pixels (no alpha
    blending — the costly AggPas path), so the later image blit hits AggPas's
    opaque copy fast-path.  Glyphs go through the font's DrawTextToBuffer.
    Only the handful of primitives the grid renderer calls are functional;
    the remaining TfpgCanvasBase abstracts are inert stubs. }
  TTermImageCanvas = class(TfpgCanvasBase)
  private
    FData: PByte;
    FStride: Integer;
    FW, FH: Integer;                              { allocated image size, px }
    FColorBGRA: LongWord;                         { pen colour, opaque BGRA }
    FClipX1, FClipY1, FClipX2, FClipY2: Integer;  { half-open clip box }
    procedure FillSpan(AX, AY, AW: Integer); inline;
  protected
    procedure DoSetColor(cl: TfpgColor); override;
    procedure DoSetTextColor(cl: TfpgColor); override;
    procedure DoSetFontRes(fntres: TfpgFontResourceBase); override;
    procedure DoFillRectangle(x, y, w, h: TfpgCoord); override;
    procedure DoDrawLine(x1, y1, x2, y2: TfpgCoord); override;
    procedure DoDrawString(x, y: TfpgCoord; const txt: string); override;
    procedure DoSetClipRect(const ARect: TfpgRect); override;
    function  DoGetClipRect: TfpgRect; override;
    procedure DoAddClipRect(const ARect: TfpgRect); override;
    procedure DoClearClipRect; override;
    { --- unused stubs --- }
    procedure DoSetLineStyle(awidth: integer; astyle: TfpgLineStyle); override;
    procedure DoXORFillRectangle(col: TfpgColor; x, y, w, h: TfpgCoord); override;
    procedure DoFillTriangle(x1, y1, x2, y2, x3, y3: TfpgCoord); override;
    procedure DoDrawRectangle(x, y, w, h: TfpgCoord); override;
    procedure DoDrawImagePart(x, y: TfpgCoord; img: TfpgImageBase; xi, yi, w, h: integer); override;
    procedure DoDrawArc(x, y, w, h: TfpgCoord; a1, a2: double); override;
    procedure DoFillArc(x, y, w, h: TfpgCoord; a1, a2: double); override;
    procedure DoDrawPolygon(const Points: array of TPoint); override;
    function  GetPixel(X, Y: integer): TfpgColor; override;
    procedure SetPixel(X, Y: integer; const AValue: TfpgColor); override;
    procedure DoBeginDraw(awidget: TfpgWidgetBase; CanvasTarget: TfpgCanvasBase); override;
    procedure DoPutBufferToScreen(x, y, w, h: TfpgCoord); override;
    procedure DoEndDraw; override;
    function  GetBufferAllocated: Boolean; override;
    procedure DoAllocateBuffer; override;
    procedure DoRestoreFromBuffer(const ARect: TfpgRect); override;
  public
    { Point the canvas at AImage; clip defaults to the AUsedW x AUsedH
      top-left region (the live grid area within a possibly-larger image). }
    procedure SetTarget(AImage: TfpgImage; AUsedW, AUsedH: Integer);
  end;

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
    { Off-screen grid cache.  The cell grid is baked into FGridImage (via
      FGridCanvas) only when content/layout actually change; every paint just
      blits it and overlays the cursor/hover.  Buffer is grow-only. }
    FGridImage: TfpgImage;
    FGridCanvas: TTermImageCanvas;
    FGridAllocW, FGridAllocH: Integer;   { allocated image size (grow-only) }
    FGridW, FGridH: Integer;             { live grid size the cache reflects }
    FGridTopRow: Integer;                { FTopRow the cache was built for }
    FGridValid: Boolean;                 { cache holds a usable render }
    FFastBlit: Integer;                  { 0=untested, 1=direct copy ok, 2=fall back }
    FGridDirtyAll: Boolean;              { whole grid must be re-rendered }
    FDirtySTop, FDirtySBot: Integer;     { dirty screen-row band; empty when Top>Bot }
    FHoverLinkId: Integer;        { OSC 8 link currently under the mouse, 0 = none }
    FDefaultFGColor: TfpgColor;
    FSelection: TTermSelection;
    FSelectionFGColor: TfpgColor;
    FSelectionBGColor: TfpgColor;
    FOnFontChanged: TNotifyEvent;
    FOnShellExit: TNotifyEvent;
    FOnKeyAction: TTermViewKeyEvent;
    FOnLinkHover: TTermLinkEvent;
    FOnLinkLeave: TTermLinkEvent;
    FOnLinkClick: TTermLinkClickEvent;
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
    { Half-open client-pixel rectangle the view must leave untouched so an
      overlay (the hover drawer) drawn on top of it survives the direct blit.
      Empty when X1>=X2 or Y1>=Y2. }
    FReservedX1, FReservedY1, FReservedX2, FReservedY2: Integer;
    FOnEdgeHover: TTermEdgeEvent;
    FLastEdge: TTermViewEdge;
    FOnViewClick: TTermViewClickEvent;
    { When OnKeyAction consumes a KeyPress, swallow the KeyChar fpGUI delivers
      right after it, so a bound plain key (e.g. drawer relaunch) doesn't also
      type into the PTY. One-shot: reset at the top of every HandleKeyPress. }
    FSuppressNextChar: Boolean;
    function  HasReserved: Boolean; inline;
    function  RectHitsReserved(AX, AY, AW, AH: Integer): Boolean;
    procedure FillRectOutsideReserved(AX, AY, AW, AH: Integer; AColor: TfpgColor);
    function  EdgeAt(AX, AY: Integer): TTermViewEdge;
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
    procedure PaintCell(const ACanvas: TfpgCanvasBase; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
    procedure PaintRowLinks(const ACanvas: TfpgCanvasBase; AViewRow: Integer; const ALine: TTermCellLine);
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
    function  LinkIdAt(X, Y: Integer): Integer;
    function  LinkURI(ALinkId: Integer): string;
    procedure OpenURI(const AURI: string);
    procedure SetHoverLink(ANewLink: Integer);
    procedure InvalidateLinkRows(ALinkA, ALinkB: Integer);
    { Grid cache machinery. }
    procedure MarkGridDirtyAll; inline;
    procedure MarkGridScreenRows(ASTop, ASBot: Integer);
    procedure EnsureGridImage(AW, AH: Integer);
    procedure RenderGridRows(AViewTop, AViewBot: Integer);
    procedure ScrollGridCache(ADeltaRows: Integer);
    procedure UpdateGridCache;
    procedure BlitGrid;
    procedure PaintCursorOverlay;
    procedure PaintHoverOverlay;
    procedure SetDefaultFGColor(AValue: TfpgColor);
    procedure SetDefaultBGColor(AValue: TfpgColor);
  protected
    procedure HandlePaint; override;
    procedure HandleResize(AWidth, AHeight: TfpgCoord); override;
    procedure HandleKeyPress(var keycode: word; var shiftstate: TShiftState; var consumed: boolean); override;
    procedure HandleKeyChar(var AText: TfpgChar; var shiftstate: TShiftState; var consumed: boolean); override;
    procedure HandleLMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleMouseMove(x, y: integer; btnstate: word; shiftstate: TShiftState);  override;
    procedure HandleMouseExit; override;
    procedure HandleLMouseUp(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleRMouseDown(x, y: integer; shiftstate: TShiftState); override;
    procedure HandleShow; override;
    procedure HandleMouseScroll(x, y: integer; shiftstate: TShiftState; delta: smallint); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AttachController(AController: TTerminalController);
    { AStopController=False detaches without killing the PTY child, so the
      live session can be handed to another view (e.g. moved to a new window). }
    procedure DetachController(AStopController: Boolean = True);
    procedure StartShell(const AShell: string = '');
    procedure ScrollBy(ADeltaRows: Integer);
    { Minimum content pixels the view needs to stay above the geometry floor
      (MIN_TERM_COLS x MIN_TERM_ROWS), scrollbar reservation included. The host
      form adds its own chrome (tab strip) and pins the window MinWidth/Height
      so the PTY is never dragged into the prompt-redraw-corruption regime. }
    procedure GetMinPixelSize(out AMinW, AMinH: Integer);

    property Controller: TTerminalController read FController;
    property FontDesc: string read FFontDesc write FFontDesc;
    property EmojiFontDesc: string read FEmojiFontDesc write FEmojiFontDesc;
    property CursorStyle: TCursorStyle read FCursorStyle write FCursorStyle;
    { Default fg/bg used when a cell carries the terminal's default colour.
      Profiles set these; call Invalidate after changing to repaint. }
    property DefaultFGColor: TfpgColor read FDefaultFGColor write SetDefaultFGColor;
    property DefaultBGColor: TfpgColor read FBackgroundColor write SetDefaultBGColor;
    { Copy/paste exposed so an app keymap can bind them to configurable chords.
      CopySelection only copies when there is a selection (returns whether it
      did), so a "smart Ctrl+C" can fall through to SIGINT when nothing is
      selected. }
    function  HasSelection: Boolean;
    function  CopySelection: Boolean;
    procedure PasteClipboard;
    { Fired at the top of key handling; assign to let the app's keybindings
      claim a chord before the view's defaults. }
    property OnKeyAction: TTermViewKeyEvent read FOnKeyAction write FOnKeyAction;
    property OnLinkHover: TTermLinkEvent read FOnLinkHover write FOnLinkHover;
    property OnLinkLeave: TTermLinkEvent read FOnLinkLeave write FOnLinkLeave;
    property OnLinkClick: TTermLinkClickEvent read FOnLinkClick write FOnLinkClick;
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

    { Run an arbitrary command line in this view's PTY (via /bin/sh -c) instead
      of a login shell.  Empty ACmdLine falls back to StartShell. Used by the
      hover drawer to host a custom app. }
    procedure StartProgram(const ACmdLine: string);
    { Reserve a client-pixel band the view will not paint into, so an overlay
      widget drawn on top of it is not clobbered by the grid blit / overlays.
      Pass a degenerate rect (or call ClearReservedRect) to release it. }
    procedure SetReservedRect(AX1, AY1, AX2, AY2: Integer);
    procedure ClearReservedRect;
    { Copy an AW x AH region of the baked grid image starting at (AX,AY) into a
      fresh 32-bit TfpgImage the caller owns.  Lets the drawer grab the pixels
      behind it (background) or its own rendered content for the fade/assemble
      animation.  Areas outside the cache come back as the background colour. }
    function CaptureRegion(AX, AY, AW, AH: Integer): TfpgImage;
    { Force the off-screen grid cache up to date without a window paint, so
      CaptureRegion has content even before the view has been shown. }
    procedure EnsureRendered;
    { Fired when the button-less pointer enters/leaves a window-edge margin. }
    property OnEdgeHover: TTermEdgeEvent read FOnEdgeHover write FOnEdgeHover;
    { Fired on a left-click into this view, so the host can dismiss an overlay
      (e.g. collapse the hover drawer when the user clicks the main console).
      Set AHandled to swallow the click. }
    property OnViewClick: TTermViewClickEvent read FOnViewClick write FOnViewClick;
  end;

  TTerminalFPGUIForm = class(TfpgForm)
  private
    FTerminalView: TTerminalFPGUIView;
  public
    procedure AfterCreate; override;
    property TerminalView: TTerminalFPGUIView read FTerminalView;
  end;

{ Copy AImg's top-left AUsedW x AUsedH region straight into ACanvas's window
  buffer at the current widget origin — a plain memory Move, no AggPas
  transformImage and no alpha blend (DrawImagePart's slow path).  Must be called
  between ACanvas.BeginDraw/EndDraw.  Falls back to DrawImagePart if the live
  canvas isn't the expected THybridCanvas or the hard-cast field layout fails
  the one-time self-check.  Returns True if the fast path was taken. }
function BlitImageDirectToCanvas(ACanvas: TfpgCanvasBase; AImg: TfpgImage;
  AUsedW, AUsedH: Integer): Boolean;

implementation

uses
  Math, process, agg_2D;

type
  { Layout-compatible twin of fpg_hybrid_canvas.THybridCanvas.  That canvas
    exposes no accessor for its window buffer and its only public image entry
    point (DrawImagePart) goes through AggPas transformImage — a per-pixel
    affine span transform that is far too slow for a per-frame full-grid blit.
    We instead hard-cast the live canvas to this twin to reach FBufData and
    copy our cached image straight in (a plain memcpy, the fast path AggPas
    only otherwise reaches via the non-exposed copyImage).

    The field list below MUST mirror THybridCanvas's private fields exactly,
    in order, so the offsets line up.  Both derive from TfpgCanvasBase under
    the same {$mode objfpc}{$H+} default alignment, so the inherited part and
    these fields land at identical offsets. }
  THybridCanvasHack = class(TfpgCanvasBase)
  public
    FAgg: agg_2D.Agg2D;
    FBufferManager: IBufferManager;
    FCurrentTextColor: TfpgColor;
    FWindowAttached: Boolean;
    FAttachedWindow: TfpgWindowBase;
    FBufData: Pointer;
    FBufStride: Integer;
    FBufWidth: Integer;
    FBufHeight: Integer;
    { Block-copy AImg's top-left AUsedW x AUsedH region into the window buffer
      at this canvas's widget origin.  No blend, no interpolation. }
    procedure BlitImageDirect(AImg: TfpgImage; AUsedW, AUsedH: Integer);
    { As BlitImageDirect, but leaves the half-open skip rect untouched so an
      overlay drawn there survives.  The skip rect is always a single edge band
      (full-width horizontal or full-height vertical), so per row we copy the
      kept x-range(s) around it. }
    procedure BlitImageDirectExcept(AImg: TfpgImage; AUsedW, AUsedH: Integer;
      ASkipX1, ASkipY1, ASkipX2, ASkipY2: Integer);
    { Confirm our overlaid fields actually line up with the real canvas by
      writing a sentinel through FBufData and reading it back via the canvas's
      own Pixels[] accessor.  Guards against a silent layout mismatch. }
    function  LayoutMatches: Boolean;
  end;

function THybridCanvasHack.LayoutMatches: Boolean;
const
  SENTINEL_BGRA = LongWord($FF123456);   { B=$56 G=$34 R=$12, opaque }
var
  saved: TfpgColor;
  ox, oy: Integer;
  p: PLongWord;
begin
  Result := False;
  if FBufData = nil then
    Exit;
  ox := FDeltaX;
  oy := FDeltaY;
  { Plausibility gate before touching the pointer: bogus offsets would surface
    as nonsensical buffer geometry here. }
  if (FBufWidth <= 0) or (FBufHeight <= 0) or (FBufWidth > 100000)
     or (FBufHeight > 100000) or (FBufStride < FBufWidth * 4)
     or (ox < 0) or (oy < 0) or (ox >= FBufWidth) or (oy >= FBufHeight) then
    Exit;
  saved := Pixels[0, 0];                  { GetPixel reads FBufData+deltas }
  p := PLongWord(PByte(FBufData) + oy * FBufStride + ox * 4);
  p^ := SENTINEL_BGRA;
  { GetPixel returns $00RRGGBB, so the sentinel reads back as $00123456. }
  Result := (Pixels[0, 0] and $00FFFFFF) = $00123456;
  Pixels[0, 0] := saved;
end;

procedure THybridCanvasHack.BlitImageDirect(AImg: TfpgImage; AUsedW, AUsedH: Integer);
var
  y, rowBytes, ox, oy, srcStride: Integer;
  src, dst: PByte;
begin
  if FBufData = nil then
    Exit;
  { For alien (virtual) widgets DoBeginDraw offsets FBufData to the widget
    origin and zeroes the deltas, but honour FDeltaX/FDeltaY anyway in case a
    given backend leaves the origin at the parent and the delta non-zero. }
  ox := FDeltaX;
  oy := FDeltaY;
  rowBytes := Min(AUsedW, FBufWidth - ox) * 4;
  if rowBytes <= 0 then
    Exit;
  srcStride := AImg.Width * 4;
  for y := 0 to AUsedH - 1 do
  begin
    if oy + y >= FBufHeight then
      Break;
    if oy + y < 0 then
      Continue;
    src := PByte(AImg.ImageData) + y * srcStride;
    dst := PByte(FBufData) + (oy + y) * FBufStride + ox * 4;
    Move(src^, dst^, rowBytes);
  end;
end;

procedure THybridCanvasHack.BlitImageDirectExcept(AImg: TfpgImage;
  AUsedW, AUsedH: Integer; ASkipX1, ASkipY1, ASkipX2, ASkipY2: Integer);
var
  y, ox, oy, srcStride, maxW, keepX2: Integer;
  src, dst: PByte;

  procedure CopySpan(ARow, AColStart, AColCount: Integer);
  begin
    if AColCount <= 0 then Exit;
    if AColStart < 0 then
    begin
      Inc(AColCount, AColStart);
      AColStart := 0;
    end;
    if AColStart + AColCount > maxW then
      AColCount := maxW - AColStart;
    if AColCount <= 0 then Exit;
    src := PByte(AImg.ImageData) + ARow * srcStride + AColStart * 4;
    dst := PByte(FBufData) + (oy + ARow) * FBufStride + (ox + AColStart) * 4;
    Move(src^, dst^, AColCount * 4);
  end;

begin
  if FBufData = nil then Exit;
  ox := FDeltaX;
  oy := FDeltaY;
  maxW := Min(AUsedW, FBufWidth - ox);
  if maxW <= 0 then Exit;
  srcStride := AImg.Width * 4;
  keepX2 := Min(ASkipX2, maxW);
  for y := 0 to AUsedH - 1 do
  begin
    if oy + y >= FBufHeight then Break;
    if oy + y < 0 then Continue;
    if (y >= ASkipY1) and (y < ASkipY2) then
    begin
      { row crosses the band: copy the kept columns on either side }
      CopySpan(y, 0, ASkipX1);
      CopySpan(y, keepX2, maxW - keepX2);
    end
    else
      CopySpan(y, 0, maxW);
  end;
end;

{ Tri-state cache for the free BlitImageDirectToCanvas helper: 0 untested,
  1 direct-copy verified, 2 fall back.  The hard-cast field layout is fixed at
  compile time, so one verification holds for every THybridCanvas instance. }
var
  GDirectBlitState: Integer = 0;

function BlitImageDirectToCanvas(ACanvas: TfpgCanvasBase; AImg: TfpgImage;
  AUsedW, AUsedH: Integer): Boolean;
begin
  Result := False;
  if (ACanvas = nil) or (AImg = nil) then Exit;
  if (GDirectBlitState = 0) and (ACanvas.ClassName = 'THybridCanvas') then
  begin
    if THybridCanvasHack(Pointer(ACanvas)).LayoutMatches then
      GDirectBlitState := 1
    else
      GDirectBlitState := 2;
  end;
  if (GDirectBlitState = 1) and (ACanvas.ClassName = 'THybridCanvas') then
  begin
    THybridCanvasHack(Pointer(ACanvas)).BlitImageDirect(AImg, AUsedW, AUsedH);
    Result := True;
  end
  else
    ACanvas.DrawImagePart(0, 0, AImg, 0, 0, AUsedW, AUsedH);
end;


const
  CURSOR_BLINK_MS = 750;
  PUMP_MS = 20;
  SELECTION_DRAG_THRESHOLD = 3; { pixels before mouse-down -> selection }
  EDGE_HOVER_PX = 6;            { pointer proximity that arms a docked drawer }

  { Floor on the PTY geometry. Below ~2 rows or a couple dozen columns a
    line-editor's SIGWINCH redraw (bash readline only erases the current
    prompt line plus one above it) stops being able to scrub a prompt that
    now wraps to 3+ rows, so stale prompt fragments survive each shrink.
    Reflow then faithfully carries those fragments forward and they pile up.
    Real terminals dodge the whole regime by refusing to get that small —
    gnome-terminal floors at 28x2 — so we do the same. }
  MIN_TERM_COLS = 28;
  MIN_TERM_ROWS = 2;

  CONTEXT_COPY = 0;
  CONTEXT_PASTE = 1;
  CONTEXT_FONT = 2;
  CONTEXT_EMOJI_FONT = 3;
  CONTEXT_COPY_HTML_SEL = 4;
  CONTEXT_COPY_HTML_SCREEN = 5;
  CONTEXT_COPY_HTML_ALL = 6;


{ fpgColorToRGB yields $00RRGGBB whose low 24 bits already sit as B,G,R in
  little-endian memory — exactly the BGRA byte order AggPas and the glyph cache
  use.  Forcing alpha to $FF keeps every pixel opaque so the image blit takes
  AggPas's straight-copy fast-path instead of the per-pixel alpha blend. }
function ColorToOpaqueBGRA(c: TfpgColor): LongWord; inline;
begin
  Result := (fpgColorToRGB(c) and $00FFFFFF) or $FF000000;
end;

{ TTermImageCanvas }

procedure TTermImageCanvas.SetTarget(AImage: TfpgImage; AUsedW, AUsedH: Integer);
begin
  FData := PByte(AImage.ImageData);
  FW := AImage.Width;
  FH := AImage.Height;
  FStride := FW * 4;
  FClipX1 := 0;
  FClipY1 := 0;
  FClipX2 := AUsedW;
  FClipY2 := AUsedH;
end;

procedure TTermImageCanvas.FillSpan(AX, AY, AW: Integer);
var
  x1, x2: Integer;
  p: PLongWord;
begin
  if (AY < FClipY1) or (AY >= FClipY2) or (AY < 0) or (AY >= FH) then
    Exit;
  x1 := AX;
  x2 := AX + AW;
  if x1 < FClipX1 then x1 := FClipX1;
  if x2 > FClipX2 then x2 := FClipX2;
  if x1 < 0 then x1 := 0;
  if x2 > FW then x2 := FW;
  if x2 <= x1 then
    Exit;
  p := PLongWord(FData + AY * FStride + x1 * 4);
  FillDWord(p^, x2 - x1, FColorBGRA);
end;

procedure TTermImageCanvas.DoSetColor(cl: TfpgColor);
begin
  FColor := cl;
  FColorBGRA := ColorToOpaqueBGRA(cl);
end;

procedure TTermImageCanvas.DoSetTextColor(cl: TfpgColor);
begin
  FTextColor := cl;
end;

procedure TTermImageCanvas.DoSetFontRes(fntres: TfpgFontResourceBase);
begin
  { TfpgCanvasBase.SetFont already stored fntres in FFont; nothing else to do. }
end;

procedure TTermImageCanvas.DoFillRectangle(x, y, w, h: TfpgCoord);
var
  yy: Integer;
begin
  if FData = nil then
    Exit;
  for yy := y to y + h - 1 do
    FillSpan(x, yy, w);
end;

procedure TTermImageCanvas.DoDrawLine(x1, y1, x2, y2: TfpgCoord);
var
  i, dx, dy, sx, sy, err, e2: Integer;
begin
  if FData = nil then
    Exit;
  if y1 = y2 then
  begin
    if x2 >= x1 then FillSpan(x1, y1, x2 - x1 + 1)
    else FillSpan(x2, y1, x1 - x2 + 1);
    Exit;
  end;
  if x1 = x2 then
  begin
    if y2 < y1 then begin i := y1; y1 := y2; y2 := i; end;
    for i := y1 to y2 do
      FillSpan(x1, i, 1);
    Exit;
  end;
  { Generic Bresenham — the grid renderer only ever draws horizontals, so this
    is just a safety net. }
  dx := Abs(x2 - x1);
  dy := -Abs(y2 - y1);
  if x1 < x2 then sx := 1 else sx := -1;
  if y1 < y2 then sy := 1 else sy := -1;
  err := dx + dy;
  while True do
  begin
    FillSpan(x1, y1, 1);
    if (x1 = x2) and (y1 = y2) then
      Break;
    e2 := 2 * err;
    if e2 >= dy then begin err := err + dy; x1 := x1 + sx; end;
    if e2 <= dx then begin err := err + dx; y1 := y1 + sy; end;
  end;
end;

procedure TTermImageCanvas.DoDrawString(x, y: TfpgCoord; const txt: string);
begin
  if (FData = nil) or (FFont = nil) or (Length(txt) = 0) then
    Exit;
  { AY is the baseline (top + ascent), matching the window canvas. }
  FFont.DrawTextToBuffer(FData, FStride, FW, FH,
    x, y + FFont.GetAscent, txt, FTextColor,
    FClipX1, FClipY1, FClipX2, FClipY2);
end;

procedure TTermImageCanvas.DoSetClipRect(const ARect: TfpgRect);
begin
  FClipX1 := ARect.Left;
  FClipY1 := ARect.Top;
  FClipX2 := ARect.Left + ARect.Width;
  FClipY2 := ARect.Top + ARect.Height;
end;

function TTermImageCanvas.DoGetClipRect: TfpgRect;
begin
  Result.SetRect(FClipX1, FClipY1, FClipX2 - FClipX1, FClipY2 - FClipY1);
end;

procedure TTermImageCanvas.DoAddClipRect(const ARect: TfpgRect);
begin
  if ARect.Left > FClipX1 then FClipX1 := ARect.Left;
  if ARect.Top  > FClipY1 then FClipY1 := ARect.Top;
  if ARect.Left + ARect.Width  < FClipX2 then FClipX2 := ARect.Left + ARect.Width;
  if ARect.Top  + ARect.Height < FClipY2 then FClipY2 := ARect.Top + ARect.Height;
end;

procedure TTermImageCanvas.DoClearClipRect;
begin
  FClipX1 := 0;
  FClipY1 := 0;
  FClipX2 := FW;
  FClipY2 := FH;
end;

{ --- inert stubs: the grid renderer never calls these --- }
procedure TTermImageCanvas.DoSetLineStyle(awidth: integer; astyle: TfpgLineStyle); begin end;
procedure TTermImageCanvas.DoXORFillRectangle(col: TfpgColor; x, y, w, h: TfpgCoord); begin end;
procedure TTermImageCanvas.DoFillTriangle(x1, y1, x2, y2, x3, y3: TfpgCoord); begin end;
procedure TTermImageCanvas.DoDrawRectangle(x, y, w, h: TfpgCoord); begin end;
procedure TTermImageCanvas.DoDrawImagePart(x, y: TfpgCoord; img: TfpgImageBase; xi, yi, w, h: integer); begin end;
procedure TTermImageCanvas.DoDrawArc(x, y, w, h: TfpgCoord; a1, a2: double); begin end;
procedure TTermImageCanvas.DoFillArc(x, y, w, h: TfpgCoord; a1, a2: double); begin end;
procedure TTermImageCanvas.DoDrawPolygon(const Points: array of TPoint); begin end;
function  TTermImageCanvas.GetPixel(X, Y: integer): TfpgColor; begin Result := 0; end;
procedure TTermImageCanvas.SetPixel(X, Y: integer; const AValue: TfpgColor); begin end;
procedure TTermImageCanvas.DoBeginDraw(awidget: TfpgWidgetBase; CanvasTarget: TfpgCanvasBase); begin end;
procedure TTermImageCanvas.DoPutBufferToScreen(x, y, w, h: TfpgCoord); begin end;
procedure TTermImageCanvas.DoEndDraw; begin end;
function  TTermImageCanvas.GetBufferAllocated: Boolean; begin Result := FData <> nil; end;
procedure TTermImageCanvas.DoAllocateBuffer; begin end;
procedure TTermImageCanvas.DoRestoreFromBuffer(const ARect: TfpgRect); begin end;


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
  FGridCanvas := TTermImageCanvas.Create(nil);
  FGridImage := nil;
  FGridAllocW := 0;
  FGridAllocH := 0;
  FGridValid := False;
  FFastBlit := 0;
  FGridDirtyAll := True;
  FGridTopRow := 0;
  FDirtySTop := 1;     { empty band (Top > Bot) }
  FDirtySBot := 0;
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
  FreeAndNil(FGridCanvas);
  FreeAndNil(FGridImage);
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
  MarkGridDirtyAll;
  Repaint;
end;

procedure TTerminalFPGUIView.DetachController(AStopController: Boolean = True);
begin
  if FController <> nil then
  begin
    FController.Core.OnInvalidate := nil;
    FController.Core.OnBell := nil;
    FController.Core.OnTitle := nil;
    FController.Core.OnClipboardSet := nil;
    FController.Core.OnClipboardGet := nil;
    if AStopController then
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

procedure TTerminalFPGUIView.StartProgram(const ACmdLine: string);
begin
  if FController = nil then Exit;
  if Trim(ACmdLine) = '' then
  begin
    StartShell;
    Exit;
  end;
  SyncSizeToController;
  { Run through the shell so the user can write a full command line (args,
    pipes, env) and still get a PTY-backed child.  argv MUST include argv[0]
    (the program name) — otherwise sh is exec'd with argv[0]='-c', treats the
    command as a filename, and exits 2 immediately. }
  FController.StartCommand('/bin/sh', ['/bin/sh', '-c', ACmdLine]);
  SyncSizeToController;
end;

function TTerminalFPGUIView.HasReserved: Boolean;
begin
  Result := (FReservedX2 > FReservedX1) and (FReservedY2 > FReservedY1);
end;

procedure TTerminalFPGUIView.SetReservedRect(AX1, AY1, AX2, AY2: Integer);
begin
  if (AX1 = FReservedX1) and (AY1 = FReservedY1)
     and (AX2 = FReservedX2) and (AY2 = FReservedY2) then
    Exit;
  FReservedX1 := AX1; FReservedY1 := AY1;
  FReservedX2 := AX2; FReservedY2 := AY2;
  Repaint;
end;

procedure TTerminalFPGUIView.ClearReservedRect;
begin
  SetReservedRect(0, 0, 0, 0);
end;

function TTerminalFPGUIView.RectHitsReserved(AX, AY, AW, AH: Integer): Boolean;
begin
  Result := HasReserved
    and (AX < FReservedX2) and (AX + AW > FReservedX1)
    and (AY < FReservedY2) and (AY + AH > FReservedY1);
end;

{ Fill the requested rect with AColor, but carve out the reserved band (up to
  four surrounding sub-rects).  Used for the sub-cell bottom remainder so it
  never repaints under the drawer. }
procedure TTerminalFPGUIView.FillRectOutsideReserved(AX, AY, AW, AH: Integer;
  AColor: TfpgColor);
var
  rx1, ry1, rx2, ry2: Integer;
begin
  Canvas.Color := AColor;
  if not RectHitsReserved(AX, AY, AW, AH) then
  begin
    Canvas.FillRectangle(AX, AY, AW, AH);
    Exit;
  end;
  rx1 := Max(AX, FReservedX1); ry1 := Max(AY, FReservedY1);
  rx2 := Min(AX + AW, FReservedX2); ry2 := Min(AY + AH, FReservedY2);
  if AY < ry1 then               { strip above the hole }
    Canvas.FillRectangle(AX, AY, AW, ry1 - AY);
  if AY + AH > ry2 then          { strip below the hole }
    Canvas.FillRectangle(AX, ry2, AW, AY + AH - ry2);
  if AX < rx1 then               { strip left of the hole }
    Canvas.FillRectangle(AX, ry1, rx1 - AX, ry2 - ry1);
  if AX + AW > rx2 then          { strip right of the hole }
    Canvas.FillRectangle(rx2, ry1, AX + AW - rx2, ry2 - ry1);
end;

function TTerminalFPGUIView.EdgeAt(AX, AY: Integer): TTermViewEdge;
var
  W, H: Integer;
begin
  Result := veNone;
  W := ClientWidth;
  H := ActualHeight;
  if (AX < 0) or (AY < 0) or (AX >= W) or (AY >= H) then Exit;
  if AX <= EDGE_HOVER_PX then Result := veLeft
  else if AX >= W - 1 - EDGE_HOVER_PX then Result := veRight
  else if AY <= EDGE_HOVER_PX then Result := veTop
  else if AY >= H - 1 - EDGE_HOVER_PX then Result := veBottom;
end;

function TTerminalFPGUIView.CaptureRegion(AX, AY, AW, AH: Integer): TfpgImage;
var
  Img: TfpgImage;
  y, copyW, srcStride, dstStride: Integer;
  src, dst: PByte;
  px: PLongWord;
  i: Integer;
begin
  if AW < 1 then AW := 1;
  if AH < 1 then AH := 1;
  Img := TfpgImage.Create;
  Img.AllocateImage(32, AW, AH);
  dstStride := AW * 4;
  { Pre-fill with the background colour so out-of-cache pixels are sane. }
  for y := 0 to AH - 1 do
  begin
    px := PLongWord(PByte(Img.ImageData) + y * dstStride);
    for i := 0 to AW - 1 do
    begin
      px^ := ColorToOpaqueBGRA(FBackgroundColor);
      Inc(px);
    end;
  end;
  if (FGridImage <> nil) and FGridValid then
  begin
    srcStride := FGridImage.Width * 4;
    for y := 0 to AH - 1 do
    begin
      if (AY + y < 0) or (AY + y >= FGridH) then Continue;
      copyW := Min(AW, FGridW - AX);
      if (AX < 0) or (copyW <= 0) then Continue;
      src := PByte(FGridImage.ImageData) + (AY + y) * srcStride + AX * 4;
      dst := PByte(Img.ImageData) + y * dstStride;
      Move(src^, dst^, copyW * 4);
    end;
  end;
  Img.UpdateImage;
  Result := Img;
end;

procedure TTerminalFPGUIView.EnsureRendered;
begin
  if FController = nil then Exit;
  UpdateMetrics;
  UpdateGridCache;
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
    MarkGridDirtyAll;
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

  { Record the changed band in screen-row coordinates (stable across FTopRow /
    history growth) so HandlePaint re-bakes only those rows of the grid cache.
    We still Invalidate the whole client: as a virtual child our invalidation
    bubbles to the parent which clears the shared buffer regardless — but the
    cache spares us re-rendering glyphs for the unchanged rows. }
  MarkGridScreenRows(ARect.Top, ARect.Bottom);
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

procedure TTerminalFPGUIView.GetMinPixelSize(out AMinW, AMinH: Integer);
begin
  UpdateMetrics;
  AMinW := MIN_TERM_COLS * FCharWidth + Max(FScrollbar.Width, 18);
  AMinH := MIN_TERM_ROWS * FCharHeight;
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

  { In the alternate screen buffer the app manages its own scrolling, so there
    is no scrollback to show — hide the bar.  The grid width is unchanged (the
    column is always reserved), so this is purely visual: no resize. }
  FScrollBar.Visible := not FController.Core.InAltBuffer;

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

function TTerminalFPGUIView.HasSelection: Boolean;
begin
  Result := FSelection.Active and FSelection.Selecting;
end;

function TTerminalFPGUIView.LinkIdAt(X, Y: Integer): Integer;
var
  P: TTermCellPos;
  Line: TTermCellLine;
begin
  Result := 0;
  if FController = nil then Exit;
  P := PixelToCell(X, Y);
  Line := GetVirtualLine(P.Row);
  if (P.Col >= 0) and (P.Col < Length(Line)) then
    Result := Line[P.Col].LinkId;
end;

procedure TTerminalFPGUIView.InvalidateLinkRows(ALinkA, ALinkB: Integer);
{ Repaint only the view rows that carry link id ALinkA or ALinkB.  Used by the
  hover machinery so toggling a link between dotted and solid touches just the
  affected lines instead of the whole grid.  Link 0 matches nothing. }
var
  Row, Col, ViewRows: Integer;
  Line: TTermCellLine;
  MinRow, MaxRow, LId: Integer;
  Rect: TfpgRect;
begin
  if FController = nil then Exit;
  if (ALinkA = 0) and (ALinkB = 0) then Exit;

  ViewRows := RowsVisible;
  MinRow := MaxInt;
  MaxRow := -1;
  for Row := 0 to ViewRows - 1 do
  begin
    Line := GetVirtualLine(FTopRow + Row);
    for Col := 0 to High(Line) do
    begin
      LId := Line[Col].LinkId;
      if (LId <> 0) and ((LId = ALinkA) or (LId = ALinkB)) then
      begin
        if Row < MinRow then MinRow := Row;
        if Row > MaxRow then MaxRow := Row;
        Break;        { one hit per row is enough to mark it dirty }
      end;
    end;
  end;

  if MaxRow < 0 then Exit;   { link isn't currently visible }

  Rect.SetRect(0, MinRow * FCharHeight, ClientWidth,
               (MaxRow - MinRow + 1) * FCharHeight + 1);  { +1 for the baseline }
  InvalidateRect(Rect);
end;

function TTerminalFPGUIView.LinkURI(ALinkId: Integer): string;
begin
  if (ALinkId <> 0) and (FController <> nil) then
    Result := FController.Core.HyperlinkURI(ALinkId)
  else
    Result := '';
end;

procedure TTerminalFPGUIView.SetHoverLink(ANewLink: Integer);
{ Change which link is drawn solid.  The cell data is never touched — the
  hovered id is a view-only overlay — and we repaint only the old and new
  link's rows so moving on/off a link is a cheap dirty-line refresh. }
var
  OldLink: Integer;
begin
  if ANewLink = FHoverLinkId then Exit;
  OldLink := FHoverLinkId;
  FHoverLinkId := ANewLink;
  if ANewLink <> 0 then
    MouseCursor := mcHand
  else
    MouseCursor := mcDefault;
  InvalidateLinkRows(OldLink, ANewLink);

  { Notify embedders: leave the old link first, then enter the new one. }
  if (OldLink <> 0) and Assigned(FOnLinkLeave) then
    FOnLinkLeave(Self, OldLink, LinkURI(OldLink));
  if (ANewLink <> 0) and Assigned(FOnLinkHover) then
    FOnLinkHover(Self, ANewLink, LinkURI(ANewLink));
end;

procedure TTerminalFPGUIView.OpenURI(const AURI: string);
var
  Proc: TProcess;
begin
  if AURI = '' then Exit;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'xdg-open';
    Proc.Parameters.Add(AURI);
    Proc.Options := [];                 { detached; don't block the pump }
    try
      Proc.Execute;
    except
      on E: Exception do { ignore — a bad URI must not crash the terminal };
    end;
  finally
    Proc.Free;
  end;
end;

function TTerminalFPGUIView.CopySelection: Boolean;
begin
  Result := HasSelection;
  if Result then
    DoCopy;
end;

procedure TTerminalFPGUIView.PasteClipboard;
begin
  DoPaste;
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
  MarkGridDirtyAll;
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
    MarkGridDirtyAll;
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
  Cols := Max(MIN_TERM_COLS, ClientWidth div FCharWidth);
  Rows := Max(MIN_TERM_ROWS, ActualHeight div FCharHeight);
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
  { Always reserve the scrollbar's column so the grid width — and therefore the
    PTY column count — stays constant whether or not the scrollbar is showing.
    Changing columns on every alt-screen enter/exit caused SIGWINCH storms and
    reflow corruption of the restored main-buffer scrollback. }
  Result := ActualWidth - FScrollbar.ActualWidth;
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

procedure TTerminalFPGUIView.PaintCell(const ACanvas: TfpgCanvasBase; ACol, AViewRow: Integer; const ACell: TTermCell; AHasCursor: Boolean); inline;
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

  ACanvas.Color := FG;
  if tafStrike in ACell.Attrs then
    ACanvas.DrawLine(R.Left, R.Top + R.Height div 2,
                     R.Right, R.Top + R.Height div 2);

  { A plain SGR underline is drawn per cell (it abuts cleanly across cells).
    Hyperlink underlines are drawn separately by PaintRowLinks as one coalesced
    run per link, so the dotted phase stays continuous instead of restarting at
    every cell boundary. }
  if (ACell.LinkId = 0) and (tafUnderline in ACell.Attrs) then
    ACanvas.DrawLine(R.Left, R.Bottom, R.Right, R.Bottom);
end;

procedure TTerminalFPGUIView.PaintRowLinks(const ACanvas: TfpgCanvasBase;
  AViewRow: Integer; const ALine: TTermCellLine);
{ Draw OSC 8 hyperlink underlines for one row, coalescing adjacent cells that
  share a link id into a single run.  A run is solid when hovered, otherwise a
  dotted line whose phase is continuous across the whole run (rather than
  restarting at each cell, which made the dots look uneven). }
var
  Col, RunStart, MaxCol, LId, X, Y, RunRight: Integer;
begin
  MaxCol := Min(High(ALine), ColsVisible - 1);
  Y := AViewRow * FCharHeight + FCharHeight - 1;
  Col := 0;
  while Col <= MaxCol do
  begin
    LId := ALine[Col].LinkId;
    if LId = 0 then
    begin
      Inc(Col);
      Continue;
    end;

    { Extend the run over contiguous cells carrying the same link id. }
    RunStart := Col;
    while (Col <= MaxCol) and (ALine[Col].LinkId = LId) do
      Inc(Col);
    RunRight := Col * FCharWidth - 1;        { right edge of the last run cell }

    { Colour the underline like the link text (first cell of the run). }
    ACanvas.Color := MapColor(ALine[RunStart].FG, False);

    if LId = FHoverLinkId then
      ACanvas.DrawLine(RunStart * FCharWidth, Y, RunRight + 1, Y)
    else
    begin
      X := RunStart * FCharWidth;
      while X <= RunRight do
      begin
        ACanvas.FillRectangle(X, Y, 1, 1);   { 1px dot ... }
        Inc(X, 3);                            { ... every 3px, continuous phase }
      end;
    end;
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
begin
  inherited HandlePaint;
  UpdateMetrics;

  Canvas.BeginDraw;
  try
    if FController <> nil then
    begin
      if FController.Core.InAltBuffer then
        FTopRow := FController.Core.HistoryCount;

      { Re-bake only what changed into the private grid image, then blit it.
        The cursor and hover highlight are drawn as overlays on top so a blink
        or a hover change costs a cheap re-blit, not a full glyph re-render. }
      UpdateGridCache;
      BlitGrid;

      { Bottom remainder (client height not an exact multiple of a cell) is not
        covered by the grid image; paint it in the background colour. }
      if FGridH < ActualHeight then
        FillRectOutsideReserved(0, FGridH, ClientWidth, ActualHeight - FGridH,
          FBackgroundColor);

      PaintCursorOverlay;
      PaintHoverOverlay;
    end
    else
    begin
      Canvas.Color := FBackgroundColor;
      Canvas.FillRectangle(0, 0, ClientWidth, ActualHeight);
    end;
  finally
    Canvas.EndDraw;
  end;
end;

procedure TTerminalFPGUIView.MarkGridDirtyAll;
begin
  FGridDirtyAll := True;
end;

procedure TTerminalFPGUIView.SetDefaultFGColor(AValue: TfpgColor);
begin
  FDefaultFGColor := AValue;
  MarkGridDirtyAll;   { default colour is baked into the grid cache }
end;

procedure TTerminalFPGUIView.SetDefaultBGColor(AValue: TfpgColor);
begin
  FBackgroundColor := AValue;
  MarkGridDirtyAll;
end;

procedure TTerminalFPGUIView.MarkGridScreenRows(ASTop, ASBot: Integer);
begin
  if ASTop > ASBot then
    Exit;
  if FDirtySTop > FDirtySBot then
  begin
    FDirtySTop := ASTop;
    FDirtySBot := ASBot;
  end
  else
  begin
    if ASTop < FDirtySTop then FDirtySTop := ASTop;
    if ASBot > FDirtySBot then FDirtySBot := ASBot;
  end;
end;

procedure TTerminalFPGUIView.EnsureGridImage(AW, AH: Integer);
var
  NW, NH: Integer;
begin
  if AW < 1 then AW := 1;
  if AH < 1 then AH := 1;
  if (FGridImage <> nil) and (FGridAllocW >= AW) and (FGridAllocH >= AH) then
    Exit;
  { Grow-only: never shrink the buffer, just enlarge it to fit. }
  NW := Max(AW, FGridAllocW);
  NH := Max(AH, FGridAllocH);
  FreeAndNil(FGridImage);
  FGridImage := TfpgImage.Create;
  FGridImage.AllocateImage(32, NW, NH);
  FGridImage.UpdateImage;
  FGridAllocW := NW;
  FGridAllocH := NH;
  FGridValid := False;   { fresh buffer holds nothing usable }
end;

{ Re-bake view rows [AViewTop..AViewBot] of the grid into FGridImage.  The
  cursor is excluded (drawn as an overlay) and hyperlink underlines are baked
  as plain dotted runs (the hover solid line is also an overlay), so neither a
  blink nor a hover change forces a re-render. }
procedure TTerminalFPGUIView.RenderGridRows(AViewTop, AViewBot: Integer);
var
  Row, Col, MaxCol, SavedHover: Integer;
  Line: TTermCellLine;
  Cell: TTermCell;
  ClipR: TfpgRect;
begin
  if FController = nil then
    Exit;
  if AViewTop < 0 then AViewTop := 0;
  if AViewBot > RowsVisible - 1 then AViewBot := RowsVisible - 1;
  if AViewTop > AViewBot then
    Exit;

  ClipR.SetRect(0, AViewTop * FCharHeight, FGridW,
                (AViewBot - AViewTop + 1) * FCharHeight);
  FGridCanvas.SetClipRect(ClipR);

  { Clear the band first so blank cells / short lines / the column remainder
    show the background colour. }
  FGridCanvas.Color := FBackgroundColor;
  FGridCanvas.FillRectangle(ClipR);

  SavedHover := FHoverLinkId;
  FHoverLinkId := 0;
  try
    for Row := AViewTop to AViewBot do
    begin
      Line := GetVirtualLine(FTopRow + Row);
      if Length(Line) = 0 then
        Continue;
      MaxCol := Min(High(Line), ColsVisible - 1);
      for Col := 0 to MaxCol do
      begin
        Cell := Line[Col];
        PaintCell(FGridCanvas, Col, Row, Cell, False);
      end;
      PaintRowLinks(FGridCanvas, Row, Line);
    end;
  finally
    FHoverLinkId := SavedHover;
  end;
end;

{ Shift the cached grid image by ADeltaRows (positive = viewport advanced, so
  content moves up) with a single memmove, then re-bake only the rows the shift
  exposed.  Lets scrollback navigation reuse the already-rendered glyphs. }
procedure TTerminalFPGUIView.ScrollGridCache(ADeltaRows: Integer);
var
  RV, stride, shiftPx, movePx: Integer;
  base: PByte;
begin
  RV := RowsVisible;
  if (FGridImage = nil) or (Abs(ADeltaRows) >= RV) then
  begin
    RenderGridRows(0, RV - 1);
    Exit;
  end;
  stride := FGridImage.Width * 4;
  base := PByte(FGridImage.ImageData);
  shiftPx := Abs(ADeltaRows) * FCharHeight;
  movePx := (RV - Abs(ADeltaRows)) * FCharHeight;
  if movePx > 0 then
  begin
    if ADeltaRows > 0 then
    begin
      Move((base + shiftPx * stride)^, base^, movePx * stride);
      RenderGridRows(RV - ADeltaRows, RV - 1);
    end
    else
    begin
      Move(base^, (base + shiftPx * stride)^, movePx * stride);
      RenderGridRows(0, (-ADeltaRows) - 1);
    end;
  end
  else
    RenderGridRows(0, RV - 1);
end;

{ Decide the minimal work to make FGridImage current, then do it. }
procedure TTerminalFPGUIView.UpdateGridCache;
var
  RV, GW, GH, D, vTop, vBot: Integer;
  ContentDirty: Boolean;
begin
  if FController = nil then
    Exit;

  RV := RowsVisible;
  GW := ClientWidth;
  GH := RV * FCharHeight;
  if GW < 1 then GW := 1;
  if GH < 1 then GH := 1;

  EnsureGridImage(GW, GH);
  FGridCanvas.SetTarget(FGridImage, GW, GH);
  FGridW := GW;
  FGridH := GH;

  ContentDirty := FDirtySTop <= FDirtySBot;

  if FGridDirtyAll or (not FGridValid) then
    RenderGridRows(0, RV - 1)
  else if ContentDirty then
  begin
    if FTopRow <> FGridTopRow then
      { content changed and the viewport scrolled in the same tick — re-bake
        the whole visible grid rather than untangle the two. }
      RenderGridRows(0, RV - 1)
    else
    begin
      vTop := FController.Core.HistoryCount + FDirtySTop - FTopRow;
      vBot := FController.Core.HistoryCount + FDirtySBot - FTopRow;
      RenderGridRows(vTop, vBot);
    end;
  end
  else if FTopRow <> FGridTopRow then
  begin
    D := FTopRow - FGridTopRow;
    if Abs(D) >= RV then
      RenderGridRows(0, RV - 1)
    else
      ScrollGridCache(D);
  end;
  { else: nothing changed — keep the cache (cursor blink / hover only). }

  FGridValid := True;
  FGridTopRow := FTopRow;
  FGridDirtyAll := False;
  FDirtySTop := 1;   { reset to empty }
  FDirtySBot := 0;
end;

procedure TTerminalFPGUIView.BlitGrid;
begin
  if FGridImage = nil then
    Exit;
  { Fast path: when the live canvas is the AggPas hybrid canvas (always, on this
    build) copy the cached image straight into its window buffer.  The first
    time, verify the hard-cast field layout actually matches before trusting it;
    fall back to the (slow) transformImage blit otherwise. }
  if FFastBlit = 0 then
  begin
    if (Canvas.ClassName = 'THybridCanvas')
       and THybridCanvasHack(Pointer(Canvas)).LayoutMatches then
      FFastBlit := 1
    else
      FFastBlit := 2;
  end;

  if FFastBlit = 1 then
  begin
    if HasReserved then
      THybridCanvasHack(Pointer(Canvas)).BlitImageDirectExcept(FGridImage,
        FGridW, FGridH, FReservedX1, FReservedY1, FReservedX2, FReservedY2)
    else
      THybridCanvasHack(Pointer(Canvas)).BlitImageDirect(FGridImage, FGridW, FGridH);
  end
  else
    Canvas.DrawImagePart(0, 0, FGridImage, 0, 0, FGridW, FGridH);
end;

procedure TTerminalFPGUIView.PaintCursorOverlay;
var
  CursorVirtualRow, CursorViewRow: Integer;
  Line: TTermCellLine;
  Cell: TTermCell;
  R: TfpgRect;
begin
  if (FController = nil) or (not FController.Core.Cursor.Visible)
     or (not FCursorBlinkVisible) then
    Exit;
  CursorVirtualRow := FController.Core.HistoryCount + FController.Core.Cursor.Row;
  CursorViewRow := CursorVirtualRow - FTopRow;
  if (CursorViewRow < 0) or (CursorViewRow >= RowsVisible) then
    Exit;
  { Don't draw the main cursor under the drawer overlay. }
  if RectHitsReserved(FController.Core.Cursor.Col * FCharWidth,
       CursorViewRow * FCharHeight, FCharWidth, FCharHeight) then
    Exit;

  case FCursorStyle of
    csBlock:
      begin
        Line := GetVirtualLine(CursorVirtualRow);
        if (FController.Core.Cursor.Col >= 0)
           and (FController.Core.Cursor.Col <= High(Line)) then
          Cell := Line[FController.Core.Cursor.Col];
        { else Cell stays default-initialised (blank), giving a plain block. }
        PaintCell(Canvas, FController.Core.Cursor.Col, CursorViewRow, Cell, True);
      end;
    csUnderscore:
      begin
        R := CellRect(FController.Core.Cursor.Col, CursorViewRow);
        Canvas.Color := $00A0A0A0;
        Canvas.FillRectangle(R.Left, R.Top + FCharHeight - 2, FCharWidth, 2);
      end;
  end;
end;

procedure TTerminalFPGUIView.PaintHoverOverlay;
var
  Row, Col, MaxCol, RunStart, RunRight, Y: Integer;
  Line: TTermCellLine;
begin
  if (FController = nil) or (FHoverLinkId = 0) then
    Exit;
  for Row := 0 to RowsVisible - 1 do
  begin
    Line := GetVirtualLine(FTopRow + Row);
    if Length(Line) = 0 then
      Continue;
    MaxCol := Min(High(Line), ColsVisible - 1);
    Y := Row * FCharHeight + FCharHeight - 1;
    Col := 0;
    while Col <= MaxCol do
    begin
      if Line[Col].LinkId <> FHoverLinkId then
      begin
        Inc(Col);
        Continue;
      end;
      RunStart := Col;
      while (Col <= MaxCol) and (Line[Col].LinkId = FHoverLinkId) do
        Inc(Col);
      RunRight := Col * FCharWidth - 1;
      if RectHitsReserved(RunStart * FCharWidth, Row * FCharHeight,
           RunRight + 1 - RunStart * FCharWidth, FCharHeight) then
        Continue;
      Canvas.Color := MapColor(Line[RunStart].FG, False);
      Canvas.DrawLine(RunStart * FCharWidth, Y, RunRight + 1, Y);
    end;
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
  MarkGridDirtyAll;
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
var
  LHandled: Boolean;
begin
  inherited HandleKeyPress(keycode, shiftstate, consumed);
  if FController = nil then
    Exit;
  FSuppressNextChar := False;

  { App keybindings get first refusal. If the app consumes the chord (e.g. ran
    a bound action), we stop; otherwise fall through to the built-in defaults. }
  if Assigned(FOnKeyAction) then
  begin
    LHandled := False;
    FOnKeyAction(Self, keycode, shiftstate, LHandled);
    if LHandled then
    begin
      consumed := True;
      FSuppressNextChar := True;   { eat the char fpGUI emits for this key }
      Exit;
    end;
  end;

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
  { A key just consumed by OnKeyAction (e.g. drawer relaunch) must not also be
    typed into the PTY. }
  if FSuppressNextChar then
  begin
    FSuppressNextChar := False;
    consumed := True;
    Exit;
  end;
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
  ClickHandled: Boolean;
begin
  { Close any open context menu first. fpGUI on Windows doesn't always
    dismiss popups on a click into the owning widget. }
  if (FContextMenu <> nil) and (FContextMenu.Window <> nil)
     and FContextMenu.Window.HasHandle then
    FContextMenu.Close;
  { Let the host claim the click (e.g. dismiss an overlay).  When it does we
    swallow the click entirely — no mouse-report, no selection start. }
  if Assigned(FOnViewClick) then
  begin
    ClickHandled := False;
    FOnViewClick(Self, ClickHandled);
    if ClickHandled then Exit;
  end;
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
  begin
    MarkGridDirtyAll;   { selection highlight is baked into the grid cache }
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.HandleMouseMove(x, y: integer; btnstate: word;
  shiftstate: TShiftState);
var
  Cell: TTermCellPos;
  Btn: TTermMouseButton;
  HasButton: Boolean;
  NewEdge: TTermViewEdge;
begin
  inherited HandleMouseMove(x, y, btnstate, shiftstate);

  { Hyperlink hover is a purely visual, non-destructive highlight: hand cursor +
    solid underline under the mouse (dirty-line repaint only).  Do it on every
    button-less motion REGARDLESS of mouse mode — VTE/gnome-terminal keep
    highlighting links even while a full-screen app (Claude, vim, etc.) has mouse
    tracking enabled.  It does not consume the event, so motion is still reported
    to the app in the block below. }
  if (btnstate and (MOUSE_LEFT or MOUSE_MIDDLE or MOUSE_RIGHT)) = 0 then
  begin
    SetHoverLink(LinkIdAt(x, y));
    { Arm/disarm a docked hover drawer as the pointer hugs a window edge. }
    if Assigned(FOnEdgeHover) then
    begin
      NewEdge := EdgeAt(x, y);
      if NewEdge <> FLastEdge then
      begin
        FLastEdge := NewEdge;
        FOnEdgeHover(Self, NewEdge);
      end;
    end;
  end;

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

  { No mouse mode and no button: hover was already handled above. }
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
    MarkGridDirtyAll;   { selection highlight is baked into the grid cache }
    Repaint;
  end;
end;

procedure TTerminalFPGUIView.HandleMouseExit;
begin
  inherited HandleMouseExit;
  { Pointer left the widget — drop any hover so the solid line reverts to dotted
    and we don't leave a stale hand cursor. }
  SetHoverLink(0);
  if (FLastEdge <> veNone) and Assigned(FOnEdgeHover) then
  begin
    FLastEdge := veNone;
    FOnEdgeHover(Self, veNone);
  end;
end;

procedure TTerminalFPGUIView.HandleLMouseUp(x, y: integer;
  shiftstate: TShiftState);
var
  LId: Integer;
  LUri: string;
  LHandled: Boolean;
begin
  if TryMouseReport(x, y, shiftstate, tmbLeft, False, False) then Exit;

  { A bare click (no drag selection) on a hyperlink opens it.  Embedders can
    intercept via OnLinkClick and set AHandled to override the default. }
  if not FSelection.Selecting then
  begin
    LId := LinkIdAt(x, y);
    if LId <> 0 then
    begin
      LUri := LinkURI(LId);
      LHandled := False;
      if Assigned(FOnLinkClick) then
        FOnLinkClick(Self, LId, LUri, LHandled);
      if not LHandled then
        OpenURI(LUri);
      FMouseDownPending := False;
      Exit;
    end;
  end;

  FMouseDownPending := False;
  if FSelection.Active and FSelection.Selecting then
  begin
    FSelection.Focus := PixelToCell(x, y);
    FSelection.Selecting := False;
    MarkGridDirtyAll;   { selection highlight is baked into the grid cache }
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

