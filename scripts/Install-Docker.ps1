<#
.SYNOPSIS
    On-demand installer/configurator for Docker Desktop (Linux-container backend via WSL2) on a
    deployed Windows box. Deliberately NOT part of the golden image - run it per machine, when needed.

.DESCRIPTION
    Three phases, each skippable:
      1. WSL2 backend  - Docker's Linux containers need WSL2. Ensures the WSL + VirtualMachinePlatform
                         features and the WSL2 kernel are in place (no distro), and sets WSL2 default.
      2. Install       - installs Docker Desktop with winget.
      3. Config        - applies any files you dropped in docker\config (real names, not *.sample):
                           .wslconfig            -> %USERPROFILE%\.wslconfig
                           daemon.json           -> %ProgramData%\Docker\config\daemon.json
                           settings-store.json   -> %APPDATA%\Docker\settings-store.json
                         Contribute your own by copying a *.sample to its real name and editing it.

    A REBOOT is required after the WSL/VMP features are first enabled. NOTE on the hypervisor stack:
    enabling WSL2/VirtualMachinePlatform turns on the Windows Hypervisor Platform, which affects how
    (and how fast) VMware Workstation runs on the same box. Weigh that if this machine also runs VMware.

    Licensing: Docker Desktop is free for personal use, education, and small business, but requires a
    paid subscription for larger organisations - confirm your case. Podman Desktop and Rancher Desktop
    are open-source alternatives that also run Linux containers over WSL2; pass a different -WingetId
    (e.g. RedHat.Podman-Desktop or SUSE.RancherDesktop) to install one of those instead.

.PARAMETER ConfigDir
    Folder holding config files to apply. Default: repo docker\config.

.PARAMETER WingetId
    The winget package to install. Default Docker.DockerDesktop.

.PARAMETER SkipWsl
    Do not touch WSL (assume the backend is already set up).

.PARAMETER SkipInstall
    Do not install anything; only apply config from ConfigDir.

.EXAMPLE
    .\scripts\Install-Docker.ps1
.EXAMPLE
    .\scripts\Install-Docker.ps1 -SkipInstall           # just (re)apply docker\config
.EXAMPLE
    .\scripts\Install-Docker.ps1 -WingetId RedHat.Podman-Desktop

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Windows PowerShell 5.1+. Elevated.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$WingetId = 'Docker.DockerDesktop',
    [switch]$SkipWsl,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (defined before first use)
# =====================================================================================
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [datetime]::Now }
function Info ($m) { Write-Host   "$(Get-TS)  $m" }
function Warn ($m) { Write-Warning "$(Get-TS)  $m" }

# Copy one config file to its destination if the REAL file (not a .sample) is present.
function Copy-Config {
    param([string]$SrcDir, [string]$Name, [string]$Dest)
    $src = Join-Path $SrcDir $Name
    if (-not (Test-Path -LiteralPath $src)) {
        if (Test-Path -LiteralPath "$src.sample") { Info "  $Name : only a .sample present - copy it to '$Name' and edit to apply. Skipped." }
        return
    }
    try {
        $parent = Split-Path $Dest -Parent
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $Dest -Force
        Info "  applied $Name -> $Dest"
    } catch { Warn "  could not apply ${Name}: $($_.Exception.Message)" }
}

# =====================================================================================
#  Setup
# =====================================================================================
$repo = Split-Path $PSScriptRoot -Parent
if (-not $ConfigDir) { $ConfigDir = Join-Path $repo 'docker\config' }

$logDir = 'C:\ProgramData\server2025-servicing'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $logDir ("Install-Docker_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))) -Append | Out-Null
Info "===== Install-Docker v$ScriptVersion ====="
Info "Config dir: $ConfigDir"

$needReboot = $false

trap {
    Warn "FATAL: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# =====================================================================================
#  1. WSL2 backend
# =====================================================================================
if (-not $SkipWsl) {
    Info '[WSL2] ensuring the WSL2 backend (features + kernel, no distro)'
    $wsl = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
    if ($wsl) {
        # The System32 wsl.exe launcher enables the features + installs the kernel on --install.
        try { & $wsl.Source --install --no-distribution 2>&1 | Out-Host } catch { Warn "  wsl --install failed: $($_.Exception.Message)" }
        try { & $wsl.Source --set-default-version 2 2>&1 | Out-Host }     catch { Write-Verbose 'set-default-version skipped' }
        $needReboot = $true
    } else {
        # Fallback: enable the features directly (deterministic, offline).
        foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
            try { Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction Stop | Out-Null; Info "  enabled: $feat" }
            catch { Warn "  could not enable ${feat}: $($_.Exception.Message)" }
        }
        $needReboot = $true
        Warn '  WSL kernel not installed (no wsl.exe). After reboot run: wsl --update'
    }
}

# =====================================================================================
#  2. Install Docker Desktop (or the -WingetId you passed)
# =====================================================================================
if (-not $SkipInstall) {
    Info "[Install] $WingetId via winget"
    $winget = Get-Command 'winget' -ErrorAction SilentlyContinue
    if ($winget) {
        & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements | Out-Host
        if ($LASTEXITCODE -ne 0) { Warn "  winget returned $LASTEXITCODE (already installed, or needs attention)." }
        else { Info '  install reported success' }
    } else {
        Warn '  winget (App Installer) not found. Install Docker Desktop manually from https://www.docker.com/products/docker-desktop/,'
        Warn '  then re-run this script with -SkipInstall to apply docker\config.'
    }
}

# =====================================================================================
#  3. Apply config
# =====================================================================================
Info "[Config] applying files from $ConfigDir (real names only; *.sample are templates)"
if (Test-Path $ConfigDir) {
    Copy-Config $ConfigDir '.wslconfig'          (Join-Path $env:USERPROFILE '.wslconfig')
    Copy-Config $ConfigDir 'daemon.json'         (Join-Path $env:ProgramData 'Docker\config\daemon.json')
    Copy-Config $ConfigDir 'settings-store.json' (Join-Path $env:APPDATA 'Docker\settings-store.json')
} else {
    Info "  no config dir at $ConfigDir - skipping config."
}

# =====================================================================================
#  Done
# =====================================================================================
Info '===== Install-Docker complete ====='
if ($needReboot) { Warn 'A REBOOT is required for the WSL2 / VirtualMachinePlatform features to take effect.' }
Info 'After reboot: start Docker Desktop, then verify with:  docker run --rm hello-world'
Info 'For a Linux shell without Docker:  wsl --install -d Ubuntu'
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0
