# Asenaizer - setup (started hidden by install.ps1, as the same user: Asenaizer installs per user, no elevation).
# Installs the unzipped package into %LOCALAPPDATA%\Programs\Asenaizer. Every change is recorded first; if a step fails
# or the install is cancelled, the previous state is put back (app files, shortcuts, registry values) and a tray that
# was running before is started again.
#
# Steps (installer\PROTOCOL.md): check, runtimes, stop, files, shortcuts, startup, register.
# Exit codes: 0 installed, 1 error (rolled back), 2 cancelled (rolled back).
# Progress for install.ps1 and the setup app: $ProgressFile, rewritten whole on every change:
#   {state, step, n, total, percent, file, warn, error}
#   state: running | rollback | error | cancelled | done. percent belongs to the current step, only moves forward and
#   stays at most 99 until done (100). file: the file being copied. warn: optional parts that failed (webview2).
# $CancelFile: created by install.ps1 or the setup app to cancel; the install then rolls back and exits with 2.
# Log: %TEMP%\asenaizer-install.log
param(
    [Parameter(Mandatory = $true)][string]$Source,  # unzipped package folder (VERSION, app\, installer\)
    [switch]$NoStartup,                             # do not start Asenaizer at sign-in (removes the Run value)
    [switch]$Desktop,                               # add a desktop shortcut
    [switch]$NoLaunch,                              # do not open Asenaizer when done
    [string]$ProgressFile,
    [string]$CancelFile
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$APP = Join-Path $env:LOCALAPPDATA 'Programs\Asenaizer'
# next to the install dir (same volume: the current install is moved there, not copied)
$RBROOT = Join-Path $env:LOCALAPPDATA 'Programs\Asenaizer.rollback'
$RBAPP = Join-Path $RBROOT 'app'
$RBFILES = Join-Path $RBROOT 'files'
$TRAY = Join-Path $APP 'asenaizer-tray.exe'
$ICON = Join-Path $APP 'asenaizer.ico'
$LOG = Join-Path $env:TEMP 'asenaizer-install.log'
$DL = Join-Path $env:TEMP 'asz-downloads'
$UTF8 = New-Object Text.UTF8Encoding $false
$TOTAL_STEPS = 7
# Asenaizer's processes, in the order they are ended (the tray first: it would start the service again). Only the ones
# running from the install dir are ours; a llama-server.exe of the user's own is left alone.
$PROCESS_NAMES = 'asenaizer-tray', 'Humanizer', 'llama-server'
$K_RUN = 'Software\Microsoft\Windows\CurrentVersion\Run'
$K_APPROVED = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$K_UNINSTALL = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Asenaizer'
# the uninstall entry of the earlier Inno Setup installer (same install dir); replaced by ours
$K_INNO = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E3C1F52-6A7B-4D19-B2E4-7C5A9F0D1B36}_is1'
$WEBVIEW2_ID = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$WEBVIEW2_URL = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
$URL_INFO = 'https://kaanalper.github.io/Asenaizer/'
$Source = [IO.Path]::GetFullPath($Source).TrimEnd('\')

$script:warnings = New-Object Collections.ArrayList
function Log([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss ') + $m
    try { Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8 } catch {}
    Write-Host $m
}
function Progress([string]$state, [hashtable]$extra) {
    if (-not $ProgressFile) { return }
    $j = [ordered]@{ state = $state; step = $script:stepId; n = $script:stepNo; total = $TOTAL_STEPS; percent = $script:stepPercent }
    if ($script:warnings.Count) { $j['warn'] = @($script:warnings) }
    if ($extra) { foreach ($k in $extra.Keys) { $j[$k] = $extra[$k] } }
    $json = $j | ConvertTo-Json -Compress
    # written whole (a reader never sees half of it); a reader holding the file open makes the move fail: then direct
    try {
        [IO.File]::WriteAllText("$ProgressFile.tmp", $json, $UTF8)
        Move-Item -LiteralPath "$ProgressFile.tmp" -Destination $ProgressFile -Force
    }
    catch { try { [IO.File]::WriteAllText($ProgressFile, $json, $UTF8) } catch {} }
}
function Assert-NotCancelled { if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw (New-Object OperationCanceledException 'Installation cancelled.') } }
$script:stepNo = 0; $script:stepId = 'start'; $script:stepPercent = 0
# id: a stable name the installer UI translates; m: English text for the log
function Step([string]$id, [string]$m) {
    Assert-NotCancelled
    $script:stepNo++; $script:stepId = $id; $script:stepPercent = 0
    Log ''; Log "==> $m"
    Progress 'running' $null
}
function Step-Progress([int]$percent) {
    $script:stepPercent = [Math]::Max($script:stepPercent, [Math]::Min(99, [Math]::Max(0, $percent)))
    Progress 'running' $null
}
# Optional parts (the WebView2 Runtime): a failure there is logged and reported at the end instead of undoing the
# install; running the installer again completes what is missing
function Optional([string]$what, [scriptblock]$sb) {
    try { & $sb }
    catch [OperationCanceledException] { throw }
    catch { Log "WARNING: $what could not be installed: $($_.Exception.Message)"; [void]$script:warnings.Add($what) }
}

# Streams a download into %TEMP%\asz-downloads so the installer UI can draw a progress bar. A dropped connection
# continues where it stopped (HTTP Range), a short file is fetched again, and only a complete download (the .ok file
# next to it) is ever reused from the cache.
function Get-File([string]$url, [string]$name, [int]$target = 0) {
    New-Item -ItemType Directory -Force $DL | Out-Null
    $dst = Join-Path $DL $name; $part = "$dst.part"; $ok = "$dst.ok"
    if ((Test-Path $dst) -and (Test-Path $ok)) { if ($target) { Step-Progress $target }; return $dst }
    Remove-Item $dst, $ok -Force -ErrorAction SilentlyContinue
    Log "    download $url"
    $last = ''
    $startPercent = $script:stepPercent
    for ($try = 1; $try -le 5; $try++) {
        Assert-NotCancelled
        try {
            $have = if (Test-Path $part) { (Get-Item $part).Length } else { 0 }
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'Asenaizer-Setup'; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
            if ($have -gt 0) { $req.AddRange([long]$have) }
            $res = $req.GetResponse()
            try {
                # 206: the server continues the file; 200: it sends it from the start
                if ([int]$res.StatusCode -ne 206) { $have = 0 }
                $total = if ($res.ContentLength -gt 0) { $have + $res.ContentLength } else { -1 }
                $in = $res.GetResponseStream()
                $out = if ($have -gt 0) { New-Object IO.FileStream($part, [IO.FileMode]::Append) } else { [IO.File]::Create($part) }
                try {
                    $buf = New-Object byte[] 262144; $done = $have; $sw = [Diagnostics.Stopwatch]::StartNew()
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n); $done += $n
                        if ($sw.ElapsedMilliseconds -ge 150) {
                            $sw.Restart()
                            if ($target -gt $startPercent -and $total -gt 0) {
                                $fraction = [Math]::Min(1.0, [double]$done / $total)
                                $script:stepPercent = [Math]::Max($script:stepPercent, [Math]::Min(99, [int][Math]::Floor($startPercent + ($target - $startPercent) * $fraction)))
                            }
                            Progress 'running' @{ file = $name }
                            Assert-NotCancelled
                        }
                    }
                }
                finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $res.Dispose() }
            if ($total -gt 0 -and $done -lt $total) { throw "the connection closed at $done of $total bytes" }
            Move-Item $part $dst -Force
            [IO.File]::WriteAllText($ok, $url)
            if ($target) { Step-Progress $target } else { Progress 'running' $null }
            return $dst
        }
        catch [OperationCanceledException] { throw }
        catch {
            $last = $_.Exception.Message
            Log "    attempt $try of 5 failed: $last"
            for ($ex = $_.Exception; $ex; $ex = $ex.InnerException) {
                # 416: the part on disk does not fit the file on the server; start over
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -eq 416) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
                # 404 / 403: the file is not there; asking again does not help
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -in 403, 404, 410) { $try = 5 }
            }
            if ($try -lt 5) { for ($w = 0; $w -lt 2 * $try; $w++) { Start-Sleep 1; Assert-NotCancelled } }
        }
    }
    throw "download failed ($url): $last"
}

