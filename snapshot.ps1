param(
  [ValidateSet('logon','periodic','pre-restore','manual')][string]$Reason='manual',
  [string]$Label='',
  [string]$Protect=''
)

function Read-Shared([string]$p){
  $fs=[IO.File]::Open($p,'Open','Read','ReadWrite,Delete')
  try{ $ms=New-Object IO.MemoryStream; $fs.CopyTo($ms); ,$ms.ToArray() } finally { $fs.Dispose() }
}

# Best-effort SNSS parser: replays SetTabWindow(0)/TabClosed(16)/WindowClosed(17)/UpdateTabNavigation(6)
function Parse-Snss([byte[]]$b){
  $tabWin=@{}; $tabUrl=@{}; $closedWin=@{}
  if($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b,0,4) -ne 'SNSS'){ return $null }
  $i=8
  while($i+3 -le $b.Length){
    $size=[BitConverter]::ToUInt16($b,$i); $i+=2
    if($size -lt 1 -or $i+$size -gt $b.Length){ break }
    $id=$b[$i]; $p=$i+1; $plen=$size-1
    try{
      switch($id){
        0 { if($plen -ge 8){ $w=[BitConverter]::ToInt32($b,$p); $t=[BitConverter]::ToInt32($b,$p+4); $tabWin[$t]=$w; $closedWin.Remove($w) } }
        16 { if($plen -ge 4){ $t=[BitConverter]::ToInt32($b,$p); $tabWin.Remove($t); $tabUrl.Remove($t) } }
        17 { if($plen -ge 4){ $closedWin[[BitConverter]::ToInt32($b,$p)]=1 } }
        6 { if($plen -ge 16){ $t=[BitConverter]::ToInt32($b,$p+4); $ul=[BitConverter]::ToInt32($b,$p+12)
              if($ul -gt 0 -and $p+16+$ul -le $i+$size){ $tabUrl[$t]=[Text.Encoding]::UTF8.GetString($b,$p+16,$ul) } } }
      }
    } catch {}
    $i+=$size
  }
  $live=@($tabWin.Keys | Where-Object { -not $closedWin.ContainsKey($tabWin[$_]) })
  $wins=@($live | ForEach-Object { $tabWin[$_] } | Sort-Object -Unique)
  $urls=@($live | ForEach-Object { $tabUrl[$_] } | Where-Object { $_ } | Sort-Object -Unique)
  [pscustomobject]@{windows=$wins.Count; tabs=$live.Count; uniqueUrls=$urls.Count}
}

function Get-SnapshotReason([IO.DirectoryInfo]$Dir){
  $metaPath = Join-Path $Dir.FullName 'meta.json'
  if(Test-Path -LiteralPath $metaPath){
    try{
      $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if($m -and $m.reason -and -not [string]::IsNullOrWhiteSpace([string]$m.reason)){
        return ([string]$m.reason).Trim()
      }
    } catch {}
  }
  if($Dir.Name -like '*_pre-restore*'){ return 'pre-restore' }
  return 'other'
}

function Test-ProtectedSnapshot([IO.DirectoryInfo]$Dir, [string]$ProtectPath){
  if([string]::IsNullOrWhiteSpace($ProtectPath)){ return $false }
  try{
    $d = [IO.Path]::GetFullPath($Dir.FullName).TrimEnd('\')
    $p = [IO.Path]::GetFullPath($ProtectPath).TrimEnd('\')
    return ($p -ieq $d) -or $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Invoke-SnapshotRetention([string]$RootDir, [int]$KeepMain, [int]$KeepPre, [string]$ProtectPath = '', [string]$CurrentDest = ''){
  if(-not (Test-Path -LiteralPath $RootDir)){ return }
  $allDirs = @(Get-ChildItem -LiteralPath $RootDir -Directory -ErrorAction SilentlyContinue)
  $preDirs = @()
  $mainDirs = @()
  foreach($d in $allDirs){
    if((Get-SnapshotReason $d) -eq 'pre-restore'){
      $preDirs += $d
    } else {
      $mainDirs += $d
    }
  }
  $toRemove = @()
  if($mainDirs.Count -gt $KeepMain){
    $toRemove += @($mainDirs | Sort-Object CreationTime, Name -Descending | Select-Object -Skip $KeepMain)
  }
  if($preDirs.Count -gt $KeepPre){
    $toRemove += @($preDirs | Sort-Object CreationTime, Name -Descending | Select-Object -Skip $KeepPre)
  }
  foreach($d in $toRemove){
    if((Test-ProtectedSnapshot $d $ProtectPath) -or (Test-ProtectedSnapshot $d $CurrentDest)){ continue }
    Remove-Item -LiteralPath $d.FullName -Recurse -Force
  }
}

if($MyInvocation.InvocationName -eq '.'){ return }

$ErrorActionPreference='Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Sessions = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Sessions'
$SnapRoot = Join-Path $Root 'snapshots'
$Keep = 10
$KeepPreRestore = 5
New-Item -ItemType Directory -Force $SnapRoot | Out-Null

$stamp=Get-Date
$name=$stamp.ToString('yyyy-MM-dd_HHmm'); if($Label){$name+="_$Label"} elseif($Reason -ne 'manual'){$name+="_$Reason"}
$dest=Join-Path $SnapRoot $name
if(Test-Path -LiteralPath $dest){
  $baseDest = $dest + '_' + $stamp.ToString('ss')
  $dest = $baseDest
  $n = 2
  while(Test-Path -LiteralPath $dest){
    $dest = '{0}_{1}' -f $baseDest, $n
    $n++
  }
}
New-Item -ItemType Directory -Force $dest | Out-Null

$Browsers=[ordered]@{
  Chrome = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Sessions'
  Brave  = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data\Default\Sessions'
  Edge   = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Sessions'
}
$meta=[ordered]@{ time=$stamp.ToString('o'); reason=$Reason; countMethod='SNSS replay of newest Session_* file (best effort)'; browsers=[ordered]@{} }
foreach($bn in $Browsers.Keys){
  $src=$Browsers[$bn]; if(-not (Test-Path $src)){ continue }
  $bd=Join-Path $dest $bn; New-Item -ItemType Directory -Force $bd | Out-Null
  $files=Get-ChildItem $src -File | Where-Object { $_.Name -match '^(Session|Tabs)_' -and $_.Length -gt 0 }
  $best=$null
  foreach($f in $files){
    $bytes=Read-Shared $f.FullName
    [IO.File]::WriteAllBytes((Join-Path $bd $f.Name),$bytes)
    if($f.Name -like 'Session_*' -and ($best -eq $null -or $f.LastWriteTime -gt $best.t)){ $best=@{t=$f.LastWriteTime;b=$bytes} }
  }
  $r=$null; if($best){ $r=Parse-Snss $best.b }
  $meta.browsers[$bn]=[ordered]@{ windows= if($r){$r.windows}else{$null}; tabs= if($r){$r.tabs}else{$null}; uniqueUrls= if($r){$r.uniqueUrls}else{$null}; files=@($files | ForEach-Object Name) }
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $dest 'meta.json')
# retention: keep newest $Keep normal snapshots and $KeepPreRestore pre-restore snapshots separately, never deleting $Protect
Invoke-SnapshotRetention -RootDir $SnapRoot -KeepMain $Keep -KeepPre $KeepPreRestore -ProtectPath $Protect -CurrentDest $dest
Write-Output ("Snapshot: $dest  " + (($meta.browsers.Keys | % { "$_ $($meta.browsers[$_].windows)w/$($meta.browsers[$_].tabs)t" }) -join ", "))


