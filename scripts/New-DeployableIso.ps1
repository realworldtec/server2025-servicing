<#
.SYNOPSIS
    Remaster the LAST patched ISO for a product into a lean, single-edition DEPLOY ISO with the
    privacy hardening baked into the image. Reuses the ~4-hour slipstream output - it
    does NOT re-service anything, so this runs in minutes.

.DESCRIPTION
    Why: the fully-patched Win11 media carries several editions and no hardening. For deploying to
    a VM or the Acer you want ONE edition (Pro) plus the SetupComplete hardening already inside the
    media, and you want to keep the already-applied patches (a fresh MS download would lag and cost
    an hour-plus of first-boot updates).

    Steps:
      1. Find the newest patched ISO for -Product (its profile's ArchiveRoot, else BasePath),
         matching the plain build name '<IsoPrefix>_<stamp>.iso' (never a prior _Deploy_ output).
      2. Mount it read-only and copy the media tree to a writable work dir.
      3. Export the ONE edition named -EditionName from install.wim into a fresh single-image
         install.wim (renumbered to index 1). boot.wim / setup / boot chain are left as-is.
      4. Inject the hardening DIRECTLY INTO the image at \Windows\Setup\Scripts (mount install.wim,
         copy SetupComplete.cmd + Invoke-PrivacyHardening.ps1, dismount /Save). This is more
         reliable than a sources\$OEM$ folder (which needs <UseConfigurationSet> in the answer
         file and has been flaky on 24H2), and matches baking into a sysprep'd image.
         CAVEAT: Windows Setup SKIPS SetupComplete.cmd when an OEM product key is in firmware
         (e.g. the Acer). For such machines run the script once by hand (it's already at
         C:\Windows\Setup\Scripts\Invoke-PrivacyHardening.ps1) or call it from the answer file's
         FirstLogonCommands. See docs/PRIVACY-HARDENING.md.
      5. Optionally (-IncludeUnattend) drop autounattend.xml at the ISO root => a fully unattended,
         DISK-WIPING installer. OFF by default (see the warning).
      6. Rebuild a UEFI+BIOS bootable ISO with oscdimg and verify the single edition + build.

.PARAMETER Product        Product profile to source from. Default 'Win11-25H2'.
.PARAMETER EditionName    Exact ImageName to keep. Default 'Windows 11 Pro'. (Names, not indexes,
                          so trimming/renumbering of the source can't pick the wrong one.)
.PARAMETER ConfigPath     Products.psd1. Default ..\config\Products.psd1.
.PARAMETER SourceIso      Override the auto-found patched ISO.
.PARAMETER OutputIso      Override the output path/name.
.PARAMETER WorkDir        Scratch dir. Default <BasePath>\remaster.
.PARAMETER HardenDir      Folder holding SetupComplete.cmd + Invoke-PrivacyHardening.ps1.
                          Default ..\harden. Pass -NoHarden to skip the image injection.
.PARAMETER NoHarden       Do not inject the hardening into the image.
.PARAMETER IncludeUnattend  Bake autounattend.xml at the ISO ROOT (fully unattended, WIPES DISK 0
                          on boot). Default OFF. Use for a dedicated deploy image only.
.PARAMETER UnattendPath   Answer file to bake when -IncludeUnattend. Default ..\unattend\autounattend-Win11.xml.
.PARAMETER SkipCurrencyCheck  Skip the metadata-only currency guard that WARNS when the chosen
                          source ISO was built with an LCU older than the current catalog LCU
                          (i.e. a fresh build had not finished when this ran). Warning only - it
                          never blocks the build.
.PARAMETER KeepWork       Keep the work dir after building (default: delete it).

.EXAMPLE
    # Newest patched Win11-25H2 -> single Pro edition + hardening baked in:
    .\scripts\New-DeployableIso.ps1

.EXAMPLE
    # Fully unattended deploy image (wipes disk 0 on boot):
    .\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro' -IncludeUnattend

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Run elevated on the build host (ADK + WinPE for oscdimg). PowerShell 5.1+.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Product     = 'Win11-25H2',
    [string]$EditionName = 'Windows 11 Pro',
    [string]$ConfigPath,
    [string]$SourceIso,
    [string]$OutputIso,
    [string]$WorkDir,
    [string]$HardenDir,
    [switch]$NoHarden,
    [switch]$IncludeUnattend,
    [string]$UnattendPath,
    # Firefox: bake the OFFLINE installer into the image so the hardening can install it with NO
    # network at first boot. -FirefoxSetup <path> uses a supplied installer; otherwise the latest
    # x64 en-US offline installer is downloaded at build time (current media -> current-ish Firefox).
    [string]$FirefoxSetup,
    [string]$FirefoxUrl  = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US',
    [switch]$NoFirefox,
    [switch]$SkipCurrencyCheck,   # skip the "is the source built with the current LCU?" warning
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.2.0'
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }

# ---- Locate oscdimg (ADK) -----------------------------------------------------
function Get-Oscdimg {
    $cands = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $hit = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $hit) { throw "oscdimg.exe not found - install the Windows ADK + WinPE add-on." }
    return $hit
}

