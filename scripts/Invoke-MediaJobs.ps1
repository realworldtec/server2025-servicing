<#
.SYNOPSIS
    Runs the slipstream for each product listed in config\Products.psd1's RunMediaJobs, in
    order. This is the entry point the scheduled task invokes: it builds only the media you
    actually want, and lets each product's own ALREADY-BUILT guard make it a fast no-op on
    days with nothing new.

.DESCRIPTION
    For each product in RunMediaJobs (or -Jobs), sequentially:
      Slipstream-WindowsMedia.ps1 -Product <name> [-NoProxy]
    The slipstream itself:
      * probes the Catalog and identifies the current LCU (seconds),
      * exits 0 "ALREADY BUILT" if that build already exists (no heavy work),
      * otherwise does the full build, verifies it, and archives it.
    So this orchestrator does NOT need its own Catalog logic or state file - it just chains the
    builds and reports a summary.

    SEQUENTIAL by design. A build is disk- and CPU-heavy (it pegs several cores for long
    stretches); running two at once would thrash the machine and the single working volume.

    One product's failure does NOT stop the rest - a Win11 problem should not block the Server
    build. Each result is captured; the script exits non-zero if ANY job failed.

.PARAMETER Jobs
    Override RunMediaJobs for a one-off run, e.g. -Jobs Server2025,Win11-25H2.

.PARAMETER ConfigPath
    Product config. Default ..\config\Products.psd1.

.PARAMETER SlipstreamScript
    Path to Slipstream-WindowsMedia.ps1. Default ..\scripts\Slipstream-WindowsMedia.ps1.

.PARAMETER NoProxy
    Pass -NoProxy through to each build (forces a direct connection).

.PARAMETER LogDir
    Where to write this orchestrator's transcript. Default: the first job's BasePath\logs, else
    the repo's .\logs.

.EXAMPLE
    .\scripts\Invoke-MediaJobs.ps1                       # build everything in RunMediaJobs
.EXAMPLE
    .\scripts\Invoke-MediaJobs.ps1 -Jobs Win11-25H2      # just this one

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Run elevated on the management/build host (ADK + WinPE).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$Jobs,
    [string]$ConfigPath,
    [string]$SlipstreamScript,
    [switch]$NoProxy,
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
function TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }

$repo = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath)       { $ConfigPath       = Join-Path $repo 'config\Products.psd1' }
if (-not $SlipstreamScript) { $SlipstreamScript = Join-Path $repo 'scripts\Slipstream-WindowsMedia.ps1' }
foreach ($p in @($ConfigPath,$SlipstreamScript)) { if (-not (Test-Path $p)) { throw "Not found: $p" } }

# ---- Load config + resolve the job list --------------------------------------
try { $CONFIG = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop }
catch { throw "Product config is not valid PowerShell data: $ConfigPath`n$($_.Exception.Message)" }
$products = if ($CONFIG -and $CONFIG.ContainsKey('Products')) { $CONFIG.Products } else { $CONFIG }
if (-not $products -or $products.Keys.Count -eq 0) { throw "Product config defines no products: $ConfigPath" }

$jobList = if ($Jobs) { @($Jobs) } elseif ($CONFIG -and $CONFIG.ContainsKey('RunMediaJobs')) { @($CONFIG.RunMediaJobs) } else { @() }
if ($jobList.Count -eq 0) {
    throw "No jobs to run. Add a RunMediaJobs list to $ConfigPath, or pass -Jobs. Defined products: $(($products.Keys | Sort-Object) -join ', ')."
}
# Validate up front - do not start an hour of building only to fail on a typo'd fourth job.
$badJobs = @($jobList | Where-Object { -not $products.ContainsKey($_) })
if ($badJobs.Count -gt 0) {
    throw "RunMediaJobs / -Jobs names an undefined product: $($badJobs -join ', '). Defined: $(($products.Keys | Sort-Object) -join ', ')."
}

# ---- Logging -----------------------------------------------------------------
if (-not $LogDir) {
    $firstBase = [string]$products[$jobList[0]].BasePath
    $LogDir = if ($firstBase) { Join-Path $firstBase 'logs' } else { Join-Path $repo 'logs' }
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Start-Transcript -Path (Join-Path $LogDir "MediaJobs_$stamp.log") -Append | Out-Null

Write-Output "$(TS): ===== Invoke-MediaJobs v$ScriptVersion ====="
Write-Output "$(TS): Config : $ConfigPath"
Write-Output "$(TS): Jobs   : $($jobList -join ' -> ')"
Write-Output ""

$results = @()
$overall = 0
try {
    foreach ($job in $jobList) {
        $t0 = Get-Date
        Write-Output "$(TS): ---- BUILD: $job ----"
        $slipArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SlipstreamScript,'-Product',$job,'-ConfigPath',$ConfigPath)
        if ($NoProxy) { $slipArgs += '-NoProxy' }

        # Child process so one job's fatal cannot abort the whole run (and so its exit code is
        # observable). The slipstream decides trim from the profile's TrimByDefault, and archives
        # itself - this orchestrator adds no build behaviour of its own.
        & powershell.exe @slipArgs
        $code = $LASTEXITCODE
        $mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

        $results += [pscustomobject]@{ Job = $job; Exit = $code; Minutes = $mins }
        if ($code -eq 0) { Write-Output "$(TS): $job OK ($mins min)." }
        else {
            $overall = 1
            Write-Warning "$(TS): $job FAILED (exit $code, $mins min). Continuing to the next job."
        }
        Write-Output ""
    }
}
finally {
    Write-Output "$(TS): ===== SUMMARY ====="
    foreach ($r in $results) {
        Write-Output ("$(TS):   {0,-14} {1}  ({2} min)" -f $r.Job, $(if ($r.Exit -eq 0) { 'OK  ' } else { "FAIL($($r.Exit))" }), $r.Minutes)
    }
    $notRun = @($jobList | Where-Object { $_ -notin $results.Job })
    foreach ($n in $notRun) { Write-Output "$(TS):   $n  (did not run)" }
    Write-Output "$(TS): Overall exit: $overall"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
}

exit $overall
