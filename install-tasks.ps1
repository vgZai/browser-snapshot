#Requires -Version 5.1
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vbs = Join-Path $Root 'run-hidden.vbs'
$Restore = Join-Path $Root 'restore.ps1'
$Wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$TaskLogon = 'BrowserSnapshot-Logon'
$Task3h = 'BrowserSnapshot-3h'

function Get-ShortcutPath {
  Join-Path ([Environment]::GetFolderPath('Desktop')) 'Browser Snapshot.lnk'
}

function Remove-TaskIfExists([string]$Name) {
  if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
  }
}

if ($Uninstall) {
  Remove-TaskIfExists $TaskLogon
  Remove-TaskIfExists $Task3h
  $lnk = Get-ShortcutPath
  if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
  Write-Host 'Removed Browser Snapshot scheduled tasks and desktop shortcut.'
  return
}

if (-not (Test-Path -LiteralPath $Vbs)) { throw "Missing $Vbs" }
if (-not (Test-Path -LiteralPath $Restore)) { throw "Missing $Restore" }

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$actionLogon = New-ScheduledTaskAction -Execute $Wscript -Argument ('"{0}" logon' -f $Vbs)
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask -TaskName $TaskLogon -Action $actionLogon -Trigger $trigLogon -Principal $principal -Settings $settings -Force | Out-Null

$action3h = New-ScheduledTaskAction -Execute $Wscript -Argument ('"{0}" periodic' -f $Vbs)
$trig3h = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName $Task3h -Action $action3h -Trigger $trig3h -Principal $principal -Settings $settings -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell
$lnkPath = Get-ShortcutPath
$lnk = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Restore
$lnk.WorkingDirectory = $Root
$ico = Join-Path $Root 'snapshot.ico'
if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
$lnk.Description = 'Browser Snapshot'
$lnk.Save()

Write-Host "Installed scheduled tasks '$TaskLogon' and '$Task3h'."
Write-Host "Desktop shortcut: $lnkPath"
Write-Host 'A first snapshot will run at the next logon, and every 3 hours after that. You can also click Snapshot now in the app.'
