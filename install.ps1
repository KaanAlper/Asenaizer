# Asenaizer - install wizard
#   irm https://raw.githubusercontent.com/KaanAlper/Asenaizer/main/install.ps1 | iex
# Finds the newest Asenaizer release, asks three short questions, downloads the package (with a progress bar; a
# dropped connection resumes where it stopped), checks its SHA-256 and runs installer\setup.ps1 from it while showing
# its steps. Asenaizer installs for the current user only (%LOCALAPPDATA%\Programs\Asenaizer): no administrator
# permission is asked for. On an error or Ctrl+C everything is put back the way it was. Nothing is left in %TEMP%.
# Options (set before running):  $env:ASZ_SOURCE = <folder>  install from a local, unzipped package (VERSION, app\, installer\)
#                                 $env:ASZ_DEFAULTS = 1       no questions (the options below, or their defaults)
#                                 $env:ASZ_NO_STARTUP = 1     do not start Asenaizer at sign-in
#                                 $env:ASZ_DESKTOP = 1        add a desktop shortcut
#                                 $env:ASZ_NO_LAUNCH = 1      do not open Asenaizer when done
#                                 $env:ASZ_PLAIN = 1          simple numbered / yes-no prompts instead of gum
#                                 $env:ASZ_NO_GUI = 1         stay in the console even on a desktop
#                                 $env:ASZ_DRIVER = <folder>  driven by the setup app (Asenaizer-Setup-x64.exe): no
#                                                             questions, phases in <folder>\status.json, <folder>\cancel stops
#                                 $env:ASZ_PREVIEW = 1        walk through the wizard, the download and a simulated install;
#                                                             nothing is stopped or changed
#                                                             (= fail: a failed install, = warn: an optional part that failed)
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'KaanAlper/Asenaizer'
$GUM_VER = '2.0.2'
$UA = 'Asenaizer-Install'
$E = [char]27

