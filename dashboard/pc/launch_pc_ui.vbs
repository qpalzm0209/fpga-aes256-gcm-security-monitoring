Option Explicit

Dim shell, fso, baseDir, batchPath, dashboardUrl
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
batchPath = fso.BuildPath(baseDir, "run_pc_ui.bat")
dashboardUrl = FindRunningDashboard()

If Len(dashboardUrl) > 0 Then
    shell.Run dashboardUrl, 1, False
    WScript.Quit 0
End If

If Not fso.FileExists(batchPath) Then
    shell.Popup "run_pc_ui.bat was not found beside this launcher.", 0, "PC Dashboard", 16
    WScript.Quit 1
End If

shell.Run Chr(34) & batchPath & Chr(34), 0, False
WScript.Quit 0

Function FindRunningDashboard()
    Dim port, url, request, body
    FindRunningDashboard = ""

    For port = 8765 To 8784
        url = "http://127.0.0.1:" & port & "/"
        On Error Resume Next
        Err.Clear
        Set request = CreateObject("WinHttp.WinHttpRequest.5.1")
        request.SetTimeouts 150, 150, 150, 150
        request.Open "GET", url & "api/state", False
        request.Send
        If Err.Number = 0 Then
            If request.Status = 200 Then
                body = request.ResponseText
                If InStr(1, body, """jetson_attack""", vbTextCompare) > 0 And _
                   InStr(1, body, """occ""", vbTextCompare) > 0 Then
                    FindRunningDashboard = url
                    On Error GoTo 0
                    Exit Function
                End If
            End If
        End If
        On Error GoTo 0
    Next
End Function
