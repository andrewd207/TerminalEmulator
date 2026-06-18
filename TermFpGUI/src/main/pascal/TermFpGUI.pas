{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  fpgui-term: a tabbed terminal emulator built on the TerminalFramework +
  fpGUI view.  Right-click a tab to open a new tab, close it, or move it to a
  new window.  Unlike ExampleTerminal (deliberately minimal, for reference)
  this is the "real app".
}
program TermFpGUI;

{$mode objfpc}{$H+}

uses
  SysUtils,
  fpg_main, fpg_stylemanager,
  { Pulling these units in registers their styles with fpgStyleManager so the
    user can pick them from the hamburger menu. }
  fpg_style_motif, fpg_style_plastic, fpg_style_fusion,
  fpg_style_win2k, fpg_style_win8,
  TermFpGUI.Config,
  TermFpGUI.Desktop,
  TermFpGUI.Window;

{ 1-based index of the first bare "--" separator, or 0 if there is none.
  Everything after it is the program to run, not our own options. }
function DashDashIndex: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to ParamCount do
    if ParamStr(i) = '--' then Exit(i);
end;

{ Scan argv[1..AMax] for --app <file> / --app=<file> / -a <file>.  '' if absent. }
function AppConfigArg(AMax: Integer): string;
var
  i: Integer;
  s: string;
begin
  Result := '';
  i := 1;
  while i <= AMax do
  begin
    s := ParamStr(i);
    if (s = '--app') or (s = '-a') then
    begin
      if i < AMax then Result := ParamStr(i + 1);
      Exit;
    end
    else if Copy(s, 1, 6) = '--app=' then
    begin
      Result := Copy(s, 7, MaxInt);
      Exit;
    end;
    Inc(i);
  end;
end;

{ Single-quote an argument for /bin/sh, so spaces and metacharacters survive
  StartProgram's "sh -c <line>" without the shell re-splitting them. }
function ShQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

{ Join argv[AFrom..ParamCount] into one shell-safe command line. }
function JoinArgs(AFrom: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := AFrom to ParamCount do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + ShQuote(ParamStr(i));
  end;
end;

procedure MainProc;
var
  Win: TTermWindow;
  Cfg: TTermConfig;
  App: TTermAppConfig;
  AppPath, MainCmd, WinTitle, RunCmd, AppErr: string;
  DD, OptMax: Integer;
begin
  fpgApplication.Initialize;
  RegisterAppIcon;                          // window icon (before any form)
  Cfg := TTermConfig.Create;
  Cfg.Load(DefaultConfigPath);              // seeds defaults if no file yet

  { Everything after a bare "--" is the program to run; our own options are only
    parsed before it. }
  DD := DashDashIndex;
  if DD > 0 then OptMax := DD - 1 else OptMax := ParamCount;
  RunCmd := '';
  if DD > 0 then RunCmd := JoinArgs(DD + 1);

  { App mode: load the launch config, fold its profile in as the active profile
    (so all the normal profile/drawer wiring applies), and remember the main
    command + title to launch. }
  App := nil;
  MainCmd := '';
  WinTitle := '';
  AppPath := AppConfigArg(OptMax);
  if AppPath <> '' then
  begin
    App := TTermAppConfig.Create;
    if App.Load(AppPath, AppErr) then
    begin
      MainCmd := App.Command;
      WinTitle := App.Title;
      if App.Theme <> '' then Cfg.Theme := App.Theme;
      Cfg.ActiveProfile := App.Name;        // the config's named profile
      Cfg.AddProfile(App.TakeProfile);      // Cfg now owns the profile
    end
    else
    begin
      { name= is mandatory and the icon (if any) must be a valid SVG — refuse to
        launch a malformed startup config rather than guessing. }
      writeln('termfpgui: ', AppErr);
      App.Free;
      Cfg.Free;
      Exit;
    end;
  end;

  { A trailing "-- prog args" overrides the command to run (app config or not),
    but does not by itself hide the tab strip — that is app mode (--app) only. }
  if RunCmd <> '' then
    MainCmd := RunCmd;

  if Cfg.Theme <> '' then
  begin
    fpgStyleManager.SetStyle(Cfg.Theme);
    fpgStyleManager.FreeStyleInstance;
    fpgStyle := fpgStyleManager.Style;      // apply the saved theme up-front
  end;
  Win := TTermWindow.Create(nil);
  try
    Win.Config := Cfg;                       // shared across torn-off windows
    if App <> nil then
    begin
      Win.EnterAppMode(App, ExpandFileName(AppPath));  // hide tabs; enable launcher prompt
      if WinTitle <> '' then Win.WindowTitle := WinTitle;
    end;
    { First tab; the program (app command or login shell) starts on show. }
    Win.AddTab(nil, WinTitle, {AStartShell=}True, MainCmd);
    Win.Show;
    fpgApplication.Run;
  finally
    App.Free;
    { Win may already have been freed during the run (e.g. its window closed
      while another stayed open), so free whatever windows remain, not Win. }
    TTermWindow.FreeAll;
    Cfg.Free;
  end;
end;

begin
  MainProc;
end.
