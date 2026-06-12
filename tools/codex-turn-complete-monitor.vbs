Option Explicit

Dim shell, fso, scriptDir, ps1Path, command, i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "codex-turn-complete-monitor.ps1")

command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File " & Q(ps1Path)
For i = 0 To WScript.Arguments.Count - 1
    command = command & " " & Q(WScript.Arguments(i))
Next

shell.Run command, 0, False

Function Q(value)
    Q = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
