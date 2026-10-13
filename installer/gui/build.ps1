# Builds Asenaizer-Setup-x64.exe with the C# compiler that comes with Windows (.NET Framework 4.8).
# Asenaizer is 64-bit only, so there is no x86 build.
# install.ps1 (repo root) is embedded: the setup app runs the same install as the one-line command.
#   .\installer\gui\build.ps1 [-Out dist] [-Shots]   (-Shots: also draws every page to dist\shots for a look)
param([string]$Out = (Join-Path $PSScriptRoot '..\..\dist'), [switch]$Shots)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found: $csc" }
if (-not (Test-Path (Join-Path $root 'install.ps1'))) { throw "install.ps1 not found in $root" }
New-Item -ItemType Directory -Force $Out | Out-Null
$exe = Join-Path $Out 'Asenaizer-Setup-x64.exe'
& $csc /nologo /codepage:65001 /target:winexe /optimize+ /platform:x64 "/out:$exe" `
    "/win32icon:$PSScriptRoot\asenaizer.ico" "/win32manifest:$PSScriptRoot\app.manifest" `
    "/resource:$root\install.ps1,install.ps1" "/resource:$PSScriptRoot\asenaizer.ico,asenaizer.ico" `
    /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll "$PSScriptRoot\Setup.cs"
if ($LASTEXITCODE) { throw 'Setup build failed (x64)' }
Write-Host "built $exe"
if ($Shots) {
    $dir = Join-Path $Out 'shots'
    $p = Start-Process $exe -ArgumentList '--shots', "`"$dir`"" -Wait -PassThru
    if ($p.ExitCode) { throw "Screenshots failed ($($p.ExitCode))" }
    Get-ChildItem $dir -Filter *.png | ForEach-Object { Write-Host "shot $($_.Name)" }
}