# ---------------------------------------------------------------- texts (Turkish / English)
# Asenaizer's interface is English only; the Turkish texts stay so a language switch is one line.
$tr = $false
function Get-Texts([bool]$tr) {
if ($tr) { @{
        tagline = 'Asenaizer: yapay zekâ taslaklarını kendi bilgisayarında, bir insan yazmış gibi yeniden yazar'
        preparing = 'Hazırlanıyor'; release = 'Son sürüm aranıyor'
        guiOpen = 'Kurulum penceresi açılıyor'; guiClosed = 'Kurulum penceresi kapandı.'; guiFallback = 'Kurulum penceresi açılamadı; kurulum burada sürüyor.'
        noRelease = 'Henüz doğrulanabilir bir Asenaizer sürümü yayımlanmamış.'
        welcome = "Asenaizer'a hoş geldin"
        welcomeBody = "Birkaç kısa soru soracağız, sonra gerisini biz hallederiz. Asenaizer yalnızca senin hesabına kurulur; yönetici izni gerekmez.`nHer değişiklik yedeklenir; bir şey ters giderse ya da vazgeçersen her şey eski haline döner."
        version = 'Sürüm'; size = 'İndirme'
        qOptions = 'Seçenekler (Boşluk ile seç / kaldır, Enter ile onayla)'
        oStartup = 'Oturum açınca Asenaizer başlasın'; oDesktop = 'Masaüstüne kısayol ekle'; oLaunch = 'Kurulum bitince Asenaizer açılsın'
        summary = 'Özet'; on = 'evet'; off = 'hayır'
        qGo = 'Kuralım mı?'; go = 'Kur'; cancel = 'Vazgeç'
        downloading = 'Asenaizer indiriliyor'; verifying = 'Paket doğrulanıyor'; extracting = 'Paket açılıyor'
        installing = 'Asenaizer kuruluyor'; ctrlc = 'Ctrl+C: vazgeç'; rollingBack = 'Değişiklikler geri alınıyor...'
        qStop = 'Kurulumu durdurup her şeyi eski haline getirelim mi?'; stopYes = 'Evet, durdur'; stopNo = 'Devam et'
        steps = @{ check = 'Windows denetleniyor'; runtimes = 'Gerekli bileşenler'; stop = 'Asenaizer durduruluyor'; files = 'Dosyalar kopyalanıyor'; shortcuts = 'Kısayollar oluşturuluyor'; startup = 'Oturum açılışı ayarlanıyor'; register = 'Uygulamalar listesine ekleniyor' }
        doneTitle = 'Hazır! Asenaizer kuruldu'
        doneBody = "Asenaizer saatin yanındaki bildirim alanında çalışır; penceresi birazdan açılıyor.`n`n  Başlat menüsü      Asenaizer`n  Kaldırmak için     Ayarlar > Uygulamalar > Asenaizer"
        doneBodyQuiet = "Asenaizer'ı Başlat menüsünden açabilirsin. Çalışırken saatin yanındaki bildirim alanında durur.`n`n  Başlat menüsü      Asenaizer`n  Kaldırmak için     Ayarlar > Uygulamalar > Asenaizer"
        errTitle = 'Olmadı, ama merak etme'
        errBody = "Kurulum '{0}' adımında takıldı. Bilgisayarında hiçbir şey yarım kalmadı: yapılan değişiklikler geri alındı ve önceki Asenaizer (varsa) yeniden açıldı."
        errDetail = 'Ayrıntı'; errLog = 'Günlük'
        errRetry = "Aynı komutu yeniden çalıştırarak tekrar deneyebilirsin. Sorun sürerse günlüğü bizimle paylaş:`nhttps://github.com/$repo/issues"
        netTitle = 'İnternete ulaşamadık'; netBody = 'Bağlantını kontrol edip aynı komutu yeniden çalıştır. Bilgisayarında hiçbir şey değişmedi.'
        cancelTitle = 'Kurulumdan vazgeçildi'; cancelBody = 'Her şey eski haline döndü, bilgisayarında hiçbir şey değişmedi.'
        oldWin = 'Asenaizer Windows 10 2004 (19041) ya da daha yenisini istiyor; bu bilgisayar {0}.'
        not64 = 'Asenaizer 64 bit Windows istiyor.'
        badPkg = 'İndirilen paket bozuk görünüyor (doğrulama tutmadı).'
        plainPick = 'Numara yaz ve Enter''a bas'; yes = 'e'
        retrying = 'bağlantı koptu, {0} sn sonra kaldığı yerden devam ({1}/5)'
        warnTitle = 'Bir ek parça kurulamadı'
        warnBody = 'Asenaizer çalışıyor, yalnızca bu eksik. Aynı komutu sonra yeniden çalıştırınca eksik tamamlanır.'
        xWebView2 = 'WebView2 Runtime (cihaz sayfası bunun yerine tarayıcıda açılır)'
    } } else { @{
        tagline = 'Asenaizer: rewrites AI drafts so they read like a person wrote them, on your own computer'
        preparing = 'Getting ready'; release = 'Looking for the latest release'
        guiOpen = 'Opening the setup window'; guiClosed = 'The setup window closed.'; guiFallback = 'The setup window could not open; setup continues here.'
        noRelease = 'No verifiable Asenaizer release has been published yet.'
        welcome = 'Welcome to Asenaizer'
        welcomeBody = "A few quick questions, then we take care of the rest. Asenaizer installs for your account only; no administrator permission is needed.`nEvery change is backed up; if something goes wrong or you cancel, everything goes back to how it was."
        version = 'Version'; size = 'Download'
        qOptions = 'Options (Space to toggle, Enter to confirm)'
        oStartup = 'Start Asenaizer when I sign in'; oDesktop = 'Add a desktop shortcut'; oLaunch = 'Open Asenaizer when the install is done'
        summary = 'Summary'; on = 'yes'; off = 'no'
        qGo = 'Ready to install?'; go = 'Install'; cancel = 'Cancel'
        downloading = 'Downloading Asenaizer'; verifying = 'Verifying the package'; extracting = 'Unpacking'
        installing = 'Installing Asenaizer'; ctrlc = 'Ctrl+C: cancel'; rollingBack = 'Putting everything back...'
        qStop = 'Stop the install and put everything back?'; stopYes = 'Yes, stop'; stopNo = 'Keep going'
        steps = @{ check = 'Checking Windows'; runtimes = 'Required components'; stop = 'Stopping Asenaizer'; files = 'Copying files'; shortcuts = 'Creating shortcuts'; startup = 'Setting up start at sign-in'; register = 'Adding to the apps list' }
        doneTitle = 'All set! Asenaizer is installed'
        doneBody = "Asenaizer runs in the notification area next to the clock; its window opens in a moment.`n`n  Start menu         Asenaizer`n  To remove it       Settings > Apps > Asenaizer"
        doneBodyQuiet = "Open Asenaizer from the Start menu. While it runs, it sits in the notification area next to the clock.`n`n  Start menu         Asenaizer`n  To remove it       Settings > Apps > Asenaizer"
        errTitle = "That didn't work, but don't worry"
        errBody = "The install got stuck at '{0}'. Nothing was left half-done: the changes were undone and the previous Asenaizer (if there was one) was started again."
        errDetail = 'Details'; errLog = 'Log'
        errRetry = "You can try again by running the same command. If it keeps happening, please share the log with us:`nhttps://github.com/$repo/issues"
        netTitle = "We couldn't reach the internet"; netBody = 'Check your connection and run the same command again. Nothing on your computer was changed.'
        cancelTitle = 'Install cancelled'; cancelBody = 'Everything is back to how it was; nothing on your computer was changed.'
        oldWin = 'Asenaizer needs Windows 10 2004 (19041) or newer; this computer is {0}.'
        not64 = 'Asenaizer needs 64-bit Windows.'
        badPkg = 'The downloaded package looks damaged (the checksum does not match).'
        plainPick = 'Type a number and press Enter'; yes = 'y'
        retrying = 'connection dropped, resuming in {0} s ({1}/5)'
        warnTitle = "An optional part couldn't be installed"
        warnBody = 'Asenaizer works; only this is missing. Run the same command again later to complete it.'
        xWebView2 = 'WebView2 Runtime (the device page opens in your browser instead)'
    } }
}
$T = Get-Texts $tr
# the steps of installer\setup.ps1, in order (PROTOCOL.md)
$STEP_IDS = 'check', 'runtimes', 'stop', 'files', 'shortcuts', 'startup', 'register'

