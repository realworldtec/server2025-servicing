<#
.SYNOPSIS
    Fully automated slipstream of the latest Windows Server 2025 (24H2) quality
    updates into the RTM MLF media, producing a new bootable, fully-patched ISO.

.DESCRIPTION
    End-to-end, unattended pipeline that:
      1. Creates the working folder tree under C:\Installs\Server2025Patching.
      2. Auto-downloads the current updates directly from the Microsoft Update Catalog
         (self-contained - no PowerShell module; retried search + BITS CDN downloads):
           - Latest Cumulative Update (LCU) + any prerequisite CHECKPOINT CUs
           - SafeOS Dynamic Update   (WinRE / winre.wim)
           - Setup  Dynamic Update   (media \sources)
           - .NET Framework Cumulative Update
         If the Catalog is unreachable, any .msu/.cab files you pre-stage in the
         package folders are used instead (offline fallback).
      3. Extracts the RTM ISO to .\newMedia.
      4. Services every image, in Microsoft's required order:
           WinRE (SSU + SafeOS DU)  ->  install.wim (ALL indexes: LCU checkpoint-aware,
           NetFX3, .NET CU, cleanup, export)  ->  boot.wim  ->  Setup DU media files.
      5. Rebuilds a UEFI+BIOS bootable ISO with the ADK's oscdimg.exe.
      6. Verifies the result by mounting the patched install.wim and reading its build.

    Reference (authoritative Microsoft procedure):
      - Update Windows installation media with Dynamic Update
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
      - Checkpoint cumulative updates and the Microsoft Update Catalog
        https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates

.NOTES
    Version    : 1.0.0
    Project    : server2025-servicing
    License    : MIT
    Run from an elevated Windows PowerShell 5.1+ prompt on a machine that has the
    Windows ADK + WinPE add-on installed in the default location.
    Latest Server 2025 LCU at time of writing: KB5094125 (2026-06, build 26100.32995).
    Requires ~30-40 GB free on C: and internet access (unless pre-staging updates).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Slipstream-Server2025.ps1
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Source RTM media
    [string]$SourceISO   = 'C:\Installs\Server2025RTM\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO',

    # Base working directory for all extractions / mounts / output
    [string]$BasePath    = 'C:\Installs\Server2025Patching',

    # Volume label for the finished ISO (max 32 chars for UDF)
    [string]$IsoLabel    = 'SERVER2025_PATCHED',

    # Set $true to keep the expanded \newMedia folder after the ISO is built
    [switch]$KeepNewMedia,

    # Force re-download even if package files already exist locally
    [switch]$ForceDownload,

    # Ignore any existing \newMedia and rebuild everything from the source ISO
    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # dramatically speeds up Save/Copy operations