# ---- Mount an ISO read-only, return its drive letter --------------------------
function Mount-IsoGetDrive {
    param([string]$Path)
    $img = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru
    Start-Sleep -Milliseconds 800
    $vol = $img | Get-Volume
    if (-not $vol.DriveLetter) { $vol = Get-DiskImage -ImagePath $Path | Get-Volume }
    if (-not $vol.DriveLetter) { throw "Could not resolve a drive letter for $Path" }
    return [string]$vol.DriveLetter
}

# ---- Currency guard helpers (metadata-only; never download) -------------------
# Ask the Microsoft Update Catalog what the CURRENT LCU KB is for a product, using the SAME
# search strings the slipstream uses (from the profile). This is a read-only second consumer of
# the profile's Catalog naming - it parses the results page and returns a KB string, nothing more.
# Returns $null if the Catalog can't be reached (caller then falls back to the date heuristic).
# The row pick mirrors the slipstream's proven logic, incl. the KB-descending tie-break within a
# month (so a month carrying both an out-of-band CU and the Patch-Tuesday LCU resolves correctly).
function Get-CurrentCatalogLcuKb {
    param([string]$Query, [string]$IncludeRegex, [string]$PreferRegex)
    if (-not $Query -or -not $IncludeRegex) { return $null }
    $uri = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    $html = $null
    for ($a = 1; $a -le 3 -and -not $html; $a++) {
        try { $html = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 60).Content }
        catch { if ($a -lt 3) { Start-Sleep -Seconds 8 } }
    }
    if (-not $html) { return $null }
    $guidRx  = [regex]'(?i)<input[^>]*\bid="([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"'
    $titleRx = [regex]'(?is)<a\b[^>]*>(.*?)</a>'
    $rows = @()
    foreach ($chunk in ($html -split '(?i)<tr[\s>]')) {
        if (-not $guidRx.Match($chunk).Success) { continue }
        $t = $titleRx.Match($chunk)
        if (-not $t.Success) { continue }
        $title = ($t.Groups[1].Value -replace '<[^>]+>','' -replace '&amp;','&' -replace '\s+',' ').Trim()
        if (-not $title -or $title -notmatch $IncludeRegex) { continue }
        $ym = if ($title -match '^\s*(\d{4})-(\d{2})') { '{0}-{1}' -f $Matches[1], $Matches[2] } else { '0000-00' }
        $rows += [pscustomobject]@{ Title = $title; YearMonth = $ym }
    }
    if ($PreferRegex) { $pref = @($rows | Where-Object { $_.Title -match $PreferRegex }); if ($pref.Count -gt 0) { $rows = $pref } }
    if ($rows | Where-Object { $_.Title -match 'x64' }) { $rows = $rows | Where-Object { $_.Title -match 'x64' } }
    if (-not $rows) { return $null }
    $pick = $rows |
            Sort-Object YearMonth, @{ Expression = { if ($_.Title -match 'KB(\d+)') { [int]$Matches[1] } else { 0 } } } -Descending |
            Select-Object -First 1
    if ($pick.Title -match 'KB(\d+)') { return "KB$($Matches[1])" }
    return $null
}

# Most recent Patch Tuesday (2nd Tuesday of the month) on/before $AsOf - the offline fallback:
# if the Catalog is unreachable we can't know the current KB, but a source built before the last
# Patch Tuesday is very likely a cycle behind.
function Get-LastPatchTuesday {
    param([datetime]$AsOf = (Get-Date))
    $second = {
        param($y, $m)
        $first = [datetime]::new($y, $m, 1)
        $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
        $first.AddDays($offset + 7)
    }
    $pt = & $second $AsOf.Year $AsOf.Month
    if ($AsOf -lt $pt) { $prev = $AsOf.AddMonths(-1); $pt = & $second $prev.Year $prev.Month }
    return $pt.Date
}

