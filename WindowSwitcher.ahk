#Requires AutoHotkey v2.0
#SingleInstance Force
#Include Lib\UIA.ahk
#Include DesktopSwitcher.ahk

; Setup uses this to replace and close the instance for this script path.
if A_Args.Length && A_Args[1] = "--exit"
    ExitApp()

A_MenuMaskKey := "vkE8"
UseAltTab := A_Args.Length > 0 && A_Args[1] = "--alt-tab"
Switcher := WindowSwitcher()
Desktops := DesktopSwitcher(Switcher)
A_IconTip := (UseAltTab ? "Window Switcher (Alt+Tab)" : "Window Switcher (Alt+F12)") " / Desktops (Win+Tab)"

#HotIf !Desktops.HasSession()
$!F12::Switcher.Cycle(1, true)
$!+F12::Switcher.Cycle(-1, true)

#HotIf UseAltTab && !Desktops.HasSession()
$!Tab::Switcher.Cycle(1)
$!+Tab::Switcher.Cycle(-1)
#HotIf Switcher.HasSession()
$*Down::Switcher.Move(1)
$*Up::Switcher.Move(-1)
$*Right::Switcher.Expand()
$*Left::Switcher.Collapse()
$*Esc::Switcher.Cancel()
#HotIf !Switcher.HasSession()
$#Tab::Desktops.Cycle(1, true)
$#+Tab::Desktops.Cycle(-1, true)
#HotIf Desktops.HasSession()
$*Right::Desktops.Cycle(1)
$*Left::Desktops.Cycle(-1)
$*Down::Desktops.Cycle(1)
$*Up::Desktops.Cycle(-1)
$*Esc::Desktops.Cancel()
#HotIf

~*LAlt Up::Switcher.Release(0xA5)
~*RAlt Up::Switcher.Release(0xA4)
~*LWin Up::Desktops.Release(0x5C)
~*RWin Up::Desktops.Release(0x5B)

class WindowSwitcher {
    static FrameCornerDiameter := 20

    __New() {
        this.session := 0
        this.releaseMonitor := ObjBindMethod(this, "CheckAltRelease")
        this.tabDiscoveryTimer := ObjBindMethod(this, "DiscoverTabs")
        this.recent := []
        this.thumbnail := 0
        this.previewWindow := 0
        this.previewedTab := 0
        this.overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "Window Switcher")
        WinSetTransparent(255, this.overlay.Hwnd)
        this.theme := this.GetTheme()
        theme := this.theme
        this.overlay.BackColor := theme.background
        this.overlay.MarginX := 26
        this.overlay.MarginY := 22
        MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
        dpiScale := A_ScreenDPI / 96
        this.dpiScale := dpiScale
        this.iconSize := Round(24 * dpiScale)
        this.fileIcons := Map()
        this.iconImages := Map()
        this.gdiplus := DllCall("LoadLibraryW", "WStr", "gdiplus.dll", "Ptr")
        this.gdiplusToken := 0
        if this.gdiplus {
            startup := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
            NumPut("UInt", 1, startup)
            token := 0
            if !DllCall("gdiplus\GdiplusStartup", "UPtr*", &token, "Ptr", startup, "Ptr", 0)
                this.gdiplusToken := token
        }
        width := Min(1460, Floor((right - left) / dpiScale * 0.92) - 2 * this.overlay.MarginX)
        height := Min(510, Floor((bottom - top) / dpiScale * 0.67))
        listWidth := Round(width * 0.42)
        previewWidth := width - listWidth - 22
        this.overlay.SetFont("s9 c" theme.text, "Segoe UI")
        ; LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT
        this.rows := this.overlay.AddListBox(
            Format("xm ym w{} h{} +0x150 -0x800000 -E0x200 Background{}", listWidth, height, theme.surface))
        SendMessage(0x01A0, 0, Round(42 * dpiScale), this.rows.Hwnd) ; LB_SETITEMHEIGHT
        this.systemRowFont := this.CreateSystemRowFont()
        this.rowFont := this.systemRowFont
            ? this.systemRowFont : SendMessage(0x31, 0, 0, this.rows.Hwnd) ; WM_GETFONT
        this.rowDetails := []
        this.rowBrush := DllCall("gdi32\CreateSolidBrush", "UInt", this.ColorRef(theme.surface), "Ptr")
        this.selectedBrush := DllCall("gdi32\CreateSolidBrush", "UInt", this.ColorRef(theme.selected), "Ptr")
        this.accentBrush := DllCall("gdi32\CreateSolidBrush", "UInt", this.ColorRef(theme.accent), "Ptr")
        OnMessage(0x002B, ObjBindMethod(this, "DrawRow")) ; WM_DRAWITEM
        OnMessage(0x0021, ObjBindMethod(this, "MouseActivate")) ; WM_MOUSEACTIVATE
        OnMessage(0x0201, ObjBindMethod(this, "ClickList")) ; WM_LBUTTONDOWN
        OnMessage(0x0202, ObjBindMethod(this, "IgnoreListClick")) ; WM_LBUTTONUP
        OnMessage(0x0203, ObjBindMethod(this, "ClickList")) ; WM_LBUTTONDBLCLK
        this.overlay.SetFont("s12 norm c" theme.muted)
        this.preview := this.overlay.AddText(
            Format("x+22 yp w{} h{} Center +0x200 Background{}", previewWidth, height, theme.preview),
            "Preview unavailable")
        this.hint := this.overlay.AddText(Format("xm y+16 w{}", width), "")
        this.overlay.Show("AutoSize Hide")
        this.RoundControl(this.overlay.Hwnd, WindowSwitcher.FrameCornerDiameter)
        this.RoundControl(this.rows.Hwnd, 14)
        this.RoundControl(this.preview.Hwnd, 16)
        this.backdrop := this.CreateBackdrop()
        this.shadow := this.CreateShadow()

