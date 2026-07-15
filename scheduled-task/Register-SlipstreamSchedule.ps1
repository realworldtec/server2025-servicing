<#
.SYNOPSIS
    Registers the daily media-build task. The task runs Invoke-MediaJobs.ps1, which builds each
    product listed in config\Products.psd1's RunMediaJobs, in order. Each build is a fast no-op
    on days with nothing new (the slipstream's own ALREADY-BUILT guard), and archives itself
    per that product's ArchiveRoot/KeepLast.

.DESCRIPTION
    Everything that used to be a parameter here - which products, where to archive, how many to
    keep, the source ISO - now lives in config\Products.psd1, so this registrar only needs to
    know WHEN to run and AS WHOM. Change what gets built by editing RunMediaJobs in the config;
    no re-registration required.

    Idempotent: re-run to update the task (-Force is implied).

.PARAMETER ConfigPath
    Product config the task will read. Default ..\config\Products.psd1.

.PARAMETER JobRunner
    Path to Invoke-MediaJobs.ps1. Default ..\scripts\Invoke-MediaJobs.ps1.

.PARAMETER Time
    Daily run time (local). Default 02:00.

.PARAMETER NoProxy
    Register the task with -NoProxy (forces a direct connection; use when running as SYSTEM on a
    host whose SYSTEM WinINET hive has a stale proxy).

.PARAMETER RunAsUser
    'SYSTEM' (default) or a domain account (prompts for a password). Note: as SYSTEM, a UNC
    ArchiveRoot is hit as the MACHINE account (DOMAIN\HOST$).

.PARAMETER ExecutionTimeLimitHours
    Task execution time limit. Default 20 (several products x multi-hour builds, back to back).

.PARAMETER TaskName
    Default 'Server2025-Servicing-MediaJobs'.

.EXAMPLE
    .\Register-SlipstreamSchedule.ps1
.EXAMPLE
    .\Register-SlipstreamSchedule.ps1 -Time 01:30 -NoProxy

.NOTES
    Version : 2.0.0
    Project : server2025-servicing
    License : MIT
    Run elevated on the management/build host (ADK + WinPE).

    Replaces v1.x, which scheduled the Server-only detector (Watch-Server2025Updates.ps1). If
    you registered that under its old name, remove it:
        Unregister-ScheduledTask -TaskName 'Server2025-Update-Watch' -Confirm:$false
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$JobRunner,
    [string]$Time      = '02:00',
    [switch]$NoProxy,
    [string]$RunAsUser = 'SYSTEM',
    [int]$ExecutionTimeLimitHours = 20,
    [string]$TaskName  = 'Server2025-Servicing-MediaJobs'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.0.0'
$repo = Split-Path $PSScriptRoot -Parent

if (-not $ConfigPath) { $ConfigPath = Join-Path $repo 'config\Products.psd1' }
if (-not $JobRunner)  { $JobRunner  = Join-Path $repo 'scripts\Invoke-MediaJobs.ps1' }
foreach ($p in @($ConfigPath,$JobRunner)) { if (-not (Test-Path $p)) { throw "Not found: $p" } }

# Trailing backslashes first: CommandLineToArgvW reads \" as an escaped quote, so a path
# ending in \ would swallow the rest of the command line. (Real class of bug.)
foreach ($v in 'ConfigPath','JobRunner') {
    $cur = Get-Variable -Name $v -ValueOnly
    if ($cur) { Set-Variable -Name $v -Value $cur.TrimEnd('\') }
}

# Report what will actually run, so registration doubles as a config sanity check.
try { $CONFIG = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop }
catch { throw "Product config is not valid PowerShell data: $ConfigPath`n$($_.Exception.Message)" }
$products = if ($CONFIG -and $CONFIG.ContainsKey('Products')) { $CONFIG.Products } else { $CONFIG }
$jobList  = if ($CONFIG -and $CONFIG.ContainsKey('RunMediaJobs')) { @($CONFIG.RunMediaJobs) } else { @() }
if ($jobList.Count -eq 0) { throw "config has no RunMediaJobs list - nothing would be built. Add one to $ConfigPath." }
$badJobs = @($jobList | Where-Object { -not ($products -and $products.ContainsKey($_)) })
if ($badJobs.Count -gt 0) { throw "RunMediaJobs names an undefined product: $($badJobs -join ', ')." }

$arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $JobRunner, $ConfigPath
if ($NoProxy) { $arg += ' -NoProxy' }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
              -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit (New-TimeSpan -Hours $ExecutionTimeLimitHours) `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$desc = "Daily media build (RunMediaJobs from config). server2025-servicing v$ScriptVersion."

$common = @{ TaskName = $TaskName; Action = $action; Trigger = $trigger; Settings = $settings; Description = $desc; RunLevel = 'Highest'; Force = $true }
if ($RunAsUser -match '^(NT AUTHORITY\\)?SYSTEM$') {
    Register-ScheduledTask @common -User 'NT AUTHORITY\SYSTEM' | Out-Null
} else {
    $cred = Get-Credential -UserName $RunAsUser -Message "Password for scheduled-task run-as account ($RunAsUser)"
    Register-ScheduledTask @common -User $cred.UserName -Password $cred.GetNetworkCredential().Password | Out-Null
}

Write-Host "Registered '$TaskName' (daily $Time, run-as $RunAsUser)."
Write-Host "Runner : $JobRunner"
Write-Host "Config : $ConfigPath"
Write-Host "Jobs   : $($jobList -join ' -> ')"
Write-Host ""
Write-Host "Dry-run now (each product no-ops unless its LCU is new):"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Change what gets built by editing RunMediaJobs in $ConfigPath (no re-registration needed)."
