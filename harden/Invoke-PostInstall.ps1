<#
.SYNOPSIS
    First-logon "post-install" phase for a deployed Win11 box. Runs the STATEFUL work that must
    NOT happen during Setup's specialize pass: appx debloat, OneDrive removal, and the app installs
    (Firefox, Office LTSC 2024, Acrobat Pro DC).

.DESCRIPTION
    WHY THIS EXISTS (the hard-won lesson):
      The specialize pass (where Invoke-PrivacyHardening runs) is too early and too fragile for
      stateful work. The Appx subsystem and Defender aren't reliably up, so Remove-AppxPackage /
      Remove-AppxProvisionedPackage silently no-op (bloat survived every deploy), and app installers
      misbehave. Registry/policy is fine at specialize; anything that CHANGES SYSTEM STATE or RUNS AN
      INSTALLER belongs HERE, at first logon, when the OS is fully settled.

    HOW IT RUNS:
      Invoke-PrivacyHardening (at specialize) registers a run-once scheduled task
      'PrivacyHardening-PostInstall' (SYSTEM, AtLogOn) that runs this script. This script does its
      work, drops an idempotency marker, then SELF-DESTRUCTS (unregisters its task and deletes
      itself + its config). It fires exactly once, on the first logon, and leaves nothing behind.

    CONFIG (optional): C:\Windows\Setup\Scripts\postinstall.config.json - New-DeployableIso.ps1
    writes this at build time so you can flip features / point Acrobat at a source without editing
    the script. Missing config => the built-in defaults below (everything on; Acrobat skipped
    unless a source is given).

    Running as SYSTEM: a UNC AcrobatSource is reached as the MACHINE account (DOMAIN\HOST$) - grant
    it read, or use a local path. Office installs ONLINE from the Microsoft CDN (needs internet).

.PARAMETER ConfigPath
    Override the config file. Default C:\Windows\Setup\Scripts\postinstall.config.json.

.PARAMETER Force
    Re-run even if the .postinstall-applied marker is present, and do NOT self-destruct. Use to test
    on a live box: .\Invoke-PostInstall.ps1 -Force

.NOTES
    Version : 1.0.0
    Project : server2025-servicing (companion to harden/Invoke-PrivacyHardening.ps1)
    License : MIT
    Windows PowerShell 5.1. SYSTEM or elevated. Reboot afterwards.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\Windows\Setup\Scripts\postinstall.config.json',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (defined before any use)
# =====================================================================================
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }
function Info ($m) { Write-Host  "$(Get-TS)  $m" }
function Warn ($m) { Write-Warning "$(Get-TS)  $m" }