# ---- Load the product profile -------------------------------------------------
$repo = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath)   { $ConfigPath   = Join-Path $repo 'config\Products.psd1' }
if (-not $HardenDir)    { $HardenDir    = Join-Path $repo 'harden' }
if (-not $UnattendPath) { $UnattendPath = Join-Path $repo 'unattend\autounattend-Win11.xml' }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$cfg = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
$profileMap = if ($cfg -and $cfg.ContainsKey('Products')) { $cfg.Products } else { $cfg }   # avoid $PRODUCTS name on purpose
if (-not $profileMap.ContainsKey($Product)) {
    throw "Unknown -Product '$Product'. Defined: $(($profileMap.Keys | Sort-Object) -join ', ')"
}
$P = $profileMap[$Product]

$BasePath = [string]$P.BasePath
$Archive  = [string]$P.ArchiveRoot
$Prefix   = [string]$P.IsoPrefix
$Label    = [string]$P.Label
if (-not $WorkDir) { $WorkDir = Join-Path $BasePath 'remaster' }

# ---- Find the newest patched source ISO ---------------------------------------
if (-not $SourceIso) {
    $rx = "^{0}_\d{{8}}_\d{{6}}\.iso$" -f [regex]::Escape($Prefix)   # plain build name only, not _Deploy_
    $searchDirs = @($Archive, $BasePath) | Where-Object { $_ -and (Test-Path $_) }
    $found = foreach ($d in $searchDirs) {
        Get-ChildItem $d -Filter "$Prefix*.iso" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $rx }
    }
    $SourceIso = ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $SourceIso) { throw "No patched '$Prefix' ISO found in: $($searchDirs -join '; '). Build one first, or pass -SourceIso." }
}
if (-not (Test-Path $SourceIso)) { throw "SourceIso not found: $SourceIso" }

# ---- Paths + output name ------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$edTag   = ($EditionName.Split(' ') | Select-Object -Last 1)        # 'Pro', 'Workstations', ... (no product literal)
if (-not $OutputIso) {
    $outDir = if ($Archive -and (Test-Path $Archive)) { $Archive } else { $BasePath }
    $OutputIso = Join-Path $outDir ("{0}_{1}_Deploy_{2}.iso" -f $Prefix, $edTag, $stamp)
}
$MEDIA = Join-Path $WorkDir 'media'
$TMP   = Join-Path $WorkDir 'tmp'
$LOGD  = Join-Path $BasePath 'logs'
foreach ($d in @($WorkDir,$MEDIA,$TMP,$LOGD)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# Clean any stale work from a prior run so Export/copy start fresh.
Get-ChildItem $MEDIA -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $TMP 'install2.wim') -Force -ErrorAction SilentlyContinue

$OSCDIMG = Get-Oscdimg
$Script:MountedISO = $null
$Script:MountedImg = $null
Start-Transcript -Path (Join-Path $LOGD "Deploy_$stamp.log") -Append | Out-Null