        ; Seed from z-order and record actual foreground changes from here on.
        this.foregroundCallback := CallbackCreate(ObjBindMethod(this, "OnForeground"), "", 7)
        this.foregroundHook := DllCall("SetWinEventHook", "UInt", 3, "UInt", 3, "Ptr", 0,
            "Ptr", this.foregroundCallback, "UInt", 0, "UInt", 0, "UInt", 2, "Ptr")
        OnExit(ObjBindMethod(this, "Cleanup"))
    }

    Cleanup(*) {
        this.RestorePreviewedTab()
        this.ClearThumbnail()
        this.ReleaseIcons()
        if this.gdiplusToken
            DllCall("gdiplus\GdiplusShutdown", "UPtr", this.gdiplusToken)
        if this.gdiplus
            DllCall("FreeLibrary", "Ptr", this.gdiplus)
        if this.systemRowFont
            DllCall("gdi32\DeleteObject", "Ptr", this.systemRowFont)
        for brush in [this.rowBrush, this.selectedBrush, this.accentBrush]
            DllCall("gdi32\DeleteObject", "Ptr", brush)
        if this.foregroundHook
            DllCall("UnhookWinEvent", "Ptr", this.foregroundHook)
        CallbackFree(this.foregroundCallback)
    }

    CreateSystemRowFont() {
        metrics := Buffer(504, 0) ; NONCLIENTMETRICSW
        NumPut("UInt", metrics.Size, metrics)
        if !DllCall("SystemParametersInfoForDpi", "UInt", 0x29, "UInt", metrics.Size,
            "Ptr", metrics, "UInt", 0, "UInt", A_ScreenDPI)
            return 0
        return DllCall("gdi32\CreateFontIndirectW", "Ptr", metrics.Ptr + 408, "Ptr") ; lfMessageFont
    }

    GetTheme() {
        light := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "AppsUseLightTheme", 1)
        if light {
            return {
                background: "F2F4F8", surface: "FAFBFD", selected: "E1EEFC",
                preview: "E6EAF1", text: "192130", muted: "505D70", accent: "0067C0",
                tintOpacity: 0xA0
            }
        }
        return {
            background: "202020", surface: "282828", selected: "344658",
            preview: "171717", text: "F4F4F5", muted: "BCC5D0", accent: "76B9ED",
            tintOpacity: 0xB8
        }
    }

    ColorRef(rgb) {
        color := Integer("0x" rgb)
        return ((color & 0xFF) << 16) | (color & 0xFF00) | (color >> 16)
    }

    CreateBackdrop() {
        if !RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "EnableTransparency", 1)
            return 0

        backdrop := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000020 -DPIScale", "Switcher backdrop")
        backdrop.BackColor := "000000"
        WinSetTransparent(255, backdrop.Hwnd)
        policy := Buffer(16, 0)
        ; ACCENT_ENABLE_ACRYLICBLURBEHIND uses an alpha and BGR tint.
        tint := (this.theme.tintOpacity << 24) | this.ColorRef(this.theme.background)
        NumPut("Int", 4, "Int", 0, "UInt", tint, policy)
        composition := Buffer(3 * A_PtrSize, 0)
        NumPut("Int", 19, composition) ; WCA_ACCENT_POLICY
        NumPut("Ptr", policy.Ptr, "UPtr", policy.Size, composition, A_PtrSize)
        corners := 2 ; DWMWCP_ROUND
        try {
            if DllCall("user32\SetWindowCompositionAttribute", "Ptr", backdrop.Hwnd,
                "Ptr", composition, "Int")
                && DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", backdrop.Hwnd, "UInt", 33,
                    "Int*", &corners, "UInt", 4, "Int") >= 0 {
                WinGetPos(,, &width, &height, this.overlay.Hwnd)
                backdrop.Show(Format("w{} h{} Hide", width, height))
                ; Keep the text, list and DWM thumbnail on a separate surface.
                WinSetTransColor(this.theme.background, this.overlay.Hwnd)
                return backdrop
            }
        }
        backdrop.Destroy()
        return 0
    }

    CreateShadow() {
        WinGetPos(,, &frameWidth, &frameHeight, this.overlay.Hwnd)
        padding := Round(40 * this.dpiScale)
        width := frameWidth + 2 * padding
        height := frameHeight + 2 * padding
        dc := DllCall("gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
        if !dc
            return 0
        bitmap := 0
        previous := 0
        try {
            pixels := 0
            bitmap := this.CreateDib(dc, width, height, &pixels)
            if !bitmap
                return 0
            previous := DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", bitmap, "Ptr")
            if !previous
                return 0
            this.DrawShadow(pixels, width, height, padding)

            window := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08080020 -DPIScale", "Switcher shadow")
            size := Buffer(8)
            NumPut("Int", width, "Int", height, size)
            origin := Buffer(8, 0)
            blend := Buffer(4, 0)
            NumPut("UChar", 255, "UChar", 1, blend, 2) ; Full opacity with per-pixel alpha.
            if DllCall("UpdateLayeredWindow", "Ptr", window.Hwnd, "Ptr", 0, "Ptr", 0,
                "Ptr", size, "Ptr", dc, "Ptr", origin, "UInt", 0, "Ptr", blend, "UInt", 2)
                return {window: window, padding: padding}
            window.Destroy()
            return 0
        } finally {
            if previous
                DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", previous, "Ptr")
            if bitmap
                DllCall("gdi32\DeleteObject", "Ptr", bitmap)
            DllCall("gdi32\DeleteDC", "Ptr", dc)
        }
    }

    CreateDib(dc, width, height, &pixels) {
        header := Buffer(40, 0)
        NumPut("UInt", 40, "Int", width, "Int", -height, "UShort", 1, "UShort", 32, header)
        return DllCall("gdi32\CreateDIBSection", "Ptr", dc, "Ptr", header,
            "UInt", 0, "Ptr*", &pixels, "Ptr", 0, "UInt", 0, "Ptr")
    }

    DrawShadow(pixels, width, height, padding) {
        DllCall("msvcrt\memset", "Ptr", pixels, "Int", 0, "UPtr", width * height * 4, "Cdecl Ptr")
        scale := this.dpiScale
        radius := Round(WindowSwitcher.FrameCornerDiameter * scale) / 2
        offset := 6 * scale
        spread := 12 * scale
        contact := 3 * scale
        alpha := []
        Loop padding + 1 {
            distance := A_Index - 1
            opacity := 52 * Exp(-0.5 * (distance / spread) ** 2)
                + 17 * Exp(-0.5 * (distance / contact) ** 2)
            alpha.Push(Round(opacity) << 24)
        }

        ; Paint only outside the frame so acrylic can sample the desktop underneath.
        straightHeight := height / 2 - padding - radius
        Loop height {
            y := A_Index - 1
            vertical := y + 0.5 - height / 2
            corner := Abs(vertical) - straightHeight
            limit := (width + 1) // 2
            if corner <= 0
                limit := padding
            else if corner < radius
                limit := padding + Floor(radius - Sqrt(radius ** 2 - corner ** 2))
            shadowY := Max(0, Abs(vertical - offset) - straightHeight)
            row := pixels + y * width * 4
            Loop limit {
                x := A_Index - 1
                shadowX := Max(0, padding + radius - x - 0.5)
                distance := Max(0, Round(Sqrt(shadowX ** 2 + shadowY ** 2) - radius))
                if distance <= padding {
                    value := alpha[distance + 1]
                    NumPut("UInt", value, row + x * 4)
                    NumPut("UInt", value, row + (width - x - 1) * 4)
                }
            }
        }
    }

    RoundControl(hwnd, diameter) {
        WinGetPos(,, &width, &height, hwnd)
        diameter := Round(diameter * this.dpiScale)
        region := DllCall("gdi32\CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", width + 1,
            "Int", height + 1, "Int", diameter, "Int", diameter, "Ptr")
        if region && !DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", region, "Int", true)
            DllCall("gdi32\DeleteObject", "Ptr", region)
    }

    DrawRow(wParam, lParam, message, hwnd) {
        ; DRAWITEMSTRUCT aligns HWND and HDC to the pointer size.
        controlOffset := A_PtrSize = 8 ? 24 : 20
        if hwnd != this.overlay.Hwnd || NumGet(lParam, controlOffset, "Ptr") != this.rows.Hwnd
            return
        index := NumGet(lParam, 8, "Int") + 1
        dc := NumGet(lParam, controlOffset + A_PtrSize, "Ptr")
        rect := lParam + controlOffset + 2 * A_PtrSize
        DllCall("FillRect", "Ptr", dc, "Ptr", rect, "Ptr", this.rowBrush)
        if index < 1 || index > this.rowDetails.Length
            return 1

        row := this.rowDetails[index]
        scale := this.dpiScale
        left := NumGet(rect, 0, "Int")
        top := NumGet(rect, 4, "Int")
        right := NumGet(rect, 8, "Int")
        bottom := NumGet(rect, 12, "Int")
        saved := DllCall("gdi32\SaveDC", "Ptr", dc)
        try {
            if NumGet(lParam, 16, "UInt") & 1 { ; ODS_SELECTED
                DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", DllCall("gdi32\GetStockObject", "Int", 8, "Ptr"), "Ptr")
                DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", this.selectedBrush, "Ptr")
                radius := Round(8 * scale)
                DllCall("gdi32\RoundRect", "Ptr", dc, "Int", left + Round(4 * scale), "Int", top + 2,
                    "Int", right - Round(5 * scale), "Int", bottom - 2, "Int", radius, "Int", radius)
                accent := Buffer(16)
                center := (top + bottom) // 2
                NumPut("Int", left + Round(6 * scale), "Int", center - Round(9 * scale),
                    "Int", left + Round(9 * scale), "Int", center + Round(9 * scale), accent)
                DllCall("FillRect", "Ptr", dc, "Ptr", accent, "Ptr", this.accentBrush)
            }

            DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", this.rowFont, "Ptr")
            DllCall("gdi32\SetBkMode", "Ptr", dc, "Int", 1)
            markerLeft := left + Round(row.markerOffset * scale)
            if row.favicon
                this.DrawTabFavicon(dc, row.favicon, markerLeft, top, bottom)
            if row.marker {
                DllCall("gdi32\SetTextColor", "Ptr", dc, "UInt", this.ColorRef(this.theme.muted))
                this.DrawRowText(dc, row.marker, markerLeft, top, right, bottom)
                if row.window && !row.window.hasTabGroups
                    this.DrawRowText(dc, row.window.tabCount, left + Round(30 * scale), top,
                        left + Round(62 * scale), bottom)
            }
            if row.window
                this.DrawWindowIcon(dc, row.window, left + Round(64 * scale), top, bottom)
            DllCall("gdi32\SetTextColor", "Ptr", dc, "UInt", this.ColorRef(this.theme.text))
            this.DrawRowText(dc, row.title, left + Round((row.window ? 98 : row.markerOffset + 30) * scale), top,
                right - Round(14 * scale), bottom)
        } finally {
            DllCall("gdi32\RestoreDC", "Ptr", dc, "Int", saved)
        }
        return 1
    }

    DrawRowText(dc, text, left, top, right, bottom) {
        rect := Buffer(16)
        NumPut("Int", left, "Int", top, "Int", right, "Int", bottom, rect)
        ; DT_END_ELLIPSIS | DT_NOPREFIX | DT_SINGLELINE | DT_VCENTER
        DllCall("DrawTextW", "Ptr", dc, "WStr", text, "Int", -1, "Ptr", rect, "UInt", 0x8824)
    }

    MouseActivate(wParam, lParam, message, hwnd) {
        if hwnd = this.overlay.Hwnd || wParam = this.overlay.Hwnd
            return 3 ; MA_NOACTIVATE: deliver the click without moving focus.
    }

    IgnoreListClick(wParam, lParam, message, hwnd) {
        if hwnd = this.rows.Hwnd
            return 0
    }

    ClickList(wParam, lParam, message, hwnd) {
        if hwnd != this.rows.Hwnd
            return
        Critical
        session := this.session
        if !session || !session.shown || session.canceled
            return 0

        hit := DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x01A9, "UPtr", 0, "Ptr", lParam, "Int")
        row := (hit & 0xFFFF) + 1
        if (hit >> 16) || row > this.rowDetails.Length
            return 0
        rect := Buffer(16)
        y := (lParam >> 16) & 0xFFFF
        ; LB_ITEMFROMPOINT also returns the last row for clicks in empty space.
        if DllCall("SendMessageW", "Ptr", hwnd, "UInt", 0x0198, "UPtr", row - 1, "Ptr", rect, "Int") = -1
            || y < NumGet(rect, 4, "Int") || y >= NumGet(rect, 12, "Int")
            return 0

        detail := this.rowDetails[row]
        x := (lParam & 0xFFFF) / this.dpiScale
        toggle := detail.window ? detail.marker && x < 61
            : detail.node.HasOwnProp("children") && x >= detail.markerOffset - 5 && x < detail.markerOffset + 25
        this.SelectRow(session, row, !toggle)
        if toggle {
            if detail.node ? detail.node.expanded : session.index = session.expandedIndex
                this.Collapse()
            else
                this.Expand()
        }
        return 0
    }

    GetWindowIcon(window) {
        if !window.HasOwnProp("icon") {
            getClassIcon := A_PtrSize = 8 ? "GetClassLongPtrW" : "GetClassLongW"
            icon := this.RequestWindowIcon(window.hwnd, 1) ; ICON_BIG
            if !icon
                icon := DllCall(getClassIcon, "Ptr", window.hwnd, "Int", -14, "Ptr") ; GCLP_HICON
            if !icon
                icon := this.ExtractFileIcon(window.hwnd)
            if !icon
                icon := this.RequestWindowIcon(window.hwnd, 0) ; ICON_SMALL
            if !icon
                icon := DllCall(getClassIcon, "Ptr", window.hwnd, "Int", -34, "Ptr") ; GCLP_HICONSM
            window.icon := icon ? icon : DllCall("LoadIconW", "Ptr", 0, "Ptr", 32512, "Ptr")
        }
        return window.icon
    }

    DrawWindowIcon(dc, window, left, top, bottom) {
        icon := this.GetWindowIcon(window)
        image := this.GetIconImage(icon)
        width := this.iconSize
        height := this.iconSize
        if image {
            scale := Min(1, this.iconSize / Max(image.width, image.height))
            width := Max(1, Round(image.width * scale))
            height := Max(1, Round(image.height * scale))
        }
        x := left + (this.iconSize - width) // 2
        y := top + (bottom - top - height) // 2
        if image && (width < image.width || height < image.height)
            && this.DrawIconBitmap(dc, image.bitmap, image.width, image.height, x, y, width, height)
            return
        DllCall("DrawIconEx", "Ptr", dc, "Int", x, "Int", y, "Ptr", icon,
            "Int", width, "Int", height, "UInt", 0, "Ptr", 0, "UInt", 3)
    }

    DrawIconBitmap(dc, bitmap, sourceWidth, sourceHeight, x, y, width, height) {
        graphics := 0
        if DllCall("gdiplus\GdipCreateFromHDC", "Ptr", dc, "Ptr*", &graphics)
            return false
        try {
            DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", graphics, "Int", 7)
            DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", graphics, "Int", 4)
            return !DllCall("gdiplus\GdipDrawImageRectRectI", "Ptr", graphics, "Ptr", bitmap,
                "Int", x, "Int", y, "Int", width, "Int", height, "Int", 0, "Int", 0,
                "Int", sourceWidth, "Int", sourceHeight, "Int", 2, "Ptr", 0, "Ptr", 0, "Ptr", 0)
        } finally {
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", graphics)
        }
    }

    DrawTabFavicon(dc, favicon, x, top, bottom) {
        bitmap := 0
        size := favicon.size
        if DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", size, "Int", size,
            "Int", size * 4, "Int", 0xE200B, "Ptr", favicon.pixels, "Ptr*", &bitmap)
            return
        try {
            displaySize := Round(16 * this.dpiScale)
            this.DrawIconBitmap(dc, bitmap, size, size, x,
                top + (bottom - top - displaySize) // 2, displaySize, displaySize)
        } finally {
            DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
        }
    }

    GetIconImage(icon) {
        if !this.gdiplusToken || !icon
            return 0
        if !this.iconImages.Has(icon) {
            this.iconImages[icon] := 0
            bitmap := 0
            if !DllCall("gdiplus\GdipCreateBitmapFromHICON", "Ptr", icon, "Ptr*", &bitmap) {
                width := 0
                height := 0
                DllCall("gdiplus\GdipGetImageWidth", "Ptr", bitmap, "UInt*", &width)
                DllCall("gdiplus\GdipGetImageHeight", "Ptr", bitmap, "UInt*", &height)
                if width && height {
                    image := {bitmap: bitmap, width: width, height: height}
                    if Max(width, height) > this.iconSize {
                        alphaImage := this.CopyAlphaIcon(icon, width, height)
                        if alphaImage {
                            DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
                            image := alphaImage
                        }
                    }
                    this.iconImages[icon] := image
                } else {
                    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
                }
            }
        }
        return this.iconImages[icon]
    }

    CopyAlphaIcon(icon, width, height) {
        dc := DllCall("gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
        if !dc
            return 0
        dib := 0
        previous := 0
        try {
            pixels := 0
            dib := this.CreateDib(dc, width, height, &pixels)
            if !dib
                return 0
            previous := DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", dib, "Ptr")
            if !previous
                return 0
            byteCount := width * height * 4
            DllCall("msvcrt\memset", "Ptr", pixels, "Int", 0, "UPtr", byteCount, "Cdecl Ptr")
            if !DllCall("DrawIconEx", "Ptr", dc, "Int", 0, "Int", 0, "Ptr", icon,
                "Int", width, "Int", height, "UInt", 0, "Ptr", 0, "UInt", 3)
                return 0
            DllCall("gdi32\GdiFlush")

            ; DrawIconEx preserves premultiplied alpha for modern icons. The
            ; GDI+ HICON conversion remains the fallback for mask-only icons.
            Loop width * height {
                if NumGet(pixels + (A_Index - 1) * 4, 3, "UChar") {
                    pixelBuffer := Buffer(byteCount)
                    DllCall("msvcrt\memcpy", "Ptr", pixelBuffer, "Ptr", pixels, "UPtr", byteCount, "Cdecl Ptr")
                    bitmap := 0
                    if !DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", width, "Int", height,
                        "Int", width * 4, "Int", 0xE200B, "Ptr", pixelBuffer, "Ptr*", &bitmap)
                        return {bitmap: bitmap, width: width, height: height, pixels: pixelBuffer}
                    break
                }
            }
            return 0
        } finally {
            if previous
                DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", previous, "Ptr")
            if dib
                DllCall("gdi32\DeleteObject", "Ptr", dib)
            DllCall("gdi32\DeleteDC", "Ptr", dc)
        }
    }

    RequestWindowIcon(hwnd, size) {
        icon := 0
        ; WM_GETICON with a short timeout keeps an unresponsive app from blocking the picker.
        if DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x007F, "UPtr", size,
            "Ptr", A_ScreenDPI, "UInt", 0x23, "UInt", 20, "UPtr*", &icon, "Ptr")
            return icon
        return 0
    }

    ExtractFileIcon(hwnd) {
        try {
            path := WinGetProcessPath(hwnd)
            if !this.fileIcons.Has(path) {
                icon := 0
                DllCall("shell32\SHDefExtractIconW", "WStr", path, "Int", 0, "UInt", 0,
                    "Ptr*", &icon, "Ptr", 0, "UInt", this.iconSize, "Int")
                this.fileIcons[path] := icon
            }
            return this.fileIcons[path]
        }
        return 0
    }

    ReleaseIcons() {
        for icon, image in this.iconImages {
            if image
                DllCall("gdiplus\GdipDisposeImage", "Ptr", image.bitmap)
        }
        this.iconImages.Clear()
        for path, icon in this.fileIcons {
            if icon
                DllCall("DestroyIcon", "Ptr", icon)
        }
        this.fileIcons.Clear()
    }

    OnForeground(hook, event, hwnd, objectId, childId, threadId, eventTime) {
        if !this.session && hwnd && !objectId && !childId
            this.Remember(hwnd)
    }

    Remember(hwnd) {
        for index, previous in this.recent {
            if previous = hwnd {
                this.recent.RemoveAt(index)
                break
            }
        }
        this.recent.InsertAt(1, hwnd)
        if this.recent.Length > 256
            this.recent.Pop()
    }

    GetWindows(originalOrder) {
        windows := []
        eligible := Map()
        zOrder := WinGetList()
        for hwnd in zOrder {
            try {
                title := WinGetTitle(hwnd)
                styles := WinGetExStyle(hwnd)
                ; Ignore shell windows, tool windows, and owned popups unless
                ; Windows marks the popup as a separate app window.
                if !title || (styles & 0x80) || (styles & 0x08000000)
                    continue
                if !(styles & 0x40000) && DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
                    continue
                cloaked := 0
                DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14,
                    "UInt*", &cloaked, "UInt", 4)
                if cloaked || hwnd = DllCall("GetShellWindow", "Ptr")
                    continue
                windowClass := WinGetClass(hwnd)
                if windowClass = "Progman" || windowClass = "WorkerW"
                    continue
                provider := this.TabProvider(WinGetProcessName(hwnd), windowClass)
                eligible[hwnd] := {
                    hwnd: hwnd, pid: WinGetPID(hwnd), title: title,
                    topmost: !!(styles & 0x8),
                    tabProvider: provider, tabCount: -1, hasTabGroups: false
                }
                originalOrder.Push(eligible[hwnd])
            }
        }
        for hwnd in this.recent.Clone() {
            if eligible.Has(hwnd)
                windows.Push(eligible.Delete(hwnd))
        }
        for hwnd in zOrder {
            if eligible.Has(hwnd)
                windows.Push(eligible.Delete(hwnd))
        }
        return windows
    }

    TabProvider(processName, windowClass) {
        if windowClass = "Chrome_WidgetWin_1" {
            if processName = "msedge.exe"
                return "edge"
            if processName = "chrome.exe"
                return "chrome"
        }
        if processName = "explorer.exe" && windowClass = "CabinetWClass"
            return "explorer"
        return ""
    }

    HasSession() => !!this.session

    Cycle(direction, startAtTop := false) {
        Critical
        if !this.session {
            origin := WinExist("A")
            if origin
                this.Remember(origin)
            originalOrder := []
            windows := this.GetWindows(originalOrder)
            if !windows.Length
                return
            ; Start at the current window, or just outside the list if the
            ; foreground belongs to the desktop or an excluded window.
            index := direction > 0 ? 0 : 1
            for row, window in windows {
                if window.hwnd = origin {
                    index := row
                    break
                }
            }
            this.session := {
                windows: windows, index: startAtTop ? 1 : index, selectedNode: 0, selectedRow: 1,
                origin: origin, originalOrder: originalOrder, previewedWindows: Map(),
                restoredWindows: Map(), expandedIndex: 0, tabs: [], tabNodes: [], query: 0, status: "",
                openedGroups: Map(),
                shown: false, canceled: false, altUpChecks: 0
            }
            SetTimer(this.releaseMonitor, 25)
            SetTimer(ObjBindMethod(this, "Show", this.session), -130)
            if startAtTop
                return
        }
        session := this.session
        if session.canceled
            return
        this.ResetTabs(session)
        count := session.windows.Length
        session.index := Mod(session.index - 1 + direction + count, count) + 1
        if session.shown
            this.Render(session)
    }

    Show(session) {
        Critical
        if this.session != session || session.canceled || session.shown
            return
        session.shown := true
        this.Render(session)
        this.overlay.Show("AutoSize Center NoActivate")
        WinGetPos(&left, &top,,, this.overlay.Hwnd)
        if this.backdrop {
            if !this.ShowBehind(this.backdrop, this.overlay, left, top) {
                WinSetTransparent(255, this.overlay.Hwnd)
                this.backdrop.Destroy()
                this.backdrop := 0
            }
        }
        if this.shadow {
            padding := this.shadow.padding
            front := this.backdrop ? this.backdrop : this.overlay
            this.ShowBehind(this.shadow.window, front, left - padding, top - padding)
        }
        this.UpdatePreview(session)
    }

    ShowBehind(window, front, left, top) {
        ; NOSIZE | NOACTIVATE | SHOWWINDOW
        return DllCall("SetWindowPos", "Ptr", window.Hwnd, "Ptr", front.Hwnd,
            "Int", left, "Int", top, "Int", 0, "Int", 0, "UInt", 0x51)
    }

    Hide() {
        SetTimer(this.tabDiscoveryTimer, 0)
        this.overlay.Hide()
        if this.backdrop
            this.backdrop.Hide()
        if this.shadow
            this.shadow.window.Hide()
        this.ClearThumbnail()
        this.rowDetails := []
        this.ReleaseIcons()
    }

    Render(session, refreshPreview := true) {
        topRow := refreshPreview ? 0 : SendMessage(0x018E, 0, 0, this.rows.Hwnd) ; LB_GETTOPINDEX
        labels := []
        details := []
        for index, window in session.windows {
            expanded := index = session.expandedIndex
            indicator := ""
            if window.tabCount > 1 {
                indicator := expanded && (session.tabs.Length || session.query) ? Chr(0x25BE) : Chr(0x25B8)
                labels.Push(indicator " " window.tabCount "  " window.title)
            } else {
                labels.Push("    " window.title)
            }
            details.Push({title: window.title, marker: indicator, window: window, favicon: 0})
            if expanded {
                for tab in session.tabs {
                    marker := tab.favicon ? "" : Chr(8627)
                    labels.Push("        " marker "  " tab.title)
                    details.Push({title: tab.title, marker: marker, window: 0, favicon: tab.favicon})
                }
            }
        }
        this.rows.Delete()
        this.rowDetails := details
        this.rows.Add(labels)
        this.UpdateSelection(session, refreshPreview)
        if !refreshPreview
            SendMessage(0x0197, topRow, 0, this.rows.Hwnd) ; LB_SETTOPINDEX
    }

    SelectedRow(session) {
        if session.expandedIndex && session.index > session.expandedIndex
            return session.index + session.tabs.Length
        return session.index + session.tabIndex
    }

    UpdateSelection(session, refreshPreview := true) {
        this.rows.Choose(this.SelectedRow(session))
        window := session.windows[session.index]
        hint := "Click or Up / Down: select     "
        if session.index = session.expandedIndex && session.tabs.Length
            hint .= "Left or chevron: collapse     "
        else if session.index = session.expandedIndex && session.status
            hint .= session.status "     "
        else if window.tabCount > 1
            hint .= "Right or chevron: expand     "
        else if window.tabCount < 0
            hint .= "Right: look for tabs     "
        this.hint.Text := hint "Release Alt: keep selection     Esc: cancel"
        if refreshPreview && DllCall("IsWindowVisible", "Ptr", this.overlay.Hwnd)
            this.UpdatePreview(session)
    }

    UpdatePreview(session) {
        ; Finish switching before Alt release or Esc can clean up the session.
        Critical
        window := session.windows[session.index]
        element := session.tabIndex ? session.tabs[session.tabIndex].element : 0
        if this.previewedTab && (!element || this.previewedTab.hwnd != window.hwnd)
            this.RestorePreviewedTab()
        this.ActivateHighlighted(session, window)
        if WinWaitActive(window.hwnd,, 0.12) {
            this.RestoreMinimizedWindows(session, window.hwnd)
            this.RestoreWindowOrder(session, window.hwnd)
        }
        if element
            this.PreviewTab(window, session.tabs, element)

        if window.tabCount < 0
            SetTimer(this.tabDiscoveryTimer, -35)
        if this.previewWindow = window.hwnd
            return
        this.ClearThumbnail()
        this.previewWindow := window.hwnd
        this.ShowThumbnail(window.hwnd)
    }

    ActivateHighlighted(session, window) {
        if WinActive(window.hwnd)
            return
        try {
            if WinGetPID(window.hwnd) != window.pid
                return
            session.previewedWindows[window.hwnd] := true
            if WinGetMinMax(window.hwnd) = -1 {
                if DllCall("ShowWindowAsync", "Ptr", window.hwnd, "Int", 9)
                    session.restoredWindows[window.hwnd] := window.pid
            }
            this.SetForeground(window.hwnd)
        }
    }

    SetForeground(hwnd) {
        if !DllCall("SetForegroundWindow", "Ptr", hwnd)
            try WinActivate(hwnd)
    }

    RestoreMinimizedWindows(session, keep := 0) {
        for hwnd, pid in session.restoredWindows.Clone() {
            if hwnd = keep
                continue
            try {
                if WinGetPID(hwnd) = pid && !DllCall("ShowWindowAsync", "Ptr", hwnd, "Int", 7) ; SW_SHOWMINNOACTIVE
                    continue
            }
            session.restoredWindows.Delete(hwnd)
        }
    }

    RestoreWindowOrder(session, keep := 0) {
        if session.previewedWindows.Count <= session.previewedWindows.Has(keep)
            return
        ; Use the preceding surviving window in each band as the anchor.
        preceding := Map(0, 0, 1, -1) ; HWND_TOP, HWND_TOPMOST
        if keep {
            try preceding[!!(WinGetExStyle(keep) & 0x8)] := keep
        }
        for window in session.originalOrder {
            hwnd := window.hwnd
            if hwnd = keep
                continue
            try {
                if WinGetPID(hwnd) != window.pid || !DllCall("IsWindowVisible", "Ptr", hwnd)
                    continue
                band := !!(WinGetExStyle(hwnd) & 0x8)
                if band != window.topmost
                    continue
                if session.previewedWindows.Has(hwnd) && !DllCall("IsHungAppWindow", "Ptr", hwnd) {
                    ; NOSIZE | NOMOVE | NOACTIVATE | NOOWNERZORDER | NOSENDCHANGING
                    if DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", preceding[band],
                        "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0613)
                        session.previewedWindows.Delete(hwnd)
                }
                preceding[band] := hwnd
            }
        }
    }

    PreviewTab(window, tabs, element) {
        if !this.previewedTab {
            for tab in tabs {
                try {
                    if tab.element.SelectionItemIsSelected {
                        this.previewedTab := {hwnd: window.hwnd, original: tab.element, current: tab.element}
                        break
                    }
                }
            }
        }
        if !this.previewedTab || this.previewedTab.current = element
            return
        if this.SelectPreviewTab(element)
            this.previewedTab.current := element
    }

    RestorePreviewedTab(keepWindow := 0) {
        previous := this.previewedTab
        this.previewedTab := 0
        if previous && previous.hwnd != keepWindow && previous.current != previous.original {
            try {
                if previous.current.SelectionItemIsSelected
                    this.SelectPreviewTab(previous.original)
            }
        }
    }

    SelectPreviewTab(element) {
        try {
            ; SELFLAG_TAKESELECTION changes the tab without requesting focus.
            element.GetCurrentPattern("LegacyIAccessible").Select(2)
            return true
        }
        try {
            element.GetCurrentPattern("SelectionItem").Select()
            return true
        }
        return false
    }

    ShowThumbnail(source) {
        thumbnail := 0
        if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", this.overlay.Hwnd, "Ptr", source,
            "Ptr*", &thumbnail, "Int") < 0
            return
        size := Buffer(8, 0)
        if DllCall("dwmapi\DwmQueryThumbnailSourceSize", "Ptr", thumbnail, "Ptr", size, "Int") < 0 {
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", thumbnail)
            return
        }
        sourceWidth := NumGet(size, 0, "Int")
        sourceHeight := NumGet(size, 4, "Int")
        if sourceWidth <= 0 || sourceHeight <= 0 {
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", thumbnail)
            return
        }

        ; Map the preview control's physical client bounds to the overlay.
        bounds := Buffer(16, 0)
        DllCall("GetClientRect", "Ptr", this.preview.Hwnd, "Ptr", bounds)
        panelWidth := NumGet(bounds, 8, "Int")
        panelHeight := NumGet(bounds, 12, "Int")
        DllCall("MapWindowPoints", "Ptr", this.preview.Hwnd, "Ptr", this.overlay.Hwnd,
            "Ptr", bounds, "UInt", 2)
        padding := Round(12 * this.dpiScale)
        scale := Min((panelWidth - 2 * padding) / sourceWidth, (panelHeight - 2 * padding) / sourceHeight)
        width := Max(1, Round(sourceWidth * scale))
        height := Max(1, Round(sourceHeight * scale))
        left := NumGet(bounds, 0, "Int") + (panelWidth - width) // 2
        top := NumGet(bounds, 4, "Int") + (panelHeight - height) // 2

        properties := Buffer(48, 0)
        ; DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE
        NumPut("UInt", 0x09, "Int", left, "Int", top, "Int", left + width,
            "Int", top + height, properties)
        NumPut("Int", 1, properties, 40)
        if DllCall("dwmapi\DwmUpdateThumbnailProperties", "Ptr", thumbnail, "Ptr", properties, "Int") < 0
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", thumbnail)
        else
            this.thumbnail := thumbnail
    }

    ClearThumbnail() {
        if this.thumbnail
            DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", this.thumbnail)
        this.thumbnail := 0
        this.previewWindow := 0
    }

    Move(direction) {
        session := this.session
        if !session || session.canceled
            return
        count := session.windows.Length + session.tabs.Length
        row := Mod(this.SelectedRow(session) - 1 + direction + count, count) + 1
        this.SelectRow(session, row)
    }

    SelectRow(session, row) {
        expanded := session.expandedIndex
        session.index := row
        session.tabIndex := 0
        if expanded && row > expanded {
            if row <= expanded + session.tabs.Length {
                session.index := expanded
                session.tabIndex := row - expanded
            } else {
                session.index -= session.tabs.Length
            }
        }
        if session.shown
            this.UpdateSelection(session)
        else
            this.Show(session)
    }

    Expand() {
        session := this.session
        if !session || session.canceled || session.tabIndex
            return
        window := session.windows[session.index]
        if session.index = session.expandedIndex {
            if session.query
                return
            if session.tabs.Length {
                this.Move(1)
                return
            }
        }
        this.ResetTabs(session)
        query := {}
        session.expandedIndex := session.index
        session.query := query
        session.status := "Reading tabs..."
        if session.shown
            this.Render(session)
        else
            this.Show(session)
        SetTimer(ObjBindMethod(this, "LoadTabs", session, query, window), -1)
    }

    LoadTabs(session, query, window) {
        if this.session != session || session.query != query || session.canceled
            return
        tabs := []
        for element in this.ReadTabElements(window) {
            try {
                title := element.Name
                tabs.Push({element: element, title: title != "" ? title : "(Untitled tab)", favicon: 0})
            }
        }
        if this.session = session && session.query = query && !session.canceled && tabs.Length > 1
            && this.gdiplusToken && (window.tabProvider = "chrome" || window.tabProvider = "edge")
            try this.CaptureBrowserFavicons(window, tabs)
        Critical
        if this.session != session || session.query != query || session.canceled
            return
        session.query := 0
        window.tabCount := tabs.Length
        session.tabs := tabs.Length > 1 ? tabs : []
        session.status := tabs.Length > 1 ? "" : "No other tabs. Window still selectable."
        this.Render(session)
    }

    DiscoverTabs() {
        session := this.session
        if !session || !session.shown || session.canceled
            return
        if session.query {
            SetTimer(this.tabDiscoveryTimer, -35)
            return
        }
        window := session.windows[session.index]
        if !this.CanDiscoverTabs(window) {
            window := 0
            for candidate in session.windows {
                if this.CanDiscoverTabs(candidate) {
                    window := candidate
                    break
                }
            }
        }
        if !window
            return

        count := this.ReadTabElements(window).Length
        Critical
        if this.session != session || session.canceled
            return
        if window.tabCount < 0 {
            window.tabCount := count
            if count > 1 || window = session.windows[session.index]
                this.Render(session, false)
        }
        ; Yield between windows so quick switching never waits for a full scan.
        SetTimer(this.tabDiscoveryTimer, -35)
    }

    CanDiscoverTabs(window) {
        try {
            return window.tabCount < 0 && !DllCall("IsHungAppWindow", "Ptr", window.hwnd)
                && WinGetMinMax(window.hwnd) != -1
        }
        return false
    }

    ReadTabElements(window) {
        try {
            if WinGetPID(window.hwnd) = window.pid
                return this.FindTabElements(UIA.ElementFromHandle(window.hwnd,, false), window)
        }
        return []
    }

    CaptureBrowserFavicons(window, tabs) {
        if !WinActive(window.hwnd) || DllCall("IsHungAppWindow", "Ptr", window.hwnd)
            return
        WinGetPos(&left, &top, &width, &height, window.hwnd)
        dpi := DllCall("GetDpiForWindow", "Ptr", window.hwnd, "UInt")
        scale := dpi ? dpi / 96 : this.dpiScale
        size := Round(16 * scale)
        leading := Round((window.tabProvider = "chrome" ? 20 : 16) * scale)
        stripTop := tabs[1].element.BoundingRectangle.t
        if Abs(tabs[2].element.BoundingRectangle.t - stripTop) > Round(3 * scale)
            return

        crops := []
        captureHeight := 0
        for tab in tabs {
            try {
                rect := tab.element.BoundingRectangle
                if Abs(rect.t - stripTop) > Round(3 * scale) || rect.r - rect.l < Round(85 * scale)
                    continue
                x := rect.l - left + leading
                y := rect.t - top + (rect.b - rect.t - size) // 2
                if x < 2 || x + size > width || y < 0 || y + size > Min(height, Round(90 * scale))
                    continue
                crops.Push({tab: tab, x: x, y: y})
                captureHeight := Max(captureHeight, y + size)
            }
        }
        if !crops.Length
            return

        dc := DllCall("gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
        if !dc
            return
        dib := 0
        previous := 0
        try {
            pixels := 0
            dib := this.CreateDib(dc, width, captureHeight, &pixels)
            if !dib
                return
            previous := DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", dib, "Ptr")
            ; Read the browser's rendered tab strip into memory only.
            if !previous || !DllCall("PrintWindow", "Ptr", window.hwnd, "Ptr", dc, "UInt", 2)
                return
            DllCall("gdi32\GdiFlush")
            for crop in crops
                crop.tab.favicon := this.CopyTabFavicon(pixels, width, crop.x, crop.y, size)
        } finally {
            if previous
                DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", previous, "Ptr")
            if dib
                DllCall("gdi32\DeleteObject", "Ptr", dib)
            DllCall("gdi32\DeleteDC", "Ptr", dc)
        }
    }

    CopyTabFavicon(pixels, width, x, y, size) {
        result := Buffer(size * size * 4, 0)
        found := false
        Loop size {
            line := A_Index - 1
            source := pixels + ((y + line) * width + x) * 4
            background := NumGet(source - 8, "UInt")
            bgR := (background >> 16) & 255, bgG := (background >> 8) & 255, bgB := background & 255
            Loop size {
                offset := (A_Index - 1) * 4
                rgb := NumGet(source + offset, "UInt")
                r := (rgb >> 16) & 255, g := (rgb >> 8) & 255, b := rgb & 255
                difference := Max(Abs(r - bgR), Abs(g - bgG), Abs(b - bgB))
                if difference <= 8
                    continue
                found := true
                alpha := Min(255, Round(difference * 255 / 48))
                pixel := (alpha << 24) | (Round(r * alpha / 255) << 16)
                    | (Round(g * alpha / 255) << 8) | Round(b * alpha / 255)
                NumPut("UInt", pixel, result, line * size * 4 + offset)
            }
        }
        return found ? {pixels: result, size: size} : 0
    }

    FindTabElements(root, window) {
        switch window.tabProvider {
            case "edge":
                return root.FindElements({Type: "TabItem", ClassName: "EdgeTab"})
            case "chrome":
                strip := root.ElementExist({Type: "Tab", ClassName: "TabContainer"})
                return strip ? strip.FindElements({Type: "TabItem", ClassName: "Tab"}) : []
            case "explorer":
                strip := root.ElementExist({Type: "Tab", AutomationId: "TabView"})
                return strip ? strip.FindElements({Type: "TabItem"}) : []
        }

        ; For other apps, look for a selectable strip near the top of the
        ; window. Tabs inside a document or a nested window aren't app tabs.
        bounds := root.BoundingRectangle
        topLimit := bounds.t + Min(200 * this.dpiScale, (bounds.b - bounds.t) / 3)
        for strip in root.FindElements({Type: "Tab"}) {
            try {
                rect := strip.BoundingRectangle
                if rect.t < bounds.t || rect.t >= topLimit || rect.b <= rect.t
                    continue
                parent := strip.Parent
                while parent && !UIA.CompareElements(parent, root) {
                    if parent.Type = UIA.Type.Document || parent.Type = UIA.Type.Window {
                        parent := 0
                        break
                    }
                    parent := parent.Parent
                }
                if parent {
                    tabs := strip.FindElements({Type: "TabItem", IsSelectionItemPatternAvailable: true})
                    if tabs.Length
                        return tabs
                }
            }
        }
        return []
    }

    ResetTabs(session) {
        session.query := 0
        session.tabs := []
        session.tabIndex := 0
        session.expandedIndex := 0
        session.status := ""
    }

    Collapse() {
        session := this.session
        if !session || session.canceled || session.index != session.expandedIndex
            return
        this.ResetTabs(session)
        if session.shown
            this.Render(session)
    }

    Cancel() {
        Critical
        session := this.session
        if !session || session.canceled
            return
        session.canceled := true
        this.ResetTabs(session)
        this.Hide()
        this.RestorePreviewedTab()
        if session.origin && !WinActive(session.origin) {
            session.previewedWindows[session.origin] := true
            this.SetForeground(session.origin)
        }
        this.RestoreMinimizedWindows(session)
        this.RestoreWindowOrder(session)
        if !this.AltIsDown()
            this.FinishRelease(session)
    }

    AltIsDown(virtualKey := 0x12) => DllCall("GetAsyncKeyState", "Int", virtualKey, "Short") < 0

    Release(otherAlt) {
        Critical
        session := this.session
        if !session || this.AltIsDown(otherAlt)
            return
        this.FinishRelease(session)
    }

    CheckAltRelease() {
        Critical
        session := this.session
        if !session {
            SetTimer(this.releaseMonitor, 0)
            return
        }
        if this.AltIsDown() {
            session.altUpChecks := 0
            return
        }
        ; Focus changes can interrupt delivery of the key-up hotkey.
        if ++session.altUpChecks >= 2
            this.FinishRelease(session)
    }

    FinishRelease(session) {
        SetTimer(this.releaseMonitor, 0)
        this.session := 0
        if !session.canceled
            this.Commit(session)
    }

    Commit(session) {
        this.Hide()
        window := session.windows[session.index]
        this.RestorePreviewedTab(session.tabIndex ? window.hwnd : 0)
        try {
            if WinGetPID(window.hwnd) != window.pid
                return
            if !WinActive(window.hwnd)
                WinActivate(window.hwnd)
            if WinActive(window.hwnd)
                this.Remember(window.hwnd)
            if session.tabIndex && WinWaitActive(window.hwnd,, 0.5) {
                ; Keep the element from the snapshot. A closed tab can fail
                ; here, in which case the selected window stays activated.
                element := session.tabs[session.tabIndex].element
                element.GetCurrentPattern("SelectionItem").Select()
            }
        } catch Error {
            ; The window or tab can disappear while the picker is open.
        } finally {
            this.RestoreMinimizedWindows(session, window.hwnd)
            this.RestoreWindowOrder(session, WinActive(window.hwnd) ? window.hwnd : 0)
        }
    }
}
