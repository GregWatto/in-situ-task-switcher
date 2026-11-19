class DesktopSwitcher {
    static RegistryKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"

    __New(windowSwitcher) {
        this.windowSwitcher := windowSwitcher
        this.theme := windowSwitcher.theme
        this.session := 0
        this.picker := 0
        this.previews := Map()
        this.releaseMonitor := ObjBindMethod(this, "CheckWinRelease")
        SetTimer(ObjBindMethod(this, "RefreshPreview"), 1500)
        OnExit(ObjBindMethod(this, "FreePreviews"))
        OnMessage(0x0021, ObjBindMethod(this, "MouseActivate"))
    }

    HasSession() => !!this.session

    ReadLayout() {
        ; Explorer stores the desktop order as consecutive binary GUIDs.
        key := DesktopSwitcher.RegistryKey
        order := RegRead(key, "VirtualDesktopIDs", "")
        current := RegRead(key, "CurrentVirtualDesktop", "")
        if !RegExMatch(order, "i)^(?:[0-9a-f]{32})+$") || !RegExMatch(current, "i)^[0-9a-f]{32}$")
            return 0
        ids := []
        index := 0
        Loop StrLen(order) // 32 {
            id := SubStr(order, (A_Index - 1) * 32 + 1, 32)
            ids.Push(id)
            if id = current
                index := A_Index
        }
        return index ? {ids: ids, index: index} : 0
    }

    GuidFromId(id) {
        guid := Buffer(16)
        Loop 16
            NumPut("UChar", Integer("0x" SubStr(id, 2 * A_Index - 1, 2)), guid, A_Index - 1)
        return guid
    }

    DesktopName(id, index) {
        text := Buffer(78)
        DllCall("ole32\StringFromGUID2", "Ptr", this.GuidFromId(id), "Ptr", text, "Int", 39)
        name := RegRead(DesktopSwitcher.RegistryKey "\Desktops\" StrGet(text, "UTF-16"), "Name", "")
        return name != "" ? name : "Desktop " index
    }

    Cycle(direction, wrap := false) {
        Critical
        if !this.session {
            layout := this.ReadLayout()
            if !layout
                return
            lastId := this.LastDesktopId()
            selected := layout.index
            for index, id in layout.ids {
                if id = lastId {
                    selected := index
                    break
                }
            }
            this.session := {ids: layout.ids, origin: layout.index, index: selected,
                first: 1, canceled: false, winUpChecks: 0}
            SetTimer(this.releaseMonitor, 25)
            SetTimer(ObjBindMethod(this, "ShowPicker", this.session), -180)
            return
        }
        session := this.session
        if session.canceled
            return
        count := session.ids.Length
        next := session.index + direction
        session.index := wrap ? Mod(next - 1 + count, count) + 1 : Max(1, Min(count, next))
        if !this.picker {
            this.ShowPicker(session)
        } else {
            this.RenderCards(session)
        }
    }

    ShowPicker(session) {
        Critical
        if this.session != session || session.canceled || this.picker || !this.AnyWinDown()
            return
        layout := this.ReadLayout()
        if layout
            this.CapturePreview(layout)
        session.labels := []
        for index, id in session.ids {
            label := this.DesktopName(id, index)
            session.labels.Push(index = session.origin ? label "  (current)" : label)
        }
        theme := this.theme
        monitor := MonitorGetPrimary()
        MonitorGet(monitor, &left, &top, &right, &bottom)
        aspect := (right - left) / (bottom - top)
        MonitorGetWorkArea(monitor, &left, , &right)
        gap := 12
        margin := 18
        available := Max(180, Floor((right - left) * 0.92 * 96 / A_ScreenDPI) - 2 * margin)
        slots := Min(session.ids.Length, 6, Max(1, (available + gap) // (180 + gap)))
        width := Min(248, (available - (slots - 1) * gap) // slots)
        height := Min(165, Round((width - 4) / aspect))

        this.picker := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "Desktop Switcher")
        this.picker.BackColor := theme.background
        this.picker.MarginX := margin
        this.picker.MarginY := margin
        session.cards := []
        Loop slots {
            x := margin + (A_Index - 1) * (width + gap)
            frame := this.picker.AddText(Format("x{} y{} w{} h{} Background{}",
                x, margin, width, height + 36, theme.surface))
            bounds := Format("x{} y{} w{} h{}", x + 2, margin + 2, width - 4, height)
            this.picker.SetFont("s10 c" theme.muted, "Segoe UI")
            placeholder := this.picker.AddText(bounds " Center +0x200 Background" theme.preview,
                "Preview after you visit")
            picture := this.picker.AddPicture(bounds " Hidden")
            this.picker.SetFont("s11 c" theme.text)
            caption := this.picker.AddText(Format("x{} y{} w{} h32 Center +0x4280 Background{}",
                x + 2, margin + height + 2, width - 4, theme.surface))
            card := {frame: frame, placeholder: placeholder, picture: picture, caption: caption,
                x: x + 2, y: margin + 2, width: width - 4, height: height, index: 0, selected: -1}
            session.cards.Push(card)
            for control in [frame, placeholder, picture, caption]
                control.OnEvent("Click", ObjBindMethod(this, "SelectCard", session, card))
        }
        this.picker.SetFont("s10 c" theme.muted)
        hint := "← / → to select   ·   Release Win to switch   ·   Esc to cancel"
        this.picker.AddText(Format("xm y{} w{} Center", margin + height + 48,
            slots * width + (slots - 1) * gap), hint)
        corners := 2 ; DWMWCP_ROUND
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", this.picker.Hwnd, "UInt", 33,
            "Int*", &corners, "UInt", 4, "Int")
        this.RenderCards(session)
        this.picker.Show("AutoSize Center NoActivate")
    }

    RenderCards(session) {
        session.first := Max(1, Min(session.first, session.index))
        session.first := Max(session.first, session.index - session.cards.Length + 1)
        highlightChanged := false
        for slot, card in session.cards {
            index := session.first + slot - 1
            if card.index != index {
                card.index := index
                card.caption.Text := session.labels[index]
                preview := this.previews.Get(session.ids[index], 0)
                card.picture.Visible := !!preview
                if preview {
                    scale := Min(card.width / preview.width, card.height / preview.height)
                    width := Max(1, Round(preview.width * scale))
                    height := Max(1, Round(preview.height * scale))
                    card.picture.Move(card.x + (card.width - width) // 2,
                        card.y + (card.height - height) // 2, width, height)
                    card.picture.Value := "HBITMAP:*" preview.bitmap
                } else {
                    card.picture.Value := ""
                }
                card.placeholder.Text := preview ? "" : "Preview after you visit"
            }
            selected := index = session.index
            if card.selected != selected {
                card.selected := selected
                card.frame.Opt("Background" (selected ? this.theme.accent : this.theme.surface))
                card.caption.Opt("Background" (selected ? this.theme.selected : this.theme.surface))
                highlightChanged := true
            }
        }
        ; Static controls keep their old paint after a background color change.
        if highlightChanged && DllCall("IsWindowVisible", "Ptr", this.picker.Hwnd)
            DllCall("RedrawWindow", "Ptr", this.picker.Hwnd, "Ptr", 0, "Ptr", 0,
                "UInt", 0x185) ; INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW
    }

    MouseActivate(wParam, lParam, message, hwnd) {
        if this.picker && (hwnd = this.picker.Hwnd || wParam = this.picker.Hwnd)
            return 3 ; MA_NOACTIVATE
    }

    SelectCard(session, card, *) {
        Critical
        if this.session != session || session.canceled
            return
        session.index := card.index
        this.RenderCards(session)
    }

    RefreshPreview() {
        Critical
        if this.session || this.windowSwitcher.HasSession()
            return
        layout := this.ReadLayout()
        if layout
            this.CapturePreview(layout)
    }

    CapturePreview(layout) {
        id := layout.ids[layout.index]
        for cachedId in this.previews.Clone() {
            found := false
            for desktopId in layout.ids {
                if desktopId = cachedId {
                    found := true
                    break
                }
            }
            if !found
                DllCall("gdi32\DeleteObject", "Ptr", this.previews.Delete(cachedId).bitmap)
        }
        MonitorGet(MonitorGetPrimary(), &left, &top, &right, &bottom)
        sourceWidth := right - left
        sourceHeight := bottom - top
        scale := 480 / Max(sourceWidth, sourceHeight)
        width := Max(1, Round(sourceWidth * scale))
        height := Max(1, Round(sourceHeight * scale))
        bitmap := this.CaptureBitmap(left, top, sourceWidth, sourceHeight, width, height)
        if !bitmap
            return
        ; A native desktop change can land while the screenshot is being taken.
        latest := this.ReadLayout()
        if !latest || latest.ids[latest.index] != id {
            DllCall("gdi32\DeleteObject", "Ptr", bitmap)
            return
        }
        if this.previews.Has(id)
            DllCall("gdi32\DeleteObject", "Ptr", this.previews[id].bitmap)
        this.previews[id] := {bitmap: bitmap, width: width, height: height}
    }

    CaptureBitmap(left, top, sourceWidth, sourceHeight, width, height) {
        screen := DllCall("GetDC", "Ptr", 0, "Ptr")
        if !screen
            return 0
        memory := DllCall("gdi32\CreateCompatibleDC", "Ptr", screen, "Ptr")
        bitmap := 0
        previous := 0
        copied := false
        try {
            if !memory
                return 0
            bitmap := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", screen,
                "Int", width, "Int", height, "Ptr")
            if !bitmap
                return 0
            previous := DllCall("gdi32\SelectObject", "Ptr", memory, "Ptr", bitmap, "Ptr")
            if !previous
                return 0
            DllCall("gdi32\SetStretchBltMode", "Ptr", memory, "Int", 4) ; HALFTONE
            DllCall("gdi32\SetBrushOrgEx", "Ptr", memory, "Int", 0, "Int", 0, "Ptr", 0)
            ; SRCCOPY | CAPTUREBLT includes layered windows.
            copied := DllCall("gdi32\StretchBlt", "Ptr", memory, "Int", 0, "Int", 0,
                "Int", width, "Int", height, "Ptr", screen, "Int", left, "Int", top,
                "Int", sourceWidth, "Int", sourceHeight, "UInt", 0x40CC0020)
            return copied ? bitmap : 0
        } finally {
            if previous
                DllCall("gdi32\SelectObject", "Ptr", memory, "Ptr", previous, "Ptr")
            if memory
                DllCall("gdi32\DeleteDC", "Ptr", memory)
            if bitmap && !copied
                DllCall("gdi32\DeleteObject", "Ptr", bitmap)
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
        }
    }

    FreePreviews(*) {
        for , preview in this.previews
            DllCall("gdi32\DeleteObject", "Ptr", preview.bitmap)
    }

    Cancel() {
        Critical
        if !this.session
            return
        this.session.canceled := true
        if this.picker
            this.picker.Hide()
    }

    Release(otherWin) {
        Critical
        if this.session && !this.WinKeyIsDown(otherWin)
            this.FinishRelease()
    }

    WinKeyIsDown(key) => DllCall("GetAsyncKeyState", "Int", key, "Short") < 0

    AnyWinDown() => this.WinKeyIsDown(0x5B) || this.WinKeyIsDown(0x5C)

    CheckWinRelease() {
        Critical
        if !this.session
            return
        if this.AnyWinDown()
            this.session.winUpChecks := 0
        else if ++this.session.winUpChecks >= 2
            this.FinishRelease()
    }

    FinishRelease() {
        session := this.session
        SetTimer(this.releaseMonitor, 0)
        this.session := 0
        if this.picker {
            this.picker.Destroy()
            this.picker := 0
        }
        if session.canceled
            return
        if !this.SwitchTo(session.ids[session.index])
            TrayTip("The selected desktop could not be reached.", "Desktop Switcher")
    }

    DesktopManager() {
        static shellClass := "{C2F03A33-21F5-47FA-B4BB-156362A2F239}"
        static serviceProvider := "{6D5140C1-7436-11CE-8034-00AA006009FA}"
        static desktopService := "{C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B}"
        ; Use only the Windows 11 24H2-generation interface with this slot layout.
        static managerInterface := "{53F5CA0B-158F-4124-900C-057158060B27}"
        shell := ComObject(shellClass, serviceProvider)
        return ComObjQuery(shell, desktopService, managerInterface)
    }

    LastDesktopId() {
        try {
            manager := this.DesktopManager()
            desktop := ComValue(13, 0) ; VT_UNKNOWN
            ComCall(23, manager, "Ptr*", desktop) ; GetLastActiveDesktop
            if !desktop.Ptr
                return ""
            guid := Buffer(16)
            ComCall(4, desktop, "Ptr", guid) ; GetId
            id := ""
            Loop guid.Size
                id .= Format("{:02X}", NumGet(guid, A_Index - 1, "UChar"))
            return id
        } catch Error {
            return ""
        }
    }

    TrySwitchDirect(target) {
        try {
            manager := this.DesktopManager()
            desktop := ComValue(13, 0) ; VT_UNKNOWN owns the returned interface reference.
            ComCall(14, manager, "Ptr", this.GuidFromId(target), "Ptr*", desktop) ; FindDesktop
            if !desktop.Ptr
                return false
            try ComCall(22, manager, "Ptr", desktop) ; SwitchDesktopWithAnimation
            catch Error
                ComCall(9, manager, "Ptr", desktop) ; SwitchDesktop
        } catch Error {
            return false
        }
        deadline := A_TickCount + 750
        loop {
            layout := this.ReadLayout()
            if layout && layout.ids[layout.index] = target
                return true
            if A_TickCount >= deadline
                return false
            Sleep(25)
        }
    }

    SwitchTo(target) {
        layout := this.ReadLayout()
        if !layout
            return false
        if layout.ids[layout.index] = target || this.TrySwitchDirect(target)
            return true
        ; Fall back to the keyboard if Explorer does not expose direct switching.
        layout := this.ReadLayout()
        if !layout
            return false
        Loop layout.ids.Length {
            if !layout
                return false
            current := layout.ids[layout.index]
            if current = target
                return true
            destination := 0
            for index, id in layout.ids {
                if id = target {
                    destination := index
                    break
                }
            }
            if !destination
                return false
            SendEvent(destination > layout.index ? "#^{Right}" : "#^{Left}")
            deadline := A_TickCount + 750
            loop {
                Sleep(25)
                layout := this.ReadLayout()
                if layout && layout.ids[layout.index] != current
                    break
                if A_TickCount >= deadline
                    return false
            }
        }
        return false
    }
}