trap {
    Write-Warning "$(Get-TS): FATAL: $($_.Exception.Message)"
    if ($Script:MountedImg) { Dismount-WindowsImage -Path $Script:MountedImg -Discard -ErrorAction SilentlyContinue | Out-Null }
    if ($Script:MountedISO) { Dismount-DiskImage -ImagePath $Script:MountedISO -ErrorAction SilentlyContinue | Out-Null }
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

Write-Output "$(Get-TS): ===== Build deploy ISO (v$ScriptVersion) ====="
Write-Output "$(Get-TS): Product     : $Product"
Write-Output "$(Get-TS): Source ISO  : $SourceIso"
Write-Output "$(Get-TS): Keep edition: $EditionName"
Write-Output "$(Get-TS): Harden      : $(if ($NoHarden) { 'NO (image injection skipped)' } else { "$HardenDir -> image \Windows\Setup\Scripts" })"
Write-Output "$(Get-TS): Firefox     : $(if ($NoFirefox) { 'NO' } elseif ($FirefoxSetup) { "supplied: $FirefoxSetup" } else { 'download latest offline installer + bake in' })"
Write-Output "$(Get-TS): Unattend    : $(if ($IncludeUnattend) { "BAKED AT ROOT (wipes disk 0!) - $UnattendPath" } else { 'not baked (attach separately)' })"
Write-Output "$(Get-TS): Output ISO  : $OutputIso"

# ---- 0. Currency guard: is the chosen source built with the CURRENT LCU? ------
# The remaster faithfully reuses the newest patched ISO on disk. If a fresh build for THIS product
# had not finished when it ran (e.g. launched mid-nightly, before the Win11 job), that "newest"
# source can predate the latest Patch-Tuesday LCU - and Windows Update then pulls the missing
# cumulative on first boot. This check is metadata-only (it never downloads): it reads the source
# ISO's manifest for the LCU it was built with, asks the Catalog what the current LCU is, and WARNS
# (never blocks) if they differ. Pass -SkipCurrencyCheck to silence it.
if (-not $SkipCurrencyCheck) {
    $mf = $null
    $mfPath = "$SourceIso.json"
    if (Test-Path $mfPath) {
        try { $mf = Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json } catch { $mf = $null }
    }
    $srcKb = if ($mf -and $mf.LcuKB) { [string]$mf.LcuKB } else { $null }
    if ($srcKb -and $srcKb -notmatch '^(?i)kb') { $srcKb = "KB$srcKb" }   # normalize to KB#######
    $srcBuilt = if ($mf -and $mf.BuiltAt) { [string]$mf.BuiltAt } else { 'unknown' }
    Write-Output ("$(Get-TS): Source built : LCU {0}, at {1}" -f ($(if ($srcKb) { $srcKb } else { 'unknown' })), $srcBuilt)

    $curKb = $null
    try { $curKb = Get-CurrentCatalogLcuKb -Query ([string]$P.LcuQuery) -IncludeRegex ([string]$P.LcuInclude) -PreferRegex ([string]$P.PreferRegex) }
    catch { $curKb = $null }

    if ($curKb) {
        if ($srcKb -and ($srcKb -ieq $curKb)) {
            Write-Output "$(Get-TS): Currency OK  : source carries the current catalog LCU ($curKb)."
        } elseif ($srcKb) {
            Write-Warning "$(Get-TS): CURRENCY WARNING - source was built with $srcKb, but the current catalog LCU is $curKb."
            Write-Warning "$(Get-TS): This deploy image will be a patch cycle behind; Windows Update will pull $curKb on first boot."
            Write-Warning "$(Get-TS): To ship current media: build $Product first (.\scripts\Invoke-MediaJobs.ps1 -Jobs $Product), then re-run this."
        } else {
            Write-Warning "$(Get-TS): CURRENCY WARNING - current catalog LCU is $curKb, but the source manifest has no LCU KB to compare. Cannot confirm the source is current."
        }
    } else {
        # Catalog unreachable -> Patch-Tuesday calendar fallback.
        $lastPT   = Get-LastPatchTuesday
        $builtDt  = [datetime]::MinValue
        $haveDate = ($mf -and $mf.BuiltAt) -and [datetime]::TryParse([string]$mf.BuiltAt, [ref]$builtDt)
        if ($haveDate -and $builtDt.Date -lt $lastPT) {
            Write-Warning ("$(Get-TS): CURRENCY WARNING - Catalog unreachable; source was built {0}, BEFORE the last Patch Tuesday ({1})." -f $builtDt.ToString('yyyy-MM-dd'), $lastPT.ToString('yyyy-MM-dd'))
            Write-Warning "$(Get-TS): A newer LCU has very likely shipped since. Rebuild $Product and re-run to be safe."
        } else {
            Write-Warning ("$(Get-TS): Currency UNVERIFIED - Catalog unreachable and could not confirm source currency (built {0}, last Patch Tuesday {1}). Proceeding." -f ($(if ($haveDate) { $builtDt.ToString('yyyy-MM-dd') } else { 'unknown' })), $lastPT.ToString('yyyy-MM-dd'))
        }
    }
}

# ---- 1. Copy the patched media tree to a writable dir -------------------------
Write-Output "$(Get-TS): Mounting source ISO..."
$drive = Mount-IsoGetDrive -Path $SourceIso
$Script:MountedISO = $SourceIso
Write-Output "$(Get-TS): Copying media $drive`:\ -> $MEDIA"
Copy-Item "$drive`:\*" $MEDIA -Recurse -Force
Dismount-DiskImage -ImagePath $SourceIso | Out-Null
$Script:MountedISO = $null
# Files copied off an ISO are read-only; clear it so we can replace install.wim.
Get-ChildItem $MEDIA -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.IsReadOnly } |
    ForEach-Object { $_.IsReadOnly = $false }

