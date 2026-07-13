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
    Path to Slipstream-WindowsMedia.ps1.

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
    .\Watch-Server2025Updates.ps1 -SlipstreamScript .\Slipstream-WindowsMedia.ps1 `
        -SourceISO 'D:\Server2025RTM\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO' `
        -ShareRoot 'D:\PatchedImages' -KeepLast 12

.NOTES
    Version : 1.1.0
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
    [ValidateRange(1,999)][int]$KeepLast = 12,
    [switch]$MonthlyOnly,
    [switch]$NoProxy,
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.2.0'
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
# NOTE: when this runs as SYSTEM (scheduled task), GetSystemWebProxy() reads SYSTEM's own
# WinINET hive (HKU\S-1-5-18), NOT your interactive user's settings. A stale ProxyEnable
# there makes us dial a dead proxy -> "Unable to connect to the remote server". The decision
# is logged, and -NoProxy forces a direct connection.
$ProxyArgs = @{}
if ($NoProxy) {
    [System.Net.WebRequest]::DefaultWebProxy = $null
    Write-Output "$(TS): -NoProxy specified: forcing a DIRECT connection (proxy detection skipped)."
} else {
    try {
        $sp = [System.Net.WebRequest]::GetSystemWebProxy()
        $sp.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        [System.Net.WebRequest]::DefaultWebProxy = $sp
        $probe = [Uri]'https://www.catalog.update.microsoft.com/'
        $pxy = $sp.GetProxy($probe)
        if ($pxy -and ($pxy.AbsoluteUri.TrimEnd('/') -ne $probe.AbsoluteUri.TrimEnd('/'))) {
            $ProxyArgs = @{ Proxy = $pxy.AbsoluteUri; ProxyUseDefaultCredentials = $true }
            Write-Output "$(TS): Detected system proxy: $($pxy.AbsoluteUri)  (re-run with -NoProxy if this is wrong)"
        } else {
            Write-Output "$(TS): No system proxy detected; using a DIRECT connection."
        }
    } catch { Write-Warning "$(TS): Proxy detection failed ($($_.Exception.Message)); using a direct connection." }
}

