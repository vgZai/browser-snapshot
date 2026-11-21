param([switch]$ListOnly)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SnapRoot = Join-Path $Root 'snapshots'
$LogFile = Join-Path $Root 'logs\restore.log'

function Write-RestoreLog([string]$Message){
  $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
  $dir = Split-Path $LogFile
  if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Force -LiteralPath $dir | Out-Null }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $utf8)
}

function Get-BrowserConfig([string]$BrowserName){
  switch($BrowserName){
    'Chrome' { $pn='chrome';  $rel='Google\Chrome' }
    'Brave'  { $pn='brave';   $rel='BraveSoftware\Brave-Browser' }
    'Edge'   { $pn='msedge';  $rel='Microsoft\Edge' }
    default  { throw "Unknown browser: $BrowserName" }
  }
  $ud = Join-Path $env:LOCALAPPDATA ($rel + '\User Data')
  $exe = $null
  $prop = Get-ItemProperty ('HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\' + $pn + '.exe') -ErrorAction SilentlyContinue
  if($prop){ $exe = $prop.'(default)' }
  if(-not $exe -or -not (Test-Path -LiteralPath $exe)){
    $guesses = @{
      Chrome = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
      )
      Brave = @(
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe'
      )
      Edge = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
      )
    }[$BrowserName]
    $exe = $guesses | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
  [pscustomobject]@{
    Name = $BrowserName
    ProcessName = $pn
    UserData = $ud
    Sessions = Join-Path $ud 'Default\Sessions'
    Preferences = Join-Path $ud 'Default\Preferences'
    Exe = $exe
  }
}

function Get-BrowserProcesses([string]$ProcessName){
  @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

function Wait-BrowserGone([string]$ProcessName, [int]$TimeoutMs){
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    if((Get-BrowserProcesses $ProcessName).Count -eq 0){ return $true }
    Start-Sleep -Milliseconds 250
  } while($sw.ElapsedMilliseconds -lt $TimeoutMs)
  return ((Get-BrowserProcesses $ProcessName).Count -eq 0)
}

function Stop-BrowserForRestore([string]$BrowserName, [string]$ProcessName){
  $procs = Get-BrowserProcesses $ProcessName
  if($procs.Count -eq 0){
    Write-RestoreLog "$BrowserName is not running"
    return
  }
  Write-RestoreLog ("Closing {0} gracefully ({1} process(es): {2})" -f $BrowserName, $procs.Count, (($procs | ForEach-Object Id) -join ','))
  $procs | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | ForEach-Object {
    $_.CloseMainWindow() | Out-Null
  }
  if(Wait-BrowserGone $ProcessName 20000){
    Write-RestoreLog "$BrowserName exited after graceful close"
    return
  }
  Write-RestoreLog "$BrowserName still running after 20s; force-killing as last resort"
  Get-BrowserProcesses $ProcessName | Stop-Process -Force -ErrorAction SilentlyContinue
  if(Wait-BrowserGone $ProcessName 15000){
    Write-RestoreLog "$BrowserName exited after force-kill"
    return
  }
  $left = (Get-BrowserProcesses $ProcessName | ForEach-Object { $_.Id }) -join ', '
  throw ("Could not close {0}. Still running: PIDs {1}. Restore aborted; no session files were changed and the browser was not launched." -f $BrowserName, $left)
}

function Test-FileWritable([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){ return $true }
  try{
    $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    $fs.Dispose()
    return $true
  } catch {
    return $false
  }
}

function Wait-PathsWritable([string[]]$Paths, [int]$TimeoutMs){
  $existing = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    $locked = @($existing | Where-Object { -not (Test-FileWritable $_) })
    if($locked.Count -eq 0){ return }
    Start-Sleep -Milliseconds 250
  } while($sw.ElapsedMilliseconds -lt $TimeoutMs)
  $locked = @($existing | Where-Object { -not (Test-FileWritable $_) })
  if($locked.Count -gt 0){
    throw ("Timed out waiting for files to unlock: {0}" -f ($locked -join ', '))
  }
}

