<#
.SYNOPSIS
    Preflight dependency check for the server2025-servicing toolchain. Verifies the external tools the
    scripts rely on BEFORE a long operation fails partway through, and reports optional tools too.

.DESCRIPTION
    Read-only. Resolves each dependency, prints a table, and returns a non-zero exit code only if a
    REQUIRED tool is missing. Run it on any build host before the first slipstream or deploy build.

    Categories:
      REQUIRED   the build cannot proceed without it (oscdimg from the Windows ADK).
      BUILT-IN   ships with Windows 10/11; checked for completeness, effectively always present.
      OPTIONAL   only needed for a specific convenience feature; scripts degrade gracefully without it.

.PARAMETER Quiet
    Suppress the per-item table; print only the final summary line and set the exit code.

.EXAMPLE
    .\tests\Test-Prerequisites.ps1
    # full table + PASS/FAIL

.EXAMPLE
    if (.\tests\Test-Prerequisites.ps1 -Quiet) { .\scripts\Build-GoldenImage.ps1 }

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Windows PowerShell 5.1+.
#>

#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (defined before first use)
# =====================================================================================

# ADK install locations for oscdimg (both Program Files roots).
function Find-Oscdimg {
    $cands = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $hit = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $hit) { $hit = (Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue).Source }  # PATH fallback
    return $hit
}

# Resolve a command's file version without invoking it (no native stdout, so no leak).
function Get-ToolVersion {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.ProductVersion } catch { return '' }
}

# Is WSL actually USABLE (not just the System32 stub)?
# Windows ships a bare 'wsl.exe' launcher even when WSL is not installed, so Get-Command finds a stub
# that can run nothing. A usable WSL has at least one registered distribution. The authoritative source
# (what 'wsl --list' reads) is the per-user Lxss registry key - check it directly, no wsl.exe spawn.
# Per-user by design: it reflects the distributions of the account running this check.
function Test-WslUsable {
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (Test-Path $lxss) {
            return (@(Get-ChildItem -Path $lxss -ErrorAction SilentlyContinue).Count -gt 0)
        }
    } catch { Write-Verbose 'Lxss registry check failed' }
    return $false
}

# Build one result row.
function New-CheckResult {
    param([string]$Tool, [ValidateSet('REQUIRED', 'BUILT-IN', 'OPTIONAL')][string]$Category,
          [bool]$Found, [string]$Detail, [string]$UsedBy, [string]$Fix)
    [pscustomobject]@{
        Tool = $Tool; Category = $Category; Found = $Found; Detail = $Detail; UsedBy = $UsedBy; Fix = $Fix
    }
}

# =====================================================================================
#  Run the checks
# =====================================================================================
$results = New-Object System.Collections.Generic.List[object]

# --- environment ---
$psOk = $PSVersionTable.PSVersion.Major -ge 5
$results.Add((New-CheckResult 'PowerShell >= 5.1' 'REQUIRED' $psOk "v$($PSVersionTable.PSVersion)" 'all scripts' 'Use Windows PowerShell 5.1 or PowerShell 7+'))

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results.Add((New-CheckResult 'Elevated (admin)' 'REQUIRED' $admin $(if ($admin) { 'yes' } else { 'NO' }) 'image mount, driver export, ISO build' 'Run the shell as Administrator'))