# ---- 2. Trim install.wim to the single named edition --------------------------
$installWim = Join-Path $MEDIA 'sources\install.wim'
if (-not (Test-Path $installWim)) { throw "No install.wim in the source media ($installWim)." }

$images = @(Get-WindowsImage -ImagePath $installWim)
$match  = $images | Where-Object { $_.ImageName -eq $EditionName }
if (-not $match) {
    throw ("Edition '$EditionName' not found in source media. Present: " + (($images | ForEach-Object ImageName) -join '; '))
}
Write-Output "$(Get-TS): Exporting single edition '$EditionName' (source index $($match.ImageIndex)) -> new index 1"
$install2 = Join-Path $TMP 'install2.wim'
Export-WindowsImage -SourceImagePath $installWim -SourceName $EditionName `
    -DestinationImagePath $install2 -CompressionType Max | Out-Null
Move-Item $install2 $installWim -Force
$ver = (Get-WindowsImage -ImagePath $installWim -Index 1).Version
Write-Output "$(Get-TS): Deploy install.wim now holds 1 edition: $EditionName ($ver)"

# ---- 3a. Resolve the Firefox offline installer (before mounting) --------------
# Downloaded on the BUILD HOST (which has internet), then baked into the image so the hardening
# installs it at first boot with NO network - solves the Acer's unconfigured-wifi first boot.
$ffLocal = $null
if (-not $NoFirefox) {
    if ($FirefoxSetup) {
        if (-not (Test-Path $FirefoxSetup)) { throw "FirefoxSetup not found: $FirefoxSetup" }
        $ffLocal = $FirefoxSetup
        Write-Output "$(Get-TS): Firefox: using supplied installer $ffLocal"
    } else {
        $ffLocal = Join-Path $TMP 'FirefoxSetup.exe'
        Write-Output "$(Get-TS): Firefox: downloading latest x64 offline installer..."
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) {
            try {
                Start-BitsTransfer -Source $FirefoxUrl -Destination $ffLocal -ErrorAction Stop
                $ok = (Test-Path $ffLocal) -and ((Get-Item $ffLocal).Length -gt 30MB)  # full installer is ~60 MB, not a stub
            } catch { Write-Warning "$(Get-TS): Firefox download attempt $i failed: $($_.Exception.Message)"; Start-Sleep 5 }
        }
        if (-not $ok) {
            Write-Warning "$(Get-TS): Could not fetch Firefox - baking WITHOUT it (the Mozilla policy still applies once Firefox is installed). Pass -FirefoxSetup <path> for an offline build."
            $ffLocal = $null
        } else {
            Write-Output "$(Get-TS): Firefox installer ready ($([math]::Round((Get-Item $ffLocal).Length/1MB,1)) MB)"
        }
    }
}

# ---- 3b. Inject hardening (+ Firefox installer) INTO the image ----------------
# Image injection, not a sources\$OEM$ folder: it doesn't depend on <UseConfigurationSet> (flaky
# on 24H2) and guarantees the files are on the OS drive. One mount cycle covers both payloads.
if ((-not $NoHarden) -or $ffLocal) {
    $needed = @('SetupComplete.cmd','Invoke-PrivacyHardening.ps1')
    if (-not $NoHarden) {
        foreach ($f in $needed) {
            if (-not (Test-Path (Join-Path $HardenDir $f))) { throw "Hardening file missing: $(Join-Path $HardenDir $f) (or pass -NoHarden)." }
        }
    }
    $mnt = Join-Path $TMP 'wimMount'
    New-Item -ItemType Directory -Path $mnt -Force | Out-Null
    Write-Output "$(Get-TS): Mounting install.wim to inject payload..."
    Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mnt | Out-Null
    $Script:MountedImg = $mnt
    try {
        if (-not $NoHarden) {
            $dest = Join-Path $mnt 'Windows\Setup\Scripts'
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            foreach ($f in $needed) { Copy-Item (Join-Path $HardenDir $f) (Join-Path $dest $f) -Force }
            Write-Output "$(Get-TS): Injected hardening -> \Windows\Setup\Scripts\ ($($needed -join ', '))"
        }
        if ($ffLocal) {
            $ffDest = Join-Path $mnt 'Windows\Setup\Files'
            New-Item -ItemType Directory -Path $ffDest -Force | Out-Null
            Copy-Item $ffLocal (Join-Path $ffDest 'FirefoxSetup.exe') -Force
            Write-Output "$(Get-TS): Injected Firefox -> \Windows\Setup\Files\FirefoxSetup.exe (installed at first logon by a self-removing task)"
        }
    } finally {
        Dismount-WindowsImage -Path $mnt -Save | Out-Null
        $Script:MountedImg = $null
    }
    if (-not $NoHarden) {
        Write-Output "$(Get-TS): NOTE: the hardening runs from the answer file's SPECIALIZE RunSynchronousCommand"
        Write-Output "$(Get-TS):       (SYSTEM, pre-OOBE, no logon) - works on the Acer's OEM-firmware-key too. Attach"
        Write-Output "$(Get-TS):       autounattend-Win11.xml (or use -IncludeUnattend). Booting WITHOUT the answer file"
        Write-Output "$(Get-TS):       falls back to SetupComplete.cmd, which Setup SKIPS on OEM-key machines - then run"
        Write-Output "$(Get-TS):       once by hand: powershell -File C:\Windows\Setup\Scripts\Invoke-PrivacyHardening.ps1 -AlsoCurrentUser"
    }
} else {
    Write-Output "$(Get-TS): -NoHarden + no Firefox: nothing to inject."
}

# ---- 4. Optional: bake the answer file at the ISO root ------------------------
if ($IncludeUnattend) {
    if (-not (Test-Path $UnattendPath)) { throw "Unattend file not found: $UnattendPath" }
    Copy-Item $UnattendPath (Join-Path $MEDIA 'autounattend.xml') -Force
    Write-Output "$(Get-TS): Baked autounattend.xml at ISO root. THIS ISO WILL WIPE DISK 0 ON BOOT."
}

# ---- 5. Rebuild the bootable ISO ----------------------------------------------
$etfs = Join-Path $MEDIA 'boot\etfsboot.com'
$efi  = Join-Path $MEDIA 'efi\microsoft\boot\efisys.bin'
foreach ($b in @($etfs,$efi)) { if (-not (Test-Path $b)) { throw "Missing boot file: $b" } }
$isoLabel = if ($Label) { ($Label + '_' + $edTag).Substring(0, [Math]::Min(32, ($Label + '_' + $edTag).Length)) } else { "WIN_$edTag" }

$bootData = "2#p0,e,b`"$etfs`"#pEF,e,b`"$efi`""
$isoCmd   = Join-Path $TMP 'build_deploy_iso.cmd'
$cmdLine  = "`"$OSCDIMG`" -bootdata:$bootData -u2 -udfver102 -l`"$isoLabel`" -o -m -h `"$MEDIA`" `"$OutputIso`""
@("@echo off", $cmdLine, "exit /b %ERRORLEVEL%") | Set-Content -Path $isoCmd -Encoding Ascii
Write-Output "$(Get-TS): Building ISO -> $OutputIso"
& $env:SystemRoot\System32\cmd.exe /c "`"$isoCmd`""
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)." }
Write-Output "$(Get-TS): ISO created: $OutputIso  ($([math]::Round((Get-Item $OutputIso).Length/1GB,2)) GB)"

