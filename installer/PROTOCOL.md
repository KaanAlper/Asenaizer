# Asenaizer Windows installer protocol

Adapted from Logical Lunge (`KaanAlper/logical-lunge`, main: `installer/gui/Setup.cs`,
`install.ps1`, `installer/setup.ps1`). Same architecture: **one install path**.

```
Asenaizer-Setup-x64.exe  (installer/gui/Setup.cs, WinForms .NET Framework 4.8, csc.exe)
   └─ embedded resource "install.ps1"  → extracted and run hidden as the normal user
        └─ downloads + verifies the release zip, then runs installer\setup.ps1 from it
             (as the same user: Asenaizer installs per user, so there is NO UAC prompt)
```

`install.ps1` also works on its own:
`irm https://raw.githubusercontent.com/KaanAlper/Asenaizer/main/install.ps1 | iex`

## Names

| Thing | Value |
| --- | --- |
| Repo | `KaanAlper/Asenaizer` |
| App release tag | `v<semver>` (for example `v0.1.0`), never draft or prerelease |
| Windows package asset | `Asenaizer-windows-x64-<ver>.zip` and `Asenaizer-windows-x64-<ver>.zip.sha256` |
| Linux package asset (same release) | `Asenaizer-<ver>-linux-x64.tar.gz` and `.sha256` |
| Setup exe asset | `Asenaizer-Setup-x64.exe` on the fixed release tag `setup` (the repository's "latest") |
| Install dir | `%LOCALAPPDATA%\Programs\Asenaizer` (app files directly inside) |
| Service data (models, logs, pairings) | `%LOCALAPPDATA%\Humanizer` (owned by the Go service, not by the installer) |
| Log | `%TEMP%\asenaizer-install.log` |
| Download cache | `%TEMP%\asz-downloads` |
| GUI work dir | `%TEMP%\asz-setup-<8 hex>` |
| install.ps1 work dir | `%TEMP%\asz-install-<8 hex>` |
| User agent | `Asenaizer-Install` / `Asenaizer-Setup` |
| Minimum Windows | build 19041, 64-bit |

## Package zip layout

```
Asenaizer-windows-x64-<ver>.zip
├─ VERSION                      (plain semver, for example 0.1.0)
├─ app\asenaizer-tray.exe       (Rust tray, starts the service)
├─ app\Humanizer.exe            (Go service, -H windowsgui)
├─ app\asenaizer.ico
├─ app\LICENSE.txt, app\NOTICE.txt
├─ app\engine\{cpu,vulkan,cuda}\llama-server.exe (+ DLLs)
├─ installer\setup.ps1
└─ installer\uninstall.ps1      (setup copies it into the install dir)
```

## Environment variables (install.ps1 inputs; no param block)

| Variable | Meaning |
| --- | --- |
| `ASZ_DRIVER` | GUI mode: path of the GUI work dir; write status there, watch `<dir>\cancel` |
| `ASZ_SOURCE` | Use a local package folder (unzipped layout above) instead of downloading |
| `ASZ_DEFAULTS` | No questions in the console |
| `ASZ_NO_STARTUP` | `1` = do not start Asenaizer at sign-in |
| `ASZ_DESKTOP` | `1` = add a desktop shortcut |
| `ASZ_NO_LAUNCH` | `1` = do not open Asenaizer when done |
| `ASZ_PREVIEW` | Simulated install, no changes (`fail` / `warn` variants like Logical Lunge) |
| `ASZ_PLAIN` | `1` = simple numbered prompts instead of gum in the console |
| `ASZ_NO_GUI` | `1` = stay in the console. Otherwise the one-liner, run by a person at a desktop (not SSH, session 0, Server Core or automated runs), downloads `Asenaizer-Setup-x64.exe` from the `setup` release, verifies its `.sha256` and opens it; any failure falls back to the console |

## status.json (install.ps1 → GUI, in `ASZ_DRIVER`)

Written atomically (`status.tmp` then move). Keys, as in Logical Lunge:
`phase, version, percent, done, total, progress, steps, title, body, message, detail, log, warn, warnTitle, warnBody`.

Phases before setup.ps1: `release`, `download` (percent, done, total in bytes), `verify`,
`extract`, `stop`. Then `setup` with `progress` = path of setup.ps1's progress JSON and
`steps` = localized step labels. Final phases: `done`, `error`, `cancelled`.

## progress.json (setup.ps1 → install.ps1 and GUI)

`{state, step, n, total, percent, file, warn}`; `state` is `running`, `rollback`, `error`,
`cancelled` or `done`. `percent` only moves forward and stays at most 99 until `done`.

## setup.ps1

`param([Parameter(Mandatory)][string]$Source, [switch]$NoStartup, [switch]$Desktop, [switch]$NoLaunch, [string]$ProgressFile, [string]$CancelFile)`

Exit codes: `0` ok, `1` error, `2` cancelled. Steps (`$TOTAL_STEPS = 7`):

1. `check` — package has `app\asenaizer-tray.exe`, `app\Humanizer.exe`, `VERSION`; build ≥ 19041; 64-bit.
2. `runtimes` — WebView2 Runtime (per-user evergreen bootstrapper `/silent /install` if missing). Optional: a failure is a warning (the tray then opens the device page in the browser).
3. `stop` — stop `asenaizer-tray.exe`, `Humanizer.exe` and any `llama-server.exe` **whose path is under the install dir** (never by name alone); retry for up to 15 s.
4. `files` — move the current install aside to a rollback folder, copy `app\*` and `installer\uninstall.ps1` in, write `VERSION`.
5. `shortcuts` — Start menu `Asenaizer.lnk` → `asenaizer-tray.exe --settings` (icon `asenaizer.ico`); desktop shortcut only with `-Desktop`.
6. `startup` — `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value `Asenaizer` = `"<dir>\asenaizer-tray.exe"`, removed when `-NoStartup`.
7. `register` — `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Asenaizer`: DisplayName `Asenaizer`, DisplayVersion, Publisher `Kaan Alper`, DisplayIcon, InstallLocation, URLInfoAbout `https://kaanalper.github.io/Asenaizer/`, UninstallString `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<dir>\uninstall.ps1"`, NoModify/NoRepair = 1, EstimatedSize (KB).

Every change is recorded; on error or cancel everything is put back (files, shortcuts, registry
values) and a previously installed tray is started again. After commit: remove the rollback
folder and, unless `-NoLaunch`, start `asenaizer-tray.exe --settings` as the user.

## uninstall.ps1

`param([switch]$RemoveData, [switch]$KeepData, [switch]$Quiet)`: stop processes as above,
remove the Run value, shortcuts, uninstall key and install dir. Ask (unless `-Quiet`) whether
to also delete `%LOCALAPPDATA%\Humanizer` (models are several GB); `-RemoveData` / `-KeepData`
answer it without asking.

## Console prompts

In the console (no `ASZ_DRIVER`) questions use [gum](https://github.com/charmbracelet/gum)
v2.0.2 like Logical Lunge's earlier installer (commit `a88fcef`): downloaded into the work dir,
verified against the release's `checksums.txt`, removed at the end. Accent `#a48bff`. Exit code
130 cancels. If gum is missing or fails, simple numbered prompts are used instead.

## Linux

`scripts/install-linux.sh` follows the same contract. With a desktop session it starts the setup
window (`Asenaizer-Setup-linux-x64` from the `setup` release, the Linux twin of the Windows
exe), which runs the script in driver mode. Without a display the same steps run in the console
with gum prompts.
