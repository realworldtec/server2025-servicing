<#
.SYNOPSIS
    Install a ROLE's set of applications with winget, on demand, after deployment. Deliberately NOT
    part of the golden image - the baseline stays minimal; role tooling is pulled current here.

.DESCRIPTION
    Reads a role manifest from winget\<role>.json (a simple, curated JSON list) and installs each
    package with winget. Visual Studio is handled specially: its manifest entry names a .vsconfig, and
    the script passes that to the VS installer so only your chosen workloads install (not the default
    multi-GB set).

    Run it AS A USER (elevated) after first logon - winget is unreliable under the SYSTEM account, which
    is why package installs are here and not in the first-logon hardening task.

    Manifest format (winget\dev.json):
        {
          "role": "dev",
          "description": "Node / web development workstation",
          "packages": [
            { "id": "Git.Git" },
            { "id": "OpenJS.NodeJS.LTS" },
            { "id": "Microsoft.VisualStudio.2022.Community", "vsconfig": "vs/dev.vsconfig" },
            { "id": "SomePkg", "override": "--custom-installer-arg" }
          ]
        }

.PARAMETER Role
    dev | admin | pentest. Selects winget\<role>.json.

.PARAMETER Manifest
    Explicit manifest path (overrides -Role).

.PARAMETER ManifestDir
    Folder holding the manifests + vs\*.vsconfig. Default: repo winget\.

.PARAMETER ListOnly
    Print what would be installed and exit. No changes.

.EXAMPLE
    .\scripts\Install-Packages.ps1 -Role dev
.EXAMPLE
    .\scripts\Install-Packages.ps1 -Role admin -ListOnly

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Windows PowerShell 5.1+, elevated. Package IDs are STARTING POINTS - verify with `winget search`.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('dev', 'admin', 'pentest')]
    [string]$Role,
    [string]$Manifest,
    [string]$ManifestDir,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (defined before first use)
# =====================================================================================
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [datetime]::Now }
function Info ($m) { Write-Host   "$(Get-TS)  $m" }
function Warn ($m) { Write-Warning "$(Get-TS)  $m" }

# =====================================================================================
#  Resolve manifest
# =====================================================================================
$repo = Split-Path $PSScriptRoot -Parent
if (-not $ManifestDir) { $ManifestDir = Join-Path $repo 'winget' }
if (-not $Manifest) {
    if (-not $Role) { throw 'Specify -Role dev|admin|pentest, or -Manifest <path>.' }
    $Manifest = Join-Path $ManifestDir "$Role.json"
}
if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest" }

$m = $null
try { $m = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { throw "Manifest is not valid JSON ($Manifest): $($_.Exception.Message)" }
$packages = @($m.packages)
if ($packages.Count -eq 0) { throw "Manifest has no 'packages': $Manifest" }

# =====================================================================================
#  Setup / logging
# =====================================================================================
$logDir = 'C:\ProgramData\server2025-servicing'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $logDir ("Install-Packages_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))) -Append | Out-Null
Info "===== Install-Packages v$ScriptVersion ====="
Info "Manifest: $Manifest"
Info "Role: $($m.role)   $($m.description)"
Info "$($packages.Count) package(s)"

trap {
    Warn "FATAL: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# --- ListOnly: show and exit -------------------------------------------------
if ($ListOnly) {
    foreach ($p in $packages) {
        $extra = if ($p.vsconfig) { "  (VS workloads: $($p.vsconfig))" } elseif ($p.override) { "  (override: $($p.override))" } else { '' }
        Write-Host ("  {0}{1}" -f $p.id, $extra)
    }
    Info '(ListOnly - nothing installed)'
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 0
}

# --- winget present? ---------------------------------------------------------
if (-not (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
    Warn "winget (App Installer) not found. Install 'App Installer' from the Microsoft Store, then re-run."
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# =====================================================================================
#  Install
# =====================================================================================
$ok = 0; $nonzero = 0
foreach ($p in $packages) {
    $id = [string]$p.id
    if (-not $id) { continue }

    $wgArgs = @('install', '-e', '--id', $id, '--accept-source-agreements', '--accept-package-agreements')

    if ($p.vsconfig) {
        # Pass the chosen workloads to the VS installer via --override. Path must be SPACE-FREE:
        # native-argument quoting of an inner-quoted path is fragile, so we guard rather than risk it.
        $vscfg = Join-Path $ManifestDir ([string]$p.vsconfig)
        if (-not (Test-Path $vscfg)) {
            Warn "  $id : vsconfig not found ($vscfg) - installing with DEFAULT workloads."
        } elseif ($vscfg -match '\s') {
            Warn "  $id : vsconfig path contains a space ($vscfg). To keep argument passing safe, move the"
            Warn "        repo to a space-free path, or apply the .vsconfig manually. Installing DEFAULT workloads."
        } else {
            $wgArgs += @('--override', "--passive --norestart --config $vscfg")
            Info "  $id  (VS workloads from $($p.vsconfig))"
        }
    } elseif ($p.override) {
        $wgArgs += @('--override', [string]$p.override)
        Info "  $id  (override: $($p.override))"
    } else {
        Info "  $id"
    }

    try {
        & winget @wgArgs | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq 0) { $ok++; Info "    ok" }
        else { $nonzero++; Warn "    winget exit $code (a non-zero code often just means 'already installed' or 'no applicable upgrade' - check the output above)." }
    } catch { $nonzero++; Warn "    install error for ${id}: $($_.Exception.Message)" }
}

# =====================================================================================
#  Done
# =====================================================================================
Info "===== Done: $ok clean, $nonzero non-zero (review) of $($packages.Count) ====="
Info 'Tip: keep everything current later with:  winget upgrade --all'
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0
