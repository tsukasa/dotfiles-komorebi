#Requires AutoHotkey v2.0.18
#SingleInstance Force

/*===========================================================================*\
*                                                                             *
* komorebi.ahk - AutoHotkey script to manage Komorebi's window manager        *
* based on LGUG2Z's original script                                           *
*                                                                             *
\*===========================================================================*/

; Set the working directory to the script's directory
SetWorkingDir(A_ScriptDir)

; -----------------------------------------------------------------------------
; Callback Registrations                                                      |
; -----------------------------------------------------------------------------

; Register message handlers
OnMessage(WinbaseConstants.WM_DISPLAYCHANGE, OnDisplayChange)
OnMessage(WinbaseConstants.WM_SETTINGCHANGE, OnSettingChange)

; Register cleanup handler
OnExit(OnScriptExit)

; -----------------------------------------------------------------------------
; Classes                                                                     |
; -----------------------------------------------------------------------------

/**
 * Class that holds global variables and methods for the script
 */
Class SGlob {
    /**
     * Path to the INI configuration file for this script
     * @type {String}
     */
    static IniFilePath := Format("{}\komorebi-ahk.ini", A_ScriptDir)

    /**
     * Saves the initial work area configuration for each monitor so we can
     * restore it when the script exits.
     * @type {Map}
     */
    static MonitorWorkArea := Map()

    /**
     * Artifically limit the number of workspaces without having to
     * remove the key bindings for them.
     * Workaround for "phantom workspaces" shown in the bar.
     * @type {Integer}
     */
    static NumberOfWorkspaces := SGlob.ReadIniValue("Settings", "NumberOfWorkspaces", 7)

    /**
     * Cache variable to hold the KomoDo path
     * @type {String}
     */
    static KomoDoPath := SGlob.GetKomoDoPath()

    /**
     * Array of window handles to restore via pop.
     */
    static WindowStack := []

    /**
     * Adjust the tray icon and tooltip.
     * Only sets the tray icon if the file "komorebi-ahk.ico"
     * exists in the script's directory.
     */
    static AdjustTray() {
        ; Set custom tray tooltip
        A_IconTip := "Komorebi AutoHotkey Helper"

        ; Set custom tray icon
        iconPath := Format("{}\komorebi-ahk.ico", A_ScriptDir)

        if (FileExist(iconPath) != "")
            TraySetIcon(iconPath, , 0)
    }

    /**
     * Broadcasts a WM_SETTINGCHANGE message to all top-level windows
     */
    static BroadcastWmSettingChange() {
        ; Broadcast to all top-level windows
        HWND_BROADCAST := 0xFFFF
    
        SendMessage(
            WinbaseConstants.WM_SETTINGCHANGE,
            ,
            ,
            ,
            HWND_BROADCAST
        )
    }

    /**
     * Function to center the active window on the monitor the application is mostly on
     */
    static CenterActiveWindow() {
        activeWindow := WinExist("A")

        if (!activeWindow)
            return

        ; Get the center and other dimensions of the active window
        activeWinPos := SGlob.GetWindowCenter(activeWindow)

        ; Get the monitor the window is on based on the center of the window
        winMonitor := SGlob.GetMonitorOfWindow(activeWinPos.centerX, activeWinPos.centerY)

        ; If invalid monitor index: return
        if (winMonitor.monitorIndex = -1)
            return

        ; Calculate new position to center the window
        newX := winMonitor.workAreaX + ((winMonitor.workAreaWidth - winMonitor.workAreaX) - activeWinPos.width) // 2
        newY := winMonitor.workAreaY + ((winMonitor.workAreaHeight - winMonitor.workAreaY) - activeWinPos.height) // 2

        ; Move the window to the new position
        WinMove(newX, newY, , , activeWindow)
    }

    /**
     * Helper method that checks whether a workspace is in allowed range.
     * Will send the specified command to Komorebi if the workspace is valid.
     * 
     * Primarily intended for the "send-to-workspace" and "focus-workspace"
     * hotkeys to prevent sending commands to non-existent workspaces.
     * @param {String} command Command to send to Komorebi
     * @param {Integer} workspace Workspace number to send to
     */
    static CheckWorkspaceAndExecute(command, workspace) {
        if (!IsInteger(workspace))
            return
        if (SGlob.NumberOfWorkspaces >= (workspace + 1)) {
            SGlob.Komorebic(Format("{} {}", command, workspace))
        }
    }

    /**
     * Get the current monitor based on the mouse cursor position
     * This method retrieves the coordinates of the mouse cursor and determines which monitor it is on.
     * @returns {Object} The monitor index and work area dimensions
     */
    static GetCurrentMonitor() {
        oldValue := CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        CoordMode("Mouse", oldValue)
        return SGlob.GetMonitorOfWindow(mx, my)
    }

    /**
     * Reads the KomoDo path from the ini file and resolves environment variables
     * @returns {String} The resolved path to the KomoDo executable
     */
    static GetKomoDoPath() {
        komodoPath := SGlob.ReadIniValue("KomoDo", "KomoDoPath", "")
        komodoPath := SGlob.ResolveEnvironmentVariables(komodoPath)
        
        if(SGlob.IsKomoDoAvailable(komodoPath))
            return komodoPath
        
        return ""
    }

    /**
     * Get Komorebi Bar processes without any qualifiers
     * @returns {Integer[]} An array of process IDs for Komorebi Bar
     */
    static GetKomorebiBarProcesses() {
        return SGlob.ProcessGetByNameAndArguments("komorebi-bar.exe", "")
    }

    /**
     * Returns all monitor device instance paths as an array
     * @returns {Array} An array of monitor instance paths
     */
    static GetMonitorDeviceInstancePaths() {
        ; Initialize an array to store device instance paths
        monitorPaths := []

        try {
            ; Create a WMI service object
            wmiService := ComObjGet("winmgmts:\\.\root\CIMV2")

            ; Query all monitors
            monitors := wmiService.ExecQuery("SELECT * FROM Win32_PnPEntity WHERE PNPClass = 'Monitor'")

            ; Loop through the monitors and get the device instance paths
            for (monitor in monitors)
            {
                deviceID := monitor.PNPDeviceID

                if (IsSet(deviceID))
                {
                    ; Remove the "DISPLAY\" prefix and replace the first backslash with a dash
                    formattedID := RegExReplace(deviceID, "^[^\\]*\\", "", , 1)
                    formattedID := RegExReplace(formattedID, "\\", "-", , 1)
                    monitorPaths.Push(formattedID)
                }
            }
        } catch {
            ; Do nothing
        }

        return monitorPaths
    }

    /**
     * Function to get the monitor IDs from the configuration file
     * @returns {Map} An object with monitor IDs as keys and PNPDeviceIDs as values
     */
    static GetMonitorIdsFromConfig() {
        monitorIds := Map()
        monitorsIniSectionContent := IniRead(SGlob.IniFilePath, "Monitors")

        loop parse monitorsIniSectionContent, "`n", "`r" {
            if (InStr(A_LoopField, "=")) {
                keyValuePair := StrSplit(A_LoopField, "=", , 2)
                monitorId := keyValuePair[1]
                devicePath := keyValuePair[2]

                monitorIds.Set(monitorId, devicePath)
            }
        }

        return monitorIds
    }

    /**
     * Function to get the monitor the window is on based on the center of the window
     * @param {Integer} windowCenterX
     * @param {Integer} windowCenterY 
     * @returns {Object} The monitor index and work area dimensions
     */
    static GetMonitorOfWindow(windowCenterX, windowCenterY) {
        ; Get number of monitors - but only ones used for the desktop!
        monitorCount := SysGet(WinuserConstants.SM_CMONITORS)

        ; Set initial value to check if we found the monitor the window is on...
        monitorIndex := -1

        ; Loop through each monitor to find which one the window is on...
        ; Do this by checking on which monitor the center of the window is, otherwise we get false positives.
        loop (monitorCount) {
            MonitorGetWorkArea(
                A_Index,
                &workAreaX,
                &workAreaY,
                &workAreaWidth,
                &workAreaHeight
            )

            if (
                windowCenterX >= workAreaX and windowCenterX <= workAreaWidth
                and
                windowCenterY >= workAreaY and windowCenterY <= workAreaHeight
            ) {
                monitorIndex := A_Index
                break
            }
        }

        return {
            monitorIndex: monitorIndex,
            workAreaX: workAreaX,
            workAreaY: workAreaY,
            workAreaWidth: workAreaWidth,
            workAreaHeight: workAreaHeight
        }
    }

    /**
     * Function to get the taskbar's HWND
     * @returns {Ptr} The taskbar's HWND
     */
    static GetTaskbarHandle() {
        return DllCall("FindWindowEx",
            "Ptr", 0,
            "Ptr", 0,
            "Str", "Shell_TrayWnd",
            "Str", ""
        )
    }

    /**
     * Function to get the center of the window and other dimensions
     * @param {Hwnd} window Hwnd of the window to get the center of
     * @returns {Object} The window's position, size, and center
     */
    static GetWindowCenter(window) {
        ; Retrieve the active window's current position and size
        WinGetPos(
            &winX,
            &winY,
            &winWidth,
            &winHeight,
            window
        )

        ; Calculate the center of the window
        windowCenterX := winX + winWidth // 2
        windowCenterY := winY + winHeight // 2

        return {
            x: winX,
            y: winY,
            width: winWidth,
            height: winHeight,
            centerX: windowCenterX,
            centerY: windowCenterY
        }
    }

    /**
     * Function to hide the taskbar
     */
    static HideTaskbar() {
        taskbarHwnd := SGlob.GetTaskbarHandle()

        if (!taskbarHwnd)
            return

        DllCall("ShowWindow",
            "Ptr", taskbarHwnd,
            "Int", WinuserConstants.SW_HIDE
        )
    }

    /**
     * Function to check if KomoDo is available
     * @param {String} komodoPath Path to the KomoDo executable
     * @returns {Boolean} True if KomoDo is available, false otherwise
     */
    static IsKomoDoAvailable(komodoPath := SGlob.KomoDoPath) {
        return (FileExist(komodoPath) != "")
    }

    /**
     * Execute commands on KomoDo
     * @param {String[]} cmd KomoDo command to execute
     */
    static KomoDo(cmd) {
        if(SGlob.IsKomoDoAvailable())
            RunWait(Format("{} {}", SGlob.KomoDoPath, cmd), , "Hide")
    }

    /**
     * Execute commands on Komorebi
     * @param {String[]} cmd komorebic command to execute
     */
    static Komorebic(cmd) {
        RunWait(Format("komorebic.exe {}", cmd), , "Hide")
    }

    /**
     * Minimizes a window and adds it to the window stack
     */
    static MinimizeWindow() {
        activeWindow := WinExist("A")

        if (!activeWindow)
            return

        if (!SGlob.WindowStack.Has(activeWindow))
            SGlob.WindowStack.Push(activeWindow)

        SGlob.Komorebic("minimize")
    }

    /**
     * Returns the process ID of the specified executable with the given argument
     * @param executable The executable to check for
     * @param argument The arguments the executable should have
     * @returns {Integer[]} The process ID of the first matching process, or -1 if not found
     */
    static ProcessGetByNameAndArguments(executable, argument) {
        listOfPids := []

        try {
            pid := 0
            wmi := ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")

            query := Format(
                "SELECT * FROM Win32_Process WHERE Name = '{}' AND CommandLine LIKE '%{}%'",
                executable,
                argument
            )

            for (proc in wmi.ExecQuery(query))
            {
                pid := proc.ProcessId
                listOfPids.Push(pid)
            }
        } catch {
            ; Do nothing
            listOfPids := []
        }

        return listOfPids
    }

    /**
     * Reads a value from the ini file
     * @param {String} section INI section to read from
     * @param {String} key INI key in the section to read
     * @param {String} defaultValue Default value if no key was found
     * @return {String} The value of the key read from the ini file
     */
    static ReadIniValue(section, key, defaultValue := "") {
        if (!FileExist(SGlob.IniFilePath))
            return defaultValue

        return IniRead(SGlob.IniFilePath, section, key, defaultValue)
    }

    /**
     * Function to register a window as an AppBar.
     * NOTE: Requires KomoDo because the AHK implementation is broken and I don't know why...
     * @param {Hwnd} hwnd Hwnd of the window to register as an AppBar
     */
    static RegisterHwndAsAppBar(hwnd) {
        if (!WinWait("ahk_id " . hwnd, , 10))
            return

        if (SGlob.IsKomoDoAvailable())
            SGlob.KomoDo("register-appbar " . hwnd)
    }

    /**
     * Registers all Komorebi Bar processes as AppBars.
     */
    static RegisterKomorebiBarsAsAppBars() {
        ; Wait for the Komorebi Bar processes to start
        ProcessWait("komorebi-bar.exe", 10)

        ; Safety sleep
        Sleep(100)

        ; Get all Komorebi Bar processes
        komorebiBarPids := SGlob.GetKomorebiBarProcesses()

        ; Register each Komorebi Bar process as an AppBar
        for (pid in komorebiBarPids) {
            barHwnd := WinWait("ahk_pid " . pid, , 10)

            ; Skip if the window does not exist
            if (barHwnd == 0)
                continue

            SGlob.RegisterHwndAsAppBar(barHwnd)
        }
    }

    /**
     * Function to resolve all environment variables within a string
     * @param {String} inputString String to resolve environment variables in
     * @returns {String} The resolved string with environment variables expanded
     */
    static ResolveEnvironmentVariables(inputString) {
        ; Allocate buffer for the expanded string
        VarSetStrCapacity(&resolvedString, 4096)

        ; Call ExpandEnvironmentStringsW to expand environment variables
        DllCall("ExpandEnvironmentStringsW",
            "wstr", inputString,
            "wstr", &resolvedString,
            "uint", 4096
        )

        return resolvedString
    }

    /**
     * Reads the ini file and runs additional startup programs.
     * This allows for a comfortable way to ensure additional tools
     * are started with the script.
     * If the application is already running, it will not be started again.
     */
    static RunAdditionalApplications() {
        if (!FileExist(SGlob.IniFilePath))
            return

        content := IniRead(SGlob.IniFilePath, "AutoRunApplications")

        loop parse, content, "`n", "`r" {
            if (InStr(A_LoopField, "=")) {
                keyValuePair := StrSplit(A_LoopField, "=", , 2)
                applicationName := keyValuePair[1]
                applicationPath := keyValuePair[2]
                applicationPath := SGlob.ResolveEnvironmentVariables(applicationPath)
                applicationPath := StrReplace(applicationPath, "`"")

                SplitPath(applicationPath, &applicationExecutable)

                if (FileExist(applicationPath) && !ProcessExist(applicationExecutable)) {
                    Run(applicationPath)
                }
            }
        }
    }

    /**
     * Function to pop a window from the window stack and restore it
     */
    static RestoreWindow() {
        if (SGlob.WindowStack.Length == 0)
            return

        windowToRestore := SGlob.WindowStack.Pop()

        if (WinExist("ahk_id " . windowToRestore))
            WinRestore("ahk_id " . windowToRestore)
    }

    /**
     * Runs a DefaultApplication key from the ini file
     * @param appName Name of the application key name from the ini file
     */
    static RunDefaultApplication(appName) {
        appPath := SGlob.ReadIniValue("DefaultApplications", appName, "")
        appPath := SGlob.ResolveEnvironmentVariables(appPath)
        if (FileExist(appPath))
            Run(appPath)
    }

    /**
     * Checks the available monitors and whether the Komorebi bar is running on them.
     * If a monitor is connected and the bar is not running, it will be started.
     * If a monitor is not connected and the bar is running, it will be closed.
     */
    static RunOrKillKomorebiBarOnDisplayChange() {
        barConfigPattern := SGlob.ReadIniValue("Settings", "KomorebiBarConfigPattern", "komorebi.bar.monitor{:02}.json")
        barLaunchWait := SGlob.ReadIniValue("Settings", "KomorebiBarLaunchWait", 2000)

        monitorPaths := SGlob.GetMonitorDeviceInstancePaths()
        monitorConfiguredIds := SGlob.GetMonitorIdsFromConfig()
        
        ; Wrong configuration, no configuration... the usual...
        if (!IsSet(monitorConfiguredIds) || !IsSet(monitorPaths))
            return

        ; Iterate through the map of expected monitor IDs and
        ; cross-reference with the actual monitor paths.
        for (monitorConfigNumber, monitorConfigPath in monitorConfiguredIds) {
            monitorConnected := false

            for (path in monitorPaths) {
                ; Make sure the strings are lowercase for comparison!
                val1 := StrLower(monitorConfigPath)
                val2 := StrLower(path)

                if (val1 == val2) {
                    monitorConnected := true
                    break
                }
            }

            ; Check if the bar is already running for this monitor
            barPidOfMonitor := SGlob.ProcessGetByNameAndArguments(
                "komorebi-bar.exe",
                Format(barConfigPattern, monitorConfigNumber)
            )

            ; Only the first PID is needed
            if (barPidOfMonitor.Length == 0)
                barPidOfMonitor := [ -1 ]

            if (!monitorConnected) {
                ; Monitor not connected but bar might be active
                for (currentBarPid in barPidOfMonitor) {
                    ProcessClose(currentBarPid)
                }
            }

            if (monitorConnected) {
                ; Monitor connected and at least one bar is already active
                if (barPidOfMonitor.Length >= 0 && barPidOfMonitor[1] != -1)
                    continue

                ; Monitor connected but bar is not active
                ; NOTE: barConfigPattern needs to be concatenated so the format string will be parsed!
                barLaunchCmd := Format(
                    "komorebi-bar.exe `"--config`" `"{}\" . barConfigPattern . "`"",
                    A_ScriptDir,
                    monitorConfigNumber
                )

                ; Windows needs to unfuck itself before we can continue,
                ; otherwise the bar will not be launched correctly.
                ; I have not found any proper implementation for this...
                Sleep(barLaunchWait)

                Run(barLaunchCmd, , "Hide", &komoBarPid)
                SGlob.TouchKomorebiBarConfig(komoBarPid)
                
                barHwnd := WinWait("ahk_pid " . komoBarPid, , 10)
                if(barHwnd != 0)
                    SGlob.RegisterHwndAsAppBar(barHwnd)
            }
        }
    }

    /**
     * Moves the active window by a specific delta.
     * @param {Integer} leftDelta Integer of the delta to move the active window left/right
     * @param {Integer} topDelta  Integer of the delta to move the active window up/down
     */
    static SetActiveWindowPosition(leftDelta, topDelta) {
        activeWindow := WinExist("A")

        if (!activeWindow)
            return

        ; Get the center and other dimensions of the active window
        activeWinPos := SGlob.GetWindowCenter(activeWindow)

        ; Get the monitor the window is on based on the center of the window
        winMonitor := SGlob.GetMonitorOfWindow(activeWinPos.centerX, activeWinPos.centerY)

        ; If invalid monitor index: return
        if (winMonitor.monitorIndex = -1)
            return

        ; Calculate the new window position
        newLeft := activeWinPos.x + leftDelta
        newTop := activeWinPos.y + topDelta

        ; Ensure we do not move the window beyond the screen boundaries
        if (newLeft <= winMonitor.workAreaX)
            newLeft := winMonitor.workAreaX
        
        if (newLeft >= winMonitor.workAreaWidth - activeWinPos.width)
            newLeft := winMonitor.workAreaWidth - activeWinPos.width

        if (newTop <= winMonitor.workAreaY)
            newTop := winMonitor.workAreaY
        
        if (newTop >= winMonitor.workAreaHeight - activeWinPos.height)
            newTop := winMonitor.workAreaHeight - activeWinPos.height

        ; Move the window to the new position
        WinMove(newLeft, newTop, activeWinPos.width, activeWinPos.height, activeWindow)
    }

    /**
     * Resizes the active window by the specific width and height deltas.
     * Will stop the window from going off-screen.
     * @param {Integer} widthDelta Positive or negative integer to change the width of the active window
     * @param {Integer} heightDelta Positive or negative integer to change the height of the active window
     */
    static SetActiveWindowSize(widthDelta, heightDelta) {
        activeWindow := WinExist("A")

        if (!activeWindow)
            return

        ; Get the center and other dimensions of the active window
        activeWinPos := SGlob.GetWindowCenter(activeWindow)

        ; Get the monitor the window is on based on the center of the window
        winMonitor := SGlob.GetMonitorOfWindow(activeWinPos.centerX, activeWinPos.centerY)

        ; If invalid monitor index: return
        if (winMonitor.monitorIndex = -1)
            return

        ; Calculate the new window size
        newWidth := activeWinPos.width + widthDelta
        newHeight := activeWinPos.height + heightDelta

        ; Make sure the window is not being resized to 0
        if (newWidth <= 0 || newHeight <= 0)
            return

        ; Try to keep the window centered at its original position
        winX := activeWinPos.x - (widthDelta // 2)
        winY := activeWinPos.y - (heightDelta // 2)

        ; If the window touches the screen edges, adjust the position
        ; to ensure it stays within the screen boundaries of the monitor
        touchEdgeCountX := 0
        touchEdgeCountY := 0

        if (winX + newWidth >= winMonitor.workAreaWidth) {
            winX := winMonitor.workAreaWidth - newWidth
            touchEdgeCountX += 1
        }

        if (winX <= winMonitor.workAreaX) {
            winX := winMonitor.workAreaX
            touchEdgeCountX += 1
        }

        if (winY + newHeight >= winMonitor.workAreaHeight) {
            winY := winMonitor.workAreaHeight - newHeight
            touchEdgeCountY += 1
        }

        if (winY <= winMonitor.workAreaY) {
            winY := winMonitor.workAreaY
            touchEdgeCountY += 1
        }

        ; If the window grows too big, we cannot adjust anymore...
        ; Centering and growing would expand the window beyond the screen boundaries.
        if (touchEdgeCountX == 2) {
            winX := activeWinPos.x
            newWidth := activeWinPos.width
        }

        if (touchEdgeCountY == 2) {
            winY := activeWinPos.y
            newHeight := activeWinPos.height
        }

        ; Move the window to the new position
        WinMove(winX, winY, newWidth, newHeight, activeWindow)
    }

    /**
     * Function to set the taskbar to be topmost.
     * Komorebi seems to put it behind other windows by default...
     */
    static SetTaskbarTopMost() {
        taskbarHwnd := SGlob.GetTaskbarHandle()

        if (!taskbarHwnd)
            return

        DllCall("SetWindowPos",
            "Ptr", taskbarHwnd,
            "Ptr", WinuserConstants.HWND_TOPMOST,
            "Int", 0,
            "Int", 0,
            "Int", 0,
            "Int", 0,
            "UInt", WinuserConstants.SWP_NOMOVE | WinuserConstants.SWP_NOSIZE | WinuserConstants.SWP_SHOWWINDOW
        )
    }

    /**
     * Function to show the taskbar
     */
    static ShowTaskbar() {
        taskbarHwnd := SGlob.GetTaskbarHandle()

        if (!taskbarHwnd)
            return

        DllCall("ShowWindow",
            "Ptr", taskbarHwnd,
            "Int", WinuserConstants.SW_SHOW
        )
    }

    /**
     * Touch komorebi-bar's configuration to force a hot-reload...
     * Otherwise the bar is too big... (yeah really!)
     * Optionally allows to specify a PID to wait for.
     * @param {Integer} pidToWaitFor The process ID to wait for before touching the configuration
     */
    static TouchKomorebiBarConfig(pidToWaitFor := -1) {
        ; It would be nicer to grab the PID and use WinExist or WinWait
        ; with ahk_oud, however this approach does not work with
        ; Scoop's shim executables.
        ; Instead of overcomplicating things, we'll just wait 500ms.
        if (pidToWaitFor == -1)
            ProcessWait("komorebi-bar.exe", 10)
        else
            ProcessWait(pidToWaitFor, 10)

        if (ProcessExist("komorebi-bar.exe")) {
            Sleep 500
            FileSetTime(
                A_Now,
                Format("{}\komorebi.bar.monitor*.json", A_ScriptDir)
            )
        }
    }
}

/**
 * Class to manage the hotkey list window
 */
Class HotkeyListHelper {
    /**
     * Creates a new instance of the HotkeyListHelper class.
     * @param {String} fgColor The foreground color for the GUI
     * @param {String} bgColor The background color for the GUI
     * @param {String} editFgColor The foreground color for the edit box
     * @param {String} editBgColor The background color for the edit box
     */
    __New() {
        ; Visibility state switch
        this.IsGuiVisible := false

        ; Store hotkeys for filtering
        this.hotkeys := []
        this.listViewRelations := Map()

        ; Clean up unwanted characters from the colors
        fgColor := SGlob.ReadIniValue("HotkeyLister", "ForegroundColor", "00FF00")
        bgColor := SGlob.ReadIniValue("HotkeyLister", "BackgroundColor", "000000")
        editFgColor := SGlob.ReadIniValue("HotkeyLister", "EditForegroundColor", "00FF00")
        editBgColor := SGlob.ReadIniValue("HotkeyLister", "EditBackgroundColor", "000000")
        
        fgColor := StrReplace(fgColor, "#", "")
        bgColor := StrReplace(bgColor, "#", "")
        editFgColor := StrReplace(editFgColor, "#", "")
        editBgColor := StrReplace(editBgColor, "#", "")

        ; Column width for hotkey column
        this.columnWidthHotkey := 250

        ; Main window
        this.hotkeyGui := Gui()
        this.hotkeyGui.Title := "Komorebi AutoHotkey Helper - Hotkey List"
        this.hotkeyGui.BackColor := editFgColor
        this.hotkeyGui.Opt("+AlwaysOnTop +Border -MaximizeBox -MinimizeBox +Resize +Theme -ToolWindow")
        this.hotkeyGui.SetFont("s10")
        
        ; Search box
        this.searchBox := this.hotkeyGui.Add("Edit", "w500 h20", "")
        this.searchBox.Opt("-E0x200 +Background" . editBgColor)
        this.searchBox.SetFont("s10", "Courier New")
        this.searchBox.SetFont("c" . editFgColor)

        ; ListView for hotkeys
        this.listView := this.hotkeyGui.Add("ListView", "-Border w500 r15 y+5", ["Hotkey", "Description"])
        this.listView.Opt("-E0x200 +LV0x10000 -Hdr +Report -Multi +Background" . bgColor)
        this.listView.SetFont("s10", "Courier New")
        this.listView.SetFont("c" . fgColor, "Courier New")

        ; Wire up events
        this.hotkeyGui.OnEvent("Close", this.hotkeyGui_OnClose.Bind(this))
        this.hotkeyGui.OnEvent("Escape", this.hotkeyGui_OnClose.Bind(this))
        this.hotkeyGui.OnEvent("Size", this.hotkeyGui_OnSize.Bind(this))
        
        this.searchBox.OnEvent("Change", this.searchBox_OnChange.Bind(this))
        
        this.listView.OnEvent("DoubleClick", this.listView_OnDoubleClick.Bind(this))
        
        ; Wire up Windows message handler
        OnMessage(0x86, this.OnWmActivate.Bind(this)) ; WM_ACTIVATE
        OnMessage(0x100, this.OnWmKeyDown.Bind(this))  ; WM_KEYDOWN = 0x100
        
        ; Prepare data
        this.LoadHotkeyDefinitions()
        this.SetListViewColumnWidth()
    }

    /**
     * Converts a hotkey string in AutoHotkey format to a human-readable string.
     * @param {String} hotkeyStr A string in AutoHotkey's hotkey format to format into a human-readable string
     * @returns {String} The formatted hotkey string
     */
    FormatHotkeyName(hotkeyStr) {
        parts := []

        ; Process modifiers in order
        ; Remove them from the string to ensure only the key remains
        if (InStr(hotkeyStr, "#")) {
            hotkeyStr := StrReplace(hotkeyStr, "#", "")
            parts.Push("Win")
        }
        if (InStr(hotkeyStr, "LWin")) {
            hotkeyStr := StrReplace(hotkeyStr, "LWin", "")
            parts.Push("L.Win")
        }
        if (InStr(hotkeyStr, "RWin")) {
            hotkeyStr := StrReplace(hotkeyStr, "RWin", "")
            parts.Push("R.Win")
        }
        if (InStr(hotkeyStr, "!")) {
            hotkeyStr := StrReplace(hotkeyStr, "!", "")
            parts.Push("Alt")
        }
        if (InStr(hotkeyStr, "^")) {
            hotkeyStr := StrReplace(hotkeyStr, "^", "")
            parts.Push("Ctrl")
        }
        if (InStr(hotkeyStr, "+")) {
            hotkeyStr := StrReplace(hotkeyStr, "+", "")
            parts.Push("Shift")
        }

        ; Extract the key (last non-modifier character)
        if (RegExMatch(hotkeyStr, "[\S]+$", &keyName)) {
            keyPart := keyName[0]
            ; Capitalize single letters
            if (StrLen(keyPart) == 1)
                keyPart := Format("{:T}", keyPart)
            parts.Push(keyPart)
        }

        ; Join all parts with " + "
        return this.JoinArrayElements(parts, " + ")
    }

    /**
     * Hides the hotkey list window.
     */
    HideWindow() {
        this.hotkeyGui.Hide()
        this.IsGuiVisible := false
    }

    /**
     * Event handler for the hotkeyGui's Close event
     * @param {Object|String} guiObj GUI object that triggered the event
     */
    hotkeyGui_OnClose(guiObj) {
        this.HideWindow()
    }

    /**
     * Event handler for the hotkeyGui's Size event
     * @param {Object|String} guiObj GUI object that triggered the event
     * @param {Integer} minMax Indicates whether the window is minimized (-1), maximized (1), or neither (0)
     * @param {Integer} minWidth The new width of the window
     * @param {Integer} minHeight The new height of the window
     */
    hotkeyGui_OnSize(guiObj, minMax, minWidth, minHeight) {
        ; Ignore if minimized...
        if minMax = -1
            return

        ; Move the search box to the top
        this.searchBox.Move(0, 0, minWidth)
        
        ; Now get the search box dimensions
        this.searchBox.GetPos(&searchBoxX, &searchBoxY, &searchBoxW, &searchBoxH)

        ; Move the ListView to the remaining space by using the search box height
        this.listView.Move(0, searchBoxH + 1, minWidth, minHeight - searchBoxH)

        ; Set the ListView column width
        this.SetListViewColumnWidth()
    }

    /**
     * OnMessage handler for WM_ACTIVATE.
     * This is used to automatically hide the hotkey list window when it loses focus.
     * @param wParam 
     * @param lParam 
     * @param msg 
     * @param hwnd 
     */
    OnWmActivate(wParam, lParam, msg, hwnd) {
        ; wParam = 0 means the window is being deactivated
        if (wParam = 0) {
            this.HideWindow()
        }
    }

    /**
     * OnMessage handler for WM_KEYDOWN.
     * Used to handle Enter key presses in the ListView.
     * @param wParam The virtual key code (VK_*)
     * @param lParam Additional message info
     * @param msg The message number (WM_*)
     * @param hwnd The window handle receiving the message
     */
    OnWmKeyDown(wParam, lParam, msg, hwnd) {
        switch(hwnd) {
            case this.searchBox.Hwnd:
                switch(wParam) {
                    ; VK_UP
                    case 0x26:
                        OutputDebug("VK_UP")
                        this.listView.Focus()
                        this.listView.Modify(this.listView.GetCount(), "+Select +Focus")

                    ; VK_DOWN
                    case 0x28:
                        this.listView.Focus()
                        this.listView.Modify(1, "+Select +Focus")
                }

            case this.listView.Hwnd:
                rowNum := this.listView.GetNext(0)
                itemCount := this.listView.GetCount()

                switch(wParam) {
                    ; VK_LEFT
                    case 0x25:
                        this.listView.Modify(0, "-Select")
                        this.searchBox.Focus()

                    ; VK_UP
                    case 0x26:
                        if (itemCount > 0 && rowNum == 1) {
                            this.searchBox.Focus()
                            this.listView.Modify(0, "-Select")
                        }

                    ; VK_DOWN
                    case 0x28:
                        if (itemCount > 0 && rowNum == itemCount) {
                            this.listView.Modify(0, "-Select")
                            this.searchBox.Focus()
                        }

                    ; VK_RETURN
                    case 0x0D:
                        if (rowNum > 0)
                            this.listView_OnDoubleClick(this.listView, rowNum)
                }
        }
    }

    /**
     * Joins an array of string elements with a delimiter
     * @param {String[]} arr Array of string elements to join
     * @param {String} delimiter The delimiter to use between elements
     * @returns {String} The joined string
     */
    JoinArrayElements(arr, delimiter) {
        result := ""
        for index, value in arr {
            if (index > 1)
                result .= delimiter
            result .= value
        }
        return result
    }

    /**
     * Event handler for the listView DoubleClick event
     * @param guiCtrlObj 
     * @param rowNum
     */
    listView_OnDoubleClick(guiCtrlObj, rowNum) {
        if (rowNum > 0) {
            selectedHotkey := this.listViewRelations.Get(rowNum)
            
            if (!selectedHotkey)
                return

            if (!selectedHotkey.functionName)
                return

            this.HideWindow()

            function := selectedHotkey.functionName
            %function%(selectedHotkey.rawhotkey)
        }
    }

    /**
     * Loads hotkey definitions from the current script and parses JavaDoc comments for context and keywords.
     */
    LoadHotkeyDefinitions() {
        scriptContent := FileRead(A_ScriptFullPath)
        
        ; Split content into lines for line number tracking
        scriptLines := StrSplit(scriptContent, "`n", "`r")
        
        ; Flag to start processing the script
        processingStarted := false

        ; Pattern for hotkey definitions at start of line
        hotkeyPattern := "^([#!^+]*[\S]+)::"
        
        ; Pattern for function definitions
        functionPattern := "^(\w+)\("

        ; Pattern for JavaDoc comments
        javadocPattern := "/\*\*(.*?)\*/"
        
        ; List of lines that should not be parsed/used again
        usedLines := []

        ; Find all hotkey definitions
        hotkeyMatches := []
        lineNum := 0
        
        for index, line in scriptLines {
            lineNum++

            ; Skip all lines until we get the directive to start processing.
            if (InStr(line, "@" . "startprocessing"))
                processingStarted := true

            if (!processingStarted)
                continue

            ; Allow for stopping the parsing at a certain point.
            ; Gotta be sneaky about it, otherwise we stop right on this line!
            if (InStr(line, "@" . "stopprocessing"))
                break

            ; Now try to match the function name, so we can explicitly call it.
            if (RegExMatch(line, hotkeyPattern, &match)) {
                functionName := ""

                ; It might not be directly below the hotkey, so we need to search for it.
                ; This has the risk of finding the wrong function, but it's good enough for now.
                Loop 5 {
                    functionLine := scriptLines[lineNum + A_Index]

                    if (RegExMatch(functionLine, functionPattern, &functionMatch)) {
                        functionName := functionMatch[1]
                        break
                    }
                }

                hotkeyMatches.Push({
                    hotkey: match[1],
                    functionName: functionName,
                    lineNum: lineNum
                })
            }
        }
        
        ; For each hotkey, find the closest preceding JavaDoc comment within a few lines
        for hotkeyMatch in hotkeyMatches {
            description := ""
            keywords := ""
            context := ""
            ignore := false
            
            ; Search up a few lines before the hotkey
            startLine := Max(1, hotkeyMatch.lineNum - 10)
            searchLines := ""

            ; Combine the lines we want to search
            loop (hotkeyMatch.lineNum - startLine) {
                currentLine := hotkeyMatch.lineNum - A_Index
                if (currentLine >= startLine)
                    ; Prepend the line to the searchLines, otherwise we end
                    ; up with the lines in reverse order that break the regex!
                    searchLines := scriptLines[currentLine] . "`n" . searchLines
            }
            
            ; Look for JavaDoc comment in these lines. This is not a perfect
            ; parser that supports all manners of formats, it is purpose-built
            ; for my own scripts and should be good enough for that.
            if (RegExMatch(searchLines, "s)" . javadocPattern, &commentMatch)) {
                ; Parse the comment block
                commentLines := StrSplit(commentMatch[1], "`n", "`r")
                isFirstLine := true
                
                for line in commentLines {
                    line := Trim(line)
                    ; Remove leading asterisks and spaces
                    line := RegExReplace(line, "^[\s/*]*", "")

                    ; Check for special directives that do not have parameters.
                    if (RegExMatch(line, "@(\w+)", &decMatch)) {
                        switch (decMatch[1]) {
                            ; The "@ignore" directive will skip this hotkey
                            ; when building the list, so it will not be shown
                            ; in the hotkey list window.
                            case "ignore":
                                ignore := true
                        }
                    }

                    ; Check for key-value directives
                    if (RegExMatch(line, "@(\w+)\s(.+)", &decMatch)) {
                        switch (decMatch[1]) {
                            ; The "@keyword" directive will add the specified
                            ; keyword to the entry, so it can be found by
                            ; that specific keyword in the hotkey list window.
                            case "keyword":
                                keywords := decMatch[2]

                            ; The "@context" directive will add the specified
                            ; context to the entry, so commands can be grouped
                            ; by (for instance) the application they are used in.
                            case "context":
                                context := decMatch[2]
                        }
                    }

                    ; Build the description from regular comment lines
                    if (line != "" && !InStr(line, "@")) {
                        if (isFirstLine) {
                            description := line
                            isFirstLine := false
                        } else {
                            description .= " " . line
                        }
                    }
                }
            }
            
            if (!ignore) {
                this.hotkeys.Push({
                    rawhotkey: hotkeyMatch.hotkey,
                    hotkey: this.FormatHotkeyName(Trim(hotkeyMatch.hotkey)),
                    context: context ? context : "General",
                    description: description ? description : "No description",
                    keywords: keywords ? keywords : "",
                    functionName: hotkeyMatch.functionName ? hotkeyMatch.functionName : ""
                })
            }
        }
    }

    /**
     * Event handler for the SearchBox's Change event
     * @param guiCtrl 
     * @param info 
     */
    searchBox_OnChange(guiCtrl, info) {
        this.UpdateListView(this.searchBox.Value)
    }

    /**
     * Sets the column width for the ListView control.
     */
    SetListViewColumnWidth() {
        this.listView.ModifyCol(1, this.columnWidthHotkey)
        this.listView.ModifyCol(2, "AutoHdr")
    }

    /**
     * Shows the Hotkey List window centered on the active monitor.
     */
    ShowWindow() {
        ; Calculate window dimensions
        w := 800
        h := 250
        mon := SGlob.GetCurrentMonitor()

        ; Calculate centered position
        x := mon.workAreaX + ((mon.workAreaWidth - mon.workAreaX) - w) // 2
        y := mon.workAreaY + ((mon.workAreaHeight - mon.workAreaY) - h) // 2

        ; Clear search and show window
        this.searchBox.Value := ""
        this.searchBox_OnChange(this.searchBox, "")
        this.hotkeyGui.Show(Format("x{} y{} w{} h{}", x, y, w, h))
        this.searchBox.Focus()
        this.IsGuiVisible := true
    }

    /**
     * Toggles the visibility of the Hotkey List window
     * and ensures the search box is cleared when shown.
     */
    ToggleWindow() {
        if (this.IsGuiVisible)
            this.HideWindow()
        else
            this.ShowWindow()
    }

    /**
     * Updates the ListView control with the hotkey list filtered by the search
     * term or all hotkeys if no search term is provided.
     * @param {String} searchTerm String that the hotkey list should be filtered by
     */
    UpdateListView(searchTerm := "") {
        DllCall("LockWindowUpdate", "UInt", this.hotkeyGui.Hwnd)
        this.listView.Delete()
        this.listViewRelations := Map()
        searchTerm := StrLower(searchTerm)
        for (hotkeyInfo in this.hotkeys) {
            if (searchTerm = ""
                || InStr(StrLower(hotkeyInfo.hotkey), searchTerm)
                || InStr(StrLower(hotkeyInfo.description), searchTerm)
                || InStr(StrLower(hotkeyInfo.context), searchTerm)
                || InStr(StrLower(hotkeyInfo.keywords), searchTerm)
            ) {
                rowNum := this.listView.Add(, hotkeyInfo.hotkey, hotkeyInfo.description)
                this.listViewRelations.Set(rowNum, hotkeyInfo)
            }
        }
        
        this.SetListViewColumnWidth()
        DllCall("LockWindowUpdate", "UInt", 0)
    }

    /**
     * Event handler for the listView KeyPress event
     * @param {Object} guiCtrlObj The GUI control that triggered the event 
     * @param {String} info The key that was pressed
     */
    listView_OnKeyPress(guiCtrlObj, info) {
        if (info == "Enter") {
            ; Get the selected row number
            rowNum := this.listView.GetNext(0)
            if (rowNum > 0) {
                ; Call the double-click handler with the selected row
                this.listView_OnDoubleClick(guiCtrlObj, rowNum)
            }
        }
    }
}

/**
 * Windows Constants
 */
Class WinuserConstants {
    static ABE_LEFT := 0
    static ABE_TOP := 1
    static ABE_RIGHT := 2
    static ABE_BOTTOM := 3

    static ABM_NEW := 0x00000000
    static ABM_REMOVE := 0x00000001
    static ABM_QUERYPOS := 0x00000002
    static ABM_SETPOS := 0x00000003
    static ABM_GETSTATE := 0x00000004
    static ABM_GETTASKBARPOS := 0x00000005
    static ABM_ACTIVATE := 0x00000006
    static ABM_GETAUTOHIDEBAR := 0x00000007
    static ABM_SETAUTOHIDEBAR := 0x00000008
    static ABM_WINDOWPOSCHANGED := 0x00000009
    static ABM_SETSTATE := 0x0000000A
    static ABM_GETAUTOHIDEBAREX := 0x0000000B
    static ABM_SETAUTOHIDEBAREX := 0x0000000C
    static ABM_SETPOS_EX := 0x0000000D

    static ABN_SETFOCUS := 0x6

    static HWND_BOTTOM := 1
    static HWND_NOTOPMOST := -2
    static HWND_TOP := 0
    static HWND_TOPMOST := -1

    ; See https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics
    ; or the AutoHotkey help for SysGet for more details
    static SM_CMONITORS := 80
    static SM_CMOUSEBUTTONS := 43
    static SM_CXFULLSCREEN := 16
    static SM_CYFULLSCREEN := 17
    static SM_CXMAXIMIZED := 61
    static SM_CYMAXIMIZED := 62
    static SM_CXMAXTRACK := 59
    static SM_CYMAXTRACK := 60
    static SM_CXMIN := 28
    static SM_CYMIN := 29
    static SM_CXMINIMIZED := 57
    static SM_CYMINIMIZED := 58
    static SM_CXMINTRACK := 34
    static SM_CYMINTRACK := 35
    static SM_CXSCREEN := 0
    static SM_CYSCREEN := 1
    static SM_CXVIRTUALSCREEN := 78
    static SM_CYVIRTUALSCREEN := 79
    static SM_MOUSEPRESENT := 19
    static SM_MOUSEWHEELPRESENT := 75
    static SM_NETWORK := 63
    static SM_REMOTECONTROL := 8193
    static SM_REMOTESESSION := 4096
    static SM_SHOWSOUNDS := 70
    static SM_SHUTTINGDOWN := 8192
    static SM_SWAPBUTTON := 23
    static SM_XVIRTUALSCREEN := 76
    static SM_YVIRTUALSCREEN := 77
    static SM_ARRANGE := 56
    static SM_CLEANBOOT := 67
    static SM_CXBORDER := 5
    static SM_CYBORDER := 6
    static SM_CXCURSOR := 13
    static SM_CYCURSOR := 14
    static SM_CXDOUBLECLK := 36
    static SM_CYDOUBLECLK := 37
    static SM_CXDRAG := 68
    static SM_CYDRAG := 69
    static SM_CXEDGE := 45
    static SM_CYEDGE := 46
    static SM_CXFIXEDFRAME := 7
    static SM_CYFIXEDFRAME := 8
    static SM_CXFOCUSBORDER := 83
    static SM_CYFOCUSBORDER := 84
    static SM_CXHSCROLL := 21
    static SM_CYHSCROLL := 3
    static SM_CXHTHUMB := 10
    static SM_CXICON := 11
    static SM_CYICON := 12
    static SM_CXICONSPACING := 38
    static SM_CYICONSPACING := 39
    static SM_CXMENUCHECK := 71
    static SM_CYMENUCHECK := 72
    static SM_CXMENUSIZE := 54
    static SM_CYMENUSIZE := 55
    static SM_CXMINSPACING := 47
    static SM_CYMINSPACING := 48
    static SM_CXSIZE := 30
    static SM_CYSIZE := 31
    static SM_CXSIZEFRAME := 32
    static SM_CYSIZEFRAME := 33
    static SM_CXSMICON := 49
    static SM_CYSMICON := 50
    static SM_CXSMSIZE := 52
    static SM_CYSMSIZE := 53
    static SM_CXVSCROLL := 2
    static SM_CYVSCROLL := 20
    static SM_CYCAPTION := 4
    static SM_CYKANJIWINDOW := 18
    static SM_CYMENU  := 15
    static SM_CYSMCAPTION := 51
    static SM_CYVTHUMB := 9
    static SM_DBCSENABLED := 42
    static SM_DEBUG := 22
    static SM_IMMENABLED := 82
    static SM_MENUDROPALIGNMENT := 40
    static SM_MIDEASTENABLED := 74
    static SM_PENWINDOWS := 41
    static SM_SECURE := 44
    static SM_SAMEDISPLAYFORMAT := 81

    static SPI_GETACCESSTIMEOUT := 0x003C
    static SPI_GETACTIVEWINDOWTRACKING := 0x1000
    static SPI_GETACTIVEWNDTRKTIMEOUT := 0x2002
    static SPI_GETACTIVEWNDTRKZORDER := 0x100C
    static SPI_GETANIMATION := 0x0048
    static SPI_GETBEEP := 0x0001
    static SPI_GETBLOCKSENDINPUTRESETS := 0x1026
    static SPI_GETCARETWIDTH := 0x2006
    static SPI_GETCOMBOBOXANIMATION := 0x1004
    static SPI_GETCURSORSHADOW := 0x101A
    static SPI_GETDEFAULTINPUTLANG := 0x0059
    static SPI_GETDRAGFULLWINDOWS := 0x0026
    static SPI_GETFASTTASKSWITCH := 0x0023
    static SPI_GETFILTERKEYS := 0x0032
    static SPI_GETFONTSMOOTHING := 0x004A
    static SPI_GETGRIDGRANULARITY := 0x0012
    static SPI_GETHIGHCONTRAST := 0x0042
    static SPI_GETHOTTRACKING := 0x100E
    static SPI_GETICONMETRICS := 0x002D
    static SPI_GETICONTITLELOGFONT := 0x001F
    static SPI_GETICONTITLEWRAP := 0x0019
    static SPI_GETKEYBOARDDELAY := 0x0016
    static SPI_GETKEYBOARDPREF := 0x0044
    static SPI_GETKEYBOARDSPEED := 0x000A
    static SPI_GETLISTBOXSMOOTHSCROLLING := 0x1006
    static SPI_GETLOWPOWERACTIVE := 0x0053
    static SPI_GETLOWPOWERTIMEOUT := 0x004F
    static SPI_GETMENUANIMATION := 0x1002
    static SPI_GETMENUDROPALIGNMENT := 0x001B
    static SPI_GETMENUFADE := 0x1012
    static SPI_GETMENUSHOWDELAY := 0x006A
    static SPI_GETMOUSE := 0x0003
    static SPI_GETMOUSEHOVERHEIGHT := 0x0064
    static SPI_GETMOUSEHOVERTIME := 0x0066
    static SPI_GETMOUSEHOVERWIDTH := 0x0062
    static SPI_GETMOUSEKEYS := 0x0036
    static SPI_GETMOUSETRAILS := 0x005E
    static SPI_GETNONCLIENTMETRICS := 0x0029
    static SPI_GETPOWEROFFACTIVE := 0x0054
    static SPI_GETPOWEROFFTIMEOUT := 0x0050
    static SPI_GETSCREENREADER := 0x0046
    static SPI_GETSCREENSAVEACTIVE := 0x0010
    static SPI_GETSCREENSAVETIMEOUT := 0x000E
    static SPI_GETSERIALKEYS := 0x003E
    static SPI_GETSHOWSOUNDS := 0x0034
    static SPI_GETSNAPTODEFBUTTON := 0x005F
    static SPI_GETSOUNDSENTRY := 0x0040
    static SPI_GETSTICKYKEYS := 0x003A
    static SPI_GETTOGGLEKEYS := 0x0034
    static SPI_GETWHEELSCROLLLINES := 0x0068
    static SPI_GETWINDOWSEXTENSION := 0x005C
    static SPI_ICONHORIZONTALSPACING := 0x000D
    static SPI_ICONVERTICALSPACING := 0x0018
    static SPI_SETACCESSTIMEOUT := 0x003D
    static SPI_SETACTIVEWINDOWTRACKING := 0x1001
    static SPI_SETACTIVEWNDTRKTIMEOUT := 0x2003
    static SPI_SETACTIVEWNDTRKZORDER := 0x100D
    static SPI_SETANIMATION := 0x0049
    static SPI_SETBEEP := 0x0002
    static SPI_SETBLOCKSENDINPUTRESETS := 0x1027
    static SPI_SETCARETWIDTH := 0x2007
    static SPI_SETCOMBOBOXANIMATION := 0x1005
    static SPI_SETCURSORSHADOW := 0x101B
    static SPI_SETDEFAULTINPUTLANG := 0x005A
    static SPI_SETDRAGFULLWINDOWS := 0x0025
    static SPI_SETFASTTASKSWITCH := 0x0024
    static SPI_SETFILTERKEYS := 0x0033
    static SPI_SETFONTSMOOTHING := 0x004B
    static SPI_SETGRIDGRANULARITY := 0x0013
    static SPI_SETHIGHCONTRAST := 0x0043
    static SPI_SETHOTTRACKING := 0x100F
    static SPI_SETICONMETRICS := 0x002E
    static SPI_SETICONTITLELOGFONT := 0x0022
    static SPI_SETICONTITLEWRAP := 0x001A
    static SPI_SETKEYBOARDDELAY := 0x0017
    static SPI_SETKEYBOARDPREF := 0x0045
    static SPI_SETKEYBOARDSPEED := 0x000B
    static SPI_SETLISTBOXSMOOTHSCROLLING := 0x1007
    static SPI_SETLOWPOWERACTIVE := 0x0055
    static SPI_SETLOWPOWERTIMEOUT := 0x0051
    static SPI_SETMENUANIMATION := 0x1003
    static SPI_SETMENUDROPALIGNMENT := 0x001C
    static SPI_SETMENUFADE := 0x1013
    static SPI_SETMENUSHOWDELAY := 0x006B
    static SPI_SETMOUSE := 0x0004
    static SPI_SETMOUSEHOVERHEIGHT := 0x0065
    static SPI_SETMOUSEHOVERTIME := 0x0067
    static SPI_SETMOUSEHOVERWIDTH := 0x0063
    static SPI_SETMOUSEKEYS := 0x0037
    static SPI_SETMOUSETRAILS := 0x005D
    static SPI_SETNONCLIENTMETRICS := 0x002A
    static SPI_SETPOWEROFFACTIVE := 0x0056
    static SPI_SETPOWEROFFTIMEOUT := 0x0052
    static SPI_SETSCREENREADER := 0x0047
    static SPI_SETSCREENSAVEACTIVE := 0x0011
    static SPI_SETSCREENSAVETIMEOUT := 0x000F
    static SPI_SETSERIALKEYS := 0x003F
    static SPI_SETSHOWSOUNDS := 0x0035
    static SPI_SETSNAPTODEFBUTTON := 0x0060
    static SPI_SETSOUNDSENTRY := 0x0041
    static SPI_SETSTICKYKEYS := 0x003B
    static SPI_SETTOGGLEKEYS := 0x0035
    static SPI_SETWHEELSCROLLLINES := 0x0069
    static SPI_SETWINDOWSEXTENSION := 0x005D
    static SPI_SETWORKAREA := 0x002F

    static SW_HIDE := 0
    static SW_MAXIMIZE := 3
    static SW_MINIMIZE := 6
    static SW_RESTORE := 9
    static SW_SHOW := 5
    static SW_SHOWDEFAULT := 10
    static SW_SHOWMAXIMIZED := 3
    static SW_SHOWMINIMIZED := 2
    static SW_SHOWMINNOACTIVE := 7
    static SW_SHOWNA := 8
    static SW_SHOWNOACTIVATE := 4
    static SW_SHOWNORMAL := 1

    static SWP_ASYNCWINDOWPOS := 0x4000
    static SWP_DEFERERASE := 0x2000
    static SWP_DRAWFRAME := 0x0020
    static SWP_FRAMECHANGED := 0x0020
    static SWP_HIDEWINDOW := 0x0080
    static SWP_NOACTIVATE := 0x0010
    static SWP_NOCOPYBITS := 0x0100
    static SWP_NOMOVE := 0x0002
    static SWP_NOOWNERZORDER := 0x0200
    static SWP_NOREDRAW := 0x0008
    static SWP_NOREPOSITION := 0x0200
    static SWP_NOSENDCHANGING := 0x0400
    static SWP_NOSIZE := 0x0001
    static SWP_NOZORDER := 0x0004
    static SWP_SHOWWINDOW := 0x0040
}

Class WinbaseConstants {
    static INFINITE := 0xFFFFFFFF

    static WM_DISPLAYCHANGE := 0x007E
    static WM_DEVICECHANGE := 0x0219
    static WM_GETMINMAXINFO := 0x0024
    static WM_INPUTLANGCHANGE := 0x0051
    static WM_INPUTLANGCHANGEREQUEST := 0x0050
    static WM_PALETTECHANGED := 0x0311
    static WM_PALETTEISCHANGING := 0x0310
    static WM_POWERBROADCAST := 0x0218
    static WM_QUERYENDSESSION := 0x0011
    static WM_QUERYOPEN := 0x0013
    static WM_SETTINGCHANGE := 0x001A
    static WM_SYSCOLORCHANGE := 0x0015
    static WM_TIMECHANGE := 0x001E
    static WM_TIMER := 0x0113
    static WM_USERCHANGED := 0x0054

    static WT_EXECUTEDEFAULT := 0x00000000
    static WT_EXECUTEINIOTHREAD := 0x00000001
    static WT_EXECUTEINUITHREAD := 0x00000002
    static WT_EXECUTEINWAITTHREAD := 0x00000004
    static WT_EXECUTEONLYONCE := 0x00000008
    static WT_EXECUTELONGFUNCTION := 0x00000010
    static WT_EXECUTEINTIMERTHREAD := 0x00000020
    static WT_EXECUTEINPERSISTENTIOTHREAD := 0x00000040
    static WT_EXECUTEINPERSISTENTTHREAD := 0x00000080
    static WT_TRANSFER_IMPERSONATION := 0x00000100

    static DELETE := 0x00010000
    static READ_CONTROL := 0x00020000
    static WRITE_DAC := 0x00040000
    static WRITE_OWNER := 0x00080000
    static SYNCHRONIZE := 0x00100000
}

; -----------------------------------------------------------------------------
; Internal Functions                                                          |
; -----------------------------------------------------------------------------

/**
 * Callback handler for the WM_DISPLAYCHANGE message
 * @param wParam Word Param.
 * This is used to send additional data about the message to the callback.
 * The W stands for Word, because it used to be 16-bits.
 * Both PARAMs are now 32 or 64 bits, depending on architecture.
 * @param lParam Long Param.
 * This is used to send additional data about the message to the callback.
 * The L stands for Word, because it used to be 32-bits.
 * Both PARAMs are now 32 or 64 bits, depending on architecture.
 * @param {Integer} msg The message number.
 * List of common WM_ Windows Messages.
 * @param {Hwnd} hwnd A handle to the window
 */
OnDisplayChange(wParam, lParam, msg, hwnd) {
    SGlob.RunOrKillKomorebiBarOnDisplayChange()
}

/**
 * Callback handler for the WM_SETTINGCHANGE message
 * @param wParam Word Param.
 * This is used to send additional data about the message to the callback.
 * The W stands for Word, because it used to be 16-bits.
 * Both PARAMs are now 32 or 64 bits, depending on architecture.
 * @param lParam Long Param.
 * This is used to send additional data about the message to the callback.
 * The L stands for Word, because it used to be 32-bits.
 * Both PARAMs are now 32 or 64 bits, depending on architecture.
 * @param {Integer} msg The message number.
 * List of common WM_ Windows Messages.
 * @param {Hwnd} hwnd A handle to the window
 */
OnSettingChange(wParam, lParam, msg, hwnd) {
    SGlob.RunOrKillKomorebiBarOnDisplayChange()

    ; Optionally hide the taskbar
    if (SGlob.ReadIniValue("Settings", "HideTaskbar", "false") == "true") {
        SGlob.HideTaskbar()
    } else {
        SGlob.ShowTaskbar()

        Sleep(100)

        ; Make the taskbar topmost if configured
        if (SGlob.ReadIniValue("Settings", "TaskbarTopmost", "false") == "true")
            SGlob.SetTaskbarTopMost()
    }
}

/**
 * The callback function to execute when Komorebi exits.
 * Will quit the script.
 * @param lpParameter The thread data passed to the function
 * @param {Boolean} bTimerOrWaitFired If this parameter is TRUE, the wait timed out. If this parameter is FALSE, the wait event has been signaled. (This parameter is always TRUE for timer callbacks.)
 */
OnProcessExit(lpParameter, bTimerOrWaitFired) {
    ExitApp(0)
}

/**
 * Cleanup function that runs when the script exits
 * @param {String} exitReason 
 * @param {Integer} exitCode
 * @returns {Integer} 0
 */
OnScriptExit(exitReason, exitCode) {
    ; Only process the following exitReasons
    validReasons := "Logoff Close Exit Reload Single Menu"

    ; Exit if the exitReason is not in the validReasons list
    if (!InStr(validReasons, exitReason, 0, 1, 1))
        return 0

    ; Unregister callbacks
    if (ProcessExitCallback)
        CallbackFree(ProcessExitCallback)

    ; Return with 0 so other callbacks can run
    return 0
}

/**
 * Function to register a wait for Komorebi process to exit
 * @param {Integer} pid The process ID to wait for exit
 */
RegisterWaitForProcessExit(pid) {
    global ProcessExitCallback

    ; Open the process handle with SYNCHRONIZE access
    hProcess := DllCall("OpenProcess",
        "UInt", WinbaseConstants.SYNCHRONIZE, ; dwDesiredAccess
        "Int", 0,                             ; bInheritHandle
        "UInt", pid,                          ; dwProcessId
        "Ptr"
    )

    if (!hProcess) {
        MsgBox("Failed to open process handle. Error: " DllCall("GetLastError"), "Error opening process handle", "OK IconX")
        return
    }

    ; Create a variable to hold a pseudo wait handle
    waitHandle := 0

    ; Register the wait
    success := DllCall("RegisterWaitForSingleObject",
        "Ptr*", &waitHandle,                         ; Output wait handle (mutable variable)
        "Ptr", hProcess,                             ; The process handle
        "Ptr", ProcessExitCallback,                  ; The callback function
        "Ptr", pid,                                  ; The parameter passed to the callback (PID)
        "UInt", WinbaseConstants.INFINITE,
        "UInt", WinbaseConstants.WT_EXECUTEONLYONCE
    )

    if (!success) {
        MsgBox("Failed to register wait. Error: " DllCall("GetLastError"), "Error registering callback", "OK IconX")
        DllCall("CloseHandle",
            "Ptr", hProcess
        )
        return
    }
}

/**
 * Function to wait for Komorebi to exit and then close the script.
 */
WaitForKomorebiExit() {
    pid := ProcessExist("komorebi.exe")

    if (pid)
        RegisterWaitForProcessExit(pid)
}

; -----------------------------------------------------------------------------
; Perform additional tasks (if necessary)                                     |
; -----------------------------------------------------------------------------

SGlob.AdjustTray()

/**
 * Initialize the Hotkey List helper window
 */
hkHelper := HotkeyListHelper()

/**
 * Since Komorebi does not close the AutoHotkey script despite using the --ahk
 * flag, the most resource-efficient way to close the script is to wait for
 * Komorebi to exit and then receive a callback to close the script.
 * @type {Integer}
 */
ProcessExitCallback := CallbackCreate(OnProcessExit)

; Check if Komorebi is running and register a callback to be notified
; when it exits.
WaitForKomorebiExit()

; ---

; Run additional programs configured in the ini file
SGlob.RunAdditionalApplications()

; ---

; Register all Komorebi Bars as app bars.
; Normally, this happens on WM_DISPLAYCHANGE, however for the initial
; startup, we need to do this manually.
SGlob.RegisterKomorebiBarsAsAppBars()

; ---

; Send a broadcast message to all windows to notify them of settings changes.
; This ensures that certain internals are being called as intended.
SGlob.BroadcastWmSettingChange()

; -----------------------------------------------------------------------------
; Workarounds                                                                 |
; -----------------------------------------------------------------------------

SGlob.TouchKomorebiBarConfig()

; -----------------------------------------------------------------------------
; Basic Options                                                               |
; -----------------------------------------------------------------------------

; Enable hot reloading of changes to this file
SGlob.Komorebic("watch-configuration enable")

; The rest of the Komorebi settings should be set in the configuration file.
; Do NOT set application overrides here, use the configuration file instead!

; -----------------------------------------------------------------------------
; Key Bindings                                                                |
; -----------------------------------------------------------------------------

; The key bindings are very loosely based on Amethyst's key bindings.
; This is what I am used to, so I am sticking with it.

; If you want your key bindings to appear in the hotkey list window, please
; make sure to add a JavaDoc comment above the hotkey definition with at least
; a description. The comment must be directly above the hotkey definition.
; You can use context, keyword, and ignore tags to provide additional filters.

; Leave this comment in, it indicates this is where the parsing should start:
; @startprocessing

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; General Helpers                                                             |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Toggle the Hotkey List Window
 * (Win + Alt + H)
 * @context General
 * @keyword hotkey-list display
 * @ignore
 */
#!H::
toggleHotkeyListWindow(hk) {
    hkHelper.ToggleWindow()
}

/**
 * Reload the AutoHotkey Script
 * (Win + Alt + A)
 * @context General
 * @keyword ahk autohotkey script reload
 */
#!A::
reloadAhkScript(hk) {
    Reload()
}

/**
 * Restores the last minimized window
 * @context General
 * @keyword restore minimized window
 */
#Numpad0::
restoreWindow(hk) {
    SGlob.RestoreWindow()
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Application Launchers                                                       |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Launch Terminal
 * (Win + Enter)
 * @context General
 * @keyword terminal application launch
 */
#Enter::
launchTerminal(hk) {
    SGlob.RunDefaultApplication("Terminal")
    return
}

/**
 * Launch Editor
 * (Win + Shift + Enter)
 * @context General
 * @keyword editor application launch
 */
#+Enter::
launchEditor(hk) {
    SGlob.RunDefaultApplication("Editor")
    return
}

/**
 * Launch Search
 * (Win + Ctrl + Enter)
 * @context General
 * @keyword search application launch
 */
#^Enter::
launchSearch(hk) {
    SGlob.RunDefaultApplication("Search")
    return
}

/**
 * Launch Browser
 * (Win + Backspace)
 * @context General
 * @keyword browser application launch
 */
#Backspace::
launchBrowser(hk) {
    SGlob.RunDefaultApplication("Browser")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Eager Focus                                                                 |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Eager Focus Wavebox
 * (Win + Q)
 * @context Komorebi
 * @keyword eager-focus wavebox browser
 */
#Q::
eagerFocusWavebox(hk) {
    SGlob.Komorebic("eager-focus wavebox.exe")
    return
}

/**
 * Eager Focus Vivaldi
 * (Win + W)
 * @context Komorebi
 * @keyword eager-focus vivaldi browser
 */
#W::
eagerFocusVivaldi(hk) {
    SGlob.Komorebic("eager-focus vivaldi.exe")
    return
}

/**
 * Eager Focus mpv
 * (Win + A)
 * @context Komorebi
 * @keyword eager-focus mpv
 */
#A::
eagerFocusMpv(hk) {
    SGlob.Komorebic("eager-focus mpv.exe")
    return
}

/**
 * Eager Focus VS Code
 * (Win + S)
 * @context Komorebi
 * @keyword eager-focus vscode
 */
#S::
eagerFocusVsCode(hk) {
    SGlob.Komorebic("eager-focus Code.exe")
    return
}

/**
 * Eager Focus Multiplicity RDP
 * (Win + Y)
 * @context Komorebi
 * @keyword eager-focus multiplicity rdp
 */
#Y::
eagerFocusMultiplicityRdp(hk) {
    SGlob.Komorebic("eager-focus MPRDP64.exe")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Window Management                                                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Toggle Maximize for Current Window
 * (Win + Insert)
 * @context Komorebi
 * @keyword toggle-maximize window
 */
#Insert::
toggleMaximize(hk){
    SGlob.Komorebic("toggle-maximize")
    return
}

/**
 * Minimize Current Window
 * (Win + Delete)
 * @context Komorebi
 * @keyword minimize window
 */
#Delete::
minimizeWindow(hk){
    SGlob.MinimizeWindow()
    return
}

/**
 * Close Window
 * (Win + Escape)
 * @context Komorebi
 * @keyword close window
 */
#Escape::
closeWindow(hk){
    SGlob.Komorebic("close")
    return
}

/**
 * Center Regular Active Window
 * (Win + Shift + C)
 * @context Komodo General
 * @keyword center-active-window
 */
#+C::
centerRegularActiveWindow(hk) {
    if (SGlob.IsKomoDoAvailable())
        SGlob.KomoDo("center-active-window")
    else
        SGlob.CenterActiveWindow()
    return
}

/**
 * Retile
 * (Alt + Shift + R)
 * @context Komorebi
 * @keyword retile
 */
!+R::
retile(hk) {
    SGlob.Komorebic("retile")
    return
}

/**
 * Enforce Workspace Rules
 * (Alt + Shift + E)
 * @context Komorebi
 * @keyword enforce-workspace-rules
 */
!+E::
enforceWorkspaceRules(hk) {
    SGlob.Komorebic("enforce-workspace-rules")
    return
}

/**
 * Toggle Pause
 * (Alt + Shift + P)
 * @context Komorebi
 * @keyword toggle-pause
 */
!+P::
togglePause(hk) {
    SGlob.Komorebic("toggle-pause")
    return
}

/**
 * Toggle Mouse follows Focus
 * (Alt + Shift + F)
 * @context Komorebi
 * @keyword toggle-mouse-follows-focus
 */
!+F::
toggleMouseFollowsFocus(hk) {
    SGlob.Komorebic("toggle-mouse-follows-focus")
    return
}

/**
 * Toggle Float for Workspace
 * (Win + Shift + Space)
 * @context Komorebi
 * @keyword toggle-float-override
 */
#+Space::
toggleFloatOverride(hk) {
    SGlob.Komorebic("toggle-float-override")
    return
}

/**
 * Toggle Float Mode
 * (Alt + Shift + Space)
 * @context Komorebi
 * @keyword toggle-float
 */
!+Space::
toggleFloat(hk) {
    SGlob.Komorebic("toggle-float")
    return
}

/**
 * Toggle Monocle Mode
 * (Alt + Shift + M)
 * @context Komorebi
 * @keyword toggle-monocle
 */
!+M::
toggleMonocle(hk) {
    SGlob.Komorebic("toggle-monocle")
    return
}

/**
 * Re-initialize the Komorebi Bar manually
 * (Win + Shift + S)
 * @context General
 * @keyword komorebi-bar display
 */
#+S::
reinitializeKomorebiBar(hk) {
    SGlob.RunOrKillKomorebiBarOnDisplayChange()
    return
}

/**
 * Stop Komorebi
 * (Win + Alt + X)
 * @context Komorebi
 * @keyword stop bar ahk
 */
#!X::
stopKomorebi(hk) {
    SGlob.Komorebic("stop --bar --ahk")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Change the focused window, Alt + ←↑↓→                                       |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Change the Focused Window (Left)
 * @context Komorebi
 * @keyword focus left
 */
!Left::
focusLeft(hk) {
    SGlob.Komorebic("focus left")
    return
}

/**
 * Change the Focused Window (Down)
 * @context Komorebi
 * @keyword focus down
 */
!Down::
focusDown(hk) {
    SGlob.Komorebic("focus down")
    return
}

/**
 * Change the Focused Window (Up)
 * @context Komorebi
 * @keyword focus up
 */
!Up::
focusUp(hk) {
    SGlob.Komorebic("focus up")
    return
}

/**
 * Change the Focused Window (Right)
 * @context Komorebi
 * @keyword focus right
 */
!Right::
focusRight(hk) {
    SGlob.Komorebic("focus right")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Move the focused window in a given direction, Alt + Shift + ←↑↓→            |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Move the Focused Window in a given Direction (Left)
 * @context Komorebi
 * @keyword move left
 */
!+Left::
moveLeft(hk) {
    SGlob.Komorebic("move left")
    return
}

/**
 * Move the Focused Window in a given Direction (Down)
 * @context Komorebi
 * @keyword move down
 */
!+Down::
moveDown(hk) {
    SGlob.Komorebic("move down")
    return
}

/**
 * Move the Focused Window in a given Direction (Up)
 * @context Komorebi
 * @keyword move up
 */
!+Up::
moveUp(hk) {
    SGlob.Komorebic("move up")
    return
}

/**
 * Move the Focused Window in a given Direction (Right)
 * @context Komorebi
 * @keyword move right
 */
!+Right::
moveRight(hk) {
    SGlob.Komorebic("move right")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Resize Windows (Win + Shift + ←↑↓→)                                         |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Resize Windows (Increase Width)
 * @context Komorebi
 * @keyword resize-axis horizontal increase
 */
#+Right::
resizeAxisHorizontalIncrease(hk) {
    SGlob.Komorebic("resize-axis horizontal increase")
    return
}

/**
 * Resize Windows (Decrease Width)
 * @context Komorebi
 * @keyword resize-axis horizontal decrease
 */
#+Left::
resizeAxisHorizontalDecrease(hk) {
    SGlob.Komorebic("resize-axis horizontal decrease")
    return
}

/**
 * Resize Windows (Increase Height)
 * @context Komorebi
 * @keyword resize-axis vertical increase
 */
#+Up::
resizeAxisVerticalIncrease(hk) {
    SGlob.Komorebic("resize-axis vertical increase")
    return
}

/**
 * Resize Windows (Decrease Height)
 * @context Komorebi
 * @keyword resize-axis vertical decrease
 */
#+Down::
resizeAxisVerticalDecrease(hk) {
    SGlob.Komorebic("resize-axis vertical decrease")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Set Layouts (Win + Alt + ←↑→)                                               |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Change Layout (bsp)
 * @context Komorebi
 * @keyword set-layout bsp
 */
#!Up::
changeLayoutBsp(hk) {
    SGlob.Komorebic("change-layout bsp")
    return
}

/**
 * Change Layout (horizontal-stack)
 * @context Komorebi
 * @keyword set-layout horizontal-stack
 */
#!Left::
changeLayoutHorizontalStack(hk) {
    SGlob.Komorebic("change-layout horizontal-stack")
    return
}

/**
 * Change Layout (vertical-stack)
 * @context Komorebi
 * @keyword set-layout vertical-stack
 */
#!Right::
changeLayoutVerticalStack(hk) {
    SGlob.Komorebic("change-layout vertical-stack")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Flip Layout (Win + PgUp/PgDn)                                               |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Flip Layout (Horizontal)
 * @context Komorebi
 * @keyword flip-layout horizontal
 */
#PgUp::
flipLayoutHorizontal(hk) {
    SGlob.Komorebic("flip-layout horizontal")
    return
}

/**
 * Flip Layout (Vertical)
 * @context Komorebi
 * @keyword flip-layout vertical
 */
#PgDn::
flipLayoutVertical(hk) {
    SGlob.Komorebic("flip-layout vertical")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Resize Regular Windows (Win + Shift + Ctrl + ←↑↓→)                          |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Resize Regular Active Window (Increase Width)
 * @context Komodo General
 */
#+^Right::
resizeRegularActiveWindowIncreaseWidth(hk) {
    SGlob.SetActiveWindowSize(20, 0)
    return
}

/**
 * Resize Regular Active Window (Decrease Width)
 * @context Komodo General
 */
#+^Left::
resizeRegularActiveWindowDecreaseWidth(hk) {
    SGlob.SetActiveWindowSize(-20, 0)
    return
}

/**
 * Resize Regular Active Window (Increase Height)
 * @context Komodo General
 */
#+^Up::
resizeRegularActiveWindowIncreaseHeight(hk) {
    SGlob.SetActiveWindowSize(0, 20)
    return
}

/**
 * Resize Regular Active Window (Decrease Height)
 * @context Komodo General
 */
#+^Down::
resizeRegularActiveWindowDecreaseHeight(hk) {
    SGlob.SetActiveWindowSize(0, -20)
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Move Regular Windows (Win + Shift + Alt + ←↑↓→)                             |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Move Regular Window (Right)
 * @context Komodo General
 * @keyword move-active-window right
 */
#+!Right::
moveRegularWindowRight(hk) {
    if (SGlob.IsKomoDoAvailable())
        SGlob.KomoDo("move-active-window 10 0")
    else
        SGlob.SetActiveWindowPosition(10, 0)
    return
}

/**
 * Move Regular Window (Left)
 * @context Komodo General
 * @keyword move-active-window left
 */
#+!Left::
moveRegularWindowLeft(hk) {
    if (SGlob.IsKomoDoAvailable())
        SGlob.KomoDo("move-active-window -10 0")
    else
        SGlob.SetActiveWindowPosition(-10, 0)
    return
}

/**
 * Move Regular Window (Up)
 * @context Komodo General
 * @keyword move-active-window up
 */
#+!Up::
moveRegularWindowUp(hk) {
    if (SGlob.IsKomoDoAvailable())
        SGlob.KomoDo("move-active-window 0 -10")
    else
        SGlob.SetActiveWindowPosition(0, -10)
    return
}

/**
 * Move Regular Window (Down)
 * @context Komodo General
 * @keyword move-active-window down
 */
#+!Down::
moveRegularWindowDown(hk) {
    if (SGlob.IsKomoDoAvailable())
        SGlob.KomoDo("move-active-window 0 10")
    else
        SGlob.SetActiveWindowPosition(0, 10)
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Stack Windows (Ctrl + Win + ←↑↓→)                                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Stack Windows (Left)
 * @context Komorebi
 * @keyword stack left
 */
^#Left::
stackWindowsLeft(hk) {
    SGlob.Komorebic("stack left")
}

/**
 * Stack Windows (Down)
 * @context Komorebi
 * @keyword stack down
 */
^#Down::
stackWindowsDown(hk) {
    SGlob.Komorebic("stack down")
    return
}

/**
 * Stack Windows (Up)
 * @context Komorebi
 * @keyword stack up
 */
^#Up::
stackWindowsUp(hk) {
    SGlob.Komorebic("stack up")
    return
}

/**
 * Stack Windows (Right)
 * @context Komorebi
 * @keyword stack right
 */
^#Right::
stackWindowsRight(hk) {
    SGlob.Komorebic("stack right")
    return
}

/**
 * Unstack Windows
 * @context Komorebi
 * @keyword unstack
 */
^#-::
unstackWindows(hk) {
    SGlob.Komorebic("unstack")
    return
}

/**
 * Cycle through the Stack of Windows (Previous)
 * @context Komorebi
 * @keyword cycle-stack previous
 */
^#,::
cycleStackPrevious(hk) {
    SGlob.Komorebic("cycle-stack previous")
    return
}

/**
 * Cycle through the Stack of Windows (Next)
 * @context Komorebi
 * @keyword cycle-stack next
 */
^#.::
cycleStackNext(hk) {
    SGlob.Komorebic("cycle-stack next")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Cycle through monitors (Win + Pos1/End)                                     |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Cycle through Monitors (Next)
 * @context Komorebi
 * @keyword cycle-monitor next
 */
#Home::
cycleMonitorNext(hk) {
    SGlob.Komorebic("cycle-monitor next")
    return
}

/**
 * Cycle through Monitors (Previous)
 * @context Komorebi
 * @keyword cycle-monitor previous
 */
#End::
cycleMonitorPrevious(hk) {
    SGlob.Komorebic("cycle-monitor previous")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Focus Monitor (Win + F1/F2)                                                 |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Focus Monitor (0)
 * @context Komorebi
 * @keyword focus-monitor 0
 */
#F1::
focusMonitor0(hk) {
    SGlob.Komorebic("focus-monitor 0")
    return
}

/**
 * Focus Monitor (1)
 * @context Komorebi
 * @keyword focus-monitor 1
 */
#F2::
focusMonitor1(hk) {
    SGlob.Komorebic("focus-monitor 1")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Send to Monitor (Win + Shift + F1/F2)                                       |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Send to Monitor (0)
 * @context Komorebi
 * @keyword send-to-monitor 0
 */
#+F1::
sendToMonitor0(hk) {
    SGlob.Komorebic("send-to-monitor 0")
    return
}

/**
 * Send to Monitor (1)
 * @context Komorebi
 * @keyword send-to-monitor 1
 */
#+F2::
sendToMonitor1(hk) {
    SGlob.Komorebic("send-to-monitor 1")
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Send to Workspace 1-7 (same monitor, Win + Shift + 1-7)                     |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Send to Workspace 1 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 0
 */
#+1::
#+Numpad1::
sendToWorkspace1(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 0)
    return
}

/**
 * Send to Workspace 2 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 1
 */
#+2::
#+Numpad2::
sendToWorkspace2(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 1)
    return
}

/**
 * Send to Workspace 3 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 2
 */
#+3::
#+Numpad3::
sendToWorkspace3(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 2)
    return
}

/**
 * Send to Workspace 4 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 3
 */
#+4::
#+Numpad4::
sendToWorkspace4(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 3)
    return
}

/**
 * Send to Workspace 5 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 4
 */
#+5::
#+Numpad5::
sendToWorkspace5(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 4)
    return
}

/**
 * Send to Workspace 6 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 5
 */
#+6::
#+Numpad6::
sendToWorkspace6(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 5)
    return
}

/**
 * Send to Workspace 7 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 6
 */
#+7::
#+Numpad7::
sendToWorkspace7(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 6)
    return
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Switch to Workspace 1-7 (same monitor, Win + 1-7)                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Switch to Workspace 1 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 0
 */
#1::
#Numpad1::
switchToWorkspace1(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 0)
    return
}

/**
 * Switch to Workspace 2 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 1
 */
#2::
#Numpad2::
switchToWorkspace2(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 1)
    return
}

/**
 * Switch to Workspace 3 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 2
 */
#3::
#Numpad3::
switchToWorkspace3(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 2)
    return
}

/**
 * Switch to Workspace 4 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 3
 */
#4::
#Numpad4::
switchToWorkspace4(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 3)
    return
}

/**
 * Switch to Workspace 5 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 4
 */
#5::
#Numpad5::
switchToWorkspace5(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 4)
    return
}

/**
 * Switch to Workspace 6 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 5
 */
#6::
#Numpad6::
switchToWorkspace6(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 5)
    return
}

/**
 * Switch to Workspace 7 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 6
 */
#7::
#Numpad7::
switchToWorkspace7(hk) {
    SGlob.CheckWorkspaceAndExecute("focus-workspace", 6)
    return
}

/* ----------------------------------------------------------------------------
| Reference of original key bindings from Komorebi's AutoHotkey script        |
|                                    (Leave this comment in: @stopprocessing) |
------------------------------------------------------------------------------*

!q::Komorebic("close")
!m::Komorebic("minimize")

; Focus windows
!h::Komorebic("focus left")
!j::Komorebic("focus down")
!k::Komorebic("focus up")
!l::Komorebic("focus right")

!+[::Komorebic("cycle-focus previous")
!+]::Komorebic("cycle-focus next")

; Move windows
!+h::Komorebic("move left")
!+j::Komorebic("move down")
!+k::Komorebic("move up")
!+l::Komorebic("move right")

; Stack windows
!Left::Komorebic("stack left")
!Down::Komorebic("stack down")
!Up::Komorebic("stack up")
!Right::Komorebic("stack right")
!;::Komorebic("unstack")
![::Komorebic("cycle-stack previous")
!]::Komorebic("cycle-stack next")

; Resize
!=::Komorebic("resize-axis horizontal increase")
!-::Komorebic("resize-axis horizontal decrease")
!+=::Komorebic("resize-axis vertical increase")
!+_::Komorebic("resize-axis vertical decrease")

; Manipulate windows
!t::Komorebic("toggle-float")
!f::Komorebic("toggle-monocle")

; Window manager options
!+r::Komorebic("retile")
!p::Komorebic("toggle-pause")

; Layouts
!x::Komorebic("flip-layout horizontal")
!y::Komorebic("flip-layout vertical")

; Workspaces
!1::Komorebic("focus-workspace 0")
!2::Komorebic("focus-workspace 1")
!3::Komorebic("focus-workspace 2")
!4::Komorebic("focus-workspace 3")
!5::Komorebic("focus-workspace 4")
!6::Komorebic("focus-workspace 5")
!7::Komorebic("focus-workspace 6")
!8::Komorebic("focus-workspace 7")

; Move windows across workspaces
!+1::Komorebic("move-to-workspace 0")
!+2::Komorebic("move-to-workspace 1")
!+3::Komorebic("move-to-workspace 2")
!+4::Komorebic("move-to-workspace 3")
!+5::Komorebic("move-to-workspace 4")
!+6::Komorebic("move-to-workspace 5")
!+7::Komorebic("move-to-workspace 6")
!+8::Komorebic("move-to-workspace 7")

-------------------------------------------------------------------------------
| End of original key bindings from Komorebi's AutoHotkey script              |
-----------------------------------------------------------------------------*/
