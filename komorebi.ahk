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
     * Path to the INI configuration file for this script.
     * IMPORTANT: This value needs to be the first in SGlob.
     * @type {String}
     */
    static IniFilePath := Format("{}\komorebi-ahk.ini", A_ScriptDir)

    /**
     * Whether to handle cursor repositioning when changing monitors
     * @type {Boolean}
     */
    static HandleCursorOnMonitorChange := SGlob.ReadIniValue("Settings", "HandleCursorOnMonitorChange", "true") == "true"

    /**
     * Holds the list of ignored processes that should not be managed by Komorebi.
     * This is read from the ini file and can be modified by the user.
     * @type {String[]}
     */
    static IgnoredProcesses := SGlob.GetIgnoredProcesses()

    /**
     * Name of the pipe used for communication with Komorebi.
     * @type {String}
     */
    static KomorebiPipeName := SGlob.ReadIniValue("Settings", "ListenerPipeName", "komorebi-ahk")

    /**
     * Map to store the start time of the monitor bar processes
     * @type {Map}
     */
    static MonitorBarStartTime := Map()

    /**
     * No Bar Mode
     * Disables certain komorebi-bar specific features.
     * @type {Boolean}
     */
    static NoBarMode := SGlob.ReadIniValue("Settings", "NoBarMode", "false") == "true"

    /**
     * Array of hwnds that are registered as AppBars, so we can unregister them on exit.
     * @type {Integer[]}
     */
    static RegisteredAppBars := []

    /**
     * Array of window handles to restore via pop.
     */
    static WindowStack := []

    /**
     * WMI object to query various informations
     */
    static WmicObject := ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")

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
        winMonitor := SGlob.GetMonitorByXYCoord(activeWinPos.centerX, activeWinPos.centerY)

        ; If invalid monitor index: return
        if (winMonitor = -1)
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
     * @param {Boolean} useZeroBasedIndex Whether the workspace number is 0-based (default: true)
     */
    static CheckWorkspaceAndExecute(command, workspace, useZeroBasedIndex := true) {
        if (!IsInteger(workspace))
            return

        monitorIndex := SGlob.GetCurrentMonitorByCursorPosition(true).monitorIndex

        if (KomorebiState.NumberOfWorkspaces.Get(monitorIndex) < (workspace + (useZeroBasedIndex ? 1 : 0)))
            return

        SGlob.Komorebic(Format("{} {}", command, (useZeroBasedIndex ? workspace : workspace - 1)))
    }

    /**
     * Fills the ignored processes group with the processes from the ini file.
     * This is called once at script startup to ensure the group is populated.
     */
    static FillIgnoredProcessesGroup() {
        for i, process in SGlob.IgnoredProcesses {
            GroupAdd("KomoIgnoreProcesses", "ahk_exe " . process)
            OutputDebug("Added ignored process: " . process)
        }
    }

    /**
     * Focuses the desktop window as a workaround for focus issues
     * with Raycast.
     */
    static FocusDesktopWorkaround() {
        WinActivate("ahk_class Progman")
        OutputDebug("[FocusDesktopWorkaround] Focused Progman!")
    }

    /**
     * Focuses the workspace on the current monitor based on the specified workspace index.
     * "Current monitor" refers to the monitor where the mouse cursor is currently located.
     * Note: The workspaceIndex is 0-based.
     * @param {Integer} workspaceIndex The index of the workspace to focus on the current monitor (0-based)
     * @param {Boolean} useZeroBasedIndex Whether the workspace index is 0-based (default: true)
     */
    static FocusCurrentMonitorWorkspace(workspaceIndex, useZeroBasedIndex := true) {
        if (!IsInteger(workspaceIndex))
            return

        ; Trying to be smart by getting active windows first is not a good idea
        ; as that usually fails with cloaking and jumps around multiple monitors...
        monitorIndex := SGlob.GetCurrentMonitorByCursorPosition(true).monitorIndex

        if (KomorebiState.NumberOfWorkspaces.Get(monitorIndex) < (workspaceIndex + (useZeroBasedIndex ? 1 : 0)))
            return

        SGlob.Komorebic(Format("focus-monitor-workspace {} {}", monitorIndex, (useZeroBasedIndex ? workspaceIndex : workspaceIndex - 1)))
    }

    /**
     * Creates and focuses a pseudo window as a workaround
     * for focus issues with Raycast 0.45 and above.
     */
    static FocusPseudoWindowWorkaround() {
        ; Determine what monitor to work on, so we don't
        ; swap focus around and windows appear on the wrong display.
        mon := SGlob.GetCurrentMonitorByCursorPosition()

        if (mon == -1) {
            OutputDebug("[FocusPseudoWindowWorkaround] Failed to get current monitor based on cursor position.")
            return
        }

        ; Calculate a position just outside the work area.
        x := mon.workAreaX + mon.workAreaWidth - 1
        y := mon.workAreaY + mon.workAreaHeight - 1

        OutputDebug(Format("[FocusPseudoWindowWorkaround] Active on monitor {}, creating pseudo window at {}, {}!", mon.monitorIndex, x, y))

        ; Create pseudo gui to trap Raycast's window detection
        pseudoGui := Gui()
        pseudoGui.BackColor := "000000"
        pseudoGui.Opt("-Caption +ToolWindow +AlwaysOnTop")
        pseudoGui.Show(Format("x{} y{} w1 h1 NoActivate", x, y))

        WinSetTransparent(0, "ahk_id " . pseudoGui.Hwnd)
        
        ; Focus and destroy the pseudo gui
        WinActivate("ahk_id " . pseudoGui.Hwnd)
        pseudoGui.Destroy()
        pseudoGui := ""

        OutputDebug("[FocusPseudoWindowWorkaround] Focused pseudo window!")
    }

    /**
     * Get the current monitor based on the mouse cursor position
     * This method retrieves the coordinates of the mouse cursor and determines which monitor it is on.
     * @param {Boolean} useZeroBasedIndex Whether to return the monitor index as 0-based (default: false, meaning 1-based index)
     * @returns {Object} The monitor index and work area dimensions
     */
    static GetCurrentMonitorByCursorPosition(useZeroBasedIndex := false) {
        oldValue := CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        CoordMode("Mouse", oldValue)
        return SGlob.GetMonitorByXYCoord(mx, my, useZeroBasedIndex)
    }

    /**
     * Determines the current monitor based on the cursor position.
     * @param {Integer} outputVar The variable to store the monitor number in
     * @param {Boolean} useZeroBasedIndex Whether to return the monitor index as 0-based (default: false, meaning 1-based index)
     */
    static GetCurrentMonitorNum(&outputVar, useZeroBasedIndex := false) {
        monitor := SGlob.GetCurrentMonitorByCursorPosition(useZeroBasedIndex := useZeroBasedIndex)

        ; No monitor found - why?
        if (monitor == -1)
            return -1

        &outputVar := monitor.monitorIndex
    }

    /**
     * Reads the ignored processes from the ini file.
     * @returns {String[]} An array of ignored process names
     */
    static GetIgnoredProcesses() {
        ignoredProcesses := []
        index := 0
        loop {
            value := SGlob.ReadIniValue("IgnoreProcesses", "Ignore" . index, "")
            if (value = "" || value = "ERROR")
                break
            ignoredProcesses.Push(value)
            index++
        }
        return ignoredProcesses
    }

    /**
     * Get Komorebi Bar processes without any qualifiers
     * @returns {Integer[]} An array of process IDs for Komorebi Bar
     */
    static GetKomorebiBarProcesses() {
        return SGlob.ProcessGetByNameAndArguments("komorebi-bar.exe", "")
    }

    /**
     * A helper method to safely get values from a nested map object.
     * @param {Map} mapObject The map object to retrieve the value from
     * @param {...Any} keys The keys to traverse the nested map, basically an XPath
     * @returns {Any} The value found at the specified keys, or an empty string if not found
     */
    static GetMapValue(mapObject, keys*) {
        currentMap := mapObject

        for (key in keys) {
            if (!currentMap.Has(key))
                return ""
            currentMap := currentMap.Get(key)
        }

        return currentMap
    }

    /**
     * Returns all monitor device instance paths as an array
     * @returns {Array} An array of monitor instance paths
     */
    static GetMonitorDeviceInstancePaths() {
        ; Initialize an array to store device instance paths
        monitorPaths := []

        try {
            ; Query all monitors
            monitors := SGlob.WmicObject.ExecQuery("SELECT * FROM Win32_PnPEntity WHERE PNPClass = 'Monitor'")

            ; Loop through the monitors and get the device instance paths
            for (monitor in monitors) {
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
            keyValuePair := StrSplit(A_LoopField, "=", , 2)

            if(keyValuePair.Length != 2)
                continue

            monitorId := keyValuePair[1]
            devicePath := keyValuePair[2]

            monitorIds.Set(monitorId, devicePath)
        }

        return monitorIds
    }

    /**
     * Function to get the monitor based on a given set of X and Y coordinates.
     * @param {Integer} xCoord The X coordinate to check
     * @param {Integer} yCoord The Y coordinate to check
     * @param {Boolean} useZeroBasedIndex Whether to return the monitor index as 0-based (default: false, meaning 1-based index)
     * @returns {Object} The monitor index and work area dimensions
     */
    static GetMonitorByXYCoord(xCoord, yCoord, useZeroBasedIndex := false) {
        monitors := SGlob.GetMonitors(useZeroBasedIndex := useZeroBasedIndex)

        ; We need two iterations here.
        ; The first run checks whether the coordinates are within any
        ; of the monitors' work areas. This does not necessarily produce
        ; a result if we are checking against the cursor's screen coordinates.
        ; These might be outside of any monitor's work area.
        ; So the second loop will clamp the coordinates to the nearest point
        ; within the work areas and check again.
        loop (2) {
            checkLoop := A_Index
            for (monitor in monitors) {
                cx := xCoord
                cy := yCoord

                ; Clamp check values on second iteration because
                ; we did not find a match yet...
                if (checkLoop == 2) {
                    cx := Max(monitor.workAreaX, Min(xCoord, monitor.workAreaX + monitor.workAreaWidth))
                    cy := Max(monitor.workAreaY, Min(yCoord, monitor.workAreaY + monitor.workAreaHeight))
                }

                if (cx >= monitor.workAreaX && cx <= monitor.workAreaWidth &&
                    cy >= monitor.workAreaY && cy <= monitor.workAreaHeight) {
                    return monitor
                }
            }
        }

        return -1
    }

    /**
     * Gets the monitor information for all connected monitors.
     * @param {Boolean} useZeroBasedIndex Return the monitorIndex as 0-based index (default: false, meaning 1-based index)
     */
    static GetMonitors(useZeroBasedIndex := false) {
        monitors := []
        monitorCount := SysGet(WinuserConstants.SM_CMONITORS)

        loop (monitorCount) {
            MonitorGetWorkArea(
                A_Index,
                &workAreaX,
                &workAreaY,
                &workAreaWidth,
                &workAreaHeight
            )

            monitors.Push({
                monitorIndex: useZeroBasedIndex ? A_Index - 1 : A_Index,
                workAreaX: workAreaX,
                workAreaY: workAreaY,
                workAreaWidth: workAreaWidth,
                workAreaHeight: workAreaHeight
            })
        }

        return monitors
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
     * Determines whether a given input is a function.
     * @param {Func} fn Pointer to a function
     * @returns {Boolean} True if the input is a function, false otherwise
     */
    static IsFunc(fn?) {
        return (IsSet(fn) && HasMethod(fn))
    }

    /**
     * Function to kill applications specified in the ini file under the AutoKillApplications section.
     */
    static KillApplications() {
        if (!FileExist(SGlob.IniFilePath))
            return

        content := IniRead(SGlob.IniFilePath, "AutoKillApplications")

        loop parse, content, "`n", "`r" {
            keyValuePair := StrSplit(A_LoopField, "=", , 2)
            
            if (keyValuePair.Length != 2)
                continue
            
            applicationName := keyValuePair[1]
            applicationExecutable := keyValuePair[2]
            applicationExecutable := StrReplace(applicationExecutable, "`"")

            if (ProcessExist(applicationExecutable)) {
                OutputDebug(Format("Attempting to kill application {}: {}", applicationName, applicationExecutable))
                ProcessClose(applicationExecutable)
            } else {
                OutputDebug(Format("No process found for {}, skipping.", applicationName))
            }
        }
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

            query := Format(
                "SELECT * FROM Win32_Process WHERE Name = '{}' AND CommandLine LIKE '%{}%'",
                executable,
                argument
            )

            for (proc in SGlob.WmicObject.ExecQuery(query)) {
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
     * @returns {String} The value of the key read from the ini file
     */
    static ReadIniValue(section, key, defaultValue := "") {
        if (!FileExist(SGlob.IniFilePath))
            return defaultValue

        return IniRead(SGlob.IniFilePath, section, key, defaultValue)
    }

    /**
     * Registers a window as an AppBar at the top of the screen.
     * @param {Integer} hwnd Window hwnd to register as an AppBar
     */
    static RegisterHwndAsAppBar(hwnd) {
        if !WinExist("ahk_id " . hwnd) {
            OutputDebug(Format("RegisterHwndAsAppBar: Invalid window handle {}.", hwnd))
            return
        }

        WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd)
        if (w = "" || h = "") {
            OutputDebug(Format("RegisterHwndAsAppBar: Failed to get window rect for hwnd {}.", hwnd))
            return
        }

        ABM_NEW := 0
        ABM_REMOVE := 1
        ABM_SETPOS := 3
        ABE_TOP := 1

        ; Ensure previous registration is cleared
        SGlob.UnregisterHwndAsAppBar(hwnd)

        ; APPBARDATA structure offsets
        ; Offsets change depending on 32bit or 64bit system...
        offsetHwnd := (A_PtrSize = 8) ? 8 : 4
        offsetCallback := offsetHwnd + A_PtrSize
        offsetEdge := offsetCallback + 4
        offsetRc := offsetEdge + 4
        offsetLparam := offsetRc + 16
        
        ; Initialize APPBARDATA structure
        abd := Buffer(offsetLparam + A_PtrSize, 0)
        NumPut("UInt", abd.Size, abd, 0)                ; cbSize
        NumPut("Ptr", hwnd, abd, offsetHwnd)            ; hWnd
        NumPut("UInt", 0, abd, offsetCallback)          ; uCallbackMessage
        NumPut("UInt", ABE_TOP, abd, offsetEdge)        ; uEdge
        NumPut("Int", x, abd, offsetRc)                 ; rc.Left
        NumPut("Int", y, abd, offsetRc + 4)             ; rc.Top
        NumPut("Int", x + w, abd, offsetRc + 8)         ; rc.Right
        NumPut("Int", y + h, abd, offsetRc + 12)        ; rc.Bottom

        DllCall("shell32\SHAppBarMessage", "UInt", ABM_NEW, "Ptr", abd, "UInt")
        DllCall("shell32\SHAppBarMessage", "UInt", ABM_SETPOS, "Ptr", abd, "UInt")

        ; Add the hwnd to the catalogue so it can be unregistered on exit
        if(!SGlob.RegisteredAppBars.Has(hwnd))
            SGlob.RegisteredAppBars.Push(hwnd)
    }

    /**
     * Registers all Komorebi Bar processes as AppBars.
     */
    static RegisterKomorebiBarsAsAppBars() {
        if (SGlob.NoBarMode)
            return

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
            keyValuePair := StrSplit(A_LoopField, "=", , 2)

            if (keyValuePair.Length != 2)
                continue

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
     * @param {String} appName Name of the application key name from the ini file
     */
    static RunDefaultApplication(appName) {
        appPath := SGlob.ReadIniValue("DefaultApplications", appName, "")
        appPath := SGlob.ResolveEnvironmentVariables(appPath)
        appArgs := SGlob.ReadIniValue("DefaultApplications", appName . "Args", "")
        appArgs := SGlob.ResolveEnvironmentVariables(appArgs)
        if (FileExist(appPath)) {
            appPathWithArgs := appPath

            if appArgs != ""
                appPathWithArgs := Format("{} {}", appPath, appArgs)

            Run(appPathWithArgs)
        }
    }

    /**
     * Checks the available monitors and whether the Komorebi bar is running on them.
     * If a monitor is connected and the bar is not running, it will be started.
     * If a monitor is not connected and the bar is running, it will be closed.
     */
    static RunOrKillKomorebiBarOnDisplayChange() {
        if (SGlob.NoBarMode)
            return

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
                    if (currentBarPid == -1)
                        continue
                    OutputDebug("Monitor " . monitorConfigNumber . " not connected, closing bar with PID " . currentBarPid)
                    ProcessClose(currentBarPid)
                }
            } else {
                ; Monitor connected and at least one bar is already active
                if (barPidOfMonitor[1] != -1) {
                    OutputDebug("Bar already running for monitor " . monitorConfigNumber . " with PID " . barPidOfMonitor[1])
                    continue
                }

                if (SGlob.MonitorBarStartTime.Has(monitorConfigNumber)) {
                    ; Check if the bar was started recently
                    startTime := SGlob.MonitorBarStartTime.Get(monitorConfigNumber)
                    currentTime := A_TickCount
                    elapsedTime := currentTime - startTime

                    if (elapsedTime < barLaunchWait) {
                        OutputDebug("Monitor " . monitorConfigNumber . " bar was started recently, skipping...")
                        continue
                    }
                }

                ; Monitor connected but bar is not active
                ; NOTE: barConfigPattern needs to be concatenated so the format string will be parsed!
                barLaunchCmd := Format(
                    "komorebi-bar.exe `"--config`" `"{}\" . barConfigPattern . "`"",
                    A_ScriptDir,
                    monitorConfigNumber
                )

                OutputDebug("Monitor " . monitorConfigNumber . " connected, launching bar in " . barLaunchWait . "ms with command: " . barLaunchCmd)

                ; Mark the start time of the bar process so it does not trigger
                ; on closely timed repeat calls to this function.
                SGlob.MonitorBarStartTime.Set(monitorConfigNumber, A_TickCount)

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
     * Sets the mouse cursor to the center of the specified monitor.
     * Does not touch the cursor if it's already on the specified monitor.
     * Also does nothing if the specified monitor number is out of bounds.
     * @param {Integer} monitorNum Monitor number to set the cursor on (1-based index)
     * @param {Boolean} useZeroBasedIndex Whether the monitor number is 0-based (default: false, meaning 1-based index)
     */
    static SetCursorToMonitorNum(monitorNum, useZeroBasedIndex := false) {
        monitors := SGlob.GetMonitors()
        currentMonitor := SGlob.GetCurrentMonitorByCursorPosition()

        if (currentMonitor = -1) {
            OutputDebug("SetCursorToMonitorNum: Failed to get current monitor based on cursor position.")
            return
        }

        monitorNum := useZeroBasedIndex ? monitorNum + 1 : monitorNum

        if (monitorNum == currentMonitor.monitorIndex)
            return

        if (monitorNum < 1 || monitorNum > monitors.Length)
            return

        oldValue := CoordMode("Mouse", "Screen")
        monitor := monitors[monitorNum]

        newX := monitor.workAreaX + ((monitor.workAreaWidth - monitor.workAreaX) // 2)
        newY := monitor.workAreaY + ((monitor.workAreaHeight - monitor.workAreaY) // 2)

        MouseMove(newX, newY)
        CoordMode("Mouse", oldValue)
    }

    /**
     * Touch komorebi-bar's configuration to force a hot-reload...
     * Otherwise the bar is too big... (yeah really!)
     * Optionally allows to specify a PID to wait for.
     * @param {Integer} pidToWaitFor The process ID to wait for before touching the configuration
     * @param {String} processNameToWaitFor The process name to wait for if PID is not specified (default: "komorebi-bar.exe")
     * @param {String} filePattern The file pattern to touch, where the monitor number will be replaced with a format specifier (default: "komorebi.bar.monitor{:02}.json")
     */
    static TouchKomorebiBarConfig(pidToWaitFor := -1, processNameToWaitFor := "komorebi-bar.exe", filePattern := "komorebi.bar.monitor*.json") {
        if (SGlob.NoBarMode)
            return

        ; It would be nicer to grab the PID and use WinExist or WinWait
        ; with ahk_pid, however this approach does not work with
        ; Scoop's shim executables.
        ; Instead of overcomplicating things, we'll just wait 500ms.
        if (pidToWaitFor == -1)
            ProcessWait(processNameToWaitFor, 10)
        else
            ProcessWait(pidToWaitFor, 10)

        if (ProcessExist(processNameToWaitFor)) {
            Sleep 500
            FileSetTime(
                A_Now,
                Format("{}\{}", A_ScriptDir, filePattern)
            )
        }
    }

    /**
     * Updates the AltSnap blacklist with the processes from the ignored processes group.
     */
    static UpdateAltSnapBlacklistProcesses() {
        altSnapIniFile := SGlob.ResolveEnvironmentVariables(SGlob.ReadIniValue("Settings", "AltSnapIniFilePath", ""))

        if (!FileExist(altSnapIniFile))
            return

        if (!SGlob.ReadIniValue("Settings", "UpdateAltSnapBlacklist", "false") == "true")
            return

        currentBlacklist := IniRead(altSnapIniFile, "Blacklist", "Processes", "")

        for process in SGlob.IgnoredProcesses {
            if !InStr(currentBlacklist, process)
            {
                if (currentBlacklist != "")
                    currentBlacklist .= ","
                currentBlacklist .= process
            }
        }

        currentBlacklist := Sort(currentBlacklist, "C0 D,")

        IniWrite(currentBlacklist, altSnapIniFile, "Blacklist", "Processes")
    }

    /**
     * Unregisters a window as an AppBar.
     * @param {Integer} hwnd Window hwnd to unregister as an AppBar.
     */
    static UnregisterHwndAsAppBar(hwnd) {
        ABM_REMOVE := 1

        offsetHwnd := (A_PtrSize = 8) ? 8 : 4
        abd := Buffer((offsetHwnd + A_PtrSize + 4 + 4 + 16 + A_PtrSize), 0)
        NumPut("UInt", abd.Size, abd, 0)      ; cbSize
        NumPut("Ptr", hwnd, abd, offsetHwnd)  ; hWnd
        DllCall("shell32\SHAppBarMessage", "UInt", ABM_REMOVE, "Ptr", abd, "UInt")
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
        this.listViewRelations := OrderedMap()

        ; Font for the GUI
        font := SGlob.ReadIniValue("HotkeyLister", "Font", "Courier New")

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
        this.columnWidthHotkey := 260

        ; Main window
        this.hotkeyGui := Gui()
        this.hotkeyGui.Title := "Komorebi AutoHotkey Helper - Hotkey List"
        this.hotkeyGui.BackColor := editFgColor
        this.hotkeyGui.Opt("+AlwaysOnTop +Border -MaximizeBox -MinimizeBox +Resize +Theme -ToolWindow")
        
        ; Search box
        this.searchBox := this.hotkeyGui.Add("Edit", "w500 h20", "")
        this.searchBox.Opt("-E0x200 +Background" . editBgColor)
        this.searchBox.SetFont("s10", font)
        this.searchBox.SetFont("bold")
        this.searchBox.SetFont("c" . editFgColor)

        ; ListView for hotkeys
        this.listView := this.hotkeyGui.Add("ListView", "-Border w500 r15 y+5", ["Hotkey", "Description"])
        this.listView.Opt("-E0x200 +LV0x10000 -Hdr +Report -Multi +Background" . bgColor)
        this.listView.SetFont("s10", font)
        this.listView.SetFont("c" . fgColor)

        ; Wire up events
        this.hotkeyGui.OnEvent("Close", this.hotkeyGui_OnClose.Bind(this))
        this.hotkeyGui.OnEvent("Escape", this.hotkeyGui_OnClose.Bind(this))
        this.hotkeyGui.OnEvent("Size", this.hotkeyGui_OnSize.Bind(this))
        
        this.searchBox.OnEvent("Change", this.searchBox_OnChange.Bind(this))
        
        this.listView.OnEvent("DoubleClick", this.listView_OnDoubleClick.Bind(this))
        
        ; Wire up Windows message handler
        OnMessage(0x86, this.OnWmActivate.Bind(this)) ; WM_ACTIVATE
        OnMessage(0x100, this.OnWmKeyDown.Bind(this)) ; WM_KEYDOWN = 0x100
        
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
        ; Define labels for each modifier key
        keyLabelsMap := OrderedMap(
            ; Win
            "<#",   "LWin",
            ">#",   "RWin",
            "#",    "Win",
            "LWin", "L.Win",
            "RWin", "R.Win",
            ; Alt
            "<^>!", "AltGr",
            "<!",   "LAlt",
            ">!",   "RAlt",
            "!",    "Alt",
            ; Ctrl
            "<^",   "LCtrl",
            ">^",   "RCtrl",
            "^",    "Ctrl",
            ; Shift
            "<+",   "LShift",
            ">+",   "RShift",
            "+",    "Shift",
        )
        parts := []

        ; Process modifiers - but only once per hotkey!
        ; Every other occurance of the modifier char is likely
        ; intended to be the literal key value.
        for key, label in keyLabelsMap {
            keyPos := InStr(hotkeyStr, key)

            if (keyPos > 0 && keyPos < StrLen(hotkeyStr) - StrLen(key) + 1) {
                if (!parts.Has(label)) {
                    hotkeyStr := StrReplace(hotkeyStr, key, "", 0, , 1)
                    parts.Push(label)
                }
            }
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
        if (!this.IsGuiVisible)
            return

        OutputDebug("Hiding Hotkey List window.")

        this.IsGuiVisible := false
        this.hotkeyGui.Hide()
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
        this.listView.Move(0, searchBoxH + 2, minWidth, minHeight - searchBoxH)

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

            if(SGlob.IsFunc(%function%?))
                %function%.Call(selectedHotkey.rawhotkey)
        }
    }

    /**
     * Loads hotkey definitions from the current script and parses JavaDoc comments for context and keywords.
     */
    LoadHotkeyDefinitions() {
        scriptContent := FileRead(A_ScriptFullPath)
        
        ; Split content into lines for line number tracking
        scriptLines := StrSplit(scriptContent, "`n", "`r")

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

            ; Try to match the function name, so we can explicitly call it.
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
            
            if (!ignore && hotkeyMatch.functionName && SGlob.IsFunc(%hotkeyMatch.functionName%?)) {
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
        if (this.IsGuiVisible)
            return

        OutputDebug("Showing Hotkey List window.")

        ; Calculate window dimensions
        w := 800
        h := 250
        mon := SGlob.GetCurrentMonitorByCursorPosition()

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
        this.listViewRelations := OrderedMap()
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
}

/**
 * Class to manage a named pipe listener for inter-process communication
 * Creates a named pipe and then listens for incoming connections and messages.
 * Non-blocking (hopefully)
 */
Class NamedPipeListener {
    /**
     * Creates a new instance of the NamedPipeListener class.
     * @param {String} pipeName The name of the pipe to create and listen on.
     * @param {Number} pollMs The interval in milliseconds to poll for new messages when a client is connected.
     * @param {Number} bufSize The size of the buffer to use when reading messages from the pipe.
     */
	__New(pipeName, pollMs := 25, bufSize := 4096) {
		this.PipeName := pipeName
		this.PollMs := pollMs
		this.IdlePollMs := 200
		this.BufSize := bufSize
		this.Handle := 0
		this._ovl := 0
		this._connectEvent := 0
		this._connecting := false
		this._connected := false
		this._readBuf := Buffer(bufSize, 0)
		this._timerInterval := 0
		this.OnMessage := (msg, bytesRead) => OutputDebug(Format("Received ({} bytes): {}", bytesRead, msg))
	}

    /**
     * Starts the pipe listener by creating the named pipe and setting up a timer to poll for connections and messages.
     */
	Start() {
		this.Handle := this._CreateInboundPipe(this.PipeName)
		this._connected := false
		this._connecting := true
		OutputDebug(Format("[NamedPipeListener] Waiting for client on {}...", this.PipeName))
		this._ConnectPipe(this.Handle)
		this._timer := ObjBindMethod(this, "_Tick")
		this._SetTimerInterval(this.IdlePollMs)
	}

    /**
     * Stops the pipe listener by closing the pipe handle and stopping the timer.
     */
	Stop() {
		if (this._timer) {
			SetTimer(this._timer, 0)
			this._timer := 0
		}
		this._ClosePipe(this.Handle)
		this.Handle := 0
	}

    /**
     * Internal method that is called on each timer tick to check for new
     * connections and read messages from the pipe.
     * If a client is not yet connected, it checks for a new connection.
     */
	_Tick() {
		if (this._connecting && !this._connected) {
			if (!this._CheckConnected())
				return
			OutputDebug("[NamedPipeListener] Client connected. Listening for data.")
			this._SetTimerInterval(this.PollMs)
		}

		if (!this._connected)
			return

		msg := ""
		bytesRead := 0
		status := this._ReadPipeMessage(this.Handle, this.BufSize, &msg, &bytesRead)

        if (status = 0) {
			OutputDebug("[NamedPipeListener] Pipe closed by client.")
			this.Stop()
			ExitApp
		}

        if (status < 0) {
			this._Fail(Format("[NamedPipeListener] ReadFile failed. Error: {}", -status))
		}

        if (bytesRead > 0) {
            cleanMsg := Trim(msg, " `t`r`n`0")
            if (cleanMsg != "" && SGlob.IsFunc(this.OnMessage))
                this.OnMessage.Call(cleanMsg, bytesRead)
		}
	}

    /**
     * Internal method to create a named pipe for inbound communication.
     * @param {String} name The name of the pipe to create.
     */
	_CreateInboundPipe(name) {
		; Inbound, message mode, blocking mode.
		PIPE_ACCESS_INBOUND := 0x00000001
		FILE_FLAG_OVERLAPPED := 0x40000000
		PIPE_TYPE_MESSAGE := 0x00000004
		PIPE_READMODE_MESSAGE := 0x00000002
		PIPE_WAIT := 0x00000000
		PIPE_UNLIMITED_INSTANCES := 255

		handle := DllCall(
			"CreateNamedPipe",
			"str", name,
			"uint", PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
			"uint", PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
			"uint", PIPE_UNLIMITED_INSTANCES,
			"uint", 0,
			"uint", this.BufSize,
			"uint", 0,
			"ptr", 0,
			"ptr"
		)

		if (handle = -1) {
			err := DllCall("GetLastError", "uint")
			this._Fail(Format("[NamedPipeListener] CreateNamedPipe failed. Error: {}", err))
		}

		OnExit(*) => this._ClosePipe(handle)
		return handle
	}

    /**
     * Internal method to adjust the timer interval for polling the pipe.
     * @param {Integer} ms The interval in milliseconds to set for the timer.
     */
	_SetTimerInterval(ms) {
		if (this._timerInterval = ms) {
			return
		}
		SetTimer(this._timer, ms)
		this._timerInterval := ms
	}

    /**
     * Internal method to start an overlapped connect to avoid blocking the main thread.
     * @param {Ptr} handle The handle to the named pipe.
     */
	_ConnectPipe(handle) {
		; Start an overlapped connect to avoid blocking the main thread.
		ERROR_PIPE_CONNECTED := 535
		ERROR_IO_PENDING := 997

		this._connectEvent := DllCall("CreateEvent", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
		this._ovl := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
		eventOffset := (A_PtrSize = 8) ? 24 : 16
		NumPut("ptr", this._connectEvent, this._ovl, eventOffset)

		if DllCall("ConnectNamedPipe", "ptr", handle, "ptr", this._ovl) {
			this._connected := true
			this._connecting := false
			return
		}

		err := DllCall("GetLastError", "uint")
		if (err = ERROR_PIPE_CONNECTED) {
			this._connected := true
			this._connecting := false
			return
		}
		if (err != ERROR_IO_PENDING) {
			this._Fail(Format("ConnectNamedPipe failed. Error: {}", err))
		}
	}

    /**
     * Internal method to check if the overlapped connection has completed and update the connection state accordingly.
     * @returns {Boolean} True if the connection is established, false otherwise.
     */
	_CheckConnected() {
		; Poll overlapped connection completion.
		WAIT_OBJECT_0 := 0
		WAIT_TIMEOUT := 258
		ERROR_IO_INCOMPLETE := 996

		if (!this._connectEvent)
			return false

        bytes := 0
		wait := DllCall("WaitForSingleObject", "ptr", this._connectEvent, "uint", 0, "uint")
        
		if (wait = WAIT_TIMEOUT)
			return false
		if (wait != WAIT_OBJECT_0)
			this._Fail(Format("WaitForSingleObject failed. Error: {}", DllCall("GetLastError", "uint")))

		if (!DllCall("GetOverlappedResult", "ptr", this.Handle, "ptr", this._ovl, "uint*", &bytes, "int", 0)) {
			err := DllCall("GetLastError", "uint")
			
            if (err = ERROR_IO_INCOMPLETE)
				return false
			
            this._Fail(Format("GetOverlappedResult failed. Error: {}", err))
		}

		this._connected := true
		this._connecting := false
		return true
	}

    /**
     * Internal method to read a complete message from the pipe, handling cases where the message may be larger than the buffer size and ensuring that messages are not split across reads.
     * @param {Ptr} handle The handle to the named pipe to read from.
     * @param {Integer} bufSize The size of the buffer to use for each read operation.
     * @param {Ref} message A reference variable to store the complete message read from the pipe.
     * @param {Ref} bytesRead A reference variable to store the total number of bytes read from the pipe.
     * @returns {Integer} 1 if the message was read successfully, 0 if the pipe was closed by the client, or a negative error code if an error occurred.
     */
	_ReadPipeMessage(handle, bufSize, &message, &bytesRead) {
        return this._ReadPipeMessageCore(handle, bufSize, &message, &bytesRead, true)
	}

    _ReadPipeMessageCore(handle, bufSize, &message, &bytesRead, nonBlocking := true) {
        ; Read a full message, optionally checking availability first.
        ERROR_NO_DATA := 232
        ERROR_MORE_DATA := 234
        ERROR_BROKEN_PIPE := 109

        if (nonBlocking) {
            avail := 0
            if !DllCall("PeekNamedPipe", "ptr", handle, "ptr", 0, "uint", 0, "uint*", 0, "uint*", &avail, "uint*", 0) {
                err := DllCall("GetLastError", "uint")
                if (err = ERROR_BROKEN_PIPE) {
                    return 0
                }
                if (err = ERROR_NO_DATA) {
                    bytesRead := 0
                    message := ""
                    return 1
                }
                return -err
            }

            if (avail = 0) {
                bytesRead := 0
                message := ""
                return 1
            }
        }

        buf := this._readBuf
        if (buf.Size != bufSize) {
            buf := Buffer(bufSize, 0)
            this._readBuf := buf
        }

        msgBuf := 0
        total := 0

        loop {
            readNow := 0
            
            ok := DllCall("ReadFile", "ptr", handle, "ptr", buf, "uint", bufSize, "uint*", &readNow, "ptr", 0)
            
            if (!ok) {
                err := DllCall("GetLastError", "uint")
                if (err = ERROR_BROKEN_PIPE)
                    return 0
                if (err != ERROR_MORE_DATA)
                    return -err
            }

            if (readNow > 0) {
                newTotal := total + readNow
            
                if (!IsObject(msgBuf)) {
                    msgBuf := Buffer(newTotal, 0)
                } else if (msgBuf.Size < newTotal) {
                    newBuf := Buffer(newTotal, 0)
                    DllCall("RtlMoveMemory", "ptr", newBuf, "ptr", msgBuf, "uptr", total)
                    msgBuf := newBuf
                }

                DllCall("RtlMoveMemory", "ptr", msgBuf.Ptr + total, "ptr", buf, "uptr", readNow)
                
                total := newTotal
            }

            if (ok)
                break
        }

        bytesRead := total
        message := (total > 0) ? StrGet(msgBuf, total, "UTF-8") : ""
        return 1
	}

    /**
     * Internal method to close the pipe handle and clean up resources when the listener is stopped or the application exits.
     * @param {Ptr} handle The handle to the named pipe to close.
     */
	_ClosePipe(handle) {
		if (handle && handle != -1) {
			DllCall("DisconnectNamedPipe", "ptr", handle)
			DllCall("CloseHandle", "ptr", handle)
		}
		
        if (this._connectEvent) {
			DllCall("CloseHandle", "ptr", this._connectEvent)
			this._connectEvent := 0
		}
		
        this._timerInterval := 0
        OutputDebug("[NamedPipeListener] Pipe closed.")
	}

    /**
    * Internal method to handle failures by outputting a debug message, showing a message box with the error, and exiting the application.
    * @param {String} message The error message to display.
    */    
	_Fail(message) {
		OutputDebug(Format("[NamedPipeListener] {}", message))
		MsgBox message, "Pipe Dream shattered", "Iconx"
		ExitApp
	}
}

/**
 * https://github.com/TheArkive/JXON_ahk2
 */
Class Jxon {
    static Load(&src, args*) {
        key := "", is_key := false
        stack := [ tree := [] ]
        next := '"{[01234567890-tfn'
        pos := 0
        
        while ( (ch := SubStr(src, ++pos, 1)) != "" ) {
            if InStr(" `t`n`r", ch)
                continue
            if !InStr(next, ch, true) {
                testArr := StrSplit(SubStr(src, 1, pos), "`n")
                
                ln := testArr.Length
                col := pos - InStr(src, "`n",, -(StrLen(src)-pos+1))

                msg := Format("{}: line {} col {} (char {})"
                ,   (next == "")      ? ["Extra data", ch := SubStr(src, pos)][1]
                : (next == "'")     ? "Unterminated string starting at"
                : (next == "\")     ? "Invalid \escape"
                : (next == ":")     ? "Expecting ':' delimiter"
                : (next == '"')     ? "Expecting object key enclosed in double quotes"
                : (next == '"}')    ? "Expecting object key enclosed in double quotes or object closing '}'"
                : (next == ",}")    ? "Expecting ',' delimiter or object closing '}'"
                : (next == ",]")    ? "Expecting ',' delimiter or array closing ']'"
                : [ "Expecting JSON value(string, number, [true, false, null], object or array)"
                    , ch := SubStr(src, pos, (SubStr(src, pos)~="[\]\},\s]|$")-1) ][1]
                , ln, col, pos)

                throw Error(msg, -1, ch)
            }
            
            obj := stack[1]
            is_array := (obj is Array)
            
            if i := InStr("{[", ch) { ; start new object / map?
                val := (i = 1) ? Map() : Array()	; ahk v2
                
                is_array ? obj.Push(val) : obj[key] := val
                stack.InsertAt(1,val)
                
                next := '"' ((is_key := (ch == "{")) ? "}" : "{[]0123456789-tfn")
            } else if InStr("}]", ch) {
                stack.RemoveAt(1)
                next := (stack[1]==tree) ? "" : (stack[1] is Array) ? ",]" : ",}"
            } else if InStr(",:", ch) {
                is_key := (!is_array && ch == ",")
                next := is_key ? '"' : '"{[0123456789-tfn'
            } else { ; string | number | true | false | null
                if (ch == '"') { ; string
                    i := pos
                    while i := InStr(src, '"',, i+1) {
                        val := StrReplace(SubStr(src, pos+1, i-pos-1), "\\", "\u005C")
                        if (SubStr(val, -1) != "\")
                            break
                    }
                    if !i ? (pos--, next := "'") : 0
                        continue

                    pos := i ; update pos

                    val := StrReplace(val, "\/", "/")
                    val := StrReplace(val, '\"', '"')
                    , val := StrReplace(val, "\b", "`b")
                    , val := StrReplace(val, "\f", "`f")
                    , val := StrReplace(val, "\n", "`n")
                    , val := StrReplace(val, "\r", "`r")
                    , val := StrReplace(val, "\t", "`t")

                    i := 0
                    while i := InStr(val, "\",, i+1) {
                        if (SubStr(val, i+1, 1) != "u") ? (pos -= StrLen(SubStr(val, i)), next := "\") : 0
                            continue 2

                        xxxx := Abs("0x" . SubStr(val, i+2, 4)) ; \uXXXX - JSON unicode escape sequence
                        if (xxxx < 0x100)
                            val := SubStr(val, 1, i-1) . Chr(xxxx) . SubStr(val, i+6)
                    }
                    
                    if is_key {
                        key := val, next := ":"
                        continue
                    }
                } else { ; number | true | false | null
                    val := SubStr(src, pos, i := RegExMatch(src, "[\]\},\s]|$",, pos)-pos)
                    
                    if IsInteger(val)
                        val += 0
                    else if IsFloat(val)
                        val += 0
                    else if (val == "true" || val == "false")
                        val := (val == "true")
                    else if (val == "null")
                        val := ""
                    else if is_key {
                        pos--, next := "#"
                        continue
                    }
                    
                    pos += i-1
                }
                
                is_array ? obj.Push(val) : obj[key] := val
                next := obj == tree ? "" : is_array ? ",]" : ",}"
            }
        }
        
        return tree[1]
    }

    static Dump(obj, indent:="", lvl:=1) {
        if IsObject(obj) {
            If !(obj is Array || obj is Map || obj is String || obj is Number)
                throw Error("Object type not supported.", -1, Format("<Object at 0x{:p}>", ObjPtr(obj)))
            
            if IsInteger(indent)
            {
                if (indent < 0)
                    throw Error("Indent parameter must be a postive integer.", -1, indent)
                spaces := indent, indent := ""
                
                Loop spaces ; ===> changed
                    indent .= " "
            }
            indt := ""
            
            Loop indent ? lvl : 0
                indt .= indent
            
            is_array := (obj is Array)
            
            lvl += 1, out := "" ; Make #Warn happy
            for k, v in obj {
                if IsObject(k) || (k == "")
                    throw Error("Invalid object key.", -1, k ? Format("<Object at 0x{:p}>", ObjPtr(obj)) : "<blank>")
                
                if !is_array ;// key ; ObjGetCapacity([k], 1)
                    out .= (ObjGetCapacity([k]) ? Jxon.Dump(k) : escape_str(k)) (indent ? ": " : ":") ; token + padding
                
                out .= Jxon.Dump(v, indent, lvl) ; value
                    .  ( indent ? ",`n" . indt : "," ) ; token + indent
            }

            if (out != "") {
                out := Trim(out, ",`n" . indent)
                if (indent != "")
                    out := "`n" . indt . out . "`n" . SubStr(indt, StrLen(indent)+1)
            }
            
            return is_array ? "[" . out . "]" : "{" . out . "}"
        
        } Else If (obj is Number)
            return obj
        
        Else ; String
            return escape_str(obj)
        
        escape_str(obj) {
            obj := StrReplace(obj,"\","\\")
            obj := StrReplace(obj,"`t","\t")
            obj := StrReplace(obj,"`r","\r")
            obj := StrReplace(obj,"`n","\n")
            obj := StrReplace(obj,"`b","\b")
            obj := StrReplace(obj,"`f","\f")
            obj := StrReplace(obj,"/","\/")
            obj := StrReplace(obj,'"','\"')
            
            return '"' obj '"'
        }
    }    
}

/**
 * An ordered Map implementation
 * https://autohotkey.com/boards/viewtopic.php?f=82&t=94114&p=418207
 */
Class OrderedMap extends Map {
    __New(KVPairs*) {
        super.__New(KVPairs*)

        KeyArray := []
        keyCount := KVPairs.Length // 2
        KeyArray.Length := keyCount

        Loop keyCount
            KeyArray[A_Index] := KVPairs[(A_Index << 1) - 1]

        this.KeyArray := KeyArray
    }

    __Item[key] {
        set {
            if !this.Has(key)
                this.KeyArray.Push(key)

            return super[key] := value
        }
    }

    Clear() {
        super.Clear()
        this.KeyArray := []
    }

    Clone() {
        Other := super.Clone()
        Other.KeyArray := this.KeyArray.Clone()
        return Other
    }

    Delete(key) {
        try {
            RemovedValue := super.Delete(key)

            CaseSense := this.CaseSense
            for i, Element in this.KeyArray {
                areSame := (Element is String)
                    ? !StrCompare(Element, key, CaseSense)
                    : (Element = key)

                if areSame {
                    this.KeyArray.RemoveAt(i)
                    break
                }
            }

            return RemovedValue
        }
        catch Error as Err
            throw Error(Err.Message, -1, Err.Extra)
    }

    Set(KVPairs*) {
        if (KVPairs.Length & 1)
            throw ValueError('Invalid number of parameters.', -1)

        KeyArray := this.KeyArray
        keyCount := KVPairs.Length // 2
        KeyArray.Capacity += keyCount

        Loop keyCount {
            key := KVPairs[(A_Index << 1) - 1]

            if !this.Has(key)
                KeyArray.Push(key)
        }

        super.Set(KVPairs*)

        return this
    }

    __Enum(*) {
        keyEnum := this.KeyArray.__Enum(1)

        keyValEnum(&key := unset, &val := unset) {
            if keyEnum(&key) {
                val := this[key]
                return true
            } else {
                return false
            }
        }

        return keyValEnum
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

Class KomorebiState {
    static FocusedMonitor := -1
    static FocusedWorkspace := -1
    static FocusedLayout := "Uninitialized"
    static NumberOfWorkspaces := Map()
    static IsPaused := false
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
 * Function to process messages received from the Komorebi IPC pipe.
 * @param {String} msg The message received from the pipe
 * @param {Integer} bytesRead The number of bytes read from the pipe
 */
OnKomorebiPipeEvent(msg, bytesRead) {
    global lastMonitorId

    jsonObj := Jxon.Load(&msg)
    eventName := jsonObj["event"]["type"]
    
    ; Keep in memory to compare against new values!
    _prevLayout := KomorebiState.FocusedLayout
    _prevMonitor := KomorebiState.FocusedMonitor
    
    ; Extract new state values from the msg
    KomorebiState.IsPaused := (SGlob.GetMapValue(jsonObj, "state", "is_paused") == 1)
    
    ; These values need their sanity checks. Seems they love to bug out when no monitor
    ; is connected...
    KomorebiState.FocusedMonitor := SGlob.GetMapValue(jsonObj, "state", "monitors", "focused")
    if (KomorebiState.FocusedMonitor == "")
        return
    KomorebiState.FocusedWorkspace := SGlob.GetMapValue(jsonObj, "state", "monitors", "elements", KomorebiState.FocusedMonitor + 1, "workspaces", "focused")
    if (KomorebiState.FocusedWorkspace == "")
        return
    KomorebiState.FocusedLayout := SGlob.GetMapValue(jsonObj, "state", "monitors", "elements", KomorebiState.FocusedMonitor + 1, "workspaces", "elements", KomorebiState.FocusedWorkspace + 1, "layout", "Default")
    if (KomorebiState.FocusedLayout == "")
        return

    ; Automatically determine the number of workspaces on each monitor.
    ; Supersedes the manually configured NumberOfWorkspaces ini setting
    ; because it allows for differing number of workspaces per monitor.
    mCnt := 0
    for monitor in SGlob.GetMapValue(jsonObj, "state", "monitors", "elements") {
        wCnt := monitor["workspaces"]["elements"].Length
        KomorebiState.NumberOfWorkspaces[mCnt] := wCnt
        mCnt++
    }

    ; Ensure that, depending on the layout, we get the proper ratios.
    if (_prevLayout != KomorebiState.FocusedLayout) {
        switch KomorebiState.FocusedLayout {
            case "HorizontalStack":
                SGlob.Komorebic("layout-ratios --columns 0.5 --rows 0.7 0.3")
            case "VerticalStack":
                SGlob.Komorebic("layout-ratios --columns 0.6 0.4 --rows 0.5")
            default:
                SGlob.Komorebic("layout-ratios --columns 0.5 --rows 0.5")
        }
    }

    switch eventName {
        case "CycleFocusMonitor",
            "CycleFocusWorkspace",
            "FocusMonitorNumber",
            "FocusMonitorWorkspaceNumber",
            "FocusWorkspaceNumber":

            ; Update where the cursor is right now.
            ; This is different from KomorebiState.FocusedMonitor,
            ; because the cursor doesn't necessarily have to be on the
            ; same monitor...
            SGlob.GetCurrentMonitorNum(&lastMonitorId, useZeroBasedIndex := true)

            eventValue := SGlob.GetMapValue(jsonObj, "event", "content")

            if (eventName == "FocusMonitorNumber" ||
                eventName == "FocusMonitorWorkspaceNumber")
                monitorId := IsObject(eventValue) ? eventValue[1] : eventValue
            if (eventName == "CycleFocusMonitor") {
                monitorId := lastMonitorId + (eventValue == "Previous" ? -1 : 1)

                ; Wrap around the monitor index if it goes out of bounds
                if (monitorId < 0)
                    monitorId := KomorebiState.NumberOfWorkspaces.Count - 1
                if (monitorId > KomorebiState.NumberOfWorkspaces.Count - 1)
                    monitorId := 0
            }

            if (SGlob.HandleCursorOnMonitorChange && lastMonitorId != monitorId) {
                SGlob.SetCursorToMonitorNum(monitorId, useZeroBasedIndex := true)
                lastMonitorId := monitorId
            }

            ; Only run FocusDesktopWorkaround if there is no active window.
            hwnd := WinActive("A")

            ; On cycle-monitor we'll try to force the focus if there is a window
            ; on the new monitor...
            if (eventName == "CycleFocusMonitor") {
                if (hwnd) {
                    WinGetPos(&hwnd_x, &hwnd_y, &hwnd_w, &hwnd_h, "ahk_id " . hwnd)
                    hwnd_mon := SGlob.GetMonitorByXYCoord(hwnd_x + hwnd_w // 2, hwnd_y + hwnd_h // 2, useZeroBasedIndex := true)

                    if(hwnd_mon != -1 && hwnd_mon.monitorIndex != lastMonitorId)
                        SGlob.Komorebic("force-focus")
                }
            }

            if (hwnd)
                return

            ; This workaround prevents windows from spawning on the wrong workspace.
            ; Primarily required if you are using Raycast.
            ;
            ; Note: Raycast 0.45 does not accept FocusDesktopWorkaround anymore,
            ;       however creating a pseudo window and focusing it seems to
            ;       achieve the desired result.
            OutputDebug(Format("No active window detected after {} event, running FocusPseudoWindowWorkaround.", eventName))
            SGlob.FocusPseudoWindowWorkaround()
            ; Focus desktop anyway to ensure taskbar auto-hide works properly.
            SGlob.FocusDesktopWorkaround()
        default:
            ;OutputDebug(Format("Ignoring incoming event type: {}", eventName))
    }
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
    global ProcessExitCallback
    global komoPipeListener

    ; Only process the following exitReasons
    validReasons := "Logoff Close Exit Reload Single Menu"

    ; Exit if the exitReason is not in the validReasons list
    if (!InStr(validReasons, exitReason, 0, 1, 1))
        return 0

    ; Unregister callbacks
    if (ProcessExitCallback)
        CallbackFree(ProcessExitCallback)

    ; Unregister appbars
    for barHwnd in SGlob.RegisteredAppBars {
        SGlob.UnregisterHwndAsAppBar(barHwnd)
    }

    ; Kill applications
    SGlob.KillApplications()

    ; Unsubscribe from Komorebi IPC events
    SGlob.Komorebic(Format("unsubscribe-pipe {}", SGlob.KomorebiPipeName))

    ; Unregister IPC listener
    komoPipeListener.Stop()

    OutputDebug(Format("{} / Script exiting with reason: `"{}`" and code: {}", FormatTime(, "yyyy-MM-dd, HH:mm:ss"), exitReason, exitCode))

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

; Debugging output to pinpoint performance issues. Please leave this in!
OutputDebug(Format("{} / SCRIPT INIT START", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; Pre-determines the monitor where the cursor is initially located.
lastMonitorId := -1
SGlob.GetCurrentMonitorNum(&lastMonitorId, useZeroBasedIndex := true)
OutputDebug(Format("{} / Finished GetCurrentMonitorNum", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

SGlob.AdjustTray()
OutputDebug(Format("{} / Finished AdjustTray", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

SGlob.FillIgnoredProcessesGroup()
OutputDebug(Format("{} / Finished FillIgnoredProcessesGroup", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

SGlob.UpdateAltSnapBlacklistProcesses()
OutputDebug(Format("{} / Finished UpdateAltSnapBlacklistProcesses", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

/**
 * Initialize the Hotkey List helper window
 */
hkHelper := HotkeyListHelper()
OutputDebug(Format("{} / Finished HotkeyListHelper init", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

/**
 * Since Komorebi does not close the AutoHotkey script despite using the --ahk
 * flag, the most resource-efficient way to close the script is to wait for
 * Komorebi to exit and then receive a callback to close the script.
 * @type {Integer}
 */
ProcessExitCallback := CallbackCreate(OnProcessExit)
OutputDebug(Format("{} / Finished ProcessExitCallback creation", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; Check if Komorebi is running and register a callback to be notified
; when it exits.
WaitForKomorebiExit()
OutputDebug(Format("{} / Finished WaitForKomorebiExit", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; ---

; Initialize the IPC Pipe Listener
komoPipeListener := NamedPipeListener(Format("\\.\pipe\{}", SGlob.KomorebiPipeName), 25, 4096)
komoPipeListener.OnMessage := OnKomorebiPipeEvent
komoPipeListener.Start()
OutputDebug(Format("{} / Finished Named Pipe Listener init", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; Subscribe to Komorebi IPC events
SGlob.Komorebic(Format("subscribe-pipe {}", SGlob.KomorebiPipeName))
OutputDebug(Format("{} / Finished komorebic subscribe-pipe", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; ---

; Run additional programs configured in the ini file
SGlob.RunAdditionalApplications()
OutputDebug(Format("{} / Finished RunAdditionalApplications", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; ---

; Register all Komorebi Bars as app bars.
; Normally, this happens on WM_DISPLAYCHANGE, however for the initial
; startup, we need to do this manually.
SGlob.RegisterKomorebiBarsAsAppBars()
OutputDebug(Format("{} / Finished RegisterKomorebiBarsAsAppBars", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; -----------------------------------------------------------------------------
; Workarounds                                                                 |
; -----------------------------------------------------------------------------

SGlob.TouchKomorebiBarConfig()
OutputDebug(Format("{} / Finished TouchKomorebiBarConfig", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

; -----------------------------------------------------------------------------
; Basic Options                                                               |
; -----------------------------------------------------------------------------

; Enable hot reloading of changes to this file
SGlob.Komorebic("watch-configuration enable")
OutputDebug(Format("{} / Finished komorebic watch-configuration enable", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

OutputDebug(Format("{} / SCRIPT INIT FINISHED!", FormatTime(, "yyyy-MM-dd, HH:mm:ss")))

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
; Also make sure to wrap the hotkey action into a function with a unique name
; so it can be referenced in the hotkey list window. If the hotkey does not have
; a function name, it will not be shown in the hotkey list window, even if
; it has a comment with a description.

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Overlays                                                                    |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Disables zoom via Ctrl + Mouse Wheel in Vivaldi when the window is active.
 * @ignore
 */
#HotIf WinActive("ahk_exe vivaldi.exe")
^WheelUp::
^WheelDown::
overlayVivaldiZoom(hk) {
    ; Just occupy this event so it does not propagate to the browser
}

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
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!H::
toggleHotkeyListWindow(hk) {
    hkHelper.ToggleWindow()
}

/**
 * Reload the AutoHotkey Script
 * (Win + Alt + A)
 * @context General
 * @keyword ahk autohotkey script reload bar
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!A::
reloadAhkScript(hk) {
    Reload()
}

/**
 * Reload the Komorebi Configuration
 * (Win + Alt + R)
 * @context Komorebi
 * @keyword replace-configuration reload
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!R::
reloadKomorebiConfig(hk) {
    cmd := SGlob.ResolveEnvironmentVariables("replace-configuration %KOMOREBI_CONFIG_HOME%\komorebi.json")
    SGlob.Komorebic(cmd)
}

/**
 * Touch the Komorebi Bar Configuration
 * (Win + Alt + B)
 * @context General
 * @keyword touch komorebi bar configuration
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!B::
touchKomorebiBar(hk) {
    SGlob.TouchKomorebiBarConfig()
}

/**
 * Restores the last minimized window
 * @context General
 * @keyword restore minimized window
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Numpad0::
restoreWindow(hk) {
    SGlob.RestoreWindow()
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
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Enter::
launchTerminal(hk) {
    SGlob.RunDefaultApplication("Terminal")
}

/**
 * Launch Editor
 * (Win + Shift + Enter)
 * @context General
 * @keyword editor application launch
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Enter::
launchEditor(hk) {
    SGlob.RunDefaultApplication("Editor")
}

/**
 * Launch Search
 * (Win + Ctrl + Enter)
 * @context General
 * @keyword search application launch
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#^Enter::
launchSearch(hk) {
    SGlob.RunDefaultApplication("Search")
}

/**
 * Launch Browser
 * (Win + Backspace)
 * @context General
 * @keyword browser application launch
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Backspace::
launchBrowser(hk) {
    SGlob.RunDefaultApplication("Browser")
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
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Q::
eagerFocusWavebox(hk) {
    SGlob.Komorebic("eager-focus wavebox.exe")
}

/**
 * Eager Focus Vivaldi
 * (Win + W)
 * @context Komorebi
 * @keyword eager-focus vivaldi browser
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#W::
eagerFocusVivaldi(hk) {
    SGlob.Komorebic("eager-focus vivaldi.exe")
}

/**
 * Eager Focus mpv
 * (Win + A)
 * @context Komorebi
 * @keyword eager-focus mpv
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#A::
eagerFocusMpv(hk) {
    SGlob.Komorebic("eager-focus mpv.exe")
}

/**
 * Eager Focus VS Code
 * (Win + S)
 * @context Komorebi
 * @keyword eager-focus vscode
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#S::
eagerFocusVsCode(hk) {
    SGlob.Komorebic("eager-focus Code.exe")
}

/**
 * Eager Focus Multiplicity RDP
 * (Win + Y)
 * @context Komorebi
 * @keyword eager-focus multiplicity rdp
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Y::
eagerFocusMultiplicityRdp(hk) {
    SGlob.Komorebic("eager-focus MPRDP64.exe")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Window Management                                                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Promote current window
 * (Win + Shift + P)
 * @context Komorebi
 * @keyword promote window
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+P::
promoteWindow(hk) {
    SGlob.Komorebic("promote")
}

/**
 * Toggle Maximize for Current Window
 * (Win + Insert)
 * @context Komorebi
 * @keyword toggle-maximize window
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Insert::
toggleMaximize(hk){
    SGlob.Komorebic("toggle-maximize")
}

/**
 * Minimize Current Window
 * (Win + Delete)
 * @context Komorebi
 * @keyword minimize window
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Delete::
minimizeWindow(hk){
    SGlob.MinimizeWindow()
}

/**
 * Close Window
 * (Win + Escape)
 * @context Komorebi
 * @keyword close window
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Escape::
closeWindow(hk){
    SGlob.Komorebic("close")
}

/**
 * Center Regular Active Window
 * (Win + Shift + C)
 * @context Komorebi General
 * @keyword center-active-window
 * @disabled
 */
/*
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+C::
centerRegularActiveWindow(hk) {
    SGlob.CenterActiveWindow()
}
*/

/**
 * Retile
 * (Alt + Shift + R)
 * @context Komorebi
 * @keyword retile
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+R::
retile(hk) {
    SGlob.Komorebic("retile")
}

/**
 * Enforce Workspace Rules
 * (Alt + Shift + E)
 * @context Komorebi
 * @keyword enforce-workspace-rules
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+E::
enforceWorkspaceRules(hk) {
    SGlob.Komorebic("enforce-workspace-rules")
}

/**
 * Toggle Pause
 * (Alt + Shift + P)
 * @context Komorebi
 * @keyword toggle-pause
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+P::
togglePause(hk) {
    SGlob.Komorebic("toggle-pause")
}

/**
 * Toggle Mouse follows Focus
 * (Alt + Shift + F)
 * @context Komorebi
 * @keyword toggle-mouse-follows-focus
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+F::
toggleMouseFollowsFocus(hk) {
    SGlob.Komorebic("toggle-mouse-follows-focus")
}

/**
 * Toggle Workspace Layer
 * (Win + Alt + Space)
 * @context Komorebi
 * @keyword toggle-workspace-layer
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!Space::
toggleWorkspaceLayer(hk) {
    SGlob.Komorebic("toggle-workspace-layer")
}

/**
 * Toggle Float for Workspace
 * (Win + Shift + Space)
 * @context Komorebi
 * @keyword toggle-float-override
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Space::
toggleFloatOverride(hk) {
    SGlob.Komorebic("toggle-float-override")
}

/**
 * Toggle Float Mode
 * (Alt + Shift + Space)
 * @context Komorebi
 * @keyword toggle-float
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+Space::
toggleFloat(hk) {
    SGlob.Komorebic("toggle-float")
}

/**
 * Toggle Monocle Mode
 * (Alt + Shift + M)
 * @context Komorebi
 * @keyword toggle-monocle
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+M::
toggleMonocle(hk) {
    SGlob.Komorebic("toggle-monocle")
}

/**
 * Re-initialize the Komorebi Bar manually
 * (Win + Shift + S)
 * @context General
 * @keyword komorebi-bar display
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+S::
reinitializeKomorebiBar(hk) {
    SGlob.RunOrKillKomorebiBarOnDisplayChange()
    SGlob.RegisterKomorebiBarsAsAppBars()
}

/**
 * Stop Komorebi
 * (Win + Alt + X)
 * @context Komorebi
 * @keyword stop bar ahk
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!X::
stopKomorebi(hk) {
    SGlob.Komorebic("stop --bar --ahk")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Change the focused window, Alt + ←↑↓→                                       |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Change the Focused Window (Left)
 * @context Komorebi
 * @keyword focus left scroll left
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!Left::
#!WheelUp::
focusLeft(hk) {
    SGlob.Komorebic("focus left")
}

/**
 * Change the Focused Window (Down)
 * @context Komorebi
 * @keyword focus down
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!Down::
focusDown(hk) {
    SGlob.Komorebic("focus down")
}

/**
 * Change the Focused Window (Up)
 * @context Komorebi
 * @keyword focus up
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!Up::
focusUp(hk) {
    SGlob.Komorebic("focus up")
}

/**
 * Change the Focused Window (Right)
 * @context Komorebi
 * @keyword focus right scroll right
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!Right::
#!WheelDown::
focusRight(hk) {
    SGlob.Komorebic("focus right")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Move the focused window in a given direction, Alt + Shift + ←↑↓→            |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Move the Focused Window in a given Direction (Left)
 * @context Komorebi
 * @keyword move left
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+Left::
moveLeft(hk) {
    SGlob.Komorebic("move left")
}

/**
 * Move the Focused Window in a given Direction (Down)
 * @context Komorebi
 * @keyword move down
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+Down::
moveDown(hk) {
    SGlob.Komorebic("move down")
}

/**
 * Move the Focused Window in a given Direction (Up)
 * @context Komorebi
 * @keyword move up
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+Up::
moveUp(hk) {
    SGlob.Komorebic("move up")
}

/**
 * Move the Focused Window in a given Direction (Right)
 * @context Komorebi
 * @keyword move right
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
!+Right::
moveRight(hk) {
    SGlob.Komorebic("move right")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Resize Windows (Win + Shift + ←↑↓→)                                         |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Resize Windows (Increase Width)
 * @context Komorebi
 * @keyword resize-axis horizontal increase
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Right::
resizeAxisHorizontalIncrease(hk) {
    SGlob.Komorebic("resize-axis horizontal increase")
}

/**
 * Resize Windows (Decrease Width)
 * @context Komorebi
 * @keyword resize-axis horizontal decrease
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Left::
resizeAxisHorizontalDecrease(hk) {
    SGlob.Komorebic("resize-axis horizontal decrease")
}

/**
 * Resize Windows (Increase Height)
 * @context Komorebi
 * @keyword resize-axis vertical increase
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Up::
resizeAxisVerticalIncrease(hk) {
    SGlob.Komorebic("resize-axis vertical increase")
}

/**
 * Resize Windows (Decrease Height)
 * @context Komorebi
 * @keyword resize-axis vertical decrease
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+Down::
resizeAxisVerticalDecrease(hk) {
    SGlob.Komorebic("resize-axis vertical decrease")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Cycle through the Workspace (Win + MWheelUp/MWheelDown)                     |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Cycle Workspace (Previous)
 * @context Komorebi
 * @keyword cycle-workspace previous
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#WheelUp::
cycleWorkspacePrevious(hk) {
    global lastMonitorId
    monitor := SGlob.GetCurrentMonitorByCursorPosition(useZeroBasedIndex := true)
    if (monitor != -1) {
        if (lastMonitorId != monitor.monitorIndex) {
            lastMonitorId := monitor.monitorIndex
            SGlob.Komorebic("focus-monitor-at-cursor")
        }
    }
    SGlob.Komorebic("cycle-workspace previous")
}

/**
 * Cycle Workspace (Next)
 * @context Komorebi
 * @keyword cycle-workspace next
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#WheelDown::
cycleWorkspaceNext(hk) {
    global lastMonitorId
    monitor := SGlob.GetCurrentMonitorByCursorPosition(useZeroBasedIndex := true)
    if (monitor != -1) {
        if (lastMonitorId != monitor.monitorIndex) {
            lastMonitorId := monitor.monitorIndex            
            SGlob.Komorebic("focus-monitor-at-cursor")
        }
    }
    SGlob.Komorebic("cycle-workspace next")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Set Layouts (Win + Alt + ←↑→)                                               |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Change Layout (bsp)
 * @context Komorebi
 * @keyword set-layout bsp
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!Up::
changeLayoutBsp(hk) {
    SGlob.Komorebic("change-layout bsp")
}

/**
 * Change Layout (horizontal-stack)
 * @context Komorebi
 * @keyword set-layout horizontal-stack
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!Left::
changeLayoutHorizontalStack(hk) {
    SGlob.Komorebic("change-layout horizontal-stack")
}

/**
 * Change Layout (vertical-stack)
 * @context Komorebi
 * @keyword set-layout vertical-stack
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#!Right::
changeLayoutVerticalStack(hk) {
    SGlob.Komorebic("change-layout vertical-stack")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Flip Layout (Win + PgUp/PgDn)                                               |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Flip Layout (Horizontal)
 * @context Komorebi
 * @keyword flip-layout horizontal
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#PgUp::
flipLayoutHorizontal(hk) {
    SGlob.Komorebic("flip-layout horizontal")
}

/**
 * Flip Layout (Vertical)
 * @context Komorebi
 * @keyword flip-layout vertical
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#PgDn::
flipLayoutVertical(hk) {
    SGlob.Komorebic("flip-layout vertical")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Stack Windows (Ctrl + Win + ←↑↓→)                                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Stack Windows (Left)
 * @context Komorebi
 * @keyword stack left
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#Left::
stackWindowsLeft(hk) {
    SGlob.Komorebic("stack left")
}

/**
 * Stack Windows (Down)
 * @context Komorebi
 * @keyword stack down
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#Down::
stackWindowsDown(hk) {
    SGlob.Komorebic("stack down")
}

/**
 * Stack Windows (Up)
 * @context Komorebi
 * @keyword stack up
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#Up::
stackWindowsUp(hk) {
    SGlob.Komorebic("stack up")
}

/**
 * Stack Windows (Right)
 * @context Komorebi
 * @keyword stack right
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#Right::
stackWindowsRight(hk) {
    SGlob.Komorebic("stack right")
}

/**
 * Unstack Windows
 * @context Komorebi
 * @keyword unstack
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#-::
unstackWindows(hk) {
    SGlob.Komorebic("unstack")
}

/**
 * Cycle through the Stack of Windows (Previous)
 * @context Komorebi
 * @keyword cycle-stack previous
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#,::
cycleStackPrevious(hk) {
    SGlob.Komorebic("cycle-stack previous")
}

/**
 * Cycle through the Stack of Windows (Next)
 * @context Komorebi
 * @keyword cycle-stack next
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
^#.::
cycleStackNext(hk) {
    SGlob.Komorebic("cycle-stack next")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Cycle through monitors (Win + Pos1/End)                                     |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Cycle through Monitors (Next)
 * @context Komorebi
 * @keyword cycle-monitor next
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#Home::
cycleMonitorNext(hk) {
    SGlob.Komorebic("cycle-monitor next")
}

/**
 * Cycle through Monitors (Previous)
 * @context Komorebi
 * @keyword cycle-monitor previous
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#End::
cycleMonitorPrevious(hk) {
    SGlob.Komorebic("cycle-monitor previous")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Focus Monitor (Win + F1/F2)                                                 |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Focus Monitor (0)
 * @context Komorebi
 * @keyword focus-monitor 0
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#F1::
focusMonitor0(hk) {
    SGlob.Komorebic("focus-monitor 0")
}

/**
 * Focus Monitor (1)
 * @context Komorebi
 * @keyword focus-monitor 1
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#F2::
focusMonitor1(hk) {
    SGlob.Komorebic("focus-monitor 1")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Send to Monitor (Win + Shift + F1/F2)                                       |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Send to Monitor (0)
 * @context Komorebi
 * @keyword send-to-monitor 0
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+F1::
sendToMonitor0(hk) {
    SGlob.Komorebic("send-to-monitor 0")
}

/**
 * Send to Monitor (1)
 * @context Komorebi
 * @keyword send-to-monitor 1
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+F2::
sendToMonitor1(hk) {
    SGlob.Komorebic("send-to-monitor 1")
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Send to Workspace 1-9 (same monitor, Win + Shift + 1-9)                     |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Send to Workspace 1 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 0
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+1::
#+Numpad1::
sendToWorkspace1(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 1, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 2 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 1
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+2::
#+Numpad2::
sendToWorkspace2(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 2, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 3 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 2
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+3::
#+Numpad3::
sendToWorkspace3(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 3, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 4 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 3
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+4::
#+Numpad4::
sendToWorkspace4(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 4, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 5 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 4
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+5::
#+Numpad5::
sendToWorkspace5(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 5, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 6 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 5
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+6::
#+Numpad6::
sendToWorkspace6(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 6, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 7 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 6
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+7::
#+Numpad7::
sendToWorkspace7(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 7, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 8 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 7
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+8::
#+Numpad8::
sendToWorkspace8(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 8, useZeroBasedIndex := false)
}

/**
 * Send to Workspace 9 (Same Monitor)
 * @context Komorebi
 * @keyword move-to-workspace 8
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#+9::
#+Numpad9::
sendToWorkspace9(hk) {
    SGlob.CheckWorkspaceAndExecute("move-to-workspace", 9, useZeroBasedIndex := false)
}

; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
; Switch to Workspace 1-9 (same monitor, Win + 1-9)                           |
; - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/**
 * Switch to Workspace 1 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 0
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#1::
#Numpad1::
switchToWorkspace1(hk) {
    SGlob.FocusCurrentMonitorWorkspace(1, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 2 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 1
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#2::
#Numpad2::
switchToWorkspace2(hk) {
    SGlob.FocusCurrentMonitorWorkspace(2, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 3 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 2
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#3::
#Numpad3::
switchToWorkspace3(hk) {
    SGlob.FocusCurrentMonitorWorkspace(3, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 4 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 3
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#4::
#Numpad4::
switchToWorkspace4(hk) {
    SGlob.FocusCurrentMonitorWorkspace(4, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 5 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 4
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#5::
#Numpad5::
switchToWorkspace5(hk) {
    SGlob.FocusCurrentMonitorWorkspace(5, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 6 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 5
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#6::
#Numpad6::
switchToWorkspace6(hk) {
    SGlob.FocusCurrentMonitorWorkspace(6, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 7 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 6
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#7::
#Numpad7::
switchToWorkspace7(hk) {
    SGlob.FocusCurrentMonitorWorkspace(7, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 8 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 7
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#8::
#Numpad8::
switchToWorkspace8(hk) {
    SGlob.FocusCurrentMonitorWorkspace(8, useZeroBasedIndex := false)
}

/**
 * Switch to Workspace 9 (Same Monitor)
 * @context Komorebi
 * @keyword focus-workspace 8
 */
#HotIf !WinActive("ahk_group KomoIgnoreProcesses")
#9::
#Numpad9::
switchToWorkspace9(hk) {
    SGlob.FocusCurrentMonitorWorkspace(9, useZeroBasedIndex := false)
}

/* ----------------------------------------------------------------------------
| Reference of original key bindings from Komorebi's AutoHotkey script        |
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
