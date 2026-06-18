{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  App icon + XDG desktop integration.

    * RegisterAppIcon  — render the embedded HVIF (Haiku Vector Icon Format)
      vector icon to a TfpgImage and make it the application/window icon.  On
      X11 this drives _NET_WM_ICON directly; on Wayland the compositor instead
      looks the icon up from an installed .desktop file matching the app_id,
      which is what the install step below provides.

    * MaybePromptInstall — if no .desktop entry exists for this app (neither a
      per-user one in $XDG_DATA_HOME nor a system one in $XDG_DATA_DIRS), offer
      to install one (Install / Not now / Don't ask again).  Installing writes
      a per-user .desktop plus the scalable SVG icon into the hicolor theme.

  The icon is embedded (termfpgui_icon.inc, generated from icons/termfpgui.svg
  by the fpgui svg2hvif tool) so there is no runtime file dependency.
}
unit TermFpGUI.Desktop;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_base, fpg_main, fpg_widget,
  TermFpGUI.Config;

const
  CDesktopBaseName = 'termfpgui';     { .desktop / icon basename and app_id }

{ Render the embedded vector icon and set it as the application icon.  Call
  before creating any window so forms pick it up as their default IconName. }
procedure RegisterAppIcon;

{ True when a .desktop entry for this app exists anywhere XDG looks (per-user or
  system). }
function DesktopInstalled: Boolean;

{ If not installed (and the user hasn't dismissed the prompt), ask whether to
  install a per-user .desktop + icon.  Reads/updates ACfg.DesktopPromptDismissed
  and persists it when the user picks "Don't ask again". }
procedure MaybePromptInstall(AOwner: TfpgWidget; ACfg: TTermConfig);

{ Like MaybePromptInstall, but for an --app launch profile: its own name + icon,
  and an Exec that re-launches this binary with "--app <AConfigPath>".  Dismissal
  is tracked per launcher (ACfg.AppDesktopDismissed). }
procedure MaybePromptInstallApp(AOwner: TfpgWidget; AApp: TTermAppConfig;
  const AConfigPath: string; ACfg: TTermConfig);

{ Filesystem-safe launcher basename (lowercase, [a-z0-9-]) from a display name. }
function SanitizeBaseName(const AName: string): string;

{ Write the per-user .desktop + scalable SVG icon and refresh the desktop
  database.  Returns True on success.  AError carries a message on failure. }
function InstallDesktop(out AError: string): Boolean;

implementation

uses
  fpg_hvif, fpg_dialogs, fpg_form, fpg_label, fpg_button;

{ The HVIF byte array: const hvif_termicon_termfpgui: array[0..N] of byte. }
{$I termfpgui_icon.inc}

{ The scalable icon written into the hicolor theme on install.  Kept in sync
  with icons/termfpgui.svg (the source the embedded HVIF is generated from). }
const
  CIconSVG: string =
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">' + LineEnding +
    '  <rect x="6" y="10" width="52" height="44" rx="8" fill="#11161f"/>' + LineEnding +
    '  <rect x="9" y="13" width="46" height="38" rx="5" fill="#1d2633"/>' + LineEnding +
    '  <rect x="9" y="13" width="46" height="9" fill="#2a3346"/>' + LineEnding +
    '  <circle cx="15" cy="17.5" r="2" fill="#ff5f56"/>' + LineEnding +
    '  <circle cx="22" cy="17.5" r="2" fill="#ffbd2e"/>' + LineEnding +
    '  <circle cx="29" cy="17.5" r="2" fill="#27c93f"/>' + LineEnding +
    '  <path d="M16 29 L27 36 L16 43 L16 39 L21 36 L16 33 Z" fill="#43d17a"/>' + LineEnding +
    '  <rect x="30" y="40" width="16" height="3.5" rx="1.5" fill="#43d17a"/>' + LineEnding +
    '</svg>' + LineEnding;

{ ===================== app icon ===================== }

procedure RegisterAppIcon;
var
  stream: TMemoryStream;
  hicon: THvifIcon;
  src, img: TfpgImage;
begin
  if fpgImages.GetImage('app.' + CDesktopBaseName) <> nil then Exit;  { once }
  stream := TMemoryStream.Create;
  hicon := nil;
  try
    stream.WriteBuffer(hvif_termicon_termfpgui[0], Length(hvif_termicon_termfpgui));
    stream.Position := 0;
    hicon := THvifIcon.CreateFromStream(stream);
    src := hicon.GetImage(48, 48);          { owned by hicon — copy it out }
    if src = nil then Exit;
    img := TfpgImage.Create;
    img.AllocateImage(32, src.Width, src.Height);
    Move(src.ImageData^, img.ImageData^, src.ImageDataSize);
    img.UpdateImage;
    fpgImages.AddImage('app.' + CDesktopBaseName, img);   { collection owns img }
    fpgApplication.AppIcon := 'app.' + CDesktopBaseName;
  finally
    hicon.Free;
    stream.Free;
  end;
end;

{ ===================== XDG paths ===================== }

function XdgDataHome: string;
begin
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.local/share';
  Result := IncludeTrailingPathDelimiter(Result);
end;

function DesktopInstalledFor(const ABase: string): Boolean;
var
  dirs, d: string;
  p: Integer;
begin
  Result := FileExists(XdgDataHome + 'applications' + PathDelim + ABase + '.desktop');
  if Result then Exit;
  { System dirs from XDG_DATA_DIRS (default /usr/local/share:/usr/share). }
  dirs := GetEnvironmentVariable('XDG_DATA_DIRS');
  if dirs = '' then dirs := '/usr/local/share:/usr/share';
  while dirs <> '' do
  begin
    p := Pos(':', dirs);
    if p = 0 then begin d := dirs; dirs := ''; end
    else begin d := Copy(dirs, 1, p - 1); Delete(dirs, 1, p); end;
    if d = '' then Continue;
    if FileExists(IncludeTrailingPathDelimiter(d) + 'applications' + PathDelim
                  + ABase + '.desktop') then
      Exit(True);
  end;
end;

function DesktopInstalled: Boolean;
begin
  Result := DesktopInstalledFor(CDesktopBaseName);
end;

function SanitizeBaseName(const AName: string): string;
var
  i: Integer;
  c: Char;
  lastDash: Boolean;
begin
  Result := '';
  lastDash := False;
  for i := 1 to Length(AName) do
  begin
    c := AName[i];
    case c of
      'A'..'Z': begin Result := Result + Chr(Ord(c) + 32); lastDash := False; end;
      'a'..'z', '0'..'9': begin Result := Result + c; lastDash := False; end;
    else
      { collapse runs of other chars into a single dash }
      if (Result <> '') and not lastDash then
      begin Result := Result + '-'; lastDash := True; end;
    end;
  end;
  while (Result <> '') and (Result[Length(Result)] = '-') do
    SetLength(Result, Length(Result) - 1);
end;

{ Absolute path to the running binary, resolving a bare name via PATH. }
function BinaryPath: string;
begin
  Result := ExpandFileName(ParamStr(0));
  if FileExists(Result) then Exit;
  Result := ExeSearch(ExtractFileName(ParamStr(0)), GetEnvironmentVariable('PATH'));
  if Result = '' then Result := ParamStr(0);
end;

{ ===================== install ===================== }

procedure RunBestEffort(const ACmd: string);
begin
  try
    ExecuteProcess('/bin/sh', ['-c', ACmd]);
  except
    { update tools are optional — the entry is usable without them }
  end;
end;

{ Write one per-user .desktop + scalable SVG icon for a launcher described by
  the parameters, then refresh the desktop/icon databases. }
function InstallEntry(const ABase, ADisplayName, AExec, AIconSVG: string;
  out AError: string): Boolean;
var
  appDir, iconDir, desktopPath, iconPath: string;
  sl, svg: TStringList;
begin
  Result := False;
  AError := '';
  appDir := XdgDataHome + 'applications' + PathDelim;
  iconDir := XdgDataHome + 'icons' + PathDelim + 'hicolor' + PathDelim
           + 'scalable' + PathDelim + 'apps' + PathDelim;
  desktopPath := appDir + ABase + '.desktop';
  iconPath := iconDir + ABase + '.svg';
  try
    if not ForceDirectories(appDir) then
      raise Exception.Create('cannot create ' + appDir);
    if not ForceDirectories(iconDir) then
      raise Exception.Create('cannot create ' + iconDir);

    svg := TStringList.Create;
    try
      svg.Text := AIconSVG;
      svg.SaveToFile(iconPath);
    finally
      svg.Free;
    end;

    sl := TStringList.Create;
    try
      sl.Add('[Desktop Entry]');
      sl.Add('Type=Application');
      sl.Add('Version=1.0');
      sl.Add('Name=' + ADisplayName);
      sl.Add('GenericName=Terminal');
      sl.Add('Comment=Tabbed terminal emulator');
      sl.Add('Exec=' + AExec);
      sl.Add('Icon=' + ABase);
      sl.Add('Terminal=false');
      sl.Add('Categories=System;TerminalEmulator;');
      sl.Add('Keywords=terminal;shell;console;command;');
      sl.Add('StartupNotify=true');
      { Match the Wayland app_id so the compositor finds this entry's icon. }
      sl.Add('StartupWMClass=' + ABase);
      sl.SaveToFile(desktopPath);
    finally
      sl.Free;
    end;

    RunBestEffort('update-desktop-database ' + appDir + ' 2>/dev/null');
    RunBestEffort('gtk-update-icon-cache -f -t '
      + XdgDataHome + 'icons' + PathDelim + 'hicolor 2>/dev/null');
    Result := True;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

function InstallDesktop(out AError: string): Boolean;
begin
  Result := InstallEntry(CDesktopBaseName, 'TermFpGUI', BinaryPath, CIconSVG, AError);
end;

{ ===================== prompt ===================== }

type
  TInstallChoice = (icInstall, icLater, icNever);

  { Small three-button dialog: Install / Not now / Don't ask again. }
  TInstallPromptForm = class(TfpgForm)
  private
    FChoice: TInstallChoice;
    FLabel: TfpgLabel;
    procedure InstallClick(Sender: TObject);
    procedure LaterClick(Sender: TObject);
    procedure NeverClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetPrompt(const AText: string);
    property Choice: TInstallChoice read FChoice;
  end;

constructor TInstallPromptForm.Create(AOwner: TComponent);
var
  Btn: TfpgButton;
begin
  inherited Create(AOwner);
  WindowTitle := 'Add to Applications Menu';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, 430, 150);
  Sizeable := False;
  FChoice := icLater;

  FLabel := TfpgLabel.Create(Self);
  FLabel.SetPosition(16, 16, 398, 70);
  FLabel.WrapText := True;
  FLabel.Text :=
    'TermFpGUI is not yet in your applications menu.' + LineEnding + LineEnding +
    'Install a launcher (and icon) for the current user?  This also lets your '
    + 'desktop show the window icon on Wayland.';

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Install';
  Btn.SetPosition(16, 110, 90, 28);
  Btn.OnClick := @InstallClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Not now';
  Btn.SetPosition(214, 110, 90, 28);
  Btn.OnClick := @LaterClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Don''t ask again';
  Btn.SetPosition(310, 110, 104, 28);
  Btn.OnClick := @NeverClick;
end;

procedure TInstallPromptForm.InstallClick(Sender: TObject);
begin FChoice := icInstall; ModalResult := mrOK; end;

procedure TInstallPromptForm.LaterClick(Sender: TObject);
begin FChoice := icLater; ModalResult := mrCancel; end;

procedure TInstallPromptForm.NeverClick(Sender: TObject);
begin FChoice := icNever; ModalResult := mrCancel; end;

procedure TInstallPromptForm.SetPrompt(const AText: string);
begin
  FLabel.Text := AText;
end;

{ Show the three-way dialog with the given message and return the choice. }
function AskInstall(const AText: string): TInstallChoice;
var
  Frm: TInstallPromptForm;
begin
  Frm := TInstallPromptForm.Create(nil);
  try
    Frm.SetPrompt(AText);
    Frm.ShowModal;
    Result := Frm.Choice;
  finally
    Frm.Free;
  end;
end;

procedure ReportInstall(ASuccess: Boolean; const AError, AName: string);
begin
  if ASuccess then
    TfpgMessageDialog.Information('Installed',
      AName + ' was added to your applications menu.')
  else
    TfpgMessageDialog.Warning('Install failed',
      'Could not install the launcher.' + LineEnding + AError);
end;

procedure MaybePromptInstall(AOwner: TfpgWidget; ACfg: TTermConfig);
var
  ok: Boolean;
  err: string;
begin
  if (ACfg <> nil) and ACfg.DesktopPromptDismissed then Exit;
  if DesktopInstalled then Exit;

  case AskInstall(
    'TermFpGUI is not yet in your applications menu.' + LineEnding + LineEnding +
    'Install a launcher (and icon) for the current user?  This also lets your '
    + 'desktop show the window icon on Wayland.') of
    icInstall:
      begin
        ok := InstallDesktop(err);
        ReportInstall(ok, err, 'TermFpGUI');
      end;
    icNever:
      if ACfg <> nil then
      begin
        ACfg.DesktopPromptDismissed := True;
        ACfg.Save(DefaultConfigPath);
      end;
    icLater: ;   { ask again next launch }
  end;
end;

{ Double-quote a path for a .desktop Exec= argument (per the spec, args with
  spaces are double-quoted; backslash and quote are escaped). }
function DQuoteExec(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := '"' + Result + '"';
end;

procedure MaybePromptInstallApp(AOwner: TfpgWidget; AApp: TTermAppConfig;
  const AConfigPath: string; ACfg: TTermConfig);
var
  base, exec, iconsvg, err: string;
  ok: Boolean;
begin
  if AApp = nil then Exit;
  base := SanitizeBaseName(AApp.Name);
  if base = '' then Exit;
  if (ACfg <> nil) and ACfg.AppDesktopDismissed(base) then Exit;
  if DesktopInstalledFor(base) then Exit;

  case AskInstall(
    'Add "' + AApp.Name + '" to your applications menu?' + LineEnding + LineEnding +
    'This installs a launcher that starts this configuration' + LineEnding +
    '(and its drawer), with its own name and icon.') of
    icInstall:
      begin
        { The launcher re-runs this binary with the startup config. }
        exec := DQuoteExec(BinaryPath) + ' --app '
              + DQuoteExec(ExpandFileName(AConfigPath));
        if AApp.IconSVG <> '' then iconsvg := AApp.IconSVG else iconsvg := CIconSVG;
        ok := InstallEntry(base, AApp.Name, exec, iconsvg, err);
        ReportInstall(ok, err, AApp.Name);
      end;
    icNever:
      if ACfg <> nil then
      begin
        ACfg.DismissAppDesktop(base);
        ACfg.Save(DefaultConfigPath);
      end;
    icLater: ;
  end;
end;

end.