# ---- rollback bookkeeping ----
$script:runReg = New-Object Collections.ArrayList     # registry values this run changed: their previous state
$script:regSeen = @{}                                 # "key|value" already recorded (the first, oldest state counts)
$script:newKeys = New-Object Collections.ArrayList    # registry keys this run created
$script:created = New-Object Collections.ArrayList    # files / folders this run created
$script:backups = New-Object Collections.ArrayList    # (path, copy in the rollback folder) of files this run replaced or removed
$script:backedUp = @{}
$script:moves = New-Object Collections.ArrayList      # (from, to) of the current install moved aside
$script:clearApp = $false                             # the install dir stayed in place: everything in it is new
$script:trayWasRunning = $false
$script:appExisted = Test-Path -LiteralPath $APP

function Remember-Created([string]$p) { if (-not (Test-Path -LiteralPath $p)) { [void]$script:created.Add($p) } }
# Before a file is written or removed: a copy of the current one (or a note that it did not exist)
function Backup-File([string]$p) {
    if ($script:backedUp.ContainsKey($p)) { return }
    $script:backedUp[$p] = $true
    if (Test-Path -LiteralPath $p) {
        New-Item -ItemType Directory -Force $RBFILES | Out-Null
        $copy = Join-Path $RBFILES ('{0}-{1}' -f $script:backups.Count, (Split-Path $p -Leaf))
        Copy-Item -LiteralPath $p -Destination $copy -Force
        [void]$script:backups.Add(@($p, $copy))
    }
    else { [void]$script:created.Add($p) }
}
# HKCU values, through .NET: the exact previous value and its kind (string, expandable string, binary, DWORD ...)
function Save-RegValue([string]$sub, [string]$name) {
    $id = "$sub|$name"
    if ($script:regSeen.ContainsKey($id)) { return }
    $script:regSeen[$id] = $true
    $entry = @{ sub = $sub; name = $name; existed = $false; old = $null; kind = $null }
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub)
    if ($k) {
        try {
            if ($k.GetValueNames() -contains $name) {
                $entry.existed = $true
                $entry.old = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $entry.kind = $k.GetValueKind($name)
            }
        }
        finally { $k.Close() }
    }
    [void]$script:runReg.Add($entry)
}
function Set-RegValue([string]$sub, [string]$name, $value, [string]$kind = 'String') {
    Save-RegValue $sub $name
    $existing = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub)
    if ($existing) { $existing.Close() }
    elseif ($script:newKeys -notcontains $sub) { [void]$script:newKeys.Add($sub) }
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub)
    try { $k.SetValue($name, $value, [Microsoft.Win32.RegistryValueKind]$kind) } finally { $k.Close() }
}
function Remove-RegValue([string]$sub, [string]$name) {
    Save-RegValue $sub $name
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
    if ($k) { try { $k.DeleteValue($name, $false) } finally { $k.Close() } }
}
# A whole key (no subkeys expected): every value is recorded, so a rollback can create it again
function Remove-RegKey([string]$sub) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub)
    if (-not $k) { return $false }
    try { $names = @($k.GetValueNames()) } finally { $k.Close() }
    foreach ($nm in $names) { Save-RegValue $sub $nm }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($sub, $false)
    return $true
}
function Restore-RegValue($r) {
    if ($r.existed) {
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($r.sub)
        try { $k.SetValue($r.name, $r.old, $r.kind) } finally { $k.Close() }
    }
    else {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($r.sub, $true)
        if ($k) { try { $k.DeleteValue($r.name, $false) } finally { $k.Close() } }
    }
}