# ---------------------------------------------------------------- drawing
$C = @{ accent = '#a48bff'; ink = '#1a1033'; text = '#e6e0e9'; dim = '#938f99'; ok = '#a8dab5'; err = '#f2b8b5'; warn = '#ffb77c' }
function Fg([string]$hex) { $h = $hex.TrimStart('#'); "$E[38;2;$([Convert]::ToInt32($h.Substring(0, 2), 16));$([Convert]::ToInt32($h.Substring(2, 2), 16));$([Convert]::ToInt32($h.Substring(4, 2), 16))m" }
$R = "$E[0m"
# Glyphs: Windows Terminal (and other modern terminals) fill in any glyph from fallback fonts; the classic console
# draws only what its font has (Consolas, Lucida Console: the WGL4 set) and prints "?" for the rest. Pick a set
# the window can draw.
$GL = if ($env:WT_SESSION -or $env:TERM_PROGRAM) {
    @{ ok = '✓'; fail = '✗'; cursor = '❯'; wait = '◌'; on = '◆'; off = '◇'; fill = '━'; tl = '╭'; tr = '╮'; bl = '╰'; br = '╯'
       spin = '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
} else {
    @{ ok = '√'; fail = 'x'; cursor = '►'; wait = '○'; on = '■'; off = '□'; fill = '─'; tl = '┌'; tr = '┐'; bl = '└'; br = '┘'
       spin = '|', '/', '-', '\' }
}
function Paint([string]$hex, [string]$s) { (Fg $hex) + $s + $R }
function Width { try { [Math]::Max(40, [Math]::Min(76, [Console]::WindowWidth - 4)) } catch { 72 } }
# Word-wrapped text lines for a box of inner width w
function Wrap([string]$text, [int]$w) {
    $out = New-Object Collections.Generic.List[string]
    foreach ($para in (($text -replace "`r", '').TrimEnd() -split "`n")) {
        if ($para.Length -le $w) { $out.Add($para); continue }
        $line = ''
        # a word longer than the box (a long path) is cut into pieces
        $words = foreach ($wd in ($para -split ' ')) { for ($k = 0; $k -lt [Math]::Max(1, $wd.Length); $k += $w) { $wd.Substring($k, [Math]::Min($w, [Math]::Max(0, $wd.Length - $k))) } }
        foreach ($word in $words) {
            if ($line.Length -eq 0) { $line = $word }
            elseif (($line.Length + 1 + $word.Length) -le $w) { $line += ' ' + $word }
            else { $out.Add($line); $line = $word }
        }
        $out.Add($line)
    }
    return $out
}
# Rounded box: title in the border color, body wrapped
function Box([string]$color, [string]$title, [string]$body) {
    $w = Width; $in = $w - 4
    $b = Fg $color
    Write-Host ''
    Write-Host ("  $b$($GL.tl)" + ('─' * ($w - 2)) + "$($GL.tr)$R")
    if ($title) {
        Write-Host ("  $b│$R " + "$E[1m" + (Fg $color) + $title.PadRight($in) + "$R $b│$R")
        Write-Host ("  $b│$R " + (' ' * $in) + " $b│$R")
    }
    foreach ($l in (Wrap $body $in)) { Write-Host ("  $b│$R " + (Fg $C.text) + $l.PadRight($in) + "$R $b│$R") }
    Write-Host ("  $b$($GL.bl)" + ('─' * ($w - 2)) + "$($GL.br)$R")
}
function Banner {
    if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch {} }
    # figlet "Calvin S"; each line a shade of the accent
    $g = '#c9b8ff', '#a48bff', '#8466f0'
    $art = @(
        '╔═╗┌─┐┌─┐┌┐┌┌─┐┬┌─┐┌─┐┬─┐',
        '╠═╣└─┐├┤ │││├─┤│┌─┘├┤ ├┬┘',
        '╩ ╩└─┘└─┘┘└┘┴ ┴┴└─┘└─┘┴└─')
    Write-Host ''
    for ($i = 0; $i -lt $art.Count; $i++) { Write-Host ('  ' + (Paint $g[$i] $art[$i])) }
    Write-Host ('  ' + (Paint $C.dim $T.tagline))
    Write-Host ''
}
function Say([string]$sym, [string]$color, [string]$text) { Write-Host ('  ' + (Paint $color $sym) + ' ' + (Paint $C.text $text)) }

$SPIN = $GL.spin
function Human([double]$b) { if ($b -ge 1MB) { '{0:0.0} MB' -f ($b / 1MB) } else { '{0:0} KB' -f ($b / 1KB) } }
# Animated bar: a soft highlight runs along the filled part
function Bar([double]$frac, [int]$width, [int]$tick) {
    $fill = [int][Math]::Floor($frac * $width)
    $s = ''
    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $fill) { $s += $(if ((($i - $tick) % 24 + 24) % 24 -lt 3) { (Fg '#e3dbff') } else { (Fg $C.accent) }) + $GL.fill }
        elseif ($i -eq $fill) { $s += (Fg $C.accent) + '╸' }
        else { $s += (Fg '#49454f') + '─' }
    }
    return $s + $R
}