$ScriptVersion          = '1.0.0'
function Get-TS { return '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }

# Retry a scriptblock a few times - the Microsoft Update Catalog frequently returns
# transient "has encountered an error. Please try again later." responses.
function Invoke-Retry {
    param([scriptblock]$Script,[int]$Retries = 6,[int]$DelaySeconds = 20,[string]$What = 'operation')
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try { return (& $Script) }
        catch {
            if ($attempt -ge $Retries) { throw }
            Write-Host "$(Get-TS): $What failed (attempt $attempt/$Retries): $($_.Exception.Message)"
            Write-Host "$(Get-TS): Retrying in $DelaySeconds s..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# Mount an ISO and reliably return its drive letter (Get-Volume can lag the mount).
function Mount-IsoGetDrive {
    param([string]$Path)
    Mount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null
    $dl = $null
    for ($i = 0; $i -lt 15 -and -not $dl; $i++) {
        Start-Sleep -Seconds 1
        $dl = (Get-DiskImage -ImagePath $Path | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $dl) { throw "Could not resolve a drive letter for mounted ISO: $Path" }
    return $dl
}

# ---------------------------------------------------------------------------
#  0.  Paths
# ---------------------------------------------------------------------------
$PKG_ROOT     = Join-Path $BasePath 'packages'
$CU_FOLDER    = Join-Path $PKG_ROOT 'CU'          # LCU + checkpoint CUs ONLY (folder-based discovery)
$SAFEOS_DIR   = Join-Path $PKG_ROOT 'SafeOS_DU'   # SafeOS Dynamic Update (one file)
$SETUP_DIR    = Join-Path $PKG_ROOT 'Setup_DU'    # Setup  Dynamic Update (one file)
$DOTNET_DIR   = Join-Path $PKG_ROOT 'DotNet_CU'   # .NET Framework CU     (one file)
$MEDIA_NEW    = Join-Path $BasePath 'newMedia'
$WORKING      = Join-Path $BasePath 'temp'
$MAIN_OS_MOUNT= Join-Path $WORKING  'MainOSMount'
$WINRE_MOUNT  = Join-Path $WORKING  'WinREMount'
$WINPE_MOUNT  = Join-Path $WORKING  'WinPEMount'
$LOG_DIR      = Join-Path $BasePath 'logs'
$stamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
$OUTPUT_ISO   = Join-Path $BasePath ("Server2025_Patched_{0}.iso" -f $stamp)

foreach ($d in @($BasePath,$PKG_ROOT,$CU_FOLDER,$SAFEOS_DIR,$SETUP_DIR,$DOTNET_DIR,$MEDIA_NEW,$WORKING,`
                 $MAIN_OS_MOUNT,$WINRE_MOUNT,$WINPE_MOUNT,$LOG_DIR)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Remove stale intermediate WIMs from a prior (possibly failed) run. Export-WindowsImage
# APPENDS to an existing target, so leftover install2/boot2/winre wims would corrupt output.
foreach ($stale in @('install2.wim','boot2.wim','winre.wim','winre2.wim')) {
    Remove-Item (Join-Path $WORKING $stale) -Force -ErrorAction SilentlyContinue
}

Start-Transcript -Path (Join-Path $LOG_DIR "Slipstream_$stamp.log") -Append | Out-Null
Write-Output "$(Get-TS): ===== Windows Server 2025 slipstream (v$ScriptVersion) started ====="
Write-Output "$(Get-TS): Source ISO : $SourceISO"
Write-Output "$(Get-TS): Base path  : $BasePath"
Write-Output "$(Get-TS): Output ISO : $OUTPUT_ISO"

# Track mounted images / ISOs so the cleanup trap can always tidy up.
$Script:MountedImagePaths = @()
$Script:MountedISOs       = @()

# ---------------------------------------------------------------------------
#  Cleanup trap - discards any half-finished mounts on failure
# ---------------------------------------------------------------------------
trap {
    Write-Warning "$(Get-TS): FATAL: $($_.Exception.Message)"
    Write-Warning $_.ScriptStackTrace
    foreach ($m in $Script:MountedImagePaths) {
        try { Dismount-WindowsImage -Path $m -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    foreach ($iso in $Script:MountedISOs) {
        try { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    try { Clear-WindowsCorruptMountPoint | Out-Null } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ===========================================================================
#  1.  Locate the ADK oscdimg.exe
# ===========================================================================
function Find-Oscdimg {
    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',
        'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $found = Get-ChildItem 'C:\Program Files (x86)\Windows Kits','C:\Program Files\Windows Kits' `
                -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
             Where-Object FullName -match 'amd64' | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "oscdimg.exe not found. Install the Windows ADK Deployment Tools."
}
$OSCDIMG = Find-Oscdimg
Write-Output "$(Get-TS): Using oscdimg: $OSCDIMG"

# ===========================================================================
#  2.  Acquire updates directly from the Microsoft Update Catalog
#      (no PowerShell module dependency; retried metadata calls + BITS CDN pulls)
# ===========================================================================
# Self-contained Microsoft Update Catalog client - no external module. Only the two
# small metadata calls hit catalog.update.microsoft.com (each retried); the actual
# packages are pulled from the download.windowsupdate.com CDN via BITS (resumable).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Script:CAT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Slipstream-Server2025'

# Make PowerShell use the same proxy the browser uses. "Unable to connect to the remote
# server" from Invoke-WebRequest (while a browser CAN reach the site) almost always means
# a system/WinINET proxy that IWR isn't honouring. Detect it once and reuse everywhere.
$Script:ProxyArgs = @{}
try {
    $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $sysProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    [System.Net.WebRequest]::DefaultWebProxy = $sysProxy
    $probeUri = [Uri]'https://www.catalog.update.microsoft.com/'
    $pxy = $sysProxy.GetProxy($probeUri)
    if ($pxy -and ($pxy.AbsoluteUri.TrimEnd('/') -ne $probeUri.AbsoluteUri.TrimEnd('/'))) {
        $Script:ProxyArgs = @{ Proxy = $pxy.AbsoluteUri; ProxyUseDefaultCredentials = $true }
        Write-Output "$(Get-TS): Detected system proxy: $($pxy.AbsoluteUri)"
    } else {
        Write-Output "$(Get-TS): No system proxy configured; using direct connection."
    }
} catch { Write-Warning "$(Get-TS): Proxy detection failed ($($_.Exception.Message)); using direct connection." }

# Single web-request path (proxy-aware, TLS1.2, basic parsing). Optional -OutFile downloads.
function Invoke-Web {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        $Body = $null,
        [string]$ContentType = $null,
        [string]$OutFile = $null,
        [int]$TimeoutSec = 120
    )
    $p = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec;
            Headers = @{ 'User-Agent' = $Script:CAT_UA } }
    if ($Body)        { $p.Body = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    if ($OutFile)     { $p.OutFile = $OutFile }
    foreach ($k in $Script:ProxyArgs.Keys) { $p[$k] = $Script:ProxyArgs[$k] }
    Invoke-WebRequest @p
}

# Query Search.aspx and return rows: @{ Guid; Title; YearMonth }.
# Real catalog markup (verified): results are table <tr> rows; the title is the <a> in
# the row, and the update GUID is the id of the Download <input> in the last cell.
function Search-Catalog {
    param([Parameter(Mandatory)][string]$Query)
    $uri = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    $html = Invoke-Retry -What "Catalog search '$Query'" -Script {
        (Invoke-Web -Uri $uri).Content
    }
    $rows    = @()
    $guidRx  = [regex]'(?i)<input[^>]*\bid="([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"'
    $titleRx = [regex]'(?is)<a\b[^>]*>(.*?)</a>'
    foreach ($chunk in ($html -split '(?i)<tr[\s>]')) {
        $g = $guidRx.Match($chunk)
        if (-not $g.Success) { continue }                     # not a result row (no Download button)
        $t = $titleRx.Match($chunk)
        if (-not $t.Success) { continue }
        $title = ($t.Groups[1].Value -replace '<[^>]+>','' -replace '&amp;','&' -replace '\s+',' ').Trim()
        if (-not $title) { continue }
        $ym = if ($title -match '^\s*(\d{4})-(\d{2})') { '{0}-{1}' -f $Matches[1],$Matches[2] } else { '0000-00' }
        $rows += [pscustomobject]@{ Guid = $g.Groups[1].Value; Title = $title; YearMonth = $ym }
    }
    return $rows
}

# Resolve the direct .msu/.cab download URLs for an update GUID (includes checkpoint
# files for post-checkpoint cumulative updates). Body/regex mirror the proven MSCatalog logic.
function Get-CatalogDownloadUrl {
    param([Parameter(Mandatory)][string]$Guid)
    $post = @{ size = 0; updateID = $Guid; uidInfo = $Guid } | ConvertTo-Json -Compress
    $body = @{ updateIDs = "[$post]" }
    $content = Invoke-Retry -What "Download dialog $Guid" -Script {
        (Invoke-Web -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
            -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded').Content
    }
    # Host-agnostic: Microsoft serves these from prefixed subdomains (b1.download...,
    # catalog.sf.dl.delivery.mp...), so DO NOT anchor on a fixed host. Match any
    # http/https URL that ends in .msu/.cab, bounded by the surrounding quotes.
    $urls = [regex]::Matches($content, '(?i)https?://[^''"\s]+?\.(?:msu|cab)') |
            ForEach-Object { $_.Value } | Sort-Object -Unique
    if (-not $urls) {
        $dump = Join-Path $LOG_DIR "DownloadDialog_$Guid.html"
        try { $content | Out-File -FilePath $dump -Encoding UTF8 } catch {}
        Write-Warning "$(Get-TS): No download URLs parsed from dialog. Raw response saved to $dump for inspection."
    }
    return $urls
}

# Resilient download: BITS first (resumable), Invoke-WebRequest as fallback.
function Get-FileResilient {
    param([string]$Url,[string]$OutFile)
    Invoke-Retry -What "Download $(Split-Path $Url -Leaf)" -Script {
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Start-BitsTransfer -Source $Url -Destination $OutFile -TransferType Download `
                -ProxyUsage SystemDefault -ErrorAction Stop
        } catch {
            Invoke-Web -Uri $Url -OutFile $OutFile -TimeoutSec 900 | Out-Null
        }
    }
}

# Pick the newest catalog update matching filters, download all of its files.
# Returns the number of files in $Destination afterward. Uses Write-Host for logging
# (this function returns a value, so Write-Output would pollute it).
function Save-CatalogUpdate {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$IncludeRegex,
        [string]$ExcludeRegex = '(?!)',
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Optional
    )
    Write-Host "$(Get-TS): Catalog search -> '$Query'"
    $rows = Search-Catalog -Query $Query |
            Where-Object { $_.Title -match $IncludeRegex -and $_.Title -notmatch $ExcludeRegex }
    # Prefer server-named packages, then x64, when such variants exist.
    if ($rows | Where-Object { $_.Title -match 'server operating system' }) { $rows = $rows | Where-Object { $_.Title -match 'server operating system' } }
    if ($rows | Where-Object { $_.Title -match 'x64' })                     { $rows = $rows | Where-Object { $_.Title -match 'x64' } }
    if (-not $rows) {
        if ($Optional) { Write-Warning "$(Get-TS): No catalog match for '$Query' (optional) - skipping."; return 0 }
        throw "No catalog result for '$Query' matching /$IncludeRegex/."
    }
    $pick = $rows | Sort-Object YearMonth -Descending | Select-Object -First 1
    Write-Host "$(Get-TS): Selected: $($pick.Title)  [$($pick.Guid)]"
    # Record the picked target's KB + build (used to identify the target LCU file vs its
    # checkpoint, and to detect an already-serviced install.wim for resume).
    if ($pick.Title -match 'KB(\d+)')            { $Script:LastPickedKB    = "kb$($Matches[1])" }
    if ($pick.Title -match '\((\d{5}\.\d+)\)')   { $Script:LastPickedBuild = "10.0.$($Matches[1])" }
    $urls = Get-CatalogDownloadUrl -Guid $pick.Guid
    if (-not $urls) { throw "Could not resolve download URLs for '$($pick.Title)'." }
    foreach ($u in $urls) {
        $name = (($u -split '/')[-1]) -replace '\?.*$',''
        Write-Host "$(Get-TS): Downloading $name"
        Get-FileResilient -Url $u -OutFile (Join-Path $Destination $name) | Out-Null
    }
    return [int](Get-ChildItem $Destination -File).Count
}

# Lightweight reachability probe (decides catalog vs. pre-staged fallback).
function Test-Catalog {
    try {
        Invoke-Retry -Retries 4 -DelaySeconds 15 -What 'Catalog reachability' -Script {
            Invoke-Web -Uri 'https://www.catalog.update.microsoft.com/' -TimeoutSec 60 | Out-Null
        }
        return $true
    } catch { Write-Warning "$(Get-TS): Catalog unreachable ($($_.Exception.Message)); will use pre-staged packages if present."; return $false }
}

# Printed when the Catalog can't be reached and packages aren't pre-staged. The build
# host may sit behind a proxy/firewall that PowerShell can't traverse - in that case
# download the four packages on any machine that CAN open the Catalog and drop them here.
function Show-PrestageHelp {
    Write-Warning @"
$(Get-TS): =========================================================================
 The Microsoft Update Catalog could not be reached from this host.
 If a browser on this machine CAN open https://www.catalog.update.microsoft.com,
 PowerShell is likely being blocked by a proxy/firewall it doesn't traverse.

 Guaranteed path - download these on any machine with Catalog access, then copy the
 files into the folders below and re-run this script (it auto-detects pre-staged files):

   LCU (+ its checkpoint .msu files, click Download and take ALL listed files)
     search: https://www.catalog.update.microsoft.com/Search.aspx?q=Cumulative%20Update%20Microsoft%20server%20operating%20system%20version%2024H2%20x64
     -> $CU_FOLDER
   SafeOS Dynamic Update
     search: https://www.catalog.update.microsoft.com/Search.aspx?q=Safe%20OS%20Dynamic%20Update%20server%20operating%20system%20version%2024H2%20x64
     -> $SAFEOS_DIR
   Setup Dynamic Update
     search: https://www.catalog.update.microsoft.com/Search.aspx?q=Setup%20Dynamic%20Update%20server%20operating%20system%20version%2024H2%20x64
     -> $SETUP_DIR
   .NET Framework CU (optional)
     search: https://www.catalog.update.microsoft.com/Search.aspx?q=Cumulative%20Update%20.NET%20Framework%20server%20operating%20system%20version%2024H2%20x64
     -> $DOTNET_DIR

 As of the latest Patch Tuesday the newest KBs are: LCU KB5094125 (build 26100.32995),
 SafeOS DU KB5094150, Setup DU KB5095966. Newer months supersede these.
=========================================================================
"@
}

# Only probe the Catalog if something actually needs downloading. This avoids the slow
# reachability retries on a resume/re-run where every package is already staged.
$cuStaged    = @(Get-ChildItem $CU_FOLDER  -Filter *.msu -File -ErrorAction SilentlyContinue).Count -gt 0
$safeStaged  = @(Get-ChildItem $SAFEOS_DIR -File -ErrorAction SilentlyContinue).Count -gt 0
$setupStaged = @(Get-ChildItem $SETUP_DIR  -File -ErrorAction SilentlyContinue).Count -gt 0
$dnStaged    = @(Get-ChildItem $DOTNET_DIR -File -ErrorAction SilentlyContinue).Count -gt 0
if ($ForceDownload -or -not ($cuStaged -and $safeStaged -and $setupStaged -and $dnStaged)) {
    $haveCatalog = Test-Catalog
} else {
    Write-Output "$(Get-TS): All update packages already staged - skipping Catalog reachability probe."
    $haveCatalog = $false
}

# --- Latest Cumulative Update (+ checkpoints)  -> CU_FOLDER --------------------
$existingCU = Get-ChildItem $CU_FOLDER -Filter *.msu -ErrorAction SilentlyContinue
if ($ForceDownload -or -not $existingCU) {
    Get-ChildItem $CU_FOLDER -File -ErrorAction SilentlyContinue | Remove-Item -Force
    if (-not $haveCatalog) { Show-PrestageHelp; throw "Catalog unreachable and no LCU pre-staged in $CU_FOLDER." }
    # Server 2025 (24H2) security LCU, x64. Its download dialog includes checkpoint .msu(s).
    Save-CatalogUpdate -Query 'Cumulative Update Microsoft server operating system version 24H2 x64' `
        -IncludeRegex 'Cumulative Update for Microsoft server operating system version 24H2' `
        -ExcludeRegex '\.NET|Preview|Dynamic' `
        -Destination $CU_FOLDER | Out-Null
} else {
    Write-Output "$(Get-TS): Using pre-staged CU package(s): $($existingCU.Name -join ', ')"
}

# Identify the TARGET LCU file (as opposed to its prerequisite checkpoint). WinRE and
# WinPE must receive ONLY the target LCU - pushing the checkpoint (an RTM-baseline CU)
# into the stripped-down boot images fails with 0x80073712. install.wim still gets the
# whole folder (checkpoint discovery is required there because we add .NET/NetFx3).
$cuFiles = @(Get-ChildItem $CU_FOLDER -Filter *.msu -File -ErrorAction SilentlyContinue)
$TARGET_LCU_FILE = $null
if ($Script:LastPickedKB) {
    $TARGET_LCU_FILE = ($cuFiles | Where-Object Name -match $Script:LastPickedKB | Select-Object -First 1).FullName
}
if (-not $TARGET_LCU_FILE -and $cuFiles.Count -gt 0) {
    # Fallback (e.g. pre-staged): the target LCU is by far the largest .msu; the checkpoint is smaller.
    $TARGET_LCU_FILE = ($cuFiles | Sort-Object Length -Descending | Select-Object -First 1).FullName
    Write-Warning "$(Get-TS): Target LCU KB not known; using largest CU file as target: $(Split-Path $TARGET_LCU_FILE -Leaf)"
}
if (-not $TARGET_LCU_FILE) { throw "No LCU .msu found in $CU_FOLDER." }
Write-Output "$(Get-TS): Target LCU (for boot.wim/WinRE): $(Split-Path $TARGET_LCU_FILE -Leaf)"
if ($cuFiles.Count -gt 1) { Write-Output "$(Get-TS): Checkpoint file(s) (install.wim only): $((($cuFiles | Where-Object FullName -ne $TARGET_LCU_FILE).Name) -join ', ')" }

# --- Single-file packages, each in its OWN folder (no filename guessing) ------
# Returns the path to the one package file in $Destination.
function Ensure-SinglePackage {
    param($Name,$Query,$Include,$Destination,$Exclude = '(?!)',[switch]$Optional)
    $have = @(Get-ChildItem $Destination -File -ErrorAction SilentlyContinue)
    if ($have.Count -gt 0 -and -not $ForceDownload) {
        Write-Host "$(Get-TS): Using pre-staged ${Name}: $($have[0].Name)"
        return $have[0].FullName
    }
    if (-not $haveCatalog) {
        if ($Optional) { Write-Warning "$(Get-TS): $Name offline and not pre-staged - skipping."; return $null }
        throw "$Name not pre-staged in $Destination and Catalog is unreachable."
    }
    Get-ChildItem $Destination -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $n = Save-CatalogUpdate -Query $Query -IncludeRegex $Include -ExcludeRegex $Exclude `
            -Destination $Destination -Optional:$Optional
    if ($n -eq 0) { return $null }
    return (Get-ChildItem $Destination -File | Select-Object -First 1).FullName
}

# NOTE: the SafeOS/Setup Dynamic Updates are keyed to build 26100 (24H2). Microsoft now
# titles them "...Windows 11, versions 24H2 and 25H2" (they still service Server 2025's
# WinRE); the match below accepts either the server-named or the 24H2 client-named package.
$SAFE_OS_DU_PATH = Ensure-SinglePackage -Name 'SafeOS DU' -Destination $SAFEOS_DIR `
    -Query 'Safe OS Dynamic Update Microsoft server operating system version 24H2 x64' `
    -Include 'Safe OS Dynamic Update for (Microsoft server operating system version 24H2|Windows 11,? version.*24H2)'
$SETUP_DU_PATH = Ensure-SinglePackage -Name 'Setup DU' -Destination $SETUP_DIR `
    -Query 'Setup Dynamic Update Microsoft server operating system version 24H2 x64' `
    -Include 'Setup Dynamic Update for (Microsoft server operating system version 24H2|Windows 11,? version.*24H2)'
$DOTNET_CU_PATH = Ensure-SinglePackage -Name '.NET CU' -Destination $DOTNET_DIR -Optional `
    -Query 'Cumulative Update .NET Framework Microsoft server operating system version 24H2 x64' `
    -Include 'Cumulative Update for \.NET Framework .*Microsoft server operating system version 24H2' `
    -Exclude 'Preview'

Write-Output "$(Get-TS): CU folder    : $CU_FOLDER  ($((Get-ChildItem $CU_FOLDER -File).Count) file(s))"
Write-Output "$(Get-TS): SafeOS DU    : $SAFE_OS_DU_PATH"
Write-Output "$(Get-TS): Setup  DU    : $SETUP_DU_PATH"
Write-Output "$(Get-TS): .NET CU      : $DOTNET_CU_PATH"
if (-not $SAFE_OS_DU_PATH) { throw "SafeOS Dynamic Update missing - cannot service WinRE." }
if (-not $SETUP_DU_PATH)   { throw "Setup Dynamic Update missing - cannot refresh media \sources." }

$INSTALL_WIM = Join-Path $MEDIA_NEW 'sources\install.wim'
$BOOT_WIM    = Join-Path $MEDIA_NEW 'sources\boot.wim'

# ---- Resume detection --------------------------------------------------------
# A prior failure (e.g. at boot.wim) leaves \newMedia intact with a fully-serviced
# install.wim. Re-servicing it costs hours, so detect that and skip straight to
# boot.wim. "Serviced" = every install.wim index is above the RTM baseline (26100.1742).
$RTM_BASE      = [Version]'10.0.26100.1742'
$SERVICED_FLAG = Join-Path $MEDIA_NEW '.slipstream_installwim_done'
$installServiced = $false
if (-not $Fresh) {
    if (Test-Path $SERVICED_FLAG) {
        $installServiced = $true                       # fast, definitive marker
    } elseif (Test-Path $INSTALL_WIM) {
        # Fallback: query EACH index for its .Version (the no -Index form omits .Version).
        try {
            $allUp = $true
            foreach ($im in (Get-WindowsImage -ImagePath $INSTALL_WIM -ErrorAction Stop)) {
                $d = Get-WindowsImage -ImagePath $INSTALL_WIM -Index $im.ImageIndex -ErrorAction Stop
                if (-not $d.Version -or ([Version]$d.Version -le $RTM_BASE)) { $allUp = $false; break }
            }
            $installServiced = $allUp
        } catch { $installServiced = $false }
    }
}

if ($installServiced) {
    Write-Output "$(Get-TS): RESUME: existing serviced install.wim found in \newMedia (all indexes > RTM). Skipping ISO extraction and install.wim servicing. Use -Fresh to force a full rebuild."
} else {
    # ===========================================================================
    #  3.  Extract the RTM ISO into \newMedia
    # ===========================================================================
    Write-Output "$(Get-TS): Mounting source ISO..."
    $srcDrive = Mount-IsoGetDrive -Path $SourceISO
    $Script:MountedISOs += $SourceISO
    $srcRoot = "$srcDrive`:\"
    Write-Output "$(Get-TS): Copying media $srcRoot -> $MEDIA_NEW"
    Get-ChildItem $MEDIA_NEW -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $srcRoot '*') -Destination $MEDIA_NEW -Recurse -Force
    Dismount-DiskImage -ImagePath $SourceISO | Out-Null
    $Script:MountedISOs = $Script:MountedISOs | Where-Object { $_ -ne $SourceISO }
    # clear read-only so the images can be serviced
    Get-ChildItem $MEDIA_NEW -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.IsReadOnly } |
        ForEach-Object { $_.IsReadOnly = $false }

    if (-not (Test-Path $INSTALL_WIM)) {
        $esd = Join-Path $MEDIA_NEW 'sources\install.esd'
        if (Test-Path $esd) {
            Write-Output "$(Get-TS): Converting install.esd -> install.wim (all indexes)..."
            $idx = Get-WindowsImage -ImagePath $esd
            foreach ($i in $idx) {
                Export-WindowsImage -SourceImagePath $esd -SourceIndex $i.ImageIndex `
                    -DestinationImagePath $INSTALL_WIM -CompressionType Max | Out-Null
            }
            Remove-Item $esd -Force
        } else { throw "Neither install.wim nor install.esd found in media \sources." }
    }

    # ===========================================================================
    #  4.  Service WinRE + every install.wim edition
    # ===========================================================================
    $WINOS_IMAGES = Get-WindowsImage -ImagePath $INSTALL_WIM
    Write-Output "$(Get-TS): install.wim contains $($WINOS_IMAGES.Count) edition(s)."

foreach ($IMAGE in $WINOS_IMAGES) {
    $ix = $IMAGE.ImageIndex
    Write-Output "$(Get-TS): ---- Mounting main OS index $ix ($($IMAGE.ImageName)) ----"
    Mount-WindowsImage -ImagePath $INSTALL_WIM -Index $ix -Path $MAIN_OS_MOUNT | Out-Null
    $Script:MountedImagePaths += $MAIN_OS_MOUNT

    if ($ix -eq 1) {
        # ----- WinRE (serviced once, reused for every edition) -----
        Copy-Item "$MAIN_OS_MOUNT\windows\system32\recovery\winre.wim" "$WORKING\winre.wim" -Force
        Write-Output "$(Get-TS): Mounting WinRE"
        Mount-WindowsImage -ImagePath "$WORKING\winre.wim" -Index 1 -Path $WINRE_MOUNT | Out-Null
        $Script:MountedImagePaths += $WINRE_MOUNT

        # Step 1: SSU via cumulative update (LCU part fails 0x8007007e on WinRE - expected).
        # Use the single TARGET LCU file, never the checkpoint (see note at download).
        Write-Output "$(Get-TS): Adding SSU (via CU) to WinRE"
        try { Add-WindowsPackage -Path $WINRE_MOUNT -PackagePath $TARGET_LCU_FILE | Out-Null }
        catch {
            if ($_.Exception.Message -like '*0x8007007e*') { Write-Warning "$(Get-TS): 0x8007007e on WinRE - known/ignored." }
            else { throw }
        }
        # Step 6: SafeOS Dynamic Update
        Write-Output "$(Get-TS): Adding SafeOS DU to WinRE"
        Add-WindowsPackage -Path $WINRE_MOUNT -PackagePath $SAFE_OS_DU_PATH | Out-Null
        # Step 7: cleanup
        Write-Output "$(Get-TS): Cleanup WinRE"
        DISM /image:$WINRE_MOUNT /cleanup-image /StartComponentCleanup /ResetBase /Defer | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "WinRE cleanup failed ($LASTEXITCODE)." }

        Dismount-WindowsImage -Path $WINRE_MOUNT -Save | Out-Null
        $Script:MountedImagePaths = $Script:MountedImagePaths | Where-Object { $_ -ne $WINRE_MOUNT }
        # Step 8: export (shrink)
        Export-WindowsImage -SourceImagePath "$WORKING\winre.wim" -SourceIndex 1 `
            -DestinationImagePath "$WORKING\winre2.wim" | Out-Null
    }

    # Put the serviced WinRE back into this edition
    Copy-Item "$WORKING\winre2.wim" "$MAIN_OS_MOUNT\windows\system32\recovery\winre.wim" -Force

    # Step 9-13: main OS. Passing the CU FOLDER lets DISM discover + apply any
    # checkpoint CUs first, then the target LCU (required because we add NetFX3).
    Write-Output "$(Get-TS): Adding CU (checkpoint-aware) to main OS index $ix"
    Add-WindowsPackage -Path $MAIN_OS_MOUNT -PackagePath $CU_FOLDER | Out-Null

    # Step 14: cleanup (tolerate CBS_E_PENDING from offline feature adds)
    Write-Output "$(Get-TS): Cleanup main OS index $ix"
    DISM /image:$MAIN_OS_MOUNT /cleanup-image /StartComponentCleanup | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($LASTEXITCODE -eq -2146498554) { Write-Warning "$(Get-TS): CBS_E_PENDING on index $ix - ignored." }
        else { throw "Main OS cleanup failed on index $ix ($LASTEXITCODE)." }
    }

    # Step 15: .NET 3.5 (source = media \sources\sxs) + .NET CU.
    # Non-fatal: if 3.5 enablement fails the rest of the image is still valid.
    $sxs = Join-Path $MEDIA_NEW 'sources\sxs'
    if (Test-Path $sxs) {
        Write-Output "$(Get-TS): Enabling .NET 3.5 (NetFx3) on index $ix"
        try {
            DISM /Image:$MAIN_OS_MOUNT /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$sxs | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$(Get-TS): DISM Enable-Feature NetFx3 returned $LASTEXITCODE; trying Add-WindowsCapability"
                Add-WindowsCapability -Name 'NetFX3~~~~' -Path $MAIN_OS_MOUNT -Source $sxs -LimitAccess -ErrorAction Stop | Out-Null
            }
        } catch { Write-Warning "$(Get-TS): Could not enable .NET 3.5 on index $ix ($($_.Exception.Message)); continuing." }
    } else { Write-Warning "$(Get-TS): \sources\sxs not found; skipping .NET 3.5 enable." }
    if ($DOTNET_CU_PATH) {
        Write-Output "$(Get-TS): Adding .NET CU to index $ix"
        Add-WindowsPackage -Path $MAIN_OS_MOUNT -PackagePath $DOTNET_CU_PATH | Out-Null
    }

    Dismount-WindowsImage -Path $MAIN_OS_MOUNT -Save | Out-Null
    $Script:MountedImagePaths = $Script:MountedImagePaths | Where-Object { $_ -ne $MAIN_OS_MOUNT }

    # Step 16: export edition into the consolidated install2.wim
    Write-Output "$(Get-TS): Exporting index $ix"
    Export-WindowsImage -SourceImagePath $INSTALL_WIM -SourceIndex $ix `
        -DestinationImagePath "$WORKING\install2.wim" | Out-Null
}
    Move-Item "$WORKING\install2.wim" $INSTALL_WIM -Force
    # Drop a resume marker so a later re-run (e.g. after a boot.wim/ISO failure) skips
    # the multi-hour install.wim phase instead of rebuilding it.
    Set-Content -Path $SERVICED_FLAG -Value ("serviced {0}" -f (Get-TS)) -ErrorAction SilentlyContinue
    Write-Output "$(Get-TS): install.wim fully serviced."
}   # end else (install.wim servicing / resume skip)

# ===========================================================================
#  5.  Service WinPE (boot.wim)  +  capture serviced boot binaries
# ===========================================================================
$WINPE_IMAGES = Get-WindowsImage -ImagePath $BOOT_WIM
foreach ($IMAGE in $WINPE_IMAGES) {
    $ix = $IMAGE.ImageIndex
    Write-Output "$(Get-TS): ---- Mounting WinPE (boot.wim) index $ix ----"
    Mount-WindowsImage -ImagePath $BOOT_WIM -Index $ix -Path $WINPE_MOUNT | Out-Null
    $Script:MountedImagePaths += $WINPE_MOUNT

    # Step 17: SSU via CU. Use the single TARGET LCU file - NOT the folder. Pushing the
    # checkpoint (RTM-baseline CU) into WinPE fails 0x80073712 (assembly missing), because
    # WinPE lacks components the checkpoint references. WinPE is already at the checkpoint
    # baseline (RTM 26100.1742), so the post-checkpoint target LCU applies directly.
    Write-Output "$(Get-TS): Adding SSU (via CU) to WinPE index $ix"
    try { Add-WindowsPackage -Path $WINPE_MOUNT -PackagePath $TARGET_LCU_FILE | Out-Null }
    catch {
        if ($_.Exception.Message -like '*0x8007007e*') { Write-Warning "$(Get-TS): 0x8007007e on WinPE - known/ignored." }
        else { throw }
    }
    # Step 23: latest cumulative update (target LCU only)
    Write-Output "$(Get-TS): Adding CU to WinPE index $ix"
    Add-WindowsPackage -Path $WINPE_MOUNT -PackagePath $TARGET_LCU_FILE | Out-Null

    # Step 24: cleanup
    Write-Output "$(Get-TS): Cleanup WinPE index $ix"
    DISM /image:$WINPE_MOUNT /cleanup-image /StartComponentCleanup /ResetBase /Defer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WinPE cleanup failed on index $ix ($LASTEXITCODE)." }

    if ($ix -eq 2) {
        # keep serviced setup binaries + boot managers so versions match the media
        Copy-Item "$WINPE_MOUNT\sources\setup.exe" "$WORKING\setup.exe" -Force
        $peVer = (Get-WindowsImage -ImagePath $BOOT_WIM -Index $ix).Version
        if ([Version]$peVer -ge [Version]'10.0.26100') {
            Copy-Item "$WINPE_MOUNT\sources\setuphost.exe" "$WORKING\setuphost.exe" -Force
        }
        Copy-Item "$WINPE_MOUNT\Windows\boot\efi\bootmgfw.efi" "$WORKING\bootmgfw.efi" -Force
        Copy-Item "$WINPE_MOUNT\Windows\boot\efi\bootmgr.efi"  "$WORKING\bootmgr.efi"  -Force
    }

    Dismount-WindowsImage -Path $WINPE_MOUNT -Save | Out-Null
    $Script:MountedImagePaths = $Script:MountedImagePaths | Where-Object { $_ -ne $WINPE_MOUNT }

    # Step 25: export
    Export-WindowsImage -SourceImagePath $BOOT_WIM -SourceIndex $ix `
        -DestinationImagePath "$WORKING\boot2.wim" | Out-Null
}
Move-Item "$WORKING\boot2.wim" $BOOT_WIM -Force
Write-Output "$(Get-TS): boot.wim fully serviced."

# ===========================================================================
#  6.  Update the remaining media files (Setup DU + serviced binaries)
# ===========================================================================
Write-Output "$(Get-TS): Expanding Setup DU into media \sources"
& "$env:SystemRoot\System32\expand.exe" $SETUP_DU_PATH -F:* (Join-Path $MEDIA_NEW 'sources') | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Setup DU expand failed ($LASTEXITCODE)." }

Copy-Item "$WORKING\setup.exe" (Join-Path $MEDIA_NEW 'sources\setup.exe') -Force
if (Test-Path "$WORKING\setuphost.exe") {
    Copy-Item "$WORKING\setuphost.exe" (Join-Path $MEDIA_NEW 'sources\setuphost.exe') -Force
}
Get-ChildItem $MEDIA_NEW -Force -Recurse -Filter b*.efi | ForEach-Object {
    switch -Regex ($_.Name) {
        '^(bootmgfw|bootx64|bootia32|bootaa64)\.efi$' { Copy-Item "$WORKING\bootmgfw.efi" $_.FullName -Force }
        '^bootmgr\.efi$'                              { Copy-Item "$WORKING\bootmgr.efi"  $_.FullName -Force }
    }
}
Write-Output "$(Get-TS): Media files refreshed."

# ===========================================================================
#  7.  Rebuild the bootable ISO with oscdimg
# ===========================================================================
# Remove the internal resume marker so it doesn't get baked into the ISO.
Remove-Item $SERVICED_FLAG -Force -ErrorAction SilentlyContinue

$etfs = Join-Path $MEDIA_NEW 'boot\etfsboot.com'
$efi  = Join-Path $MEDIA_NEW 'efi\microsoft\boot\efisys.bin'
if (-not (Test-Path $etfs)) { throw "Missing $etfs" }
if (-not (Test-Path $efi))  { throw "Missing $efi" }

# 2#... = El Torito: BIOS (etfsboot.com) + UEFI (efisys.bin) no-emulation boot.
# oscdimg needs literal quotes around paths; passing those through PowerShell to a
# native exe is unreliable (PS 5.1), so we emit a .cmd and let cmd handle the quoting.
$bootData = "2#p0,e,b`"$etfs`"#pEF,e,b`"$efi`""
$isoCmd   = Join-Path $WORKING 'build_iso.cmd'
$cmdLine  = "`"$OSCDIMG`" -bootdata:$bootData -u2 -udfver102 -l`"$IsoLabel`" -o -m -h `"$MEDIA_NEW`" `"$OUTPUT_ISO`""
@("@echo off", $cmdLine, "exit /b %ERRORLEVEL%") | Set-Content -Path $isoCmd -Encoding Ascii
Write-Output "$(Get-TS): Building ISO -> $OUTPUT_ISO"
Write-Output "$(Get-TS): oscdimg command: $cmdLine"
& $env:SystemRoot\System32\cmd.exe /c "`"$isoCmd`""
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)." }
Write-Output "$(Get-TS): ISO created: $OUTPUT_ISO  ($([math]::Round((Get-Item $OUTPUT_ISO).Length/1GB,2)) GB)"

# ===========================================================================
#  8.  Verify the patched build
# ===========================================================================
Write-Output "$(Get-TS): ===== Verification ====="
$verifyMount = Join-Path $WORKING 'VerifyMount'
New-Item -ItemType Directory -Path $verifyMount -Force | Out-Null
$vDrive = Mount-IsoGetDrive -Path $OUTPUT_ISO
$Script:MountedISOs += $OUTPUT_ISO
$vWim = "$vDrive`:\sources\install.wim"
Mount-WindowsImage -ImagePath $vWim -Index 1 -Path $verifyMount -ReadOnly | Out-Null
$Script:MountedImagePaths += $verifyMount

$ver = (Get-WindowsImage -ImagePath $vWim -Index 1).Version
$lcuPkgs = Get-WindowsPackage -Path $verifyMount |
           Where-Object { $_.PackageName -match 'Cumulative|LanguageFeatures|NetFX|Checkpoint' -or $_.ReleaseType -match 'Update' } |
           Sort-Object PackageName
Write-Output "$(Get-TS): Patched install.wim (index 1) build version: $ver"
Write-Output "$(Get-TS): Update packages present in image:"
$lcuPkgs | Select-Object PackageName, PackageState | Format-Table -AutoSize | Out-String | Write-Output

Dismount-WindowsImage -Path $verifyMount -Discard | Out-Null
$Script:MountedImagePaths = $Script:MountedImagePaths | Where-Object { $_ -ne $verifyMount }
Dismount-DiskImage -ImagePath $OUTPUT_ISO | Out-Null
$Script:MountedISOs = $Script:MountedISOs | Where-Object { $_ -ne $OUTPUT_ISO }

# ===========================================================================
#  9.  Cleanup
# ===========================================================================
if (-not $KeepNewMedia) {
    Write-Output "$(Get-TS): Removing working folders (use -KeepNewMedia to retain \newMedia)"
    Remove-Item $WORKING   -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $MEDIA_NEW -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Remove-Item $WORKING -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "$(Get-TS): ===== DONE. Patched ISO: $OUTPUT_ISO ====="
Stop-Transcript | Out-Null
