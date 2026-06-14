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
  fpg_main, fpg_stylemanager,
  { Pulling these units in registers their styles with fpgStyleManager so the
    user can pick them from the hamburger menu. }
  fpg_style_motif, fpg_style_plastic, fpg_style_fusion,
  fpg_style_win2k, fpg_style_win8,
  TermFpGUI.Config,
  TermFpGUI.Window;

procedure MainProc;
var
  Win: TTermWindow;
  Cfg: TTermConfig;
begin
  fpgApplication.Initialize;
  Cfg := TTermConfig.Create;
  Cfg.Load(DefaultConfigPath);              // seeds defaults if no file yet
  if Cfg.Theme <> '' then
  begin
    fpgStyleManager.SetStyle(Cfg.Theme);
    fpgStyleManager.FreeStyleInstance;
    fpgStyle := fpgStyleManager.Style;      // apply the saved theme up-front
  end;
  Win := TTermWindow.Create(nil);
  try
    Win.Config := Cfg;                       // shared across torn-off windows
    Win.AddTab(nil, '', {AStartShell=}True); // first tab; shell starts on show
    Win.Show;
    fpgApplication.Run;
  finally
    Win.Free;
    Cfg.Free;
  end;
end;

begin
  MainProc;
end.