# ---- 6. Verify ----------------------------------------------------------------
Write-Output "$(Get-TS): ===== Verify ====="
$vDrive = Mount-IsoGetDrive -Path $OutputIso
$Script:MountedISO = $OutputIso
$vWim = "$vDrive`:\sources\install.wim"
$vImgs = @(Get-WindowsImage -ImagePath $vWim)
$vImgs | Select-Object ImageIndex, ImageName, @{n='Version';e={ (Get-WindowsImage -ImagePath $vWim -Index $_.ImageIndex).Version }} |
    Format-Table -AutoSize | Out-String | Write-Output
Dismount-DiskImage -ImagePath $OutputIso | Out-Null
$Script:MountedISO = $null

if ($vImgs.Count -ne 1)                { throw "VERIFY FAILED: output holds $($vImgs.Count) editions, expected 1." }
if ($vImgs[0].ImageName -ne $EditionName) { throw "VERIFY FAILED: output edition is '$($vImgs[0].ImageName)', expected '$EditionName'." }
Write-Output "$(Get-TS): VERIFY OK: single edition '$EditionName'."

# ---- 7. Cleanup ---------------------------------------------------------------
if (-not $KeepWork) {
    Write-Output "$(Get-TS): Removing work dir (use -KeepWork to retain)"
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "$(Get-TS): ===== DONE. Deploy ISO: $OutputIso ====="
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0