# Run an installer and return its exit code. Start-Process (a cmdlet, not a bare native call) so its
# stdout can't leak into a return value, and so we can -Wait + capture the code cleanly.
function Invoke-Installer {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMin = 60)
    if (-not (Test-Path -LiteralPath $FilePath)) { Warn "  installer not found: $FilePath"; return $null }
    try {
        Info "  running: `"$FilePath`" $($Arguments -join ' ')"
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
        Info "  exit code: $($p.ExitCode)"
        return $p.ExitCode
    } catch { Warn "  installer FAILED ($FilePath): $($_.Exception.Message)"; return $null }
}

# =====================================================================================
#  Logging + config
# =====================================================================================
$dir = 'C:\ProgramData\PrivacyHardening'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$LogPath = Join-Path $dir ("postinstall_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogPath -Append | Out-Null
Info "===== Post-install (first logon) v$ScriptVersion ====="
$whoami = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'unknown' }
Info "Running as: $whoami"

# Defaults, overridden by the JSON config if present.
$cfg = [ordered]@{
    DebloatAppx    = $true
    RemoveOneDrive = $true
    InstallFirefox = $true
    InstallOffice  = $true
    OfficeSetup    = 'C:\Windows\Setup\Files\Office\setup.exe'
    OfficeConfig   = 'C:\Windows\Setup\Files\Office\proplus2024-online.xml'
    InstallAcrobat = $true
    AcrobatSource  = ''    # UNC/local path to Acrobat's setup.exe, its folder, or an .iso. Empty => skip.
}
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } }
        Info "Config loaded: $ConfigPath"
    } catch { Warn "Config unreadable ($ConfigPath): $($_.Exception.Message) - using defaults." }
} else {
    Info "No config at $ConfigPath - using built-in defaults."
}

$AppliedMarker = Join-Path $dir '.postinstall-applied'
if ((Test-Path $AppliedMarker) -and -not $Force) {
    Info "Already applied ($AppliedMarker present). Use -Force to re-run. Exiting."
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 0
}

# Fatal-handler: log, stop transcript, exit non-zero. Trap (not finally) so Rule A stays satisfied.
trap {
    Warn "FATAL: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# =====================================================================================
#  1. Appx debloat  (RELIABLE here - the Appx stack is fully up at first logon)
# =====================================================================================
# Remove the consumer bloat that survived specialize (Xbox / LinkedIn / WhatsApp / etc.). Same
# remove/keep lists as before, with the KEEP guard protecting dev-critical packages. Both the
# provisioned copies (future profiles) AND the already-installed copies (this profile) are removed.
if ($cfg.DebloatAppx) {
    Info '[DebloatAppx] removing consumer bloat (dev-critical protected)'
    $removeMatch = @(
        'BingNews','BingWeather','BingSearch','Bing.Search',
        'GamingApp','Xbox','ZuneMusic','ZuneVideo',
        'windowscommunicationsapps','People','SolitaireCollection',
        'Clipchamp','Todos','PowerAutomateDesktop','MicrosoftOfficeHub',
        'GetHelp','Getstarted','Teams','MSTeams','Copilot','549981C3F5F10',
        'MixedReality.Portal','WindowsMaps','YourPhone','Microsoft.Phone',
        'WindowsFeedbackHub','OutlookForWindows','QuickAssist','Wallet',
        'Microsoft.Windows.Ai.Copilot.Provider',
        'LinkedIn','WhatsApp','Facebook','Instagram','SpotifyAB.Spotify','SpotifyMusic',
        'Disney','PrimeVideo','Amazon.com.Amazon','TikTok','Netflix','Dolby','DevHome',
        'Family','Microsoft.Windows.DevHome'
    )
    $keepMatch = @(
        'DesktopAppInstaller','WindowsStore','StorePurchaseApp','WindowsTerminal',
        'WebView','VCLibs','UI.Xaml','NET.Native','DotNet',
        'WindowsCalculator','WindowsNotepad','Paint','ScreenSketch','SnippingTool',
        'SecHealthUI','WindowsCamera','Winget'
    )
    # (a) provisioned -> future profiles
    foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
        $name = $p.DisplayName
        if (($removeMatch | Where-Object { $name -like "*$_*" }) -and -not ($keepMatch | Where-Object { $name -like "*$_*" })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; Info "  removed (provisioned)  $name" }
            catch { Warn "  remove FAILED (provisioned)  $name - $($_.Exception.Message)" }
        }
    }
    # (b) already-installed for all users -> this profile
    foreach ($a in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
        $name = $a.Name
        if (($removeMatch | Where-Object { $name -like "*$_*" }) -and -not ($keepMatch | Where-Object { $name -like "*$_*" })) {
            try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop; Info "  removed (installed)  $name" }
            catch { Warn "  remove FAILED (installed)  $name - $($_.Exception.Message)" }
        }
    }
}

# =====================================================================================
#  2. OneDrive - FULL removal (uninstall + block reinstall)
# =====================================================================================
# Policy (DisableFileSyncNGSC) is already set at specialize. Here we actually UNINSTALL the running
# OneDrive and stop it coming back: kill it, run its own /uninstall, remove the Run stubs and its
# scheduled tasks. You use NextCloud/Veeam, so nothing depends on it.
if ($cfg.RemoveOneDrive) {
    Info '[RemoveOneDrive] uninstalling OneDrive + blocking reinstall'
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($ods in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
        if (Test-Path $ods) { Invoke-Installer -FilePath $ods -Arguments @('/uninstall') -TimeoutMin 10 | Out-Null }
    }
    # Kill the per-user auto-install stubs so new profiles don't re-add it.
    foreach ($runKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                          'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        try { Remove-ItemProperty -Path $runKey -Name 'OneDriveSetup' -ErrorAction SilentlyContinue } catch { Write-Verbose 'no OneDriveSetup run key' }
    }
    Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    # Enforce the policy again at runtime (belt-and-braces; specialize already set it).
    try { New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Force | Out-Null
          New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1 -PropertyType DWord -Force | Out-Null } catch { Warn "  OneDrive policy set failed: $($_.Exception.Message)" }
}

# =====================================================================================
#  3. Firefox - silent install from the baked offline installer
# =====================================================================================
if ($cfg.InstallFirefox) {
    Info '[InstallFirefox] silent install from baked installer'
    $ff = 'C:\Windows\Setup\Files\FirefoxSetup.exe'
    if (Test-Path $ff) { Invoke-Installer -FilePath $ff -Arguments @('/S') -TimeoutMin 15 | Out-Null }
    else { Info "  no Firefox installer at $ff - skipping (Mozilla policy still applies once installed)" }
}

# =====================================================================================
#  4. Office LTSC 2024 - ONLINE install via the ODT (downloads from the Microsoft CDN)
# =====================================================================================
# setup.exe /configure <cfg.xml>. The config has AllowCdnFallback=TRUE and no local source, so ODT
# downloads Office from the CDN and installs in one step - needs internet at first logon. AUTOACTIVATE
# in the config handles KMS activation via DNS auto-discovery.
if ($cfg.InstallOffice) {
    Info '[InstallOffice] Office LTSC 2024 via ODT (online)'
    if ((Test-Path $cfg.OfficeSetup) -and (Test-Path $cfg.OfficeConfig)) {
        $code = Invoke-Installer -FilePath $cfg.OfficeSetup -Arguments @('/configure', $cfg.OfficeConfig) -TimeoutMin 90
        if ($code -eq 0) { Info '  Office install reported success' }
        elseif ($null -ne $code) { Warn "  Office setup returned $code - check the ODT log under C:\ProgramData or %TEMP%." }
    } else {
        Warn "  Office ODT not baked (need setup.exe + config): $($cfg.OfficeSetup) / $($cfg.OfficeConfig) - skipping."
    }
}

# =====================================================================================
#  5. Acrobat Pro DC - silent install from a supplied source (share / folder / .iso)
# =====================================================================================
# Acrobat has no public CDN, so it comes from cfg.AcrobatSource. Accepts a direct setup.exe, a
# folder containing setup.exe, or an .iso we mount. Silent switches for the Acrobat DC volume
# installer: /sAll (silent) /rs (suppress reboot) /msi EULA_ACCEPT=YES.
if ($cfg.InstallAcrobat -and $cfg.AcrobatSource) {
    Info "[InstallAcrobat] Acrobat Pro DC from: $($cfg.AcrobatSource)"
    $src = [string]$cfg.AcrobatSource
    $setup = $null
    $mounted = $null
    try {
        if ($src -match '\.iso$' -and (Test-Path -LiteralPath $src)) {
            $img = Mount-DiskImage -ImagePath $src -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 2
            $drv = ($img | Get-Volume).DriveLetter
            $mounted = $src
            $setup = Join-Path ("{0}:\" -f $drv) 'setup.exe'
        } elseif ((Test-Path -LiteralPath $src) -and (Get-Item -LiteralPath $src).PSIsContainer) {
            $setup = Join-Path $src 'setup.exe'
        } else {
            $setup = $src   # assume it's the setup.exe itself
        }
        if ($setup -and (Test-Path -LiteralPath $setup)) {
            Invoke-Installer -FilePath $setup -Arguments @('/sAll', '/rs', '/msi', 'EULA_ACCEPT=YES') -TimeoutMin 45 | Out-Null
        } else {
            Warn "  Acrobat setup.exe not found under source - skipping. (As SYSTEM, a UNC needs the machine account granted read.)"
        }
    } catch { Warn "  Acrobat install error: $($_.Exception.Message)" }
    finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $mounted -ErrorAction SilentlyContinue | Out-Null }
    }
} elseif ($cfg.InstallAcrobat) {
    Info '[InstallAcrobat] no AcrobatSource configured - skipping. Set it in postinstall.config.json.'
}

# =====================================================================================
#  Marker + self-destruct
# =====================================================================================
try { Set-Content -Path $AppliedMarker -Value ("applied {0} v{1}" -f (Get-TS), $ScriptVersion) -ErrorAction Stop }
catch { Warn "Could not write marker $AppliedMarker : $($_.Exception.Message)" }

if (-not $Force) {
    Info 'Self-destruct: unregistering task + removing this script and its config.'
    Unregister-ScheduledTask -TaskName 'PrivacyHardening-PostInstall' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

Info '===== Post-install complete (reboot recommended) ====='
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0
