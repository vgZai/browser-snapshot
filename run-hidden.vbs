' usage: wscript run-hidden.vbs <reason>
Dim sh, dir: Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\snapshot.ps1"" -Reason " & WScript.Arguments(0), 0, False
