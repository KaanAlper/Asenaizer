# Asenaizer - uninstaller (per user, no elevation). setup.ps1 copies it into the install dir; Windows' list of apps
# runs it from there (UninstallString).
# Stops Asenaizer's own processes (by their path in the install dir, never by name alone), then removes the start at
# sign-in, the shortcuts, the apps list entry and %LOCALAPPDATA%\Programs\Asenaizer.
# The service's data (models, logs, paired browsers) in %LOCALAPPDATA%\Humanizer, plus the run and model folders the
# user chose in the app (location.json; only the files Asenaizer wrote there), is kept or removed:
#   -KeepData / -RemoveData, or a question in the console when neither is given (the models are several GB).
#   -Quiet: no questions (the data is kept unless -RemoveData), no "press Enter" at the end.
#   $env:ASENAIZER_UNINSTALL_DELETE_DATA = 1 (the earlier installer's switch) works like -RemoveData.
# Started from inside the install dir, it copies itself to %TEMP% and runs from there, so the dir can go.
# Log: %TEMP%\asenaizer-install.log. Exit codes: 0 removed, 1 failed or partly removed, 2 not uninstalled (cancelled).
param([switch]$RemoveData, [switch]$KeepData, [switch]$Quiet)
$ErrorActionPreference = 'Stop'

$LOCAL = $env:LOCALAPPDATA
$PROGRAMS = Join-Path $LOCAL 'Programs'
$APP = Join-Path $PROGRAMS 'Asenaizer'
$RBROOT = Join-Path $PROGRAMS 'Asenaizer.rollback'
$TRAY = Join-Path $APP 'asenaizer-tray.exe'
$DATA = Join-Path $LOCAL 'Humanizer'
$DL = Join-Path $env:TEMP 'asz-downloads'
$LOG = Join-Path $env:TEMP 'asenaizer-install.log'
$PROCESS_NAMES = 'asenaizer-tray', 'Humanizer', 'llama-server'
$K_CV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
$K_INNO = '{8E3C1F52-6A7B-4D19-B2E4-7C5A9F0D1B36}_is1'

