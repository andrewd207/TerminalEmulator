{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  Tabbed terminal window.

  UI:       a custom TTermTabBar (tabs + integrated hamburger) on top, and a
            content panel below that shows the active tab's view.  Each tab owns
            a TTerminalController; the view is only the painting widget, so a tab
            can be torn off by handing the live controller to a fresh view in a
            new window (right-click tab -> Move to New Window).

  Actions:  keybindings and signal (OSC/bell) bindings both resolve to a
            TTermAction via the shared TTermConfig.  Builtins run through this
            window's DoBuiltin sink; external actions shell out.
}
unit TermFpGUI.Window;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  fpg_base, fpg_main, fpg_form, fpg_menu, fpg_dialogs, fpg_panel,
  fpg_stylemanager,
  Terminal.Controller, Terminal.Core, Terminal.Parser, Terminal.View.fpGUI,
  TermFpGUI.Actions, TermFpGUI.Config, TermFpGUI.TabBar, TermFpGUI.Drawer;

type
  { One terminal session living in one tab.  Parallel-indexed with FTabBar. }
  TTermTab = class
    View: TTerminalFPGUIView;
    Drawer: TTermDrawer;          // hover side-panel, nil when profile disables it
    NeedStart: Boolean;
    function Controller: TTerminalController;
  end;

  TTermWindow = class(TfpgForm)
  private
  class var
    { Every live TTermWindow (main + torn-off), so the app stays up until the
      last one closes and MainProc can free whatever remains. }
    FWindows: TFPList;
  private
    FConfig: TTermConfig;          // shared, not owned
    FTabBar: TTermTabBar;
    FContent: TfpgBevel;
    FMenu: TfpgPopupMenu;          // hamburger menu (rebuilt on open)
    FTabMenu: TfpgPopupMenu;       // tab right-click menu
    FMiMoveItem: TfpgMenuItem;     // "Move to New Window" — hidden for a lone tab
    FTabs: TFPList;                // of TTermTab
    FMenuTab: TTermTab;
    FNextNum: Integer;
    FShown: Boolean;
    FFlashTimer: TfpgTimer;
    FFlashSaved: string;
    FLinkHoverSaved: string;       // window title stashed while hovering a link
    FLinkHovering: Boolean;
    { Tabs whose shell exited are torn down here, on a one-shot timer, rather
      than synchronously inside the view's pump-timer callback — freeing a view
      (and its timer) from within its own timer fire is a use-after-free. }
    FDisposeTimer: TfpgTimer;
    FPendingDispose: TFPList;      // of TTermTab awaiting deferred disposal
    procedure QueueDispose(ATab: TTermTab);
    procedure DisposeTick(Sender: TObject);
    procedure BuildTabMenu;
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCloseQuery(Sender: TObject; var ACanClose: Boolean);
    { tab bar events }
    procedure TabSelected(AIndex: Integer);
    procedure TabRightClicked(AIndex, AX, AY: Integer);
    procedure HamburgerClicked(Sender: TObject);
    { lookups / state }
    function  IndexOfTab(ATab: TTermTab): Integer;
    function  TabForView(AView: TObject): TTermTab;
    function  TabForCore(ACore: TObject): TTermTab;
    function  TabForParser(AParser: TObject): TTermTab;
    function  ActiveTab: TTermTab;
    function  TitleOfTab(ATab: TTermTab): string;
    procedure SyncActive;
    procedure SelectTab(AIndex: Integer);
    procedure StartTabShell(ATab: TTermTab);
    function  MakeContext(ATab: TTermTab; ACode: Integer; const APayload: RawByteString): TTermActionContext;
    { menu handlers }
    procedure MiNewTab(Sender: TObject);
    procedure MiMoveToWindow(Sender: TObject);
    procedure MiCloseTab(Sender: TObject);
    procedure MiApplyProfile(Sender: TObject);
    procedure MiApplyTheme(Sender: TObject);
    procedure MiSettings(Sender: TObject);
    { per-tab callbacks }
    procedure ViewShellExit(Sender: TObject);
    procedure ViewFontChanged(Sender: TObject);
    procedure ViewKeyAction(Sender: TObject; AKeyCode: Word; AShift: TShiftState; var AHandled: Boolean);
    procedure ViewLinkHover(Sender: TObject; ALinkId: Integer; const AURI: string);
    procedure ViewLinkLeave(Sender: TObject; ALinkId: Integer; const AURI: string);
    procedure ViewLinkClick(Sender: TObject; ALinkId: Integer; const AURI: string; var AHandled: Boolean);
    procedure ViewEdgeHover(Sender: TObject; AEdge: TTermViewEdge);
    procedure ViewClicked(Sender: TObject; var AHandled: Boolean);
    procedure DrawerHostKey(Sender: TObject; AKeyCode: Word; AShift: TShiftState; var AHandled: Boolean);
    procedure DrawerPersist;
    procedure SetupTabDrawer(ATab: TTermTab);
    procedure ApplyConfigToTabs;
    procedure CoreTitle(Sender: TObject; const ATitle: string);
    procedure CoreBell(Sender: TObject);
    procedure ParserOSC(Sender: TObject; ACode: Integer; const APayload: RawByteString; var AHandled: Boolean);
    { builtin-action sink }
    procedure DoBuiltin(ABuiltin: TTermBuiltinAction; const AArg: string; const ACtx: TTermActionContext);
    procedure FlashWindow;
    procedure FlashTick(Sender: TObject);
    procedure DisposeTab(ATab: TTermTab; AFreeController: Boolean);
    { Pin the window's minimum size to the active view's geometry floor plus the
      tab strip, so the WM refuses to drag the PTY below MIN_TERM_COLS/ROWS. }
    procedure UpdateMinSize(AView: TTerminalFPGUIView);
  protected
    procedure AfterCreate; override;
    procedure HandleResize(awidth, aheight: TfpgCoord); override;
  public
    destructor Destroy; override;
    function AddTab(AController: TTerminalController; const ATitle: string;
                    AStartShell: Boolean): TTermTab;
    { Free every window still open (called once the message loop has ended). }
    class procedure FreeAll;
    property Config: TTermConfig read FConfig write FConfig;
  end;