# ---- processes and shortcuts ----
# Asenaizer's processes running from the install dir: which ones are ours is decided by where they run from, never
# by their names alone
function Get-OwnProcesses {
    $prefix = $APP.TrimEnd('\') + '\'
    $found = @(Get-Process -Name $PROCESS_NAMES -ErrorAction SilentlyContinue | Where-Object {
        $path = $null; try { $path = $_.Path } catch {}
        $_.Id -ne $PID -and $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
    return @($found | Sort-Object @{ Expression = { [array]::IndexOf($PROCESS_NAMES, $_.ProcessName) } })
}
# Ended and waited for: the files are moved right after this. A process started again in between is ended too.
# Bounded: what still runs after 15 s fails the step (and the install rolls back).
function Stop-Asenaizer([bool]$report) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $round = -1
    while ($true) {
        $left = @(Get-OwnProcesses)
        if (-not $left.Count) { return }
        if ($watch.ElapsedMilliseconds -ge 15000) {
            throw "Asenaizer is still running: $((@($left) | ForEach-Object { "$($_.ProcessName).exe ($($_.Id))" }) -join ', ')"
        }
        $now = [int][Math]::Floor($watch.ElapsedMilliseconds / 2000)
        if ($now -ne $round) {
            $round = $now
            foreach ($p in $left) { Log "    stopping $($p.ProcessName).exe ($($p.Id))"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Milliseconds 250
        if ($report) { Step-Progress ([int]($watch.ElapsedMilliseconds / 160)) }
    }
}
function Get-ShortcutTarget([string]$lnk) {
    try { return (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath } catch { return $null }
}
function New-AppShortcut([string]$lnk) {
    Backup-File $lnk
    New-Item -ItemType Directory -Force (Split-Path $lnk) | Out-Null
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $TRAY
    $s.Arguments = '--settings'
    $s.WorkingDirectory = $APP
    $s.IconLocation = $(if (Test-Path -LiteralPath $ICON) { $ICON } else { $TRAY }) + ',0'
    $s.Description = 'Asenaizer'
    $s.Save()
    Log "    shortcut $lnk"
}
# A shortcut of ours (it starts the installed tray) is removed, backed up first
function Remove-OwnShortcut([string]$lnk) {
    if (-not (Test-Path -LiteralPath $lnk)) { return }
    $target = Get-ShortcutTarget $lnk
    if (-not $target -or $target -ine $TRAY) { return }
    Backup-File $lnk
    Remove-Item -LiteralPath $lnk -Force
    Log "    removed $lnk"
}
function Get-FolderBytes([string]$dir) {
    $sum = [long]0
    foreach ($f in [IO.Directory]::GetFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { $sum += (New-Object IO.FileInfo $f).Length }
    return $sum
}
function Test-WebView2 {
    foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$WEBVIEW2_ID", "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$WEBVIEW2_ID") {
        $pv = (Get-ItemProperty -LiteralPath $key -Name pv -ErrorAction SilentlyContinue).pv
        if ($pv -and [string]$pv -ne '0.0.0.0') { return [string]$pv }
    }
    return $null
}

# ---- rollback ----
# Puts back what this run changed and starts the tray that was running before
function Undo-Install {
    Log ''; Log '==> Rolling back'
    Progress 'rollback' $null
    try { Undo-Changes }
    catch { Log "    rollback step failed: $($_.Exception.Message)" }
    finally { Start-PreviousTray }
    Log '    rollback finished'
}
function Undo-Changes {
    # nothing of the new install should be running; whatever is, holds the files
    try { Stop-Asenaizer $false } catch { Log "    $($_.Exception.Message)" }
    # each restore on its own: one that fails must not stop the rest
    for ($i = $script:runReg.Count - 1; $i -ge 0; $i--) {
        $r = $script:runReg[$i]
        try { Restore-RegValue $r } catch { Log "    registry HKCU\$($r.sub)\$($r.name): $($_.Exception.Message)" }
    }
    for ($i = $script:newKeys.Count - 1; $i -ge 0; $i--) {
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:newKeys[$i], $false) } catch { Log "    registry key HKCU\$($script:newKeys[$i]): $($_.Exception.Message)" }
    }
    if ($script:runReg.Count) { Log "    $($script:runReg.Count) registry values restored" }
    # the new files (a first install: the whole install dir)
    if ($script:clearApp -and (Test-Path -LiteralPath $APP)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $APP -Force)) {
            try { Remove-Item -LiteralPath $item.FullName -Recurse -Force } catch { Log "    could not remove $($item.FullName): $($_.Exception.Message)" }
        }
    }
    for ($i = $script:created.Count - 1; $i -ge 0; $i--) {
        try { if (Test-Path -LiteralPath $script:created[$i]) { Remove-Item -LiteralPath $script:created[$i] -Recurse -Force } }
        catch { Log "    could not remove $($script:created[$i]): $($_.Exception.Message)" }
    }
    # replaced or removed files (shortcuts) back from their copies
    foreach ($b in $script:backups) {
        try { New-Item -ItemType Directory -Force (Split-Path $b[0]) | Out-Null; Copy-Item -LiteralPath $b[1] -Destination $b[0] -Force }
        catch { Log "    could not restore $($b[0]): $($_.Exception.Message)" }
    }
    # the previous install back in place
    $movedBack = $true
    for ($i = $script:moves.Count - 1; $i -ge 0; $i--) {
        $mv = $script:moves[$i]
        try { if (Test-Path -LiteralPath $mv[1]) { Move-Item -LiteralPath $mv[1] -Destination $mv[0] -Force } }
        catch { $movedBack = $false; Log "    could not move back $($mv[1]): $($_.Exception.Message)" }
    }
    if ($script:moves.Count) { Log $(if ($movedBack) { '    previous app files restored' } else { "    some previous app files are still in $RBAPP" }) }
    # the rollback folder goes only when it holds nothing of the previous install any more
    if ($movedBack -and (Test-Path -LiteralPath $RBROOT)) { Remove-Item -LiteralPath $RBROOT -Recurse -Force -ErrorAction SilentlyContinue }
}
# The tray that was running before this run (whatever the rollback could restore); it starts the service itself
function Start-PreviousTray {
    if ($script:trayWasRunning -and (Test-Path -LiteralPath $TRAY)) {
        try { Start-Process -FilePath $TRAY -WorkingDirectory $APP; Log '    previous Asenaizer started again' }
        catch { Log "    could not start the previous Asenaizer: $($_.Exception.Message)" }
    }
}

Log "Asenaizer setup - $(Get-Date)"
Log "user: $env:USERDOMAIN\$env:USERNAME  source: $Source  install dir: $APP  existing install: $($script:appExisted)"
Log "options: startup=$(-not $NoStartup) desktop=$([bool]$Desktop) launch=$(-not $NoLaunch)"
$ok = $false; $cancelled = $false; $failure = $null; $version = $null
try {
    # ------------------------------------------------------------ 1. check
    Step 'check' 'Checking Windows and the package'
    foreach ($need in 'app\asenaizer-tray.exe', 'app\Humanizer.exe', 'VERSION', 'installer\uninstall.ps1') {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $need))) { throw "The package is incomplete: $need is missing in $Source." }
    }
    $version = [IO.File]::ReadAllText((Join-Path $Source 'VERSION')).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "The package VERSION is not a version number: '$version'." }
    # a package inside the install dir would be moved away by the files step
    if (($Source + '\').StartsWith($APP.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "The package must not be inside the install folder ($APP)." }
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -lt 19041) { throw "Windows 10 2004 (build 19041) or newer is required; this is build $build." }
    if (-not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows is required.' }
    Log "    Asenaizer $version, Windows build $build"
    Step-Progress 99

    # ------------------------------------------------------------ 2. runtimes
    # The tray's window uses WebView2; without it the tray opens the device page in the browser (a warning, not an error)
    Step 'runtimes' 'Checking the WebView2 Runtime'
    Optional 'webview2' {
        $have = Test-WebView2
        if ($have) { Log "    WebView2 Runtime $have"; return }
        Log '    installing the Microsoft Edge WebView2 Runtime'
        $boot = Get-File $WEBVIEW2_URL 'MicrosoftEdgeWebview2Setup.exe' 40
        $proc = Start-Process -FilePath $boot -ArgumentList '/silent', '/install' -PassThru
        [void]$proc.Handle
        $wait = 45
        while (-not $proc.WaitForExit(500)) { Assert-NotCancelled; $wait = [Math]::Min(95, $wait + 1); Step-Progress $wait }
        $have = Test-WebView2
        if (-not $have) { throw "the WebView2 installer ended with exit code $($proc.ExitCode) and the runtime is still missing" }
        Log "    WebView2 Runtime $have installed"
    }
    Step-Progress 99

    # ------------------------------------------------------------ 3. stop
    Step 'stop' 'Stopping Asenaizer'
    $script:trayWasRunning = [bool](@(Get-OwnProcesses) | Where-Object { $_.ProcessName -eq 'asenaizer-tray' })
    Stop-Asenaizer $true
    Step-Progress 99

    # ------------------------------------------------------------ 4. files
    Step 'files' 'Copying Asenaizer'
    if (Test-Path -LiteralPath $RBROOT) {
        # left by an earlier run that stopped half-way (a power cut): its moved-aside install is the good copy then
        if ((Test-Path -LiteralPath (Join-Path $RBAPP 'asenaizer-tray.exe')) -and -not (Test-Path -LiteralPath $TRAY)) {
            Log "    restoring the install an earlier run left in $RBAPP"
            if (Test-Path -LiteralPath $APP) { Remove-Item -LiteralPath $APP -Recurse -Force }
            Move-Item -LiteralPath $RBAPP -Destination $APP
        }
        Remove-Item -LiteralPath $RBROOT -Recurse -Force
    }
    $script:appExisted = Test-Path -LiteralPath $APP
    if ($script:appExisted) {
        New-Item -ItemType Directory -Force $RBROOT | Out-Null
        # as a whole (one rename on the same volume); item by item when that is refused (a window open in the folder)
        try {
            Move-Item -LiteralPath $APP -Destination $RBAPP
            [void]$script:moves.Add(@($APP, $RBAPP))
        }
        catch {
            Log "    the install dir could not be moved as a whole ($($_.Exception.Message)); moving its items"
            New-Item -ItemType Directory -Force $RBAPP | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $APP -Force)) {
                $to = Join-Path $RBAPP $item.Name
                Move-Item -LiteralPath $item.FullName -Destination $to
                [void]$script:moves.Add(@($item.FullName, $to))
            }
            $script:clearApp = $true
        }
        Log '    previous install moved aside'
    }
    Step-Progress 5
    if (-not (Test-Path -LiteralPath $APP)) { Remember-Created $APP; New-Item -ItemType Directory -Force $APP | Out-Null }
    $appSrc = Join-Path $Source 'app'
    $files = @([IO.Directory]::GetFiles($appSrc, '*', [IO.SearchOption]::AllDirectories))
    $totalBytes = [long]0
    foreach ($f in $files) { $totalBytes += (New-Object IO.FileInfo $f).Length }
    $totalBytes = [Math]::Max([long]1, $totalBytes)
    $copied = [long]0; $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $files) {
        $rel = $f.Substring($appSrc.Length).TrimStart('\')
        $dst = Join-Path $APP $rel
        $dir = Split-Path $dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        [IO.File]::Copy($f, $dst, $true)
        $copied += (New-Object IO.FileInfo $f).Length
        if ($sw.ElapsedMilliseconds -ge 150) {
            $sw.Restart()
            $script:stepPercent = [Math]::Max($script:stepPercent, [Math]::Min(99, 5 + [int][Math]::Floor(85.0 * $copied / $totalBytes)))
            Progress 'running' @{ file = $rel }
            Assert-NotCancelled
        }
    }
    Log "    $($files.Count) files copied ($([Math]::Round($copied / 1MB, 1)) MB)"
    Step-Progress 92
    Copy-Item -LiteralPath (Join-Path $Source 'installer\uninstall.ps1') -Destination (Join-Path $APP 'uninstall.ps1') -Force
    [IO.File]::WriteAllText((Join-Path $APP 'VERSION'), $version, $UTF8)
    Step-Progress 99

    # ------------------------------------------------------------ 5. shortcuts
    Step 'shortcuts' 'Creating the shortcuts'
    New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Asenaizer.lnk')
    Step-Progress 50
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Asenaizer.lnk'
    if ($Desktop) { New-AppShortcut $desktopLnk } else { Remove-OwnShortcut $desktopLnk }
    Step-Progress 99

    # ------------------------------------------------------------ 6. startup
    Step 'startup' $(if ($NoStartup) { 'Not starting Asenaizer at sign-in' } else { 'Starting Asenaizer at sign-in' })
    # the earlier Inno Setup installer started the tray from the Startup folder; the Run value does that now
    Remove-OwnShortcut (Join-Path ([Environment]::GetFolderPath('Startup')) 'Asenaizer.lnk')
    Step-Progress 30
    if ($NoStartup) { Remove-RegValue $K_RUN 'Asenaizer' }
    else {
        Set-RegValue $K_RUN 'Asenaizer' "`"$TRAY`"" 'String'
        # switched off in Task Manager's startup apps before: the user asked for it again
        Remove-RegValue $K_APPROVED 'Asenaizer'
    }
    Step-Progress 99

    # ------------------------------------------------------------ 7. register
    Step 'register' 'Adding Asenaizer to the apps list'
    $sizeKB = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling((Get-FolderBytes $APP) / 1KB))
    Step-Progress 30
    Set-RegValue $K_UNINSTALL 'DisplayName' 'Asenaizer'
    Set-RegValue $K_UNINSTALL 'DisplayVersion' $version
    Set-RegValue $K_UNINSTALL 'Publisher' 'Kaan Alper'
    Set-RegValue $K_UNINSTALL 'DisplayIcon' $(if (Test-Path -LiteralPath $ICON) { $ICON } else { $TRAY })
    Set-RegValue $K_UNINSTALL 'InstallLocation' $APP
    Set-RegValue $K_UNINSTALL 'URLInfoAbout' $URL_INFO
    Set-RegValue $K_UNINSTALL 'UninstallString' "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $APP 'uninstall.ps1')`""
    Set-RegValue $K_UNINSTALL 'NoModify' 1 'DWord'
    Set-RegValue $K_UNINSTALL 'NoRepair' 1 'DWord'
    Set-RegValue $K_UNINSTALL 'EstimatedSize' $sizeKB 'DWord'
    Step-Progress 80
    # the earlier Inno Setup installer's entry: its uninstaller went with the previous files
    if (Remove-RegKey $K_INNO) { Log '    the earlier installer''s apps list entry was replaced' }
    Step-Progress 99
    Assert-NotCancelled
    $ok = $true
}
catch [OperationCanceledException] { $cancelled = $true; Log ''; Log 'Cancelled.' }
catch { $failure = $_; Log "ERROR: $($_.Exception.Message)"; Log "    at $($_.InvocationInfo.PositionMessage)" }
finally {
    # also runs when the process is being stopped: nothing is left half-installed
    if (-not $ok) { try { Undo-Install } catch { Log "rollback error: $($_.Exception.Message)" } }
}

if (-not $ok) {
    if ($cancelled) { Progress 'cancelled' $null; exit 2 }
    $msg = if ($failure) { [string]$failure.Exception.Message } else { 'unknown error' }
    Progress 'error' @{ error = $msg }
    if (-not $ProgressFile) { Write-Host "Setup failed: $msg" -ForegroundColor Red; Write-Host "Log: $LOG"; Write-Host 'Press Enter to close.'; [void](Read-Host) }
    exit 1
}

# ---------------------------------------------------------------- committed
# Nothing below can undo the install; failures are only logged.
try { if (Test-Path -LiteralPath $RBROOT) { Remove-Item -LiteralPath $RBROOT -Recurse -Force } }
catch { Log "    could not remove the rollback folder $RBROOT : $($_.Exception.Message)" }
try {
    if (-not $NoLaunch) { Start-Process -FilePath $TRAY -ArgumentList '--settings' -WorkingDirectory $APP; Log '    Asenaizer started' }
    # not opened, but it was running before the update: it comes back as it was (in the tray, no window)
    elseif ($script:trayWasRunning) { Start-Process -FilePath $TRAY -WorkingDirectory $APP; Log '    Asenaizer started again (in the tray)' }
}
catch { Log "    could not start Asenaizer: $($_.Exception.Message)" }
Log "Done. Asenaizer $version is installed in $APP$(if ($script:warnings.Count) { " (missing: $($script:warnings -join ', '))" })"
$script:stepPercent = 100
Progress 'done' $null
exit 0
