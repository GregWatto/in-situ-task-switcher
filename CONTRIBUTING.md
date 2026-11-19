# Contributing

`WindowSwitcher.ahk` is the entry point for both pickers. It handles the keyboard shortcuts, window list, tab discovery, and live window previews. `DesktopSwitcher.ahk` handles virtual desktop selection and snapshots. `Lib/UIA.ahk` is the vendored UI Automation library.

## Validate the scripts

From the repository folder in PowerShell, using your AutoHotkey v2 executable path:

```powershell
Start-Process -FilePath "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" `
    -ArgumentList '/ErrorStdOut /Validate ".\WindowSwitcher.ahk"' -Wait -PassThru |
    Select-Object ExitCode
```

An exit code of 0 means AutoHotkey loaded the entry point and its includes successfully.

## Build the Windows installer

Install [Inno Setup 7](https://jrsoftware.org/inno-setup/downloads). Run this from the repository root in PowerShell 7 with your path to `ISCC.exe`.

```powershell
.\installer\Build-Installer.ps1 -Version 0.1.0 -IsccPath "C:\Path\To\Inno Setup 7\ISCC.exe"
```

The build checks the bundled AutoHotkey archive against the upstream SHA-256 and writes `dist/InSitu-Setup-0.1.0-x64.exe`. Publish the corresponding AutoHotkey source archive alongside the installer on the release page.

## Manual checks on Windows 11

- **Windows and tabs.** Open two browser or File Explorer tabs and a separate app, such as Notepad. From the separate app, open the window picker, expand the tab list, and select a tab. Check that the live preview follows and that releasing **Alt** commits the exact tab. Repeat with the mouse and keyboard.
- **Cancel and restore.** Start from a different window, preview a tab, and press **Esc**. Verify that the original window regains focus and the previewed window returns to its original tab. Try collapsing the tab list with **←**.
- **Optional Alt+Tab.** Launch with `--alt-tab`. Try a quick **Alt+Tab**, then cycle in both directions while holding **Alt**. Release **Alt** and verify the highlighted window becomes active.
- **Desktop previews and switching.** Create three virtual desktops in Task View and visit each one. Tap **Win+Tab** to return to the previous desktop. Hold **Win** after pressing **Tab** to check the preview cards, then cycle and release **Win** to jump to another desktop. Repeat and press **Esc** to verify that the current desktop stays active.

In a bug report, include your Windows build, AutoHotkey version, steps to reproduce, and the expected and observed behavior. For tab issues, also include the affected app and version.