# ---------------------------------------------------------------- input (gum, or simple prompts)
$script:gum = $null
$script:cancelled = $false
function Assert-Answer([int]$code) { if ($code -eq 130) { $script:cancelled = $true; throw (New-Object OperationCanceledException) } }
# gum could not draw a prompt (an error, not an answer): this and every later question use the simple prompts
function Use-PlainPrompts { $script:gum = $null }
# Several options at once. items: @(@(label, value), ...); selected: the values ticked at the start.
# Returns the ticked values. (Labels must not contain commas: gum's --selected takes a comma-separated list.)
function Choose([string]$header, [object[]]$items, [string[]]$selected) {
    if ($script:gum) {
        $args2 = @('choose', '--no-limit', '--header', $header, '--cursor', '❯ ', '--cursor.foreground', $C.accent, '--header.foreground', $C.accent,
            '--selected.foreground', $C.accent, '--selected-prefix', '◆ ', '--unselected-prefix', '◇ ', '--cursor-prefix', '◇ ')
        $pre = @($items | Where-Object { $selected -contains $_[1] } | ForEach-Object { $_[0] })
        if ($pre.Count) { $args2 += @('--selected', ($pre -join ',')) }
        foreach ($it in $items) { $args2 += $it[0] }
        $out = & $script:gum @args2
        Assert-Answer $LASTEXITCODE
        if ($LASTEXITCODE -eq 0) {
            $labels = @($out | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
            return @($items | Where-Object { $labels -contains $_[0] } | ForEach-Object { $_[1] })
        }
        Use-PlainPrompts
    }
    Write-Host ('  ' + (Paint $C.accent $header))
    $res = @()
    foreach ($it in $items) {
        $def = $selected -contains $it[1]
        $hint = if ($def) { "$($T.yes.ToUpper())/n" } else { "$($T.yes)/N" }
        $a = (Read-Host ('    ' + $it[0] + " [$hint]")).Trim()
        if ($a -eq '') { if ($def) { $res += $it[1] } }
        elseif ($a -like "$($T.yes)*" -or $a -like 'y*') { $res += $it[1] }
    }
    return $res
}
function Confirm([string]$prompt, [string]$yes, [string]$no, [bool]$default = $true) {
    if ($script:gum) {
        $d = if ($default) { '--default=true' } else { '--default=false' }
        & $script:gum confirm $prompt --affirmative $yes --negative $no $d --prompt.foreground $C.accent --selected.background $C.accent --selected.foreground $C.ink
        if ($LASTEXITCODE -eq 130) { return $false }
        if ($LASTEXITCODE -le 1) { return ($LASTEXITCODE -eq 0) }
        Use-PlainPrompts
    }
    $hint = if ($default) { "$($T.yes.ToUpper())/n" } else { "$($T.yes)/N" }
    $a = (Read-Host ("  $prompt [$hint]")).Trim()
    if ($a -eq '') { return $default }
    return ($a -like "$($T.yes)*" -or $a -like 'y*')
}
# gum: downloaded into the work dir (removed with it at the end) and checked against the release's checksums.txt
function Get-Gum {
    $gz = Join-Path $work 'gum.zip'
    $base = "https://github.com/charmbracelet/gum/releases/download/v$GUM_VER"
    $name = "gum_${GUM_VER}_Windows_x86_64.zip"
    $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = $UA
    $wc.DownloadFile("$base/$name", $gz)
    $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = $UA
    $sums = $wc.DownloadString("$base/checksums.txt")
    $line = $sums -split "`n" | Where-Object { $_ -match ([regex]::Escape($name) + '\s*$') } | Select-Object -First 1
    $want = if ($line) { (($line -split '\s+') | Where-Object { $_ } | Select-Object -First 1) } else { $null }
    if (-not $want -or $want.ToUpper() -ne (Get-FileHash $gz -Algorithm SHA256).Hash) { throw 'gum checksum does not match' }
    [IO.Compression.ZipFile]::ExtractToDirectory($gz, (Join-Path $work 'gum'))
    $exe = Get-ChildItem (Join-Path $work 'gum') -Recurse -Filter gum.exe | Select-Object -First 1
    if (-not $exe) { throw 'gum.exe not found in the archive' }
    return $exe.FullName
}

# ---------------------------------------------------------------- the release to install
# Never /releases/latest: the fixed "setup" release (the setup exe) is the repository's latest. Only v<x.y.z> tags
# that carry exactly the Windows package and its checksum count; the highest version wins.
function Select-Release([object[]]$releases) {
    $best = $null; $bestVer = [version]'0.0.0'
    foreach ($rel in $releases) {
        if ($rel.draft -or $rel.prerelease) { continue }
        if (([string]$rel.tag_name) -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
        $plain = $Matches[1]; $v = [version]$plain
        $name = "Asenaizer-windows-x64-$plain.zip"
        $zip = @($rel.assets | Where-Object { $_.name -eq $name })
        $sha = @($rel.assets | Where-Object { $_.name -eq "$name.sha256" })
        if ($zip.Count -eq 1 -and $sha.Count -eq 1 -and (-not $best -or $v -gt $bestVer)) {
            $best = @{ version = $plain; zip = $zip[0]; sha = $sha[0] }; $bestVer = $v
        }
    }
    return $best
}
function Get-Release {
    $all = @(); $page = 1
    do {
        # (not wrapped in @(): Windows PowerShell hands the JSON array over as one object, and @() would nest it)
        $batch = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = $UA; 'Accept' = 'application/vnd.github+json' } "https://api.github.com/repos/$repo/releases?per_page=100&page=$page"
        $all += $batch; $page++
    } while ($batch.Count -eq 100 -and $page -le 20)
    return (Select-Release $all)
}

# ---------------------------------------------------------------- download with an animated progress bar
function Get-WithBar([string]$url, [string]$dst, [string]$label, [long]$sizeHint) {
    # a dropped connection continues where it stopped (HTTP Range) instead of starting over or giving up
    $tick = 0; $last = ''
    for ($try = 1; $try -le 5; $try++) {
        try {
            $have = if (Test-Path $dst) { (Get-Item $dst).Length } else { 0 }
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = $UA; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
            if ($have -gt 0) { $req.AddRange([long]$have) }
            $res = $req.GetResponse()
            try {
                if ([int]$res.StatusCode -ne 206) { $have = 0 }
                $total = if ($res.ContentLength -gt 0) { $have + $res.ContentLength } else { $sizeHint }
                $in = $res.GetResponseStream()
                $out = if ($have -gt 0) { New-Object IO.FileStream($dst, [IO.FileMode]::Append) } else { [IO.File]::Create($dst) }
                try {
                    $buf = New-Object byte[] 131072; $done = $have
                    $sw = [Diagnostics.Stopwatch]::StartNew(); $draw = [Diagnostics.Stopwatch]::StartNew()
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n); $done += $n
                        if ($draw.ElapsedMilliseconds -ge 60) {
                            $draw.Restart(); $tick++
                            Poll-CtrlC
                            # 1.0, not 1: [Math]::Min(1, 0.74) picks the integer overload and gives 1
                            $frac = if ($total -gt 0) { [Math]::Min(1.0, [double]$done / $total) } else { 0 }
                            Report @{ phase = 'download'; version = [string]$ver; percent = [int]($frac * 100); done = $done; total = $total }
                            Draw-Download $label $frac $done $total ($(if ($sw.Elapsed.TotalSeconds -gt 0.3) { ($done - $have) / $sw.Elapsed.TotalSeconds } else { 0 })) $tick
                        }
                    }
                }
                finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $res.Dispose() }
            if ($total -gt 0 -and $done -lt $total) { throw "the connection closed at $(Human $done) of $(Human $total)" }
            Report @{ phase = 'download'; version = [string]$ver; percent = 100; done = $done; total = $total }
            Write-Host ("`r  " + (Paint $C.ok $GL.ok) + ' ' + $label + '  ' + (Paint $C.dim (Human (Get-Item $dst).Length)) + "$E[K")
            return
        }
        catch [OperationCanceledException] { throw }
        catch {
            $last = $_.Exception.Message
            # (not $e: variable names ignore case, and $E is the escape character the drawing uses)
            for ($ex = $_.Exception; $ex; $ex = $ex.InnerException) {
                # 416: what is on disk does not fit the file on the server; start over
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -eq 416) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
                # 404 / 403: the file is not there; asking again does not help
                if ($ex -is [Net.WebException] -and $ex.Response -and [int]$ex.Response.StatusCode -in 403, 404, 410) { $try = 5 }
            }
            if ($try -eq 5) { break }
            for ($w = 2 * $try; $w -gt 0; $w--) {
                Write-Host -NoNewline ("`r  " + (Paint $C.warn '↻') + ' ' + $label + '  ' + (Paint $C.dim ($T.retrying -f $w, ($try + 1))) + "$E[K")
                for ($k = 0; $k -lt 10; $k++) { Start-Sleep -Milliseconds 100; Poll-CtrlC }
            }
        }
    }
    throw $last
}
# One frame of the download line: spinner, label, bar, percent, MB done / total and speed
function Draw-Download([string]$label, [double]$frac, [double]$done, [double]$total, [double]$bytesPerSec, [int]$tick) {
    $speed = if ($bytesPerSec -gt 0) { (Human $bytesPerSec) + '/s' } else { '' }
    $pct = if ($total -gt 0) { '{0,3:0}%' -f ($frac * 100) } else { '' }
    $info = ((Human $done) + $(if ($total -gt 0) { ' / ' + (Human $total) }) + '  ' + $speed)
    $bw = 16
    try { $bw = [Math]::Max(5, [Math]::Min(40, [Console]::WindowWidth - 14 - $label.Length - $pct.Length - $info.Length)) } catch {}
    Write-Host -NoNewline ("`r  " + (Paint $C.accent $SPIN[$tick % $SPIN.Count]) + ' ' + $label + '  ' + (Bar $frac $bw $tick) + ' ' + (Paint $C.text $pct) + '  ' + (Paint $C.dim $info) + "$E[K")
}
# Preview without a published release: the download bar played with made-up numbers
function Preview-Download([string]$label) {
    $total = 180MB; $tick = 0
    for ($i = 0; $i -le 100; $i++) {
        Poll-CtrlC
        $done = $total * $i / 100
        Report @{ phase = 'download'; version = [string]$ver; percent = $i; done = [long]$done; total = [long]$total }
        Draw-Download $label ($i / 100.0) $done $total (24MB) $tick
        Start-Sleep -Milliseconds 40; $tick++
    }
    Write-Host ("`r  " + (Paint $C.ok $GL.ok) + ' ' + $label + '  ' + (Paint $C.dim (Human $total)) + "$E[K")
}
# A short step: "◌ label" while it runs, then ✓ / ✗ in place
function With-Spinner([string]$label, [scriptblock]$sb) {
    Write-Host -NoNewline ('  ' + (Paint $C.accent $GL.wait) + ' ' + $label)
    # (not $r: variable names ignore case, and $R is the colour reset Paint appends)
    try { $result = & $sb; Write-Host ("`r  " + (Paint $C.ok $GL.ok) + ' ' + $label + "$E[K"); return $result }
    catch { Write-Host ("`r  " + (Paint $C.err $GL.fail) + ' ' + $label + "$E[K"); throw }
}
# Ctrl+C while we draw: treated as input so that it can be confirmed instead of killing the install half-way
function Poll-CtrlC {
    if ($driver -and (Test-Path -LiteralPath (Join-Path $driver 'cancel'))) { $script:ctrlC = $true }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $script:ctrlC = $true }
        }
    }
    catch {}
    if ($script:ctrlC -and -not $script:setupStarted) { $script:cancelled = $true; throw (New-Object OperationCanceledException) }
}

