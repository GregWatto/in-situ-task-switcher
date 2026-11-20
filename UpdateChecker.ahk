ScheduleAutomaticUpdates() {
    if !ReadInstalledVersion()
        return

    SetTimer(CheckForAutomaticUpdates, 6 * 60 * 60 * 1000)
    ; A failed install can also restart the app. Wait for the regular check before retrying.
    if !A_Args.Length || A_Args[A_Args.Length] != "--after-update"
        SetTimer(() => CheckForAutomaticUpdates(), -30000)
}

CheckForAutomaticUpdates() {
    CheckForUpdates(false)
}

CheckForUpdates(manual := true) {
    global UseAltTab
    static checking := false
    static releases := "https://github.com/GregWatto/in-situ-task-switcher/releases/latest"

    if checking
        return

    installed := ReadInstalledVersion()
    if !installed {
        if manual && MsgBox("This copy has no installer version. Open the latest release page?",
            "In Situ updates", "YesNo Iconi") = "Yes"
            Run(releases)
        return
    }

    checking := true
    try {
        powershell := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
        mode := UseAltTab ? "AltTab" : "Default"
        args := Format('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{}" -InstalledVersion {} -AppProcessId {} -Mode {}',
            A_ScriptDir "\Install-Update.ps1", installed, ProcessExist(), mode)
        if RunWait('"' powershell '" ' args, , "Hide") != 0
            throw Error("Update failed.")
        if manual
            MsgBox("In Situ v" installed " is up to date.", "In Situ updates", "Iconi")
    } catch {
        if manual && MsgBox("Could not complete the update check. Open the release page in your browser?",
            "In Situ updates", "YesNo Icon!") = "Yes"
            try Run(releases)
    } finally {
        checking := false
    }
}

ReadInstalledVersion() {
    version := IniRead(A_ScriptDir "\InSitu-version.ini", "In Situ", "Version", "")
    return RegExMatch(version, "^\d+\.\d+\.\d+$") ? version : ""
}
