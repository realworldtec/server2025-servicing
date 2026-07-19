<#
.SYNOPSIS
    Scripted, repeatable Visual Studio 2022 Community setup: install with a chosen .vsconfig workload
    set, apply git globals, and import your Tools->Options settings from a .vssettings file. Prints the
    (manual, verified) Copilot removal + policy steps at the end.

.DESCRIPTION
    What IS fully scripted:
      1. Install     - VS Community via winget, workloads pinned by a .vsconfig (no default bloat).
      2. Git globals - user.name / user.email / init.defaultBranch / fetch.prune / pull.rebase.
      3. Settings    - imports a .vssettings via `devenv /ResetSettings`, which reproduces almost all of
                       Tools->Options in one shot (theme, preview features, the Copilot-badge hide, git
                       UI toggles, editor prefs). Export yours once from a tuned VS:
                       Tools -> Import and Export Settings -> Export selected environment settings.

    What is NOT cleanly scriptable (do once, by hand - see the printed checklist and VS2022-Community-Setup.md):
      - A few newer per-feature toggles that .vssettings does not round-trip.
      - Disabling GitHub Copilot durably. Microsoft ships this as an ADMX/Group Policy; the raw registry
        value is not published, so this script does NOT write a guessed key. It prints the verified
        installer + Local Group Policy steps instead.

.PARAMETER VsConfig    Workload manifest. Default: repo winget\vs\dev.vsconfig.
.PARAMETER Settings    A .vssettings to import. Default: repo winget\vs\*.vssettings if exactly one exists.
.PARAMETER WingetId    VS package id. Default Microsoft.VisualStudio.2022.Community.
.PARAMETER GitName     git user.name. Default RealWorldTec.
.PARAMETER GitEmail    git user.email. Default realworldtec@gmail.com.
.PARAMETER SkipInstall Skip the VS install (configure an existing install only).

.EXAMPLE
    .\scripts\Setup-VisualStudio.ps1
.EXAMPLE
    .\scripts\Setup-VisualStudio.ps1 -SkipInstall -Settings .\winget\vs\RealWorldTec.vssettings

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Windows PowerShell 5.1+, elevated.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VsConfig,
    [string]$Settings,
    [string]$WingetId = 'Microsoft.VisualStudio.2022.Community',
    [string]$GitName  = 'RealWorldTec',
    [string]$GitEmail = 'realworldtec@gmail.com',
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

# Locate devenv.exe via vswhere (robust across install paths).
function Get-DevEnv {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $path = & $vswhere -latest -products '*' -property productPath 2>$null | Select-Object -First 1
        if ($path -and (Test-Path $path)) { return $path }
    }
    $guess = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe"
    if (Test-Path $guess) { return $guess }
    return $null
}

# =====================================================================================
#  Resolve inputs
# =====================================================================================
$repo = Split-Path $PSScriptRoot -Parent
if (-not $VsConfig) { $VsConfig = Join-Path $repo 'winget\vs\dev.vsconfig' }
if (-not $Settings) {
    $found = @(Get-ChildItem (Join-Path $repo 'winget\vs') -Filter *.vssettings -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) { $Settings = $found[0].FullName }
}

$logDir = 'C:\ProgramData\server2025-servicing'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $logDir ("Setup-VisualStudio_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))) -Append | Out-Null
Info "===== Setup-VisualStudio v$ScriptVersion ====="
Info "VsConfig : $VsConfig"
Info "Settings : $(if ($Settings) { $Settings } else { '(none - Options will not be imported)' })"

trap {
    Warn "FATAL: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# =====================================================================================
#  1. Install VS with the pinned workloads
# =====================================================================================
if (-not $SkipInstall) {
    Info "[Install] $WingetId with workloads from $VsConfig"
    if (-not (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
        Warn '  winget not found. Install "App Installer" from the Store, or install VS manually, then re-run -SkipInstall.'
    } elseif (-not (Test-Path $VsConfig)) {
        Warn "  vsconfig not found ($VsConfig) - installing with DEFAULT workloads."
        & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements | Out-Host
    } elseif ($VsConfig -match '\s') {
        Warn "  vsconfig path has a space ($VsConfig): native-arg quoting of --config is fragile. Move the repo to a"
        Warn "  space-free path, or apply the .vsconfig by hand. Installing DEFAULT workloads."
        & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements | Out-Host
    } else {
        & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements --override "--quiet --norestart --config $VsConfig" | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { Warn "  winget exit $LASTEXITCODE (often 'already installed' - check output)." }
}

# =====================================================================================
#  2. Git globals  (VS reads the same ~/.gitconfig)
# =====================================================================================
Info '[Git] applying global config'
if (Get-Command 'git' -ErrorAction SilentlyContinue) {
    $pairs = @(
        @('user.name',         $GitName),
        @('user.email',        $GitEmail),
        @('init.defaultBranch','main'),
        @('fetch.prune',       'true'),
        @('pull.rebase',       'false')
    )
    foreach ($kv in $pairs) {
        & git config --global $kv[0] $kv[1] 2>&1 | Out-Null
        Info "  $($kv[0]) = $($kv[1])"
    }
} else {
    Warn '  git not found - skipping git globals. Install Git first (winget dev.json), then re-run.'
}

# =====================================================================================
#  3. Import Tools->Options from a .vssettings
# =====================================================================================
if ($Settings) {
    if (-not (Test-Path $Settings)) {
        Warn "[Settings] file not found: $Settings - skipping."
    } else {
        $devenv = Get-DevEnv
        if (-not $devenv) {
            Warn '[Settings] devenv.exe not found (is VS installed yet?) - import skipped. Re-run with -SkipInstall after install.'
        } else {
            Info "[Settings] importing $Settings via devenv /ResetSettings (VS will open briefly)"
            # /ResetSettings applies the file and launches the IDE; there is no fully-silent import.
            try { & $devenv /ResetSettings "$Settings" | Out-Null; Info '  settings applied' }
            catch { Warn "  settings import failed: $($_.Exception.Message)" }
        }
    }
} else {
    Info '[Settings] no .vssettings supplied - export one from a tuned VS and pass -Settings to reproduce your Options.'
}

# =====================================================================================
#  4. Copilot - verified MANUAL steps (no guessed registry keys)
# =====================================================================================
Info '[Copilot] to remove + keep it off (do once; see VS2022-Community-Setup.md):'
Info '  Remove components : VS Installer -> Modify -> Individual components -> search "copilot" ->'
Info '                      uncheck GitHub Copilot, GitHub Copilot Chat, GitHub Copilot Completions -> Modify.'
Info '  Keep it off (GPO) : download the VS Administrative Templates (ADMX) [aka.ms id=104405] into'
Info '                      C:\Windows\PolicyDefinitions, then gpedit.msc ->'
Info '                      Computer Configuration > Administrative Templates > Visual Studio > Copilot Settings.'
Info '  Badge             : Tools > Options > Environment > General > Hide Copilot menu badge (or via the .vssettings).'

Info '===== Setup-VisualStudio complete ====='
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0
