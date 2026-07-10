<#
.SYNOPSIS
    Registers the DAILY Server 2025 update detector (Watch-Server2025Updates.ps1) as a
    scheduled task. The detector polls the Microsoft Update Catalog and only launches the
    (slow) slipstream when a build newer than the last one built appears - so the patched
    ISO is produced the day the CU actually publishes, including out-of-band releases.

.DESCRIPTION
    This replaces the earlier fixed "2nd Wednesday" trigger. The task runs the detector once
    a day at -Time; the detector is a fast no-op on days with nothing new. Archive + retention
    are handled by the detector.

    Idempotent: re-run to update the task (-Force).

.PARAMETER ShareRoot
    UNC/local folder to archive finished ISOs to (passed to the detector). Required.

.PARAMETER WatchScript
    Path to Watch-Server2025Updates.ps1. Default: ..\scripts\Watch-Server2025Updates.ps1.

.PARAMETER SlipstreamScript
    Path to Slipstream-Server2025.ps1. Default: ..\scripts\Slipstream-Server2025.ps1.

.PARAMETER OutputDir
    Slipstream output dir. Default C:\Installs\Server2025Patching.

.PARAMETER StateFile
    Detector state marker. Default <OutputDir>\state\last-built.json.

.PARAMETER KeepLast
    Archived ISOs to retain on the share. Default 12.

.PARAMETER Time
    Daily run time (local). Default 02:00.

.PARAMETER MonthlyOnly
    Register the detector with -MonthlyOnly (build only for the 2nd-Tuesday security LCU).

.PARAMETER RunAsUser
    'SYSTEM' (default) or a domain account (prompts for password) if the share needs auth.

.PARAMETER TaskName
    Default 'Server2025-Update-Watch'.

.EXAMPLE
    .\Register-SlipstreamSchedule.ps1 -ShareRoot '\\fileserver\Images\Server2025' -KeepLast 12

.EXAMPLE
    .\Register-SlipstreamSchedule.ps1 -ShareRoot '\\fileserver\Images\Server2025' `
        -RunAsUser 'CORP\svc-imaging' -MonthlyOnly

.NOTES
    Version : 1.1.0
    Project : server2025-servicing
    License : MIT
    Run elevated on the decoupled management/build host (must have ADK + WinPE).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShareRoot,
    [string]$WatchScript,
    [string]$SlipstreamScript,
    [string]$OutputDir = 'C:\Installs\Server2025Patching',
    [string]$StateFile,
    [int]$KeepLast     = 12,
    [string]$Time      = '02:00',
    [switch]$MonthlyOnly,
    [string]$RunAsUser = 'SYSTEM',
    [string]$TaskName  = 'Server2025-Update-Watch'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1.0'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path $here -Parent

if (-not $WatchScript)      { $WatchScript      = Join-Path $repo 'scripts\Watch-Server2025Updates.ps1' }
if (-not $SlipstreamScript) { $SlipstreamScript = Join-Path $repo 'scripts\Slipstream-Server2025.ps1' }
if (-not $StateFile)        { $StateFile        = Join-Path $OutputDir 'state\last-built.json' }
foreach ($p in @($WatchScript,$SlipstreamScript)) { if (-not (Test-Path $p)) { throw "Script not found: $p" } }
if (-not (Test-Path $ShareRoot)) { Write-Warning "ShareRoot not reachable right now: $ShareRoot (task still registered; verify access under the run-as account)." }

# --- Build the detector command line the task will run -------------------------
$arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SlipstreamScript "{1}" -OutputDir "{2}" -StateFile "{3}" -KeepLast {4} -ShareRoot "{5}"' -f `
        $WatchScript, $SlipstreamScript, $OutputDir, $StateFile, $KeepLast, $ShareRoot
if ($MonthlyOnly) { $arg += ' -MonthlyOnly' }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
              -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit (New-TimeSpan -Hours 10) `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$desc = "Daily Server 2025 update detector; builds patched ISO when a new LCU publishes. server2025-servicing v$ScriptVersion."

$common = @{ TaskName = $TaskName; Action = $action; Trigger = $trigger; Settings = $settings; Description = $desc; RunLevel = 'Highest'; Force = $true }
if ($RunAsUser -eq 'SYSTEM') {
    Register-ScheduledTask @common -User 'NT AUTHORITY\SYSTEM' | Out-Null
} else {
    $cred = Get-Credential -UserName $RunAsUser -Message "Password for scheduled-task run-as account ($RunAsUser)"
    Register-ScheduledTask @common -User $cred.UserName -Password $cred.GetNetworkCredential().Password | Out-Null
}

Write-Host "Registered '$TaskName' (daily $Time, run-as $RunAsUser, MonthlyOnly=$MonthlyOnly)."
Write-Host "Detector : $WatchScript"
Write-Host "Archive  : $ShareRoot  (retention: keep $KeepLast)"
Write-Host "State    : $StateFile"
Write-Host ""
Write-Host "Dry-run the detector now (no build unless a new LCU is out):"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'    # then watch $OutputDir\logs\Watch_*.log"
Write-Host "Force a one-off build regardless of state: delete $StateFile, or run Slipstream-Server2025.ps1 directly."