implementation

uses
  TermFpGUI.SettingsForm;

const
  TAB_STRIP_H = 26;
  HAMB_W      = 28;

{ TTermTab }

function TTermTab.Controller: TTerminalController;
begin
  if View <> nil then Result := View.Controller else Result := nil;
end;

{ TTermWindow }

procedure TTermWindow.AfterCreate;
begin
  inherited AfterCreate;
  WindowTitle := 'fpGUI Terminal';
  SetPosition(100, 100, 900, 560);
  FTabs := TFPList.Create;
  FNextNum := 1;
  if FWindows = nil then
    FWindows := TFPList.Create;
  FWindows.Add(Self);

  { Anchors (Delphi/Lazarus-style, as used by the project's own view form):
    the tab strip spans the full width at the top; the content panel fills the
    rest.  Both track window resizes. }
  FTabBar := TTermTabBar.Create(Self);
  FTabBar.SetPosition(0, 0, Width, TAB_STRIP_H);
  FTabBar.HamburgerWidth := HAMB_W;
  FTabBar.OnSelect := @TabSelected;
  FTabBar.OnTabRightClick := @TabRightClicked;
  FTabBar.OnMenu := @HamburgerClicked;

  FContent := TfpgBevel.Create(Self);
  FContent.SetPosition(0, TAB_STRIP_H, Width, Height - TAB_STRIP_H);
  FContent.Shape := bsBox;

  BuildTabMenu;

  FFlashTimer := TfpgTimer.Create(350);
  FFlashTimer.OnTimer := @FlashTick;
  FFlashTimer.Enabled := False;

  FPendingDispose := TFPList.Create;
  FDisposeTimer := TfpgTimer.Create(1);   // one-shot; disabled inside its handler
  FDisposeTimer.OnTimer := @DisposeTick;
  FDisposeTimer.Enabled := False;

  OnShow := @FormShow;
  { Before the close commits, if this is the app's main form and other windows
    remain, hand the main-form role to one of them — otherwise fpGUI would quit
    the whole app (Terminate) when the main window closes. The last window left
    keeps the role and quits normally. }
  OnCloseQuery := @FormCloseQuery;
  { Free the window on close (fpGUI defers it safely via FPGM_FREEME for a
    non-main form).  Torn-off windows are otherwise only hidden and never freed,
    which strands their Wayland buffer manager in the present queue with a dead
    surface -> SIGSEGV in FlushPendingPresents.  The main form's caFree just
    terminates the loop (MainProc frees it). }
  OnClose := @FormClose;
end;

procedure TTermWindow.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
end;

{ Runs before fpGUI captures IsMainForm, so reassigning MainForm here decides
  whether closing this window terminates the app. }
procedure TTermWindow.FormCloseQuery(Sender: TObject; var ACanClose: Boolean);
var
  i: Integer;
begin
  ACanClose := True;
  if fpgApplication.MainForm <> Self then Exit;
  if FWindows = nil then Exit;
  for i := 0 to FWindows.Count - 1 do
    if FWindows[i] <> Pointer(Self) then
    begin
      fpgApplication.MainForm := TTermWindow(FWindows[i]);
      Exit;
    end;
  { No other window: this is the last one, leave it as MainForm so the close
    terminates the app normally. }
end;

class procedure TTermWindow.FreeAll;
begin
  if FWindows = nil then Exit;
  while FWindows.Count > 0 do
    TTermWindow(FWindows[0]).Free;   { Destroy removes itself from FWindows }
end;

{ Explicitly lay out the two top-level children on every resize.  fpGUI's
  anchor handling proved unreliable for the strip, so we own the geometry: the
  tab bar spans the full width at a fixed height, the content panel fills the
  rest.  Views inside FContent follow it via their own anchors. }
procedure TTermWindow.HandleResize(awidth, aheight: TfpgCoord);
var
  i, vw, vh: Integer;
begin
  inherited HandleResize(awidth, aheight);
  if FTabBar <> nil then
    FTabBar.SetPosition(0, 0, awidth, TAB_STRIP_H);
  if FContent <> nil then
    FContent.SetPosition(0, TAB_STRIP_H, awidth, aheight - TAB_STRIP_H);

  { Anchors don't reliably cascade to the views inside FContent in this fpGUI
    build, so size them all explicitly (background tabs included, so they're
    correct when shown). }
  vw := awidth;
  vh := aheight - TAB_STRIP_H;
  if FTabs <> nil then
    for i := 0 to FTabs.Count - 1 do
      if TTermTab(FTabs[i]).View <> nil then
      begin
        TTermTab(FTabs[i]).View.SetPosition(0, 0, vw, vh);
        if TTermTab(FTabs[i]).Drawer <> nil then
          TTermTab(FTabs[i]).Drawer.Layout;
      end;
end;

destructor TTermWindow.Destroy;
var
  i: Integer;
  Tab: TTermTab;
  Ctrl: TTerminalController;
begin
  if FWindows <> nil then
    FWindows.Remove(Self);
  FreeAndNil(FFlashTimer);
  FreeAndNil(FDisposeTimer);          { stop deferred disposal before teardown }
  FreeAndNil(FPendingDispose);
  if FTabs <> nil then
  begin
    for i := 0 to FTabs.Count - 1 do
    begin
      Tab := TTermTab(FTabs[i]);
      FreeAndNil(Tab.Drawer);
      Ctrl := Tab.Controller;
      if Tab.View <> nil then
        Tab.View.DetachController(True);
      Ctrl.Free;
      Tab.Free;
    end;
    FreeAndNil(FTabs);
  end;
  inherited Destroy;
end;

procedure TTermWindow.BuildTabMenu;
begin
  FTabMenu := TfpgPopupMenu.Create(Self);
  FTabMenu.AddMenuItem('New Tab',            '', @MiNewTab);
  FTabMenu.AddMenuItem('-',                  '', nil);
  FMiMoveItem := FTabMenu.AddMenuItem('Move to New Window', '', @MiMoveToWindow);
  FTabMenu.AddMenuItem('Close Tab',          '', @MiCloseTab);
end;

procedure TTermWindow.FormShow(Sender: TObject);
var
  i: Integer;
  Tab: TTermTab;
begin
  FShown := True;
  for i := 0 to FTabs.Count - 1 do
  begin
    Tab := TTermTab(FTabs[i]);
    if Tab.NeedStart then
    begin
      Tab.NeedStart := False;
      Tab.View.StartShell;
    end;
  end;
  Tab := ActiveTab;
  if (Tab <> nil) and (Tab.View <> nil) then
    Tab.View.SetFocus;
end;

function TTermWindow.AddTab(AController: TTerminalController;
  const ATitle: string; AStartShell: Boolean): TTermTab;
var
  View: TTerminalFPGUIView;
  Ctrl: TTerminalController;
  Title: string;
  Idx: Integer;
  Prof: TTermProfile;
begin
  Title := ATitle;
  if Title = '' then
    Title := 'Terminal ' + IntToStr(FNextNum);
  Inc(FNextNum);

  Idx := FTabBar.AddTab(Title);

  View := TTerminalFPGUIView.Create(FContent);
  View.Parent := FContent;
  View.SetPosition(0, 0, FContent.Width, FContent.Height);
  View.OnShellExit := @ViewShellExit;
  View.OnKeyAction := @ViewKeyAction;
  View.OnFontChanged := @ViewFontChanged;
  View.OnLinkHover := @ViewLinkHover;
  View.OnLinkLeave := @ViewLinkLeave;
  View.OnLinkClick := @ViewLinkClick;
  View.OnEdgeHover := @ViewEdgeHover;
  View.OnViewClick := @ViewClicked;

  if AController <> nil then
    Ctrl := AController
  else
    Ctrl := TTerminalController.Create(80, 25, 5000);

  View.AttachController(Ctrl);
  Ctrl.Core.OnTitle := @CoreTitle;
  Ctrl.Core.OnBell  := @CoreBell;
  Ctrl.Parser.OnOSC := @ParserOSC;

  Result := TTermTab.Create;
  Result.View := View;
  FTabs.Add(Result);

  { Apply the saved active profile (font lives in the profile now); fall back to
    the first profile if the saved name is gone. }
  if FConfig <> nil then
  begin
    Prof := FConfig.FindProfile(FConfig.ActiveProfile);
    if (Prof = nil) and (FConfig.ProfileCount > 0) then
      Prof := FConfig.Profiles[0];
    if Prof <> nil then
      Prof.ApplyTo(View);
    if FConfig.EmojiFont <> '' then
      View.EmojiFontDesc := FConfig.EmojiFont;
  end;

  UpdateMinSize(View);                  // font is set, so cell metrics are known

  SetupTabDrawer(Result);               // hover side-panel, if the profile enables it

  SelectTab(Idx);                       // shows this view, hides others

  if AStartShell then
  begin
    if FShown then
      StartTabShell(Result)
    else
      Result.NeedStart := True;
  end;
end;

procedure TTermWindow.UpdateMinSize(AView: TTerminalFPGUIView);
var
  MinW, MinH: Integer;
begin
  if AView = nil then Exit;
  AView.GetMinPixelSize(MinW, MinH);
  MinWidth := MinW;
  MinHeight := MinH + TAB_STRIP_H;
end;

procedure TTermWindow.StartTabShell(ATab: TTermTab);
begin
  if (ATab = nil) or (ATab.View = nil) then Exit;
  ATab.View.StartShell;
  ATab.View.SetFocus;
end;

{ ---- index / lookups ---- }

function TTermWindow.IndexOfTab(ATab: TTermTab): Integer;
begin
  Result := FTabs.IndexOf(ATab);
end;

function TTermWindow.TabForView(AView: TObject): TTermTab;
var i: Integer;
begin
  for i := 0 to FTabs.Count - 1 do
    if TTermTab(FTabs[i]).View = AView then Exit(TTermTab(FTabs[i]));
  Result := nil;
end;

function TTermWindow.TabForCore(ACore: TObject): TTermTab;
var i: Integer; Tab: TTermTab;
begin
  for i := 0 to FTabs.Count - 1 do
  begin
    Tab := TTermTab(FTabs[i]);
    if (Tab.Controller <> nil) and (TObject(Tab.Controller.Core) = ACore) then Exit(Tab);
  end;
  Result := nil;
end;

function TTermWindow.TabForParser(AParser: TObject): TTermTab;
var i: Integer; Tab: TTermTab;
begin
  for i := 0 to FTabs.Count - 1 do
  begin
    Tab := TTermTab(FTabs[i]);
    if (Tab.Controller <> nil) and (TObject(Tab.Controller.Parser) = AParser) then Exit(Tab);
  end;
  Result := nil;
end;

function TTermWindow.ActiveTab: TTermTab;
var ai: Integer;
begin
  ai := FTabBar.ActiveIndex;
  if (ai >= 0) and (ai < FTabs.Count) then
    Result := TTermTab(FTabs[ai])
  else
    Result := nil;
end;

function TTermWindow.TitleOfTab(ATab: TTermTab): string;
begin
  Result := FTabBar.TitleOf(IndexOfTab(ATab));
end;

{ Show only the active tab's view; update caption + focus. }
procedure TTermWindow.SyncActive;
var
  i, ai: Integer;
begin
  ai := FTabBar.ActiveIndex;
  for i := 0 to FTabs.Count - 1 do
  begin
    TTermTab(FTabs[i]).View.Visible := (i = ai);
    if TTermTab(FTabs[i]).Drawer <> nil then
      TTermTab(FTabs[i]).Drawer.SetActive(i = ai);
  end;
  if (ai >= 0) and (ai < FTabs.Count) then
  begin
    WindowTitle := FTabBar.TitleOf(ai);
    if FShown then
      TTermTab(FTabs[ai]).View.SetFocus;
  end;
end;

procedure TTermWindow.SelectTab(AIndex: Integer);
begin
  FTabBar.ActiveIndex := AIndex;
  SyncActive;
end;

function TTermWindow.MakeContext(ATab: TTermTab; ACode: Integer;
  const APayload: RawByteString): TTermActionContext;
begin
  Result := Default(TTermActionContext);
  Result.Code := ACode;
  Result.Payload := APayload;
  if ATab <> nil then
  begin
    Result.SourceTab := ATab;
    Result.SourceView := ATab.View;
    Result.TabTitle := TitleOfTab(ATab);
  end;
end;

{ ---- tab bar events ---- }

procedure TTermWindow.TabSelected(AIndex: Integer);
begin
  SyncActive;                           // tab bar already updated ActiveIndex
end;

procedure TTermWindow.TabRightClicked(AIndex, AX, AY: Integer);
begin
  if (AIndex < 0) or (AIndex >= FTabs.Count) then Exit;
  FMenuTab := TTermTab(FTabs[AIndex]);
  { Moving the only tab to a new window is a no-op (it just recreates this
    window), so hide it when there's a single tab. }
  if FMiMoveItem <> nil then
    FMiMoveItem.Visible := FTabs.Count > 1;
  FTabMenu.ShowAt(FTabBar, AX, FTabBar.Height);
end;

procedure TTermWindow.HamburgerClicked(Sender: TObject);
var
  i: Integer;
  Item, Sub: TfpgMenuItem;
  Styles: TStringList;
begin
  FreeAndNil(FMenu);
  FMenu := TfpgPopupMenu.Create(Self);
  FMenu.AddMenuItem('New Tab', '', @MiNewTab);

  { Submenus, owned by their parent item (the canonical fpGUI pattern).  The
    active profile / theme is shown checked (fpGUI's radio equivalent), so the
    saved-and-restored selection is visible. }
  Item := FMenu.AddMenuItem('Profile', '', nil);
  Item.SubMenu := TfpgPopupMenu.Create(Item);
  if FConfig <> nil then
    for i := 0 to FConfig.ProfileCount - 1 do
    begin
      Sub := Item.SubMenu.AddMenuItem(FConfig.Profiles[i].Name, '', @MiApplyProfile);
      Sub.Checked := SameText(FConfig.Profiles[i].Name, FConfig.ActiveProfile);
    end;

  Item := FMenu.AddMenuItem('Theme', '', nil);
  Item.SubMenu := TfpgPopupMenu.Create(Item);
  Styles := TStringList.Create;
  try
    fpgStyleManager.AssignStyleTypes(Styles);
    for i := 0 to Styles.Count - 1 do
    begin
      Sub := Item.SubMenu.AddMenuItem(Styles[i], '', @MiApplyTheme);
      if FConfig <> nil then
        Sub.Checked := SameText(Styles[i], FConfig.Theme);
    end;
  finally
    Styles.Free;
  end;

  FMenu.AddMenuItem('-', '', nil);
  FMenu.AddMenuItem('Settings…', '', @MiSettings);

  FMenu.ShowAt(FTabBar, FTabBar.Width - HAMB_W, FTabBar.Height);
end;

{ ---- menu handlers ---- }

procedure TTermWindow.MiNewTab(Sender: TObject);
begin
  AddTab(nil, '', True);
end;

procedure TTermWindow.MiCloseTab(Sender: TObject);
begin
  QueueDispose(FMenuTab);
  FMenuTab := nil;
end;

procedure TTermWindow.MiMoveToWindow(Sender: TObject);
var
  Tab: TTermTab;
  Ctrl: TTerminalController;
  Title: string;
  NewWin: TTermWindow;
begin
  Tab := FMenuTab;
  FMenuTab := nil;
  if (Tab = nil) or (Tab.Controller = nil) then Exit;
  if FTabs.Count <= 1 then Exit;   { nothing to gain moving the only tab }

  Ctrl  := Tab.Controller;
  Title := TitleOfTab(Tab);

  Tab.View.DetachController(False);     // keep the shell alive

  NewWin := TTermWindow.Create(nil);
  NewWin.Config := FConfig;
  NewWin.AddTab(Ctrl, Title, False);
  NewWin.Show;

  { Defer: this can run inside the old view's key handler. The controller is
    already detached (Tab.Controller is now nil), so the deferred DisposeTab
    won't touch the moved shell. }
  QueueDispose(Tab);
end;

{ Menu item text is "Profile:  Name" / "Theme:  Name"; take the part after ':'. }
function NameAfterColon(const AText: string): string;
var
  p: Integer;
begin
  p := Pos(':', AText);
  if p > 0 then Result := Trim(Copy(AText, p + 1, MaxInt))
  else Result := Trim(AText);
end;

procedure TTermWindow.MiApplyProfile(Sender: TObject);
var
  Prof: TTermProfile;
  Tab: TTermTab;
begin
  if FConfig = nil then Exit;
  Prof := FConfig.FindProfile(NameAfterColon(TfpgMenuItem(Sender).Text));
  if Prof = nil then Exit;
  { Remember the choice so it is restored next launch and shown checked. }
  FConfig.ActiveProfile := Prof.Name;
  FConfig.Save(DefaultConfigPath);
  Tab := ActiveTab;
  if (Tab <> nil) and (Tab.View <> nil) then
  begin
    Prof.ApplyTo(Tab.View);
    Tab.View.Invalidate;
  end;
end;

procedure TTermWindow.MiApplyTheme(Sender: TObject);
var
  StyleName: string;
begin
  StyleName := NameAfterColon(TfpgMenuItem(Sender).Text);
  if fpgStyleManager.SetStyle(StyleName) then
  begin
    fpgStyleManager.FreeStyleInstance;      // drop the old instance
    fpgStyle := fpgStyleManager.Style;      // recreate with the new style
    if FConfig <> nil then
    begin
      FConfig.Theme := StyleName;
      FConfig.Save(DefaultConfigPath);      // persist so it is restored on restart
    end;
    Invalidate;                             // repaint chrome with the new style
  end;
end;

procedure TTermWindow.MiSettings(Sender: TObject);
var
  Frm: TTermSettingsForm;
begin
  if FConfig = nil then Exit;
  Frm := TTermSettingsForm.CreateFor(nil, FConfig, DefaultConfigPath);
  try
    Frm.ShowModal;
  finally
    Frm.Free;
  end;
  ApplyConfigToTabs;                   { reflect edits live }
end;

{ ---- per-tab callbacks ---- }

{ Called from the view's pump-timer callback when its shell exits.  We must NOT
  free the view here (that frees the timer we're running inside) — queue it and
  tear it down from our own one-shot timer, after this event has returned. }
procedure TTermWindow.ViewShellExit(Sender: TObject);
begin
  QueueDispose(TabForView(Sender));
end;

{ Defer a tab's teardown to the one-shot timer so it never runs synchronously
  inside that tab's own view event (pump timer / key handler), where freeing the
  view would pull the rug out from under the code still on the stack. }
procedure TTermWindow.QueueDispose(ATab: TTermTab);
begin
  if ATab = nil then Exit;
  if FPendingDispose.IndexOf(ATab) < 0 then
    FPendingDispose.Add(ATab);
  FDisposeTimer.Enabled := True;
end;

procedure TTermWindow.DisposeTick(Sender: TObject);
var
  i: Integer;
  Tab: TTermTab;
begin
  FDisposeTimer.Enabled := False;
  for i := 0 to FPendingDispose.Count - 1 do
  begin
    Tab := TTermTab(FPendingDispose[i]);
    if FTabs.IndexOf(Tab) >= 0 then     { may have been closed another way }
      DisposeTab(Tab, True);
  end;
  FPendingDispose.Clear;
  if FTabs.Count = 0 then Close else SyncActive;
end;

{ The view's right-click "Change Font" fires this; fold the new font into the
  active profile so it persists and future tabs inherit it. }
procedure TTermWindow.ViewFontChanged(Sender: TObject);
var
  V: TTerminalFPGUIView;
  Prof: TTermProfile;
begin
  if (FConfig = nil) or (not (Sender is TTerminalFPGUIView)) then Exit;
  V := TTerminalFPGUIView(Sender);
  Prof := FConfig.FindProfile(FConfig.ActiveProfile);
  if (Prof = nil) and (FConfig.ProfileCount > 0) then
    Prof := FConfig.Profiles[0];
  if Prof <> nil then
    Prof.FontDesc := V.FontDesc;
  FConfig.EmojiFont := V.EmojiFontDesc;   { emoji font stays a global override }
  FConfig.Save(DefaultConfigPath);
  UpdateMinSize(V);                       { font size changed -> re-floor the window }
end;

procedure TTermWindow.ViewKeyAction(Sender: TObject; AKeyCode: Word;
  AShift: TShiftState; var AHandled: Boolean);
var
  Tab: TTermTab;
  Bind: TTermKeyBinding;
  Ctx: TTermActionContext;
begin
  if FConfig = nil then Exit;
  Bind := FConfig.MatchKey(AKeyCode, AShift);
  if Bind = nil then Exit;

  Tab := TabForView(Sender);
  if Tab = nil then Exit;
  Ctx := MakeContext(Tab, -1, '');

  { Smart copy: only consume when there was a selection, so a bare Ctrl+C with
    nothing selected falls through to SIGINT. }
  if (Bind.Action.Kind = takBuiltin) and (Bind.Action.Builtin = baCopy) then
  begin
    AHandled := Tab.View.CopySelection;
    Exit;
  end;

  Bind.Action.Execute(@DoBuiltin, Ctx);
  AHandled := True;
end;

{ Show the link target in the title bar while hovering, then restore the tab's
  real title on leave. }
procedure TTermWindow.ViewLinkHover(Sender: TObject; ALinkId: Integer;
  const AURI: string);
begin
  if not FLinkHovering then
  begin
    FLinkHoverSaved := WindowTitle;
    FLinkHovering := True;
  end;
  WindowTitle := AURI;
end;

procedure TTermWindow.ViewLinkLeave(Sender: TObject; ALinkId: Integer;
  const AURI: string);
begin
  if FLinkHovering then
  begin
    WindowTitle := FLinkHoverSaved;
    FLinkHovering := False;
  end;
end;

{ Honour a configured opener (LinkOpenCommand, '%u' = URI); otherwise let the
  view fall back to its built-in xdg-open. }
procedure TTermWindow.ViewLinkClick(Sender: TObject; ALinkId: Integer;
  const AURI: string; var AHandled: Boolean);
var
  Act: TTermAction;
  Ctx: TTermActionContext;
  Cmd: string;
begin
  if FConfig = nil then Exit;
  Cmd := FConfig.LinkOpenCommand;
  if Trim(Cmd) = '' then Exit;            { AHandled stays False -> view opens }

  Ctx := MakeContext(TabForView(Sender), -1, RawByteString(AURI));
  Act := TTermAction.CreateExternal(StringReplace(Cmd, '%u', AURI, [rfReplaceAll]));
  try
    Act.Execute(@DoBuiltin, Ctx);
  finally
    Act.Free;
  end;
  AHandled := True;
end;

{ Resolve the active profile and, if it defines a drawer, create one for this
  tab.  Each tab owns its own drawer instance (independent program). }
procedure TTermWindow.SetupTabDrawer(ATab: TTermTab);
var
  Prof, ColorProf: TTermProfile;
begin
  if (FConfig = nil) or (ATab = nil) or (ATab.View = nil) then Exit;
  Prof := FConfig.FindProfile(FConfig.ActiveProfile);
  if (Prof = nil) and (FConfig.ProfileCount > 0) then
    Prof := FConfig.Profiles[0];
  if (Prof = nil) or (not Prof.DrawerEnabled) then Exit;
  ColorProf := nil;
  if Prof.DrawerColorProfile <> '' then
    ColorProf := FConfig.FindProfile(Prof.DrawerColorProfile);
  ATab.Drawer := TTermDrawer.Create(FContent, ATab.View, Prof, ColorProf);
  ATab.Drawer.OnPersist := @DrawerPersist;
  ATab.Drawer.OnHostKey := @DrawerHostKey;
  ATab.Drawer.PrimeIfEager;
end;

{ Re-apply the (just-edited) active profile to every open tab — colours, font,
  and drawer appearance — so Settings changes show without reopening tabs.
  The hosted programs keep running; a changed drawer command takes effect on the
  next open/relaunch. }
procedure TTermWindow.ApplyConfigToTabs;
var
  i: Integer;
  Prof, ColorProf: TTermProfile;
  Tab: TTermTab;
begin
  if FConfig = nil then Exit;
  Prof := FConfig.FindProfile(FConfig.ActiveProfile);
  if (Prof = nil) and (FConfig.ProfileCount > 0) then
    Prof := FConfig.Profiles[0];
  if Prof = nil then Exit;

  ColorProf := nil;
  if Prof.DrawerColorProfile <> '' then
    ColorProf := FConfig.FindProfile(Prof.DrawerColorProfile);

  for i := 0 to FTabs.Count - 1 do
  begin
    Tab := TTermTab(FTabs[i]);
    if Tab.View <> nil then
    begin
      Prof.ApplyTo(Tab.View);
      Tab.View.Invalidate;
    end;
    if Prof.DrawerEnabled then
    begin
      if Tab.Drawer = nil then
        SetupTabDrawer(Tab)            { newly enabled }
      else
        Tab.Drawer.RefreshLook(ColorProf);
    end
    else
      FreeAndNil(Tab.Drawer);          { newly disabled }
  end;

  if (ActiveTab <> nil) and (ActiveTab.View <> nil) then
    UpdateMinSize(ActiveTab.View);     { font may have changed }
  SyncActive;                          { normalise drawer/view visibility }
end;

procedure TTermWindow.ViewEdgeHover(Sender: TObject; AEdge: TTermViewEdge);
var
  Tab: TTermTab;
begin
  Tab := TabForView(Sender);
  if (Tab = nil) or (Tab.Drawer = nil) then Exit;
  if AEdge = Tab.Drawer.Gravity then
    Tab.Drawer.Arm
  else
    Tab.Drawer.Disarm;
end;

procedure TTermWindow.DrawerPersist;
begin
  if FConfig <> nil then
    FConfig.Save(DefaultConfigPath);
end;

{ Resolve a global keybinding while a drawer's view is focused, so chords like
  ToggleDrawer / copy work without first clicking back into the main console.
  Sender is the TTermDrawer; copy/paste target its own view. }
procedure TTermWindow.DrawerHostKey(Sender: TObject; AKeyCode: Word;
  AShift: TShiftState; var AHandled: Boolean);
var
  Drawer: TTermDrawer;
  Tab: TTermTab;
  Bind: TTermKeyBinding;
  Ctx: TTermActionContext;
  i: Integer;
begin
  if (FConfig = nil) or not (Sender is TTermDrawer) then Exit;
  Drawer := TTermDrawer(Sender);
  Bind := FConfig.MatchKey(AKeyCode, AShift);
  if Bind = nil then Exit;

  Tab := nil;
  for i := 0 to FTabs.Count - 1 do
    if TTermTab(FTabs[i]).Drawer = Drawer then begin Tab := TTermTab(FTabs[i]); Break; end;

  Ctx := MakeContext(Tab, -1, '');
  Ctx.SourceView := Drawer.InnerView;     { copy/paste act on the drawer's terminal }

  if (Bind.Action.Kind = takBuiltin) and (Bind.Action.Builtin = baCopy) then
  begin
    if Drawer.InnerView <> nil then
      AHandled := Drawer.InnerView.CopySelection;
    Exit;
  end;

  Bind.Action.Execute(@DoBuiltin, Ctx);
  AHandled := True;
end;

{ Clicking into the main console collapses that tab's open drawer, and the
  click is swallowed so it doesn't also land in the terminal. }
procedure TTermWindow.ViewClicked(Sender: TObject; var AHandled: Boolean);
var
  Tab: TTermTab;
begin
  Tab := TabForView(Sender);
  if (Tab = nil) or (Tab.Drawer = nil) then Exit;
  if Tab.Drawer.IsOpen then
  begin
    Tab.Drawer.CloseDrawer;
    AHandled := True;
  end;
end;

procedure TTermWindow.CoreTitle(Sender: TObject; const ATitle: string);
var
  Tab: TTermTab;
  Idx: Integer;
begin
  if ATitle = '' then Exit;
  Tab := TabForCore(Sender);
  if Tab = nil then Exit;
  Idx := IndexOfTab(Tab);
  FTabBar.SetTitle(Idx, ATitle);
  if FTabBar.ActiveIndex = Idx then
    WindowTitle := ATitle;
end;

procedure TTermWindow.CoreBell(Sender: TObject);
var
  Tab: TTermTab;
  Bind: TTermSignalBinding;
  Ctx: TTermActionContext;
begin
  Tab := TabForCore(Sender);
  if FConfig <> nil then Bind := FConfig.MatchSignalKind(tskBell) else Bind := nil;
  if Bind <> nil then
  begin
    Ctx := MakeContext(Tab, -1, '');
    Bind.Action.Execute(@DoBuiltin, Ctx);
  end
  else
    FlashWindow;
end;

procedure TTermWindow.ParserOSC(Sender: TObject; ACode: Integer;
  const APayload: RawByteString; var AHandled: Boolean);
var
  Tab: TTermTab;
  Bind: TTermSignalBinding;
  Ctx: TTermActionContext;
begin
  if FConfig = nil then Exit;
  Bind := FConfig.MatchOSC(ACode);
  if Bind = nil then Exit;
  Tab := TabForParser(Sender);
  Ctx := MakeContext(Tab, ACode, APayload);
  Bind.Action.Execute(@DoBuiltin, Ctx);
  AHandled := True;
end;

{ ---- builtin sink ---- }

procedure TTermWindow.DoBuiltin(ABuiltin: TTermBuiltinAction; const AArg: string;
  const ACtx: TTermActionContext);
var
  View: TTerminalFPGUIView;
  Tab: TTermTab;
  Prof: TTermProfile;
  Idx, ai: Integer;
  Notify: TTermAction;
begin
  View := nil;
  if ACtx.SourceView is TTerminalFPGUIView then View := TTerminalFPGUIView(ACtx.SourceView);
  Tab := nil;
  if ACtx.SourceTab is TTermTab then Tab := TTermTab(ACtx.SourceTab);

  case ABuiltin of
    baCopy:    if View <> nil then View.CopySelection;
    baPaste:   if View <> nil then View.PasteClipboard;
    baNewTab:  AddTab(nil, '', True);
    baCloseTab:
      QueueDispose(Tab);    { deferred — we're inside this tab's key handler }
    baMoveToWindow:
      begin
        FMenuTab := Tab;
        MiMoveToWindow(nil);
      end;
    baNextTab, baPrevTab:
      if FTabs.Count > 1 then
      begin
        ai := FTabBar.ActiveIndex;
        if ABuiltin = baNextTab then ai := (ai + 1) mod FTabs.Count
        else ai := (ai - 1 + FTabs.Count) mod FTabs.Count;
        SelectTab(ai);
      end;
    baBeep, baFlash:
      FlashWindow;
    baNotify:
      begin
        Notify := TTermAction.CreateExternal('notify-send "Terminal" %p');
        try
          Notify.Execute(nil, ACtx);
        finally
          Notify.Free;
        end;
      end;
    baApplyProfile:
      if (FConfig <> nil) and (View <> nil) then
      begin
        Prof := FConfig.FindProfile(AArg);
        if Prof <> nil then Prof.ApplyTo(View);
      end;
    baSetTabTitle:
      if Tab <> nil then
      begin
        Idx := IndexOfTab(Tab);
        if AArg <> '' then FTabBar.SetTitle(Idx, AArg)
        else FTabBar.SetTitle(Idx, string(ACtx.Payload));
      end;
    baToggleDrawer:
      if Tab <> nil then
      begin
        { Create on demand so enabling the drawer in Settings takes effect on
          an already-open tab without needing a new tab. }
        if Tab.Drawer = nil then
          SetupTabDrawer(Tab);
        if Tab.Drawer <> nil then
          Tab.Drawer.Toggle;
      end;
  end;
end;

procedure TTermWindow.FlashWindow;
begin
  if FFlashTimer.Enabled then Exit;
  FFlashSaved := WindowTitle;
  WindowTitle := '● ' + FFlashSaved;
  FFlashTimer.Enabled := True;
end;

procedure TTermWindow.FlashTick(Sender: TObject);
begin
  FFlashTimer.Enabled := False;
  WindowTitle := FFlashSaved;
end;

procedure TTermWindow.DisposeTab(ATab: TTermTab; AFreeController: Boolean);
var
  Ctrl: TTerminalController;
  Idx: Integer;
begin
  if ATab = nil then Exit;
  FreeAndNil(ATab.Drawer);              // owns its own view+controller
  Idx := IndexOfTab(ATab);
  Ctrl := ATab.Controller;
  if ATab.View <> nil then
    ATab.View.DetachController(AFreeController);
  if ATab.View <> nil then
    ATab.View.Free;                     // remove the painting widget
  if Idx >= 0 then
    FTabBar.RemoveTab(Idx);
  if AFreeController then
    Ctrl.Free;
  FTabs.Remove(ATab);
  ATab.Free;
end;

end.