# --- REQUIRED external: oscdimg (Windows ADK) ---
$osc = Find-Oscdimg
$results.Add((New-CheckResult 'oscdimg.exe (Windows ADK)' 'REQUIRED' ([bool]$osc) `
    $(if ($osc) { "v$(Get-ToolVersion $osc) @ $osc" } else { 'not found' }) `
    'New-DeployableIso, New-UnattendIso, Slipstream-WindowsMedia' `
    'Install Windows ADK + "Windows PE add-on"; select Deployment Tools'))

# --- BUILT-IN Windows tools (should always be present; checked for completeness) ---
$builtin = @(
    @{ n = 'dism.exe';     used = 'Slipstream, Repair-Server2025Store' },
    @{ n = 'pnputil.exe';  used = 'Get-MachineInventory (driver export)' },
    @{ n = 'reagentc.exe'; used = 'Invoke-PostInstall (WinRE enable)' },
    @{ n = 'diskpart.exe'; used = 'answer file (runtime, not build)' },
    @{ n = 'icacls.exe';   used = 'Invoke-PostInstall (SSH ACLs)' },
    @{ n = 'reg.exe';      used = 'Invoke-PrivacyHardening' }
)
foreach ($b in $builtin) {
    $cmd = Get-Command $b.n -ErrorAction SilentlyContinue
    $ver = if ($cmd) { Get-ToolVersion $cmd.Source } else { '' }
    $results.Add((New-CheckResult $b.n 'BUILT-IN' ([bool]$cmd) $(if ($cmd) { "v$ver" } else { 'MISSING (unexpected)' }) $b.used 'Ships with Windows 10/11'))
}

# --- OPTIONAL: password-hash generators for New-UbuntuUserData (any ONE, or paste a hash) ---
$osslCands = @(
    (Get-Command 'openssl.exe' -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles}\Git\usr\bin\openssl.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
    "${env:LOCALAPPDATA}\Programs\Git\usr\bin\openssl.exe"
)
$ossl = $osslCands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$results.Add((New-CheckResult 'openssl (hash gen)' 'OPTIONAL' ([bool]$ossl) `
    $(if ($ossl) { $ossl } else { 'not found' }) 'New-UbuntuUserData password hash' `
    'Optional: install Git for Windows (bundles openssl), or just paste a hash'))

$wslUsable = Test-WslUsable
$results.Add((New-CheckResult 'WSL (hash gen fallback)' 'OPTIONAL' $wslUsable `
    $(if ($wslUsable) { 'usable (>=1 distro registered)' } else { 'no distro (bare wsl.exe stub does not count)' }) `
    'New-UbuntuUserData password hash (fallback)' `
    'Optional: NOT required. Only a fallback if openssl is absent; you can always paste a hash'))

$dotnet = Get-Command 'dotnet' -ErrorAction SilentlyContinue
$results.Add((New-CheckResult 'dotnet CLI' 'OPTIONAL' ([bool]$dotnet) `
    $(if ($dotnet) { 'present' } else { 'not installed' }) 'Get-MachineInventory (.NET runtime list)' `
    'Optional: only enriches the runtimes inventory'))

$git = Get-Command 'git' -ErrorAction SilentlyContinue
$results.Add((New-CheckResult 'git' 'OPTIONAL' ([bool]$git) `
    $(if ($git) { 'present' } else { 'not installed' }) 'version control (repo hygiene, .gitignore)' `
    'Optional: recommended so the credential .gitignore rules actually apply'))

# =====================================================================================
#  Report
# =====================================================================================
if (-not $Quiet) {
    Write-Host ''
    Write-Host "Prerequisite check - server2025-servicing (v$ScriptVersion)" -ForegroundColor Cyan
    Write-Host ('=' * 78)
    foreach ($r in $results) {
        if ($r.Found)                       { $mark = '  ok '; $color = 'Green' }
        elseif ($r.Category -eq 'OPTIONAL') { $mark = ' opt '; $color = 'Yellow' }
        else                                { $mark = 'MISS '; $color = 'Red' }
        Write-Host ("[{0}] {1,-26} {2,-9} {3}" -f $mark, $r.Tool, $r.Category, $r.Detail) -ForegroundColor $color
        if (-not $r.Found -and $r.Category -ne 'OPTIONAL') {
            Write-Host ("        used by : {0}" -f $r.UsedBy) -ForegroundColor DarkGray
            Write-Host ("        fix     : {0}" -f $r.Fix)    -ForegroundColor DarkGray
        }
    }
    Write-Host ('=' * 78)
}

$missingRequired = @($results | Where-Object { -not $_.Found -and $_.Category -eq 'REQUIRED' })
$missingOptional = @($results | Where-Object { -not $_.Found -and $_.Category -eq 'OPTIONAL' })

if ($missingRequired.Count -gt 0) {
    Write-Host ("PREREQUISITES: FAIL - {0} required item(s) missing: {1}" -f `
        $missingRequired.Count, (($missingRequired.Tool) -join ', ')) -ForegroundColor Red
    return $false
}

$note = if ($missingOptional.Count -gt 0) { " ({0} optional not present: {1})" -f $missingOptional.Count, (($missingOptional.Tool) -join ', ') } else { '' }
Write-Host ("PREREQUISITES: PASS - all required tools present.$note") -ForegroundColor Green
return $true