# Asenaizer's interface is English only; the Turkish texts stay so a language switch is one line.
$tr = $false
function T([string]$trText, [string]$enText) { if ($tr) { $trText } else { $enText } }
function Log([string]$m, [string]$color = '') {
    try { Add-Content -LiteralPath $LOG -Value ((Get-Date -Format 'HH:mm:ss ') + $m) -Encoding UTF8 } catch {}
    if ($color) { Write-Host $m -ForegroundColor $color } else { Write-Host $m }
}
function Wait-Close { if (-not $Quiet -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { Write-Host ''; [void](Read-Host (T 'Kapatmak için Enter''a bas' 'Press Enter to close')) } }

# ---------------------------------------------------------------- run from a copy outside the install dir
$self = $PSCommandPath
if ($self -and ([IO.Path]::GetFullPath($self)).StartsWith($APP.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $copyDir = Join-Path $env:TEMP ('asz-uninstall-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $copyDir | Out-Null
    $copy = Join-Path $copyDir 'uninstall.ps1'
    Copy-Item -LiteralPath $self -Destination $copy -Force
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $copy)
    if ($RemoveData) { $argList += '-RemoveData' }
    if ($KeepData) { $argList += '-KeepData' }
    if ($Quiet) { $argList += '-Quiet' }
    # this process must not hold the install dir as its current directory either
    Set-Location -LiteralPath $env:TEMP
    [Environment]::CurrentDirectory = $env:TEMP
    # same console, waited for: the questions and the result show here
    & powershell.exe @argList
    exit $LASTEXITCODE
}
# the copy in %TEMP% removes itself at the end (a running script does not hold its file)
$selfDir = if ($self) { Split-Path $self } else { $null }
$isTempCopy = $selfDir -and (Split-Path $selfDir -Leaf) -like 'asz-uninstall-*' -and
    ([IO.Path]::GetFullPath($selfDir)).StartsWith(([IO.Path]::GetFullPath($env:TEMP)).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
try { Set-Location -LiteralPath $env:TEMP; [Environment]::CurrentDirectory = $env:TEMP } catch {}
function Exit-Uninstall([int]$code) {
    Wait-Close
    if ($isTempCopy) { Remove-Item -LiteralPath $selfDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit $code
}

# ---------------------------------------------------------------- safe removal
# A path to remove must sit inside its intended root, and no folder on the way may be a link (junction, symbolic link):
# GetFullPath normalizes dot segments but does not resolve links.
function Assert-SafePath([string]$target, [string]$root) {
    if (-not [IO.Path]::IsPathRooted($target) -or -not [IO.Path]::IsPathRooted($root)) { throw 'Uninstall paths must be absolute.' }
    $absolute = [IO.Path]::GetFullPath($target).TrimEnd('\')
    $boundary = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw "Uninstall target escapes its intended directory: $target" }
    $ancestor = $absolute
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Uninstall refuses a linked path: $ancestor" }
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if (-not $parent -or $parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    return $absolute
}
# Removes a file or a folder tree. A link inside the tree is removed as a link: what it points to is never entered.
function Remove-Tree([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { Remove-Tree $child.FullName }
        [IO.Directory]::Delete($item.FullName, $false)
    }
    else {
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) { $item.Attributes = [IO.FileAttributes]::Normal }
        [IO.File]::Delete($item.FullName)
    }
}
$script:leftovers = New-Object Collections.ArrayList
function Remove-Quiet([string]$p) {
    try { Remove-Tree $p }
    catch { Log "    could not remove $p : $($_.Exception.Message)" 'Yellow'; [void]$script:leftovers.Add($p) }
}
function Remove-IfEmpty([string]$dir) {
    if ((Test-Path -LiteralPath $dir -PathType Container) -and -not @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count) {
        try { [IO.Directory]::Delete($dir, $false) } catch {}
    }
}

# ---------------------------------------------------------------- the service's data
# Default folder %LOCALAPPDATA%\Humanizer: Asenaizer's own, removed as a whole. The run folder (data_dir) and the model
# folder (model_dir) in its location.json were chosen by the user and may hold other files: only the files Asenaizer
# wrote there go, then the folders that are empty. A location.json that cannot be read, or a path that is not a plain
# absolute path or points at a drive root, the user's profile or a system folder, counts as not set.
function Test-PlainAbsDir([string]$s) {
    if (-not $s -or $s.Length -lt 4 -or $s.Contains('/')) { return $false }
    $t = $s + '\'
    if ($t.Contains('\..\') -or $t.Contains('\.\') -or $t.Substring(2).Contains('\\')) { return $false }
    if ($s -match '^[A-Za-z]:\\') { return $true }
    if ($s.StartsWith('\\') -and $s[2] -ne '?' -and $s[2] -ne '.') { return (($s.ToCharArray() | Where-Object { $_ -eq '\' }).Count -ge 4) }  # \\server\share\folder
    return $false
}
function Test-SameDir([string]$a, [string]$b) { return ($a.TrimEnd('\') -ieq $b.TrimEnd('\')) }
function Test-Inside([string]$a, [string]$b) { return ($a.TrimEnd('\') + '\').StartsWith($b.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
function Test-BigDir([string]$d) {
    $big = @($env:USERPROFILE, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'), $LOCAL, $env:APPDATA,
        $env:WINDIR, [Environment]::SystemDirectory, $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:USERPROFILE 'Downloads'), $PROGRAMS)
    foreach ($b in $big) { if ($b -and (Test-SameDir $d $b)) { return $true } }
    return $false
}
function Read-Location {
    $file = Join-Path $DATA 'location.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Remove-Named([string]$dir, [string]$prefix, [string]$part, [bool]$withDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($it in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        $n = $it.Name.ToLowerInvariant()
        if (-not $n.StartsWith($prefix.ToLowerInvariant())) { continue }
        if ($part -and -not $n.Contains($part.ToLowerInvariant())) { continue }
        if (-not $it.PSIsContainer -or $withDirs) { Remove-Quiet $it.FullName }
    }
}
function Clear-ModelDir([string]$dir) {
    Remove-Named $dir 'humanizer-' '.gguf' $false
    Remove-Named (Join-Path $dir 'lite') 'humanizer-' '.gguf' $false
    Remove-IfEmpty (Join-Path $dir 'lite')
    Remove-IfEmpty $dir
}
function Clear-RunDir([string]$dir) {
    foreach ($name in 'settings.json', 'config.json', 'instance.json', 'location.json', 'update-state.json', 'update-result.json',
        'model-hashes.json', 'external-api-key', 'pairings.json') {
        foreach ($f in (Join-Path $dir $name), (Join-Path $dir "$name.tmp")) { if (Test-Path -LiteralPath $f) { Remove-Quiet $f } }
    }
    foreach ($f in (Join-Path $dir 'tray-webview'), (Join-Path $dir '.humanizer-write-test'), (Join-Path $dir 'updates\apply-plan.json')) {
        if (Test-Path -LiteralPath $f) { Remove-Quiet $f }
    }
    foreach ($prefix in 'launcher.log', 'llama-server.log', 'update.log', 'update-install.log') { Remove-Named (Join-Path $dir 'logs') $prefix '' $false }
    Remove-IfEmpty (Join-Path $dir 'logs')
    Remove-Named (Join-Path $dir 'updates') 'humanizer-' '' $true
    Remove-IfEmpty (Join-Path $dir 'updates')
    Clear-ModelDir (Join-Path $dir 'models')
    Remove-IfEmpty $dir
}

# ---------------------------------------------------------------- processes and shortcuts
function Get-OwnProcesses {
    $prefix = $APP.TrimEnd('\') + '\'
    $found = @(Get-Process -Name $PROCESS_NAMES -ErrorAction SilentlyContinue | Where-Object {
        $path = $null; try { $path = $_.Path } catch {}
        $_.Id -ne $PID -and $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
    return @($found | Sort-Object @{ Expression = { [array]::IndexOf($PROCESS_NAMES, $_.ProcessName) } })
}
# the tray first (it would start the service again); bounded at 15 s
function Stop-Asenaizer {
    $watch = [Diagnostics.Stopwatch]::StartNew(); $round = -1
    while ($true) {
        $left = @(Get-OwnProcesses)
        if (-not $left.Count) { return $true }
        if ($watch.ElapsedMilliseconds -ge 15000) { Log "    still running: $((@($left) | ForEach-Object { "$($_.ProcessName).exe ($($_.Id))" }) -join ', ')" 'Yellow'; return $false }
        $now = [int][Math]::Floor($watch.ElapsedMilliseconds / 2000)
        if ($now -ne $round) { $round = $now; foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
        Start-Sleep -Milliseconds 250
    }
}
# a shortcut is ours when it starts something in the install dir
function Remove-OwnShortcut([string]$lnk) {
    if (-not (Test-Path -LiteralPath $lnk)) { return }
    $target = $null
    try { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath } catch {}
    if (-not $target -or -not (Test-Inside $target $APP)) { Log "    kept $lnk (it does not start Asenaizer)"; return }
    Remove-Quiet $lnk
}

# ---------------------------------------------------------------- what to do
Log ''
Log "Asenaizer uninstaller - $(Get-Date)"
if ($env:ASENAIZER_UNINSTALL_DELETE_DATA -eq '1' -and -not $KeepData) { $RemoveData = $true }
if ($RemoveData -and $KeepData) { $KeepData = $false }
$installed = (Test-Path -LiteralPath $APP) -or (Test-Path -LiteralPath "$K_CV\Uninstall\Asenaizer")

$loc = Read-Location
$dataDir = if ($loc -and $loc.data_dir) { ([string]$loc.data_dir).TrimEnd('\') } else { '' }
$modelDir = if ($loc -and $loc.model_dir) { ([string]$loc.model_dir).TrimEnd('\') } else { '' }
$hasDef = Test-Path -LiteralPath $DATA -PathType Container
$hasData = (Test-PlainAbsDir $dataDir) -and -not (Test-BigDir $dataDir) -and -not ($hasDef -and (Test-Inside $dataDir $DATA)) -and
    (Test-Path -LiteralPath $dataDir -PathType Container) -and (Test-Path -LiteralPath (Join-Path $dataDir 'logs\launcher.log'))
$hasModel = (Test-PlainAbsDir $modelDir) -and -not ($hasDef -and (Test-Inside $modelDir $DATA)) -and
    -not ($hasData -and (Test-SameDir $modelDir (Join-Path $dataDir 'models'))) -and (Test-Path -LiteralPath $modelDir -PathType Container)
$dataList = @()
if ($hasDef) { $dataList += $DATA }
if ($hasData) { $dataList += ($dataDir + ' ' + (T '(yalnızca Asenaizer''ın kendi dosyaları)' '(only Asenaizer''s own files)')) }
if ($hasModel) { $dataList += ($modelDir + ' ' + (T '(yalnızca Asenaizer''ın kendi dosyaları)' '(only Asenaizer''s own files)')) }
Log "    installed: $installed  data: $($dataList.Count) folder(s)  choice: $(if ($RemoveData) { 'remove data' } elseif ($KeepData) { 'keep data' } else { 'ask' })"

if (-not $RemoveData -and -not $KeepData) {
    if ($Quiet -or -not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $KeepData = $true }
    else {
        Write-Host ''
        Write-Host (T 'Asenaizer kaldırılacak.' 'Asenaizer will be removed.') -ForegroundColor Cyan
        if ($dataList.Count) {
            Write-Host ''
            Write-Host (T 'İndirilen modeller, günlükler ve eşleştirilmiş tarayıcılar da silinsin mi?' 'Also delete the downloaded models, logs and paired browsers?')
            foreach ($d in $dataList) { Write-Host "    $d" }
            Write-Host (T 'Model dosyaları büyüktür (birkaç GB). Sonra yeniden kuracaksan sakla.' 'The model files are large (several GB). Keep them if you will reinstall later.') -ForegroundColor DarkGray
            Write-Host ''
            Write-Host ('  ' + (T 'e = hepsini sil' 'y = delete everything'))
            Write-Host ('  ' + (T 'h = verilerimi sakla (varsayılan)' 'n = keep my data (default)'))
            Write-Host ('  ' + (T 'i = kaldırma' 'c = don''t uninstall'))
            while (-not $RemoveData -and -not $KeepData) {
                $a = (Read-Host (T 'Seçimin [e/H/i]' 'Your choice [y/N/c]')).Trim().ToLowerInvariant()
                if ($a -eq '' -or $a -like 'n*' -or $a -like 'h*') { $KeepData = $true }
                elseif ($a -like 'y*' -or $a -like 'e*') { $RemoveData = $true }
                elseif ($a -like 'c*' -or $a -like 'i*') { Log (T 'Kaldırılmadı.' 'Not uninstalled.'); Exit-Uninstall 2 }
            }
        }
        else {
            $a = (Read-Host (T 'Devam edilsin mi? [E/h]' 'Continue? [Y/n]')).Trim().ToLowerInvariant()
            if ($a -like 'n*' -or $a -like 'h*') { Log (T 'Kaldırılmadı.' 'Not uninstalled.'); Exit-Uninstall 2 }
            $KeepData = $true
        }
        Write-Host ''
    }
}

# ---------------------------------------------------------------- remove
$failed = $false
try {
    Log '==> Stopping Asenaizer'
    if (-not (Stop-Asenaizer)) {
        Log (T 'Asenaizer kapatılamadı; hiçbir şey kaldırılmadı. Bilgisayarını yeniden başlatıp tekrar dene.' 'Asenaizer could not be stopped; nothing was removed. Restart your computer and try again.') 'Red'
        Exit-Uninstall 1
    }

    Log '==> Removing the start at sign-in and the shortcuts'
    Remove-ItemProperty -LiteralPath "$K_CV\Run" -Name 'Asenaizer' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath "$K_CV\Explorer\StartupApproved\Run" -Name 'Asenaizer' -ErrorAction SilentlyContinue
    foreach ($folder in 'Programs', 'Desktop', 'Startup') { Remove-OwnShortcut (Join-Path ([Environment]::GetFolderPath($folder)) 'Asenaizer.lnk') }

    Log '==> Removing the apps list entry'
    foreach ($key in 'Asenaizer', $K_INNO) {
        $path = "$K_CV\Uninstall\$key"
        if (Test-Path -LiteralPath $path) {
            try { Remove-Item -LiteralPath $path -Recurse -Force } catch { Log "    $path : $($_.Exception.Message)" 'Yellow'; $failed = $true }
        }
    }

    Log '==> Removing the program files'
    foreach ($dir in $APP, $RBROOT) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $safe = Assert-SafePath $dir $PROGRAMS
        # files that were in use a moment ago are released shortly after their process ended
        for ($try = 1; $try -le 4; $try++) {
            try { Remove-Tree $safe; break }
            catch {
                if ($try -eq 4) { Log "    could not remove $safe : $($_.Exception.Message)" 'Yellow'; [void]$script:leftovers.Add($safe) }
                else { Start-Sleep -Seconds 1 }
            }
        }
    }
    # the installer's download cache (the WebView2 bootstrapper)
    if (Test-Path -LiteralPath $DL) { try { Remove-Quiet (Assert-SafePath $DL $env:TEMP) } catch { Log "    $DL : $($_.Exception.Message)" } }

    if ($RemoveData) {
        Log '==> Removing the models, logs and paired browsers'
        if ($hasData) { Clear-RunDir $dataDir }
        if ($hasModel) { Clear-ModelDir $modelDir }
        if ($hasDef) { Remove-Quiet (Assert-SafePath $DATA $LOCAL) }
    }
    else { Log "    data kept in $DATA" }
}
catch { $failed = $true; Log "ERROR: $($_.Exception.Message)" 'Red' }

Log ''
if ($failed -or $script:leftovers.Count) {
    Log (T 'Asenaizer kaldırıldı, ama bazı parçalar silinemedi:' 'Asenaizer was removed, but some parts could not be deleted:') 'Yellow'
    foreach ($l in $script:leftovers) { Log "    $l" 'Yellow' }
    Log (T "Oturumu kapatıp açtıktan sonra bunları elle silebilirsin. Günlük: $LOG" "You can delete them by hand after signing out and in again. Log: $LOG") 'Yellow'
    Exit-Uninstall 1
}
if ($RemoveData) { Log (T 'Asenaizer ve verileri kaldırıldı.' 'Asenaizer and its data have been removed.') 'Green' }
elseif ($dataList.Count) { Log (T "Asenaizer kaldırıldı. Modeller ve ayarlar $DATA içinde duruyor." "Asenaizer has been removed. The models and settings are kept in $DATA.") 'Green' }
else { Log (T 'Asenaizer kaldırıldı.' 'Asenaizer has been removed.') 'Green' }
Exit-Uninstall 0
