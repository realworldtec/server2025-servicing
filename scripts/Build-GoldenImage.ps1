<#
.SYNOPSIS
    One command to build a point-in-time golden workstation image end to end: refresh the patched
    media for the profile's product, then build the hardened, app-loaded, disk-wiping deploy ISO.

.DESCRIPTION
    Reads a golden-image profile from config\Deploy.psd1 and runs the two stages in order:

      [1/2]  Slipstream (Invoke-MediaJobs.ps1 -Jobs <profile.Product>)
             Ensures the patched source media is CURRENT. Fast no-op if this month's LCU is already
             built (the slipstream's own ALREADY-BUILT guard). This is why the golden image is
             always "point in time" against the latest cumulative update.

      [2/2]  Deploy ISO (New-DeployableIso.ps1 -DeployProfile <name>)
             Trims to the single edition, downloads + bakes the current Office bits, embeds Acrobat,
             injects the hardening + first-logon post-install, bakes the answer file, builds + verifies
             the bootable ISO. All settings come from the profile.

    Both sub-scripts run as child processes (so their exit codes are observable and their own
    `exit` can't abort this orchestrator). If a stage fails, the run stops with a clear message.

    Everything that defines the image lives in config\Deploy.psd1 - edit that, not this script.

.PARAMETER DeployProfile
    Profile to build. Default: the config's DefaultProfile.

.PARAMETER DeployConfig
    Deploy config. Default ..\config\Deploy.psd1.

.PARAMETER NoProxy
    Pass -NoProxy through to the slipstream (force a direct connection).

.PARAMETER SkipSlipstream
    Skip stage 1 and build the deploy ISO from the EXISTING patched media (e.g. you just built it,
    or you're only iterating on the deploy side).

.EXAMPLE
    .\scripts\Build-GoldenImage.ps1
.EXAMPLE
    .\scripts\Build-GoldenImage.ps1 -DeployProfile 'Win11-Pro-Lean'
.EXAMPLE
    .\scripts\Build-GoldenImage.ps1 -SkipSlipstream        # media already current

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Run elevated on the build host (ADK + WinPE). This is the long one - it can download ~3 GB of
    Office and build a ~12-13 GB ISO. That's expected for a self-contained golden USB.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$DeployProfile,
    [string]$DeployConfig,
    [switch]$NoProxy,
    [switch]$SkipSlipstream
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }

$repo = Split-Path $PSScriptRoot -Parent
if (-not $DeployConfig) { $DeployConfig = Join-Path $repo 'config\Deploy.psd1' }
if (-not (Test-Path $DeployConfig)) { throw "Deploy config not found: $DeployConfig" }

$deployCfg  = Import-PowerShellDataFile -Path $DeployConfig -ErrorAction Stop
$dpProfiles = if ($deployCfg.ContainsKey('Profiles')) { $deployCfg.Profiles } else { $deployCfg }
if (-not $DeployProfile -and $deployCfg.ContainsKey('DefaultProfile')) { $DeployProfile = [string]$deployCfg.DefaultProfile }
if (-not $DeployProfile) { throw "No -DeployProfile given and no DefaultProfile in $DeployConfig." }
if (-not ($dpProfiles -and $dpProfiles.ContainsKey($DeployProfile))) {
    throw "Deploy profile '$DeployProfile' not found in $DeployConfig. Defined: $(($dpProfiles.Keys | Sort-Object) -join ', ')."
}
$prof    = $dpProfiles[$DeployProfile]
$product = [string]$prof.Product
if (-not $product) { throw "Deploy profile '$DeployProfile' has no Product." }

$slip   = Join-Path $repo 'scripts\Invoke-MediaJobs.ps1'
$deploy = Join-Path $repo 'scripts\New-DeployableIso.ps1'
foreach ($p in @($slip, $deploy)) { if (-not (Test-Path $p)) { throw "Required script not found: $p" } }

Write-Host ""
Write-Host "===== Build-GoldenImage v$ScriptVersion ====================================" -ForegroundColor Cyan
Write-Host "$(Get-TS): Profile : $DeployProfile"
Write-Host "$(Get-TS): Product : $product"
Write-Host "$(Get-TS): Config  : $DeployConfig"
Write-Host ""

# ---- [1/2] Refresh the patched media (no-op if the current LCU is already built) --------------
if (-not $SkipSlipstream) {
    Write-Host "$(Get-TS): [1/2] Refreshing patched media for '$product' (no-op if already current)..." -ForegroundColor Cyan
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$slip,'-Jobs',$product)
    if ($NoProxy) { $a += '-NoProxy' }
    & powershell.exe @a
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "[1/2] Slipstream failed for '$product' (exit $code). Fix the media before building the golden ISO." }
    Write-Host "$(Get-TS): [1/2] Patched media is current." -ForegroundColor Green
} else {
    Write-Host "$(Get-TS): [1/2] SKIPPED (-SkipSlipstream) - using the existing patched media." -ForegroundColor Yellow
}
Write-Host ""

# ---- [2/2] Build the golden deploy ISO from the profile ---------------------------------------
Write-Host "$(Get-TS): [2/2] Building the golden deploy ISO (this is the long one)..." -ForegroundColor Cyan
$a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$deploy,'-DeployProfile',$DeployProfile,'-DeployConfig',$DeployConfig)
& powershell.exe @a
$code = $LASTEXITCODE
if ($code -ne 0) { throw "[2/2] New-DeployableIso failed (exit $code)." }

Write-Host ""
Write-Host "$(Get-TS): ===== GOLDEN IMAGE COMPLETE ('$DeployProfile') =====" -ForegroundColor Green
Write-Host "$(Get-TS): The deploy ISO is in this product's ArchiveRoot/BasePath (see the [2/2] log above)."
exit 0