# The setup app (ASZ_DRIVER) follows the phases from this file; written whole, so it never reads half of it
function Report([hashtable]$status) {
    if (-not $driver) { return }
    if ($status.phase -in 'done', 'error', 'cancelled') { $script:reported = $true }
    try {
        $tmp = Join-Path $driver 'status.tmp'
        [IO.File]::WriteAllText($tmp, ($status | ConvertTo-Json -Compress -Depth 4), (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination (Join-Path $driver 'status.json') -Force
    } catch {}
}
# On a desktop the one-liner hands over to the setup window, Asenaizer-Setup-x64.exe from the "setup"
# release (the same program as the website's download, with this script embedded). It runs only for
# a person at a desktop: not over SSH, not in session 0 or Server Core (no Explorer in this
# session), not when automated (ASZ_DEFAULTS, ASZ_SOURCE, redirected input) or when ASZ_NO_GUI is set.
function Test-Desktop {
    if ($env:ASZ_NO_GUI -eq '1' -or $env:ASZ_SOURCE -or $env:SSH_CONNECTION -or $env:SSH_CLIENT) { return $false }
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($session -eq 0) { return $false }
    [bool](Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}
# Downloads and verifies the setup window and runs it; returns its exit code, or $null when it could not start.
function Open-SetupWindow {
    try {
        $base = "https://github.com/$repo/releases/download/setup"
        $exe = Join-Path $work 'Asenaizer-Setup-x64.exe'
        $web = New-Object Net.WebClient
        $web.Headers['User-Agent'] = 'Asenaizer-Install'
        $want = ($web.DownloadString("$base/Asenaizer-Setup-x64.exe.sha256").Trim() -split '\s+')[0]
        if ($want -notmatch '^[0-9a-fA-F]{64}$') { throw 'no checksum for the setup window' }
        With-Spinner $T.guiOpen { $web.DownloadFile("$base/Asenaizer-Setup-x64.exe", $exe) } | Out-Null
        if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $want.ToUpper()) { throw 'setup window checksum mismatch' }
        $p = Start-Process -FilePath $exe -PassThru -Wait
        Say $GL.ok $C.ok $T.guiClosed
        return $p.ExitCode
    } catch {
        Say '!' $C.warn $T.guiFallback
        return $null
    }
}

function Fail-Box([string]$color, [string]$title, [string]$message) {
    Report @{ phase = 'error'; version = [string]$ver; title = $title; message = $message }
    Box $color $title $message
}

# ---------------------------------------------------------------- main
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $env:TEMP ('asz-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$oldOut = [Console]::OutputEncoding
$script:setup = $null; $script:setupStarted = $false; $script:ctrlC = $false; $script:reported = $false
$ver = $null
$driver = if ($env:ASZ_DRIVER -and (Test-Path -LiteralPath $env:ASZ_DRIVER -PathType Container)) { $env:ASZ_DRIVER } else { $null }
$interactive = (-not $env:ASZ_DEFAULTS) -and (-not $driver) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
$preview = [bool]$env:ASZ_PREVIEW
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    New-Item -ItemType Directory -Force $work | Out-Null
    Banner

    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -lt 19041) { Fail-Box $C.err $T.errTitle ($T.oldWin -f $build); return }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail-Box $C.err $T.errTitle $T.not64; return }

    if ($interactive -and (Test-Desktop)) {
        $code = Open-SetupWindow
        if ($null -ne $code) { $global:LASTEXITCODE = $code; return }
    }

    # gum (the prompts); without it the prompts are simple numbered / yes-no questions
    if ($interactive -and $env:ASZ_PLAIN -ne '1') {
        try { $script:gum = With-Spinner $T.preparing { Get-Gum } }
        catch { $script:gum = $null }
    }

    # ------------------------------------------------------------ the release
    $src = $env:ASZ_SOURCE; $zipUrl = $null; $shaUrl = $null; $zipSize = 0; $fakeDownload = $false
    if ($src) {
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "ASZ_SOURCE is not a folder: $src" }
        $src = (Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\')
        $ver = if (Test-Path -LiteralPath (Join-Path $src 'VERSION')) { [IO.File]::ReadAllText((Join-Path $src 'VERSION')).Trim() } else { '?' }
    }
    else {
        Report @{ phase = 'release' }
        $found = $null; $netFailed = $false
        try { $found = With-Spinner $T.release { Get-Release } }
        catch {
            if (-not $preview) { Fail-Box $C.err $T.netTitle ($T.netBody + "`n`n$($T.errDetail): $($_.Exception.Message)"); return }
            $netFailed = $true
        }
        if ($found) {
            $ver = $found.version
            $zipUrl = $found.zip.browser_download_url; $zipSize = [long]$found.zip.size; $shaUrl = $found.sha.browser_download_url
        }
        elseif ($preview) { $fakeDownload = $true; $ver = '0.0.0'; $zipSize = 180MB }
        elseif (-not $netFailed) { Fail-Box $C.warn $T.release $T.noRelease; return }
    }

    Box $C.accent $T.welcome ($T.welcomeBody + "`n`n$($T.version): $ver" + $(if ($zipSize) { "   $($T.size): $(Human $zipSize)" }))
    Write-Host ''

    # ------------------------------------------------------------ options
    $opt = [ordered]@{ startup = ($env:ASZ_NO_STARTUP -ne '1'); desktop = ($env:ASZ_DESKTOP -eq '1'); launch = ($env:ASZ_NO_LAUNCH -ne '1') }
    if ($interactive) {
        $items = @(@($T.oStartup, 'startup'), @($T.oDesktop, 'desktop'), @($T.oLaunch, 'launch'))
        $ticked = @($opt.Keys | Where-Object { $opt[$_] })
        $picked = @(Choose $T.qOptions $items $ticked)
        foreach ($key in @($opt.Keys)) { $opt[$key] = $picked -contains $key }
        $yn = { param($b) if ($b) { $T.on } else { $T.off } }
        Box $C.accent $T.summary ("$($T.version): $ver`n$($T.oStartup): $(& $yn $opt.startup)`n$($T.oDesktop): $(& $yn $opt.desktop)`n$($T.oLaunch): $(& $yn $opt.launch)")
        Write-Host ''
        if (-not (Confirm $T.qGo $T.go $T.cancel $true)) { $script:cancelled = $true; throw (New-Object OperationCanceledException) }
        Write-Host ''
    }
    Report @{ phase = 'download'; version = [string]$ver; percent = 0 }

    # ------------------------------------------------------------ package
    # no console input (redirected, ASZ_DEFAULTS in a pipeline): Ctrl+C then simply ends the script
    try { [Console]::TreatControlCAsInput = $true } catch {}
    if ($fakeDownload) { Preview-Download $T.downloading }
    elseif (-not $src) {
        $zip = Join-Path $work 'Asenaizer.zip'
        try { Get-WithBar $zipUrl $zip $T.downloading $zipSize }
        catch [OperationCanceledException] { throw }
        catch { Fail-Box $C.err $T.netTitle ($T.netBody + "`n`n$($T.errDetail): $($_.Exception.Message)"); return }
        Report @{ phase = 'verify'; version = [string]$ver }
        $ok = With-Spinner $T.verifying {
            $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = $UA
            $raw = $wc.DownloadString($shaUrl)
            $expected = ([string](($raw -split '\s+') | Where-Object { $_ } | Select-Object -First 1)).Trim().ToUpper()
            ($expected -match '^[0-9A-F]{64}$') -and ($expected -eq (Get-FileHash $zip -Algorithm SHA256).Hash)
        }
        if (-not $ok) { Fail-Box $C.err $T.errTitle $T.badPkg; return }
        Poll-CtrlC
        Report @{ phase = 'extract'; version = [string]$ver }
        $pkg = Join-Path $work 'pkg'
        With-Spinner $T.extracting { [IO.Compression.ZipFile]::ExtractToDirectory($zip, $pkg) } | Out-Null
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        # the package's files sit at the root of the zip; a zip with one top folder is accepted too
        $src = if (Test-Path (Join-Path $pkg 'installer\setup.ps1')) { $pkg }
               else { (Get-ChildItem $pkg -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'installer\setup.ps1') } | Select-Object -First 1).FullName }
        if (-not $src) { Fail-Box $C.err $T.errTitle $T.badPkg; return }
        $pkgVer = if (Test-Path (Join-Path $src 'VERSION')) { [IO.File]::ReadAllText((Join-Path $src 'VERSION')).Trim() } else { '' }
        if ($pkgVer -ne $ver) { Fail-Box $C.err $T.errTitle $T.badPkg; return }
    }
    if (-not $fakeDownload) {
        foreach ($need in 'installer\setup.ps1', 'app\asenaizer-tray.exe', 'app\Humanizer.exe', 'VERSION') {
            if (-not (Test-Path (Join-Path $src $need))) { Fail-Box $C.err $T.errTitle ($T.badPkg + "`n`n$($T.errDetail): $need"); return }
        }
    }
    Poll-CtrlC

    # ------------------------------------------------------------ setup (same user, hidden); we draw its progress
    # Nothing is stopped here: setup.ps1's "stop" step ends Asenaizer's own processes (by their path)
    $progressFile = Join-Path $work 'progress.json'; $cancelFile = Join-Path $work 'cancel'
    if ($preview) {
        # the steps of setup.ps1 played by an ordinary hidden process: same progress file, same cancel file
        $sim = Join-Path $work 'preview-setup.ps1'
        [IO.File]::WriteAllText($sim, @'
param([string]$ProgressFile, [string]$CancelFile, [string]$Mode)
$utf8 = New-Object Text.UTF8Encoding $false
function P([hashtable]$o) { $o.total = 7; [IO.File]::WriteAllText($ProgressFile, ($o | ConvertTo-Json -Compress), $utf8) }
$files = 'asenaizer-tray.exe', 'Humanizer.exe', 'engine\cpu\llama-server.exe', 'engine\vulkan\ggml-vulkan.dll', 'engine\cuda\ggml-cuda.dll', 'engine\cuda\cublasLt64_12.dll'
$n = 0
foreach ($id in 'check', 'runtimes', 'stop', 'files', 'shortcuts', 'startup', 'register') {
    $n++
    for ($pc = 0; $pc -le 99; $pc += 3) {
        if (Test-Path $CancelFile) { P @{ state = 'rollback'; step = $id; n = $n; percent = $pc }; Start-Sleep 2; P @{ state = 'cancelled'; step = $id; n = $n; percent = $pc }; exit 2 }
        if ($Mode -eq 'fail' -and $id -eq 'files' -and $pc -ge 50) {
            P @{ state = 'rollback'; step = $id; n = $n; percent = $pc }; Start-Sleep -Milliseconds 1500
            P @{ state = 'error'; step = $id; n = $n; percent = $pc; error = 'Preview: simulated failure' }; exit 1
        }
        $p = @{ state = 'running'; step = $id; n = $n; percent = $pc }
        if ($id -eq 'files') { $p.file = $files[[int][Math]::Floor($pc / 17)] }
        if ($Mode -eq 'warn' -and $id -eq 'runtimes') { $p.warn = @('webview2') }
        P $p; Start-Sleep -Milliseconds $(if ($id -eq 'files') { 110 } else { 30 })
    }
}
if ($Mode -eq 'warn') { P @{ state = 'done'; step = 'register'; n = 7; percent = 100; warn = @('webview2') } } else { P @{ state = 'done'; step = 'register'; n = 7; percent = 100 } }
exit 0
'@, (New-Object Text.UTF8Encoding $false))
        $mode = switch ($env:ASZ_PREVIEW) { 'fail' { 'fail' } 'warn' { 'warn' } default { 'ok' } }
        $script:setup = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$sim`"",
            '-ProgressFile', "`"$progressFile`"", '-CancelFile', "`"$cancelFile`"", '-Mode', $mode)
    }
    else {
        $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $src 'installer\setup.ps1')`"",
            '-Source', "`"$src`"", '-ProgressFile', "`"$progressFile`"", '-CancelFile', "`"$cancelFile`"")
        if (-not $opt.startup) { $args2 += '-NoStartup' }
        if ($opt.desktop) { $args2 += '-Desktop' }
        if (-not $opt.launch) { $args2 += '-NoLaunch' }
        $script:setup = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $args2
    }
    # keeps the process handle open: without it Windows PowerShell may report no exit code once it has ended
    [void]$script:setup.Handle
    $script:setupStarted = $true
    Report @{ phase = 'setup'; version = [string]$ver; progress = $progressFile; steps = @($STEP_IDS | ForEach-Object { $T.steps[$_] }) }

    Write-Host ''
    Write-Host ('  ' + "$E[1m" + (Paint $C.accent $T.installing))
    $lines = $STEP_IDS.Count + 3
    for ($i = 0; $i -lt $lines; $i++) { Write-Host '' }
    Write-Host -NoNewline "$E[?25l"
    $tick = 0; $clock = [Diagnostics.Stopwatch]::StartNew(); $p = $null; $asked = $false
    while ($true) {
        $done = $script:setup.HasExited
        try { if (Test-Path $progressFile) { $p = [IO.File]::ReadAllText($progressFile) | ConvertFrom-Json } } catch {}
        Poll-CtrlC
        if ($script:ctrlC -and -not $asked -and -not $done -and $driver) {
            $asked = $true
            New-Item -ItemType File -Force $cancelFile | Out-Null
        }
        if ($script:ctrlC -and -not $asked -and -not $done) {
            $asked = $true
            Write-Host -NoNewline "$E[?25h"; Write-Host ''
            try { [Console]::TreatControlCAsInput = $false } catch {}
            if (Confirm $T.qStop $T.stopYes $T.stopNo $false) { New-Item -ItemType File -Force $cancelFile | Out-Null }
            else { $script:ctrlC = $false; $asked = $false }
            try { [Console]::TreatControlCAsInput = $true } catch {}
            Write-Host -NoNewline "$E[?25l"
            for ($i = 0; $i -lt $lines; $i++) { Write-Host '' }
        }
        # redraw the step list in place
        $n = if ($p) { [int]$p.n } else { 0 }
        $state = if ($p) { [string]$p.state } else { 'running' }
        $out = "$E[$($lines)A"
        $progressRow = $false
        for ($i = 0; $i -lt $STEP_IDS.Count; $i++) {
            $label = $T.steps[$STEP_IDS[$i]]
            if ($i + 1 -lt $n -or ($state -eq 'done')) { $row = (Paint $C.ok $GL.ok) + ' ' + (Paint $C.dim $label) }
            elseif ($i + 1 -eq $n -and $state -eq 'running') { $row = (Paint $C.accent $SPIN[$tick % $SPIN.Count]) + ' ' + (Paint $C.text $label) }
            elseif ($i + 1 -eq $n -and $state -in 'error', 'rollback') { $row = (Paint $C.err $GL.fail) + ' ' + (Paint $C.text $label) }
            else { $row = (Paint '#49454f' '·') + ' ' + (Paint '#6f6a75' $label) }
            $out += "`r  $row$E[K`n"
            if ($i + 1 -eq $n -and $state -eq 'running') {
                $percent = [Math]::Max(0, [Math]::Min(99, [int]$p.percent))
                $detail = ''
                if ($p.file) {
                    $name = [string]$p.file
                    if ($name.Length -gt 26) { $name = '...' + $name.Substring($name.Length - 23) }
                    $detail = '  ' + $name
                }
                $out += "`r    " + (Bar ([double]$percent / 100.0) 24 $tick) + ' ' + (Paint $C.text ('{0,3}%' -f $percent)) + (Paint $C.dim $detail) + "$E[K`n"
                $progressRow = $true
            }
        }
        if (-not $progressRow) { $out += "`r$E[K`n" }
        $foot = if ($state -eq 'rollback' -or (Test-Path $cancelFile)) { Paint $C.warn $T.rollingBack } else { Paint $C.dim $T.ctrlc }
        $out += "`r$E[K`n`r  " + (Paint $C.dim ('{0:mm\:ss}' -f $clock.Elapsed)) + '  ' + $foot + "$E[K`n"
        Write-Host -NoNewline $out
        if ($done) { break }
        Start-Sleep -Milliseconds 90; $tick++
    }
    Write-Host -NoNewline "$E[?25h"
    # the last progress the setup wrote (it can end between two reads)
    try { if (Test-Path $progressFile) { $p = [IO.File]::ReadAllText($progressFile) | ConvertFrom-Json } } catch {}
    $code = $script:setup.ExitCode
    $script:setupStarted = $false
    $log = Join-Path $env:TEMP 'asenaizer-install.log'
    if ($code -eq 0) {
        $warnNames = @{ webview2 = $T.xWebView2 }
        $warn = @(@($p.warn | Where-Object { $_ }) | ForEach-Object { if ($warnNames.ContainsKey([string]$_)) { $warnNames[[string]$_] } else { [string]$_ } })
        $body = if ($opt.launch) { $T.doneBody } else { $T.doneBodyQuiet }
        Report @{ phase = 'done'; version = [string]$ver; title = $T.doneTitle; body = $body; warnTitle = $T.warnTitle; warnBody = $T.warnBody; warn = $warn; log = $log }
        Box $C.ok $T.doneTitle $body
        # optional parts that failed (WebView2): Asenaizer is installed, these are reported
        if ($warn.Count) {
            $list = @($warn | ForEach-Object { '• ' + $_ }) -join "`n"
            Box $C.warn $T.warnTitle ($list + "`n`n" + $T.warnBody + "`n$($T.errLog): $log")
        }
    }
    elseif ($code -eq 2 -or (Test-Path $cancelFile)) { Report @{ phase = 'cancelled'; version = [string]$ver; title = $T.cancelTitle; message = $T.cancelBody }; Box $C.warn $T.cancelTitle $T.cancelBody }
    else {
        $stepName = if ($p -and $T.steps.ContainsKey([string]$p.step)) { $T.steps[[string]$p.step] } else { '?' }
        $detail = if ($p -and $p.error) { [string]$p.error } else { "exit $code" }
        Report @{ phase = 'error'; version = [string]$ver; title = $T.errTitle; message = ($T.errBody -f $stepName); detail = $detail; log = $log }
        Box $C.err $T.errTitle (($T.errBody -f $stepName) + "`n`n$($T.errDetail): $detail`n$($T.errLog): $log`n`n" + $T.errRetry)
    }
}
catch [OperationCanceledException] {
    Report @{ phase = 'cancelled'; version = [string]$ver; title = $T.cancelTitle; message = $T.cancelBody }
    Write-Host ''
    Box $C.warn $T.cancelTitle $T.cancelBody
}
catch {
    Report @{ phase = 'error'; version = [string]$ver; title = $T.errTitle; message = ($T.errBody -f $T.preparing); detail = $_.Exception.Message }
    Box $C.err $T.errTitle (($T.errBody -f $T.preparing) + "`n`n$($T.errDetail): $($_.Exception.Message)`n`n" + $T.errRetry)
}
finally {
    if ($driver -and -not $script:reported) { Report @{ phase = 'error'; title = $T.errTitle; message = $T.errRetry } }
    # Ctrl+C that got through: the setup rolls back by itself once it sees the cancel file
    if ($script:setupStarted -and $script:setup -and -not $script:setup.HasExited) {
        New-Item -ItemType File -Force (Join-Path $work 'cancel') -ErrorAction SilentlyContinue | Out-Null
        [void]$script:setup.WaitForExit(120000)
    }
    try { [Console]::TreatControlCAsInput = $false } catch {}
    Write-Host -NoNewline "$E[?25h$R"
    try { [Console]::OutputEncoding = $oldOut } catch {}
    # nothing stays in %TEMP%: gum, the package, the progress files
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ''
}
}
