CheckForUpdates(*) {
    static checking := false
    static releases := "https://github.com/GregWatto/in-situ-task-switcher/releases"

    if checking
        return

    checking := true
    try {
        installed := IniRead(A_ScriptDir "\InSitu-version.ini", "In Situ", "Version", "")
        if !RegExMatch(installed, "^\d+\.\d+\.\d+$") {
            if MsgBox("This copy has no installer version. Open the latest release page?",
                "In Situ updates", "YesNo Iconi") = "Yes"
                Run(releases "/latest")
            return
        }

        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.SetTimeouts(3000, 3000, 3000, 3000)
        request.Open("HEAD", releases "/latest", true)
        request.Option[6] := false ; WinHttpRequestOption_EnableRedirects
        request.Send()

        deadline := A_TickCount + 10000
        while !request.WaitForResponse(0) {
            if A_TickCount >= deadline {
                request.Abort()
                throw Error("Release check timed out.")
            }
            Sleep(50)
        }

        if request.Status != 302
            throw Error("Unexpected release response.")
        location := request.GetResponseHeader("Location")
        if !RegExMatch(location, "i)^\Q" releases "\E/tag/v(\d+\.\d+\.\d+)$", &release)
            throw Error("Unexpected release tag.")

        latest := release[1]
        if VerCompare(latest, installed) > 0 {
            if MsgBox("In Situ v" latest " is available. You have v" installed ".`n`nOpen the release page?",
                "In Situ updates", "YesNo Iconi") = "Yes"
                Run(releases "/tag/v" latest)
        } else {
            MsgBox("In Situ v" installed " is up to date.", "In Situ updates", "Iconi")
        }
    } catch {
        if MsgBox("Could not check for updates. Open the release page in your browser?",
            "In Situ updates", "YesNo Icon!") = "Yes"
            try Run(releases "/latest")
    } finally {
        checking := false
    }
}