function Get-FileSha256([string]$Path){
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-SessionSnapshot([string]$SourceDir, [string]$SessionsDir){
  $srcFiles = @(Get-ChildItem -LiteralPath $SourceDir -File -ErrorAction Stop | Where-Object { $_.Name -match '^(Session|Tabs)_' })
  if($srcFiles.Count -eq 0){ throw "Snapshot has no Session_* / Tabs_* files: $SourceDir" }
  New-Item -ItemType Directory -Force -LiteralPath $SessionsDir | Out-Null

  $stage = Join-Path $env:TEMP ('bs-restore-stage-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -LiteralPath $stage | Out-Null
  try{
    foreach($f in $srcFiles){
      $staged = Join-Path $stage $f.Name
      Copy-Item -LiteralPath $f.FullName -Destination $staged -Force
      if((Get-Item -LiteralPath $staged).Length -ne $f.Length){ throw "Staging size mismatch: $($f.Name)" }
      if((Get-FileSha256 $staged) -ne (Get-FileSha256 $f.FullName)){ throw "Staging hash mismatch: $($f.Name)" }
    }
    Write-RestoreLog ("Staged and verified {0} snapshot file(s)" -f $srcFiles.Count)

    $existing = @(Get-ChildItem -LiteralPath $SessionsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Session|Tabs)_' })
    foreach($e in $existing){ Remove-Item -LiteralPath $e.FullName -Force }
    Write-RestoreLog ("Removed {0} existing session file(s) from {1}" -f $existing.Count, $SessionsDir)

    foreach($f in $srcFiles){
      $dest = Join-Path $SessionsDir $f.Name
      Copy-Item -LiteralPath (Join-Path $stage $f.Name) -Destination $dest -Force
      if(-not (Test-Path -LiteralPath $dest)){ throw "Copy missing destination: $($f.Name)" }
      if((Get-Item -LiteralPath $dest).Length -ne $f.Length){ throw "Destination size mismatch: $($f.Name)" }
      if((Get-FileSha256 $dest) -ne (Get-FileSha256 $f.FullName)){ throw "Destination hash mismatch: $($f.Name)" }
      Write-RestoreLog ("Copied {0} ({1} bytes, SHA256={2})" -f $f.Name, $f.Length, (Get-FileSha256 $dest))
    }
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Surgical Preferences patch: set profile.exit_type="Normal" and profile.exited_cleanly=true.
# Compact JSON is preserved exactly except for those two keys. UTF-8 no BOM.
function Patch-PreferencesExit([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){ throw "Preferences not found: $Path" }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $raw = [IO.File]::ReadAllText($Path, $utf8)
  $exitRe = [regex]'"exit_type"\s*:\s*"(Normal|Crashed|SessionEnded)"'
  $found = $exitRe.Matches($raw)
  if($found.Count -eq 0){ throw "No exit_type (Normal/Crashed/SessionEnded) in $Path" }
  if($found.Count -gt 1){
    Write-RestoreLog ("Warning: {0} exit_type keys in Preferences; patching all recognized values" -f $found.Count)
  }
  $raw2 = $exitRe.Replace($raw, '"exit_type":"Normal"')

  $raw2 = [regex]::Replace($raw2, '"exited_cleanly"\s*:\s*(true|false)\s*,\s*"exit_type":"Normal"', '"exited_cleanly":true,"exit_type":"Normal"')
  $raw2 = [regex]::Replace($raw2, '"exit_type":"Normal"\s*,\s*"exited_cleanly"\s*:\s*(true|false)', '"exit_type":"Normal","exited_cleanly":true')

  $adjacent = ('"exit_type":"Normal"\s*,\s*"exited_cleanly"\s*:\s*true', '"exited_cleanly"\s*:\s*true\s*,\s*"exit_type":"Normal"')
  $hasAdjacent = $false
  foreach($p in $adjacent){ if([regex]::IsMatch($raw2, $p)){ $hasAdjacent = $true; break } }
  if(-not $hasAdjacent){
    $token = '"exit_type":"Normal"'
    $idx = $raw2.IndexOf($token)
    if($idx -lt 0){ throw "exit_type replace failed in $Path" }
    $raw2 = $raw2.Insert($idx + $token.Length, ',"exited_cleanly":true')
  }

  try { $null = $raw2 | ConvertFrom-Json } catch { throw "Patched Preferences is not valid JSON: $($_.Exception.Message)" }

  $tmp = $Path + '.tmp'
  [IO.File]::WriteAllText($tmp, $raw2, $utf8)
  try {
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Invoke-SessionRestore([string]$BrowserName, [string]$SnapshotDir){
  $cfg = Get-BrowserConfig $BrowserName
  Write-RestoreLog ("Restore start: browser={0} snapshot={1}" -f $BrowserName, $SnapshotDir)
  if(-not $cfg.Exe){ throw "Could not find $BrowserName executable" }
  if(-not (Test-Path -LiteralPath $SnapshotDir)){ throw "Snapshot folder not found: $SnapshotDir" }

  Stop-BrowserForRestore $BrowserName $cfg.ProcessName
  Start-Sleep -Seconds 1
  if((Get-BrowserProcesses $cfg.ProcessName).Count -gt 0){
    $left = (Get-BrowserProcesses $cfg.ProcessName | ForEach-Object Id) -join ', '
    throw ("Refusing to launch {0} because it is still running (PIDs {1})." -f $BrowserName, $left)
  }

  $waitPaths = @($cfg.Preferences)
  if(Test-Path -LiteralPath $cfg.Sessions){
    $waitPaths += @(Get-ChildItem -LiteralPath $cfg.Sessions -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
  }
  Wait-PathsWritable $waitPaths 15000
  Write-RestoreLog "Browser gone and profile files unlocked"

  Copy-SessionSnapshot $SnapshotDir $cfg.Sessions
  Write-RestoreLog "Session files copied and verified"

  Patch-PreferencesExit $cfg.Preferences
  Write-RestoreLog ("Patched Preferences exit_type=Normal, exited_cleanly=true: {0}" -f $cfg.Preferences)

  if((Get-BrowserProcesses $cfg.ProcessName).Count -gt 0){
    $left = (Get-BrowserProcesses $cfg.ProcessName | ForEach-Object Id) -join ', '
    throw ("Refusing to launch {0}: a process reappeared before launch (PIDs {1}). Session files and Preferences may already have been updated." -f $BrowserName, $left)
  }

  Write-RestoreLog ("Launching {0}: {1} --restore-last-session" -f $BrowserName, $cfg.Exe)
  Start-Process -FilePath $cfg.Exe -ArgumentList '--restore-last-session' | Out-Null
  Write-RestoreLog "Restore finished (launched)"
}

# Dot-sourcing loads helpers only (for tests). Do not show the GUI or touch any browser.
if($MyInvocation.InvocationName -eq '.'){ return }

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Namespace BS -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h,int a,ref int v,int s);'
$Chrome = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -EA 0).'(default)'
if(-not $Chrome){ $Chrome='C:\Program Files (x86)\Google\Chrome\Application\chrome.exe' }

[BS.W]::SetProcessDPIAware() | Out-Null
[Windows.Forms.Application]::EnableVisualStyles()
$g=[Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k=$g.DpiX/96; $g.Dispose()
function P($x,$y){ New-Object Drawing.Point ([int]($x*$k)),([int]($y*$k)) }
function Z($w,$h){ New-Object Drawing.Size ([int]($w*$k)),([int]($h*$k)) }
$bg=[Drawing.Color]::FromArgb(30,31,34); $panel=[Drawing.Color]::FromArgb(43,45,49); $fg=[Drawing.Color]::FromArgb(230,230,230); $acc=[Drawing.Color]::FromArgb(88,184,72)
$form=New-Object Windows.Forms.Form
$form.Text='Browser Snapshot'; $form.ClientSize=(Z 620 420); $form.StartPosition='CenterScreen'; $form.BackColor=$bg; $form.ForeColor=$fg; $form.FormBorderStyle='FixedSingle'; $form.MaximizeBox=$false
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$ico=Join-Path $Root 'snapshot.ico'; if(Test-Path $ico){ $form.Icon=New-Object Drawing.Icon $ico }
$hdr=New-Object Windows.Forms.Label; $hdr.Text='Pick a snapshot to bring back every window and tab.'; $hdr.Location=(P 16 14); $hdr.Size=(Z 440 24); $hdr.ForeColor=[Drawing.Color]::FromArgb(170,170,170)
$list=New-Object Windows.Forms.ListBox; $list.Location=(P 16 44); $list.Size=(Z 588 300); $list.Font=New-Object Drawing.Font('Segoe UI',11); $list.BackColor=$panel; $list.ForeColor=$fg; $list.BorderStyle='None'; $list.IntegralHeight=$false
$list.DrawMode='OwnerDrawFixed'; $list.ItemHeight=[int](34*$k)
$list.Add_DrawItem({ param($s,$e) if($e.Index -lt 0){return}; $sel=($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
  $b=New-Object Drawing.SolidBrush ($(if($sel){$acc}else{$panel})); $e.Graphics.FillRectangle($b,$e.Bounds); $b.Dispose()
  $e.Graphics.TextRenderingHint='ClearTypeGridFit'
  $r=New-Object Drawing.RectangleF ($e.Bounds.X+10*$k),($e.Bounds.Y+7*$k),($e.Bounds.Width-20*$k),($e.Bounds.Height)
  $tb=New-Object Drawing.SolidBrush ($(if($sel){[Drawing.Color]::White}else{$fg})); $e.Graphics.DrawString($list.Items[$e.Index],$list.Font,$tb,$r); $tb.Dispose() })
$cmb=New-Object Windows.Forms.ComboBox; $cmb.DropDownStyle='DropDownList'; $cmb.FlatStyle='Flat'; $cmb.BackColor=$panel; $cmb.ForeColor=$fg; $cmb.Location=(P 474 10); $cmb.Size=(Z 130 28)
@('Chrome','Brave','Edge') | % { [void]$cmb.Items.Add($_) }; $cmb.SelectedIndex=0
$form.Controls.AddRange(@($hdr,$list,$cmb))
function B($t,$x,$primary){ $b=New-Object Windows.Forms.Button; $b.Text=$t; $b.Location=(P $x 360); $b.Size=(Z 140 40); $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.BackColor=$(if($primary){$acc}else{$panel}); $b.ForeColor=[Drawing.Color]::White; $b.Cursor='Hand'; $b }
$btnR=B 'Restore' 16 $true; $btnS=B 'Snapshot now' 166 $false; $btnF=B 'Open folder' 316 $false
$form.Controls.AddRange(@($btnR,$btnS,$btnF))
$script:items=@()

function Load-List{
  $list.Items.Clear(); $script:items=@()
  $bn=$cmb.SelectedItem
  Get-ChildItem $SnapRoot -Directory -EA 0 | Sort-Object CreationTime -Descending | ForEach-Object {
    $m=$null; try{ $m=Get-Content (Join-Path $_.FullName 'meta.json') -Raw | ConvertFrom-Json }catch{}
    $dir=Join-Path $_.FullName $bn; $w=$null; $t=$null
    if($m -and $m.browsers){ $x=$m.browsers.$bn; if($x){ $w=$x.windows; $t=$x.tabs } }
    elseif($bn -eq 'Chrome'){ $dir=$_.FullName; if($m){ $w=$m.windows; $t=$m.tabs } }
    if(-not (Test-Path $dir) -or -not (Get-ChildItem $dir -File -Filter 'Session_*' -EA 0)){ return }
    $tm= if($m){ ([datetime]$m.time).ToString('ddd MMM d h:mm tt') } else { $_.Name }
    $rs= if($m){ $m.reason } else { '' }
    $list.Items.Add(('{0}     {1} windows  ·  {2} tabs     {3}' -f $tm,$w,$t,$rs)) | Out-Null; $script:items+=$dir
  }
  if($list.Items.Count){ $list.SelectedIndex=0 }
}
function Run-Snap([string]$reason, [string]$protect = ''){
  $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'snapshot.ps1'), '-Reason', $reason)
  if($protect){ $argsList += @('-Protect', $protect) }
  $out = & powershell @argsList 2>&1
  if($LASTEXITCODE -ne 0){
    throw ("Snapshot ($reason) failed (exit $LASTEXITCODE): " + (($out | Out-String).Trim()))
  }
}

$btnS.Add_Click({
  $form.Cursor='WaitCursor'
  try{
    Run-Snap 'manual'
    Load-List
  } catch {
    Write-RestoreLog ("ERROR: " + $_.Exception.Message)
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Browser Snapshot', 'OK', 'Error') | Out-Null
  } finally {
    $form.Cursor='Default'
  }
})
$btnF.Add_Click({ Start-Process explorer.exe $SnapRoot })
$btnR.Add_Click({
  if($list.SelectedIndex -lt 0){ return }
  $src=$script:items[$list.SelectedIndex]
  $bn=$cmb.SelectedItem
  $form.Cursor='WaitCursor'
  try{
    Write-RestoreLog "UI Restore clicked: $bn <- $src"
    if(-not (Test-Path -LiteralPath $src)){ throw "Snapshot folder not found: $src" }
    Run-Snap 'pre-restore' $src
    Write-RestoreLog 'Pre-restore snapshot taken'
    Invoke-SessionRestore $bn $src
  } catch {
    Write-RestoreLog ("ERROR: " + $_.Exception.Message)
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Browser Snapshot', 'OK', 'Error') | Out-Null
  } finally {
    try { Load-List } catch {}
    $form.Cursor='Default'
  }
})
$cmb.Add_SelectedIndexChanged({ Load-List })
Load-List
if($ListOnly){ $list.Items; return }
$con=[BS.W]::GetConsoleWindow(); if($con -ne [IntPtr]::Zero){ [BS.W]::ShowWindow($con,0) | Out-Null }
# first ShowWindow may inherit SW_HIDE from a hidden launcher; force it visible afterwards
$form.Add_HandleCreated({ $v=1; [BS.W]::DwmSetWindowAttribute($form.Handle,20,[ref]$v,4)|Out-Null; [BS.W]::DwmSetWindowAttribute($form.Handle,19,[ref]$v,4)|Out-Null })
$form.Show(); [BS.W]::ShowWindow($form.Handle,1) | Out-Null; $form.Activate()
[Windows.Forms.Application]::Run($form)
