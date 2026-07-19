# Prerequisites

Run the preflight before the first build:

```powershell
.\tests\Test-Prerequisites.ps1
```

It resolves every dependency, prints a table, and returns a non-zero result only if a required tool
is missing. Use it in a guard if you like:

```powershell
if (.\tests\Test-Prerequisites.ps1 -Quiet) { .\scripts\Build-GoldenImage.ps1 }
```

## Required

| Tool | Used by | Install |
|------|---------|---------|
| Windows PowerShell 5.1+ | all scripts | Ships with Windows; PowerShell 7+ also works |
| Administrator rights | image mount, driver export, ISO build | Run the shell as Administrator |
| `oscdimg.exe` (Windows ADK) | `New-DeployableIso`, `New-UnattendIso`, `Slipstream-WindowsMedia` | Install the Windows ADK and its "Windows PE add-on", which includes the Deployment Tools |

`oscdimg.exe` is the only external application you must install. Without it, ISO creation fails. The
scripts look for it under `...\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\
Oscdimg\`, then on `PATH`.

## Built in to Windows

These ship with Windows 10/11 and are effectively always present. The preflight checks them for
completeness.

| Tool | Used by |
|------|---------|
| `dism.exe` | `Slipstream-WindowsMedia`, `Repair-Server2025Store` |
| `pnputil.exe` | `Get-MachineInventory` (driver export) |
| `reagentc.exe` | `Invoke-PostInstall` (WinRE enable) |
| `diskpart.exe` | answer file at install time |
| `icacls.exe` | `Invoke-PostInstall` (SSH ACLs) |
| `reg.exe` | `Invoke-PrivacyHardening` |

## Optional

None of these is required. Each feature that uses one checks for it with
`Get-Command … -ErrorAction SilentlyContinue` and degrades gracefully if it is absent.

| Tool | Used by | If absent |
|------|---------|-----------|
| `openssl` | `New-UbuntuUserData` password hash | Falls back to WSL, then to pasting a hash |
| WSL (a registered distro) | `New-UbuntuUserData` password hash (fallback) | Not required. Only used if `openssl` is missing; you can always paste a hash |
| `dotnet` | `Get-MachineInventory` (.NET runtime list) | That one inventory sub-list is skipped |
| `git` | repository hygiene | The credential `.gitignore` rules only apply inside a git repo |

The WSL check looks for a **registered distribution**, not just `wsl.exe`. Windows ships a bare
`wsl.exe` launcher in `System32` even when WSL was never installed, so a simple "is `wsl.exe` present"
test reports a false positive. The preflight reads the per-user `Lxss` registry (what `wsl --list`
uses) and only reports WSL as usable when at least one distro is registered.

The most convenient way to get `openssl` on Windows is Git for Windows, which bundles it at
`C:\Program Files\Git\usr\bin\openssl.exe`. If you would rather not install anything, generate the
hash on any Linux machine (`openssl passwd -6` or `mkpasswd --method=SHA-512`) and paste it when
`New-UbuntuUserData.ps1` asks.

## Note on the oscdimg checks

Each ISO-building script currently resolves `oscdimg.exe` on its own and throws a clear error if it
is missing. That check works but is duplicated across three scripts and fails at the point of use,
which for a slipstream can be after a long image mount. The preflight above surfaces the same problem
up front. Centralising the three copies into one shared resolver is a possible follow-up; it would
touch the core build scripts, so it is not done yet.