# The Catalog endpoint is demonstrably flaky (transient "Unable to connect", HTTP errors),
# and its DNS returns AAAA records whose IPv6 path isn't always routable. A miss here costs a
# whole day (we exit 0 and wait for tomorrow), so budget generously: 8 x 30s ~= 4 minutes.
function Invoke-Retry {
    param([scriptblock]$Script,[int]$Retries = 8,[int]$Delay = 30)
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

# A Catalog miss is survivable for a day - but a PERMANENT miss (Microsoft changes the search
# markup, or the title format, and the parser silently returns nothing) used to be an exit 0
# EVERY DAY, FOREVER. Task Scheduler would show "The operation completed successfully" while
# patched media quietly stopped being produced, and nothing would ever escalate. Count the
# misses; after 3 consecutive days, fail loudly so the task history goes red.
$MissFile = Join-Path (Split-Path $StateFile -Parent) 'miss-streak.txt'
function Register-Miss {
    param([string]$Reason)
    $n = 0
    if (Test-Path $MissFile) { $n = [int](Get-Content $MissFile -Raw).Trim() }
    $n++
    Set-Content -Path $MissFile -Value $n
    Write-Warning "$(TS): $Reason (consecutive misses: $n)"
    if ($n -ge 3) {
        Write-Warning "$(TS): $n consecutive Catalog misses - this is no longer a blip. The Catalog parser may be broken."
        return 2      # non-zero: surface it in the task history
    }
    return 0
}
function Clear-Miss { if (Test-Path $MissFile) { Remove-Item $MissFile -Force -ErrorAction SilentlyContinue } }

try {
    # 1. Detect
    $latest = $null
    # NOTE on every 'exit' below: do NOT call Stop-Transcript here - the finally block is the
    # sole owner of the transcript. A second Stop-Transcript throws, and a terminating error in
    # finally overrides the exit code (clean 'exit 0' becomes 1).
    try { $latest = Get-LatestServerLcu }
    catch { exit (Register-Miss "Catalog unreachable ($($_.Exception.Message)); will retry next run.") }
    if (-not $latest) { exit (Register-Miss 'No Server 2025 LCU found in Catalog results - parser may be broken.') }
    Clear-Miss
    Write-Output "$(TS): Latest available LCU: $($latest.KB) build $($latest.Build) (Catalog date $($latest.Date.ToString('yyyy-MM-dd')))"

    # 2. Compare to state
    $lastBuild = [Version]'0.0.0.0'
    if (Test-Path $StateFile) {
        # A corrupt/partial state file must NOT block a build - fall back to 0.0.0.0 (build anew).
        # Assign via a temp: a valid JSON with no .Build member casts to $null WITHOUT throwing,
        # so the catch never fires and $lastBuild silently became $null instead of 0.0.0.0.
        try {
            $b = (Get-Content $StateFile -Raw | ConvertFrom-Json).Build
            if ($b) { $lastBuild = [Version]$b }
            else    { Write-Warning "$(TS): State file has no Build member; treating as never-built." }
        }
        catch { Write-Warning "$(TS): State file unreadable ($($_.Exception.Message)); treating as never-built." }
    }
    if ($latest.Build -le $lastBuild) {
        Write-Output "$(TS): No new build (latest $($latest.Build) <= last built $lastBuild). Nothing to do."
        exit 0
    }

    # 2b. MonthlyOnly gate (skip OOB / off-cycle)
    # A WINDOW, not an equality test. The Catalog's "Last Updated" column is not the release
    # date: Microsoft re-publishes LCU metadata, and the column has been observed a day off.
    # With `-ne $secondTue`, one day of drift means we skip - and because we exit 0 WITHOUT
    # stamping state, every subsequent daily run re-detects the same build, re-evaluates the
    # same date, and skips again. The month's security media would never be built, and the only
    # symptom would be a "skipping" line in a log nobody reads.
    if ($MonthlyOnly -and $latest.Date -ne [datetime]::MinValue) {
        $secondTue = (Get-SecondTuesday -Year $latest.Date.Year -Month $latest.Date.Month).Date
        if ($latest.Date.Date -lt $secondTue -or $latest.Date.Date -gt $secondTue.AddDays(6)) {
            Write-Output "$(TS): -MonthlyOnly: $($latest.KB) dated $($latest.Date.ToString('yyyy-MM-dd')) is outside the patch-Tuesday window ($($secondTue.ToString('yyyy-MM-dd')) .. $($secondTue.AddDays(6).ToString('yyyy-MM-dd'))); skipping."
            exit 0
        }
    }

    # 3. Build. Pass paths EXPLICITLY so nothing depends on the slipstream's own defaults
    #    (-BasePath is the slipstream's working+output dir, so it must equal $OutputDir).
    # This detector's Catalog query is Server-2025-specific (see Get-LatestServerLcu), so it
    # pins the slipstream to the matching product profile. A Windows 11 detector would be a
    # separate task with its own state file.
    $slipArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SlipstreamScript,
                  '-Product','Server2025','-BasePath',$OutputDir)
    if ($SourceISO) { $slipArgs += @('-SourceISO',$SourceISO) }
    if ($NoProxy)   { $slipArgs += '-NoProxy' }   # the slipstream makes its own Catalog calls
    Write-Output "$(TS): New build detected -> launching slipstream: $SlipstreamScript"
    Write-Output "$(TS):   -BasePath $OutputDir$(if($SourceISO){"  -SourceISO $SourceISO"})"
    & powershell.exe @slipArgs
    $slipExit = $LASTEXITCODE
    if ($slipExit -ne 0) { throw "Slipstream exited $slipExit; state NOT stamped (will retry next run)." }

    $iso = Get-ChildItem $OutputDir -Filter 'Server2025_Patched_*.iso' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw "Slipstream reported success but no ISO found in $OutputDir." }

    # ---- Prove the ISO is the build we asked for ------------------------------
    # "Newest ISO in the folder" is NOT proof. The slipstream can legitimately exit 0 without
    # producing anything (its ALREADY-BUILT guard), and a stale-resume bug could ship media
    # whose install.wim is a month old. Either way we would archive LAST MONTH'S ISO and then
    # stamp state with THIS month's build - permanently marking the new LCU as built. It would
    # never be built again, and every log would be green.
    #
    # The slipstream writes a manifest beside every ISO it verifies. No manifest, or a manifest
    # that doesn't carry our build => refuse to archive and refuse to stamp. Retry tomorrow.
    $mfPath = "$($iso.FullName).json"
    if (-not (Test-Path $mfPath)) {
        throw "No manifest beside $($iso.Name) - cannot prove it contains $($latest.KB). Refusing to archive or stamp state."
    }
    $mf = Get-Content $mfPath -Raw | ConvertFrom-Json
    if (-not $mf.ActualBuild) {
        throw "Manifest $($iso.Name).json has no ActualBuild - refusing to archive or stamp state."
    }
    if ([Version]$mf.ActualBuild -lt $latest.Build) {
        throw ("Newest ISO $($iso.Name) ships build $($mf.ActualBuild) but the detected LCU is $($latest.Build). " +
               "The slipstream did not build what we asked for (stale resume, or it no-op'd). State NOT stamped.")
    }
    Write-Output "$(TS): Built ISO: $($iso.Name) ($([math]::Round($iso.Length/1GB,2)) GB), ships build $($mf.ActualBuild) - verified."

    # 4. Archive + retention
    if ($ShareRoot) {
        if (-not (Test-Path $ShareRoot)) { New-Item -ItemType Directory -Path $ShareRoot -Force | Out-Null }
        Write-Output "$(TS): Archiving to $ShareRoot"
        Copy-Item $iso.FullName (Join-Path $ShareRoot $iso.Name) -Force
        # Archive the manifest too. It is the only record of WHICH LCU is inside the archived
        # ISO - leaving it behind makes the archive unauditable.
        Copy-Item $mfPath (Join-Path $ShareRoot (Split-Path $mfPath -Leaf)) -Force

        # The slipstream writes its transcript to <BasePath>\logs, i.e. $OutputDir\logs - NOT to
        # this detector's $LogDir. They only coincide by default; pass -LogDir and the build log
        # was silently never archived (the `if ($log)` swallowed it).
        $slipLogDir = Join-Path $OutputDir 'logs'
        $log = Get-ChildItem $slipLogDir -Filter 'Slipstream_*.log' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) { Copy-Item $log.FullName (Join-Path $ShareRoot $log.Name) -Force }
        else      { Write-Warning "$(TS): No slipstream log found in $slipLogDir to archive." }

        # Prune ISOs, then their orphaned manifests. -File on both: a DIRECTORY named
        # Server2025_Patched_*.iso would otherwise be selected as "the ISO", and Remove-Item
        # -Force without -Recurse on a non-empty directory prompts or fails.
        Get-ChildItem $ShareRoot -Filter 'Server2025_Patched_*.iso' -File |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLast |
            ForEach-Object {
                Write-Output "$(TS): pruning $($_.Name)"
                Remove-Item $_.FullName -Force
                Remove-Item "$($_.FullName).json" -Force -ErrorAction SilentlyContinue
            }
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
    # Sole owner of the transcript. Guarded: with $ErrorActionPreference='Stop', a redundant
    # Stop-Transcript throws "host is not currently transcribing", and a terminating error in
    # a finally block OVERRIDES the script's exit code (turning a clean 'exit 0' into 1).
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose "transcript already stopped" }
}
exit $exit
