<#
.SYNOPSIS
    Availability detector for Windows Server 2025 (24H2) cumulative updates. Runs daily,
    polls the Microsoft Update Catalog for the latest LCU, and launches the slipstream
    ONLY when a build newer than the last one built appears. Idempotent by design.

.DESCRIPTION
    Replaces a fixed "2nd Wednesday" calendar guess with the authoritative signal: the LCU's
    presence (and LastUpdated date) in the Catalog. This makes the build fire the day the
    update actually publishes, and naturally covers slipped or out-of-band releases.

    Flow each run:
      1. Cheap Catalog search (no download) -> latest Server 2025 24H2 x64 LCU (build + KB + date).
      2. Compare its build to the state marker (last successfully built build).
      3. If newer (and, with -MonthlyOnly, it's the 2nd-Tuesday security release), run the
         slipstream, archive the ISO to -ShareRoot with retention, then stamp the marker.
      4. Otherwise exit quietly. Catalog hiccups are non-fatal (retry tomorrow).

.PARAMETER SlipstreamScript
    Path to Slipstream-Server2025.ps1.

.PARAMETER OutputDir
    Slipstream working + output dir (passed to the slipstream as -BasePath, so the two always
    agree). Default D:\Server2025Patching.

.PARAMETER SourceISO
    Full path to the Server 2025 RTM ISO on THIS host. Passed to the slipstream as -SourceISO.
    Omit only if the slipstream's own default path is correct on this machine.

.PARAMETER StateFile
    JSON marker of the last-built LCU. Default <OutputDir>\state\last-built.json.

.PARAMETER ShareRoot
    Optional UNC/local archive folder for finished ISOs (+ transcript). Retention applies.

.PARAMETER KeepLast
    Archived ISOs to retain on the share. Default 12.

.PARAMETER MonthlyOnly
    Only build for the monthly security LCU (LastUpdated == 2nd Tuesday). Ignores OOB releases.

.PARAMETER LogDir
    Transcript folder. Default <OutputDir>\logs.

.EXAMPLE
    .\Watch-Server2025Updates.ps1 -SlipstreamScript .\Slipstream-Server2025.ps1 `
        -SourceISO 'D:\Server2025RTM\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO' `
        -ShareRoot 'D:\PatchedImages' -KeepLast 12

.NOTES
    Version : 1.0.2
    Project : server2025-servicing
    License : MIT
    Intended to run on a decoupled management/build host (ADK + WinPE), elevated.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SlipstreamScript,
    [string]$OutputDir = 'D:\Server2025Patching',
    [string]$SourceISO,
    [string]$StateFile,
    [string]$ShareRoot,
    [int]$KeepLast = 12,
    [switch]$MonthlyOnly,
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.2'
if ($SourceISO -and -not (Test-Path $SourceISO)) { throw "SourceISO not found on this host: $SourceISO" }
if (-not $StateFile) { $StateFile = Join-Path $OutputDir 'state\last-built.json' }
if (-not $LogDir)    { $LogDir    = Join-Path $OutputDir 'logs' }
foreach ($d in @((Split-Path $StateFile -Parent), $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Start-Transcript -Path (Join-Path $LogDir "Watch_$stamp.log") -Append | Out-Null
function TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }
Write-Output "$(TS): Watch-Server2025Updates v$ScriptVersion starting (MonthlyOnly=$MonthlyOnly)"

# --- proxy-aware, retried Catalog access (lightweight: search only, no download) ----
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Watch-Server2025Updates'
$ProxyArgs = @{}
try {
    $sp = [System.Net.WebRequest]::GetSystemWebProxy()
    $sp.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    [System.Net.WebRequest]::DefaultWebProxy = $sp
    $probe = [Uri]'https://www.catalog.update.microsoft.com/'
    $pxy = $sp.GetProxy($probe)
    if ($pxy -and ($pxy.AbsoluteUri.TrimEnd('/') -ne $probe.AbsoluteUri.TrimEnd('/'))) {
        $ProxyArgs = @{ Proxy = $pxy.AbsoluteUri; ProxyUseDefaultCredentials = $true }
    }
} catch {}

function Invoke-Retry {
    param([scriptblock]$Script,[int]$Retries = 4,[int]$Delay = 15)
    for ($i = 1; $i -le $Retries; $i++) {
        try { return (& $Script) }
        catch { if ($i -ge $Retries) { throw }; Write-Output "$(TS): retry $i/$Retries after: $($_.Exception.Message)"; Start-Sleep -Seconds $Delay }
    }
}

function Get-SecondTuesday { param([int]$Year,[int]$Month)
    $d = [datetime]::new($Year,$Month,1)
    while ($d.DayOfWeek -ne 'Tuesday') { $d = $d.AddDays(1) }
    $d.AddDays(7)
}

# Returns newest non-preview Server 2025 24H2 x64 LCU: @{ KB; Build; Date; Title }
function Get-LatestServerLcu {
    $q   = 'Cumulative Update Microsoft server operating system version 24H2 x64'
    $uri = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($q)
    $html = Invoke-Retry { (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = $UA } @ProxyArgs).Content }
    $guidRx  = [regex]'(?i)<input[^>]*\bid="([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"'
    $titleRx = [regex]'(?is)<a\b[^>]*>(.*?)</a>'
    $dateRx  = [regex]'\b(\d{1,2}/\d{1,2}/\d{4})\b'
    $rows = @()
    foreach ($chunk in ($html -split '(?i)<tr[\s>]')) {
        if (-not $guidRx.Match($chunk).Success) { continue }
        $t = $titleRx.Match($chunk); if (-not $t.Success) { continue }
        $title = ($t.Groups[1].Value -replace '<[^>]+>','' -replace '&amp;','&' -replace '\s+',' ').Trim()
        if ($title -notmatch 'Cumulative Update for Microsoft server operating system version 24H2') { continue }
        if ($title -match '\.NET|Preview|Dynamic') { continue }
        if ($title -notmatch 'x64') { continue }
        if ($title -notmatch '\((\d{5}\.\d+)\)') { continue }
        $build = [Version]"10.0.$($Matches[1])"
        $kb    = if ($title -match 'KB(\d+)') { "KB$($Matches[1])" } else { $null }
        $dm    = $dateRx.Match($chunk)
        $date  = if ($dm.Success) { [datetime]$dm.Groups[1].Value } else { [datetime]::MinValue }
        $rows += [pscustomobject]@{ KB = $kb; Build = $build; Date = $date; Title = $title }
    }
    if (-not $rows) { return $null }
    $rows | Sort-Object Build -Descending | Select-Object -First 1
}

$exit = 0
try {
    # 1. Detect
    $latest = $null
    try { $latest = Get-LatestServerLcu }
    catch { Write-Warning "$(TS): Catalog unreachable ($($_.Exception.Message)); will retry next run."; Stop-Transcript | Out-Null; exit 0 }
    if (-not $latest) { Write-Warning "$(TS): No Server 2025 LCU found in Catalog results; skipping."; Stop-Transcript | Out-Null; exit 0 }
    Write-Output "$(TS): Latest available LCU: $($latest.KB) build $($latest.Build) (Catalog date $($latest.Date.ToString('yyyy-MM-dd')))"

    # 2. Compare to state
    $lastBuild = [Version]'0.0.0.0'
    if (Test-Path $StateFile) {
        try { $lastBuild = [Version](Get-Content $StateFile -Raw | ConvertFrom-Json).Build } catch {}
    }
    if ($latest.Build -le $lastBuild) {
        Write-Output "$(TS): No new build (latest $($latest.Build) <= last built $lastBuild). Nothing to do."
        Stop-Transcript | Out-Null; exit 0
    }

    # 2b. MonthlyOnly gate (skip OOB / off-cycle)
    if ($MonthlyOnly -and $latest.Date -ne [datetime]::MinValue) {
        $secondTue = (Get-SecondTuesday -Year $latest.Date.Year -Month $latest.Date.Month).Date
        if ($latest.Date.Date -ne $secondTue) {
            Write-Output "$(TS): -MonthlyOnly: $($latest.KB) dated $($latest.Date.ToString('yyyy-MM-dd')) is not the 2nd-Tuesday release ($($secondTue.ToString('yyyy-MM-dd'))); skipping."
            Stop-Transcript | Out-Null; exit 0
        }
    }

    # 3. Build. Pass paths EXPLICITLY so nothing depends on the slipstream's own defaults
    #    (-BasePath is the slipstream's working+output dir, so it must equal $OutputDir).
    $slipArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SlipstreamScript,'-BasePath',$OutputDir)
    if ($SourceISO) { $slipArgs += @('-SourceISO',$SourceISO) }
    Write-Output "$(TS): New build detected -> launching slipstream: $SlipstreamScript"
    Write-Output "$(TS):   -BasePath $OutputDir$(if($SourceISO){"  -SourceISO $SourceISO"})"
    & powershell.exe @slipArgs
    $slipExit = $LASTEXITCODE
    if ($slipExit -ne 0) { throw "Slipstream exited $slipExit; state NOT stamped (will retry next run)." }

    $iso = Get-ChildItem $OutputDir -Filter 'Server2025_Patched_*.iso' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw "Slipstream reported success but no ISO found in $OutputDir." }
    Write-Output "$(TS): Built ISO: $($iso.Name) ($([math]::Round($iso.Length/1GB,2)) GB)"

    # 4. Archive + retention
    if ($ShareRoot) {
        if (-not (Test-Path $ShareRoot)) { New-Item -ItemType Directory -Path $ShareRoot -Force | Out-Null }
        Write-Output "$(TS): Archiving to $ShareRoot"
        Copy-Item $iso.FullName (Join-Path $ShareRoot $iso.Name) -Force
        $log = Get-ChildItem $LogDir -Filter 'Slipstream_*.log' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) { Copy-Item $log.FullName (Join-Path $ShareRoot $log.Name) -Force }
        Get-ChildItem $ShareRoot -Filter 'Server2025_Patched_*.iso' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLast |
            ForEach-Object { Write-Output "$(TS): pruning $($_.Name)"; Remove-Item $_.FullName -Force }
    }

    # 5. Stamp state (only after a successful build + archive)
    [pscustomobject]@{
        KB          = $latest.KB
        Build       = $latest.Build.ToString()
        CatalogDate = $latest.Date.ToString('yyyy-MM-dd')
        Iso         = $iso.Name
        BuiltAt     = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Output "$(TS): State stamped -> $StateFile"
    Write-Output "$(TS): DONE. Patched media for $($latest.KB) (build $($latest.Build)) is ready."
}
catch {
    Write-Warning "$(TS): FAILED: $($_.Exception.Message)"
    $exit = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $exit
