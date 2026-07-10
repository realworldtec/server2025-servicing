<#
.SYNOPSIS
    Repairs the Windows Server 2025 online component store using offline sources
    (Features-on-Demand ISO + patched install.wim), then verifies health.
    Optionally re-enables WinRE and runs a ResetBase cleanup.

.DESCRIPTION
    Built for a 2008 R2 -> ... -> 2025 in-place-upgrade host whose store is
    "repairable" and whose corruption is dominated by staged FoD / language /
    optional packages (payloads absent). Online RestoreHealth against Windows
    Update fails 0x800f0915, so this repairs from local media with /LimitAccess.

    Steps:
      1. Elevation + pending-reboot guard (aborts if servicing is mid-flight).
      2. Resolve sources: FoD folder (LanguagesAndOptionalFeatures) + install.wim,
         auto-detecting drive letters and the install.wim index for THIS edition.
      3. CheckHealth (before) -> RestoreHealth (dual source, /LimitAccess,
         /ScratchDir) -> sfc /scannow -> CheckHealth (after).
      4. Optional: -ResetBase (prune superseded), -EnableWinRE (re-register WinRE).
      5. Copies CBS.log / dism.log next to the transcript for the record.

.PARAMETER FodSource
    Folder holding the FoD .cab payloads. Default auto-detects
    <drive>:\LanguagesAndOptionalFeatures across mounted volumes (your G:).

.PARAMETER InstallWim
    Path to the patched install.wim. Default auto-detects <drive>:\sources\install.wim
    (your F:). Must be the SAME build as the running OS (26100.32995).

.PARAMETER Index
    install.wim index to use as the in-box source. Default: auto-detected from the
    running edition (Datacenter/Standard + Desktop Experience vs Core). Your box = 4.

.PARAMETER ScratchDir
    DISM scratch directory. Default E:\DISMscratch.

.PARAMETER ResetBase
    After the store is healthy, run StartComponentCleanup /ResetBase to prune the
    superseded (legacy upgrade) chain and shrink WinSxS.

.PARAMETER EnableWinRE
    Attempt to re-enable WinRE (reagentc /enable). If Winre.wim is missing from
    C:\Windows\System32\Recovery it is extracted from the patched install.wim first.

.PARAMETER SkipSfc
    Skip the sfc /scannow pass.

.PARAMETER Force
    Proceed even if a pending reboot / pending package is detected (not recommended).

.EXAMPLE
    .\Repair-Server2025Store.ps1
.EXAMPLE
    .\Repair-Server2025Store.ps1 -EnableWinRE -ResetBase
.EXAMPLE
    .\Repair-Server2025Store.ps1 -FodSource G:\LanguagesAndOptionalFeatures -InstallWim F:\sources\install.wim -Index 4

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$FodSource,
    [string]$InstallWim,
    [int]$Index = 0,
    [string]$ScratchDir = 'E:\DISMscratch',
    [string]$LogDir     = 'E:\Server2025Repair\logs',
    [switch]$ResetBase,
    [switch]$EnableWinRE,
    [switch]$SkipSfc,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }
function Info  ($m) { Write-Host  "$(Get-TS): $m" }
function Warn  ($m) { Write-Warning "$(Get-TS): $m" }

# --- logging -------------------------------------------------------------------
foreach ($d in @($ScratchDir,$LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $LogDir "Repair_$stamp.log"
Start-Transcript -Path $logFile -Append | Out-Null
Info "===== Windows Server 2025 component-store repair (v$ScriptVersion) ====="

# DISM often exits 3010 (success, reboot required); treat 0 and 3010 as success.
function Invoke-Dism {
    param([string[]]$Arguments,[string]$What)
    Info "DISM $What -> dism.exe $($Arguments -join ' ')"
    # Pipe to Out-Host so DISM's stdout is shown + transcribed but NOT captured into
    # this function's return value (which must be just the $true/$false below).
    & dism.exe @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -eq 0)        { Info "$What completed (0)." ; return $true }
    if ($code -eq 3010)     { Info "$What completed, reboot required (3010)." ; return $true }
    Warn "$What FAILED (exit $code)."
    return $false
}

# --- pending-reboot / pending-package guard ------------------------------------
function Test-Blocked {
    # Only CBS/WU *reboot* signals block servicing. PendingFileRenameOperations is NOT a
    # servicing blocker (it's set on many healthy systems) and is deliberately excluded.
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate RebootRequired' }
    try {
        $pending = Get-WindowsPackage -Online | Where-Object { $_.PackageState -match 'Pending' }
        if ($pending) { $reasons += "$($pending.Count) package(s) in a *Pending state" }
    } catch { Warn "Could not enumerate packages: $($_.Exception.Message)" }
    # Emit the strings normally (NO comma idiom). The caller wraps with @() so the
    # count is correct for 0, 1, or many reasons. (A comma here + @() there nests
    # the array and makes the count always 1 - a false-positive block.)
    return $reasons
}

# --- resolve the FoD source folder ---------------------------------------------
function Resolve-FodSource {
    param([string]$Preferred)
    if ($Preferred -and (Test-Path $Preferred) -and (Get-ChildItem $Preferred -Filter *.cab -EA SilentlyContinue)) { return $Preferred }
    foreach ($v in (Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)) {
        $p = "$($v.DriveLetter):\LanguagesAndOptionalFeatures"
        if ((Test-Path $p) -and (Get-ChildItem $p -Filter *.cab -EA SilentlyContinue)) { return $p }
        $r = "$($v.DriveLetter):\"
        if (Test-Path (Join-Path $r 'FoD')) { $r2 = Join-Path $r 'FoD'; if (Get-ChildItem $r2 -Filter *.cab -EA SilentlyContinue) { return $r2 } }
    }
    return $null
}

# --- resolve install.wim + index for the RUNNING edition -----------------------
function Resolve-InstallWim {
    param([string]$Preferred)
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    foreach ($v in (Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)) {
        $p = "$($v.DriveLetter):\sources\install.wim"
        if (Test-Path $p) { return $p }
    }
    return $null
}
function Resolve-Index {
    param([string]$Wim)
    $cv       = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $edID     = $cv.EditionID          # e.g. ServerDatacenter / ServerStandard
    $instType = $cv.InstallationType   # 'Server' (Desktop Experience) or 'Server Core'
    $edToken  = if ($edID -match 'Datacenter') { 'Datacenter' } elseif ($edID -match 'Standard') { 'Standard' } else { $edID }
    $desktop  = ($instType -eq 'Server')
    Info "Running edition: $edID / $instType  ->  looking for '$edToken'$(if($desktop){' (Desktop Experience)'}else{' (Core)'})"
    $imgs = Get-WindowsImage -ImagePath $Wim
    $match = $imgs | Where-Object {
        $_.ImageName -match $edToken -and
        ( ($desktop -and $_.ImageName -match 'Desktop Experience') -or (-not $desktop -and $_.ImageName -notmatch 'Desktop Experience') )
    }
    if (@($match).Count -eq 1) { Info "Auto-selected index $($match.ImageIndex): $($match.ImageName)"; return [int]$match.ImageIndex }
    Warn "Could not uniquely auto-detect the index. Available:"
    $imgs | Format-Table ImageIndex, ImageName | Out-String | Write-Host
    throw "Specify -Index explicitly (your running OS is Datacenter Desktop = index 4)."
}

# --- optional WinRE re-enable ---------------------------------------------------
function Enable-WinREImage {
    param([string]$Wim,[int]$Idx)
    Info '----- WinRE re-enable -----'
    $info = (& reagentc /info) 2>&1
    $info | Write-Host
    if ($info -match 'Windows RE status:\s*Enabled') { Info 'WinRE already Enabled - nothing to do.'; return }

    $reDir  = 'C:\Windows\System32\Recovery'
    $reWim  = Join-Path $reDir 'Winre.wim'
    if (-not (Test-Path $reDir)) { New-Item -ItemType Directory -Path $reDir -Force | Out-Null }

    if (-not (Test-Path $reWim)) {
        Info "Winre.wim missing locally; extracting from patched image (index $Idx)."
        $mnt = Join-Path $ScratchDir 'winremount'
        if (-not (Test-Path $mnt)) { New-Item -ItemType Directory -Path $mnt -Force | Out-Null }
        try {
            Mount-WindowsImage -ImagePath $Wim -Index $Idx -Path $mnt -ReadOnly | Out-Null
            $src = Join-Path $mnt 'Windows\System32\Recovery\Winre.wim'
            if (Test-Path $src) { Copy-Item $src $reWim -Force; Info "Staged Winre.wim -> $reWim" }
            else { Warn "Winre.wim not found inside the image at $src." }
        } finally {
            Dismount-WindowsImage -Path $mnt -Discard -EA SilentlyContinue | Out-Null
        }
    }
    if (-not (Test-Path $reWim)) { Warn 'No Winre.wim available; cannot enable WinRE. Skipping.'; return }

    Info 'Enabling WinRE (Winre.wim staged in the default C:\Windows\System32\Recovery)...'
    & reagentc /enable 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Warn "reagentc /enable returned $LASTEXITCODE. On this MBR disk the moved recovery partition may need a valid WinRE partition (type 0x27). Verify with 'reagentc /info' and the partition layout."
    }
    (& reagentc /info) 2>&1 | Write-Host
}

# ==============================================================================
#  MAIN
# ==============================================================================
try {
    # 1. Guard
    $blocked = @(Test-Blocked)
    if ($blocked.Count -gt 0) {
        Warn "Servicing appears mid-flight: $($blocked -join '; ')."
        if (-not $Force) { throw "Reboot and let servicing finish, then re-run. Use -Force to override (not recommended)." }
        Warn 'Proceeding due to -Force.'
    } else { Info 'No pending reboot / pending packages detected. Clear to proceed.' }

    # 2. Sources
    $fod = Resolve-FodSource -Preferred $FodSource
    $wim = Resolve-InstallWim -Preferred $InstallWim
    if (-not $fod -and -not $wim) { throw 'Neither a FoD source nor install.wim could be found. Mount the FoD ISO and the patched Server 2025 ISO.' }
    if ($wim) {
        if ($Index -le 0) { $Index = Resolve-Index -Wim $wim }
        else { Info "Using caller-specified index $Index." }
    }
    Info "FoD source : $(if($fod){$fod}else{'(none)'})"
    Info "install.wim: $(if($wim){"$wim (index $Index)"}else{'(none)'})"
    Info "Scratch    : $ScratchDir"

    # Build the ordered /Source list (FoD first - it matches the staged RTM FoDs).
    $srcArgs = @()
    if ($fod) { $srcArgs += "/Source:$fod" }
    if ($wim) { $srcArgs += "/Source:WIM:$wim`:$Index" }

    # 3a. CheckHealth (before)
    Invoke-Dism -What 'CheckHealth (before)' -Arguments @('/Online','/Cleanup-Image','/CheckHealth') | Out-Null

    # 3b. RestoreHealth
    $rhArgs = @('/Online','/Cleanup-Image','/RestoreHealth') + $srcArgs + @('/LimitAccess',"/ScratchDir:$ScratchDir")
    $rhOk = Invoke-Dism -What 'RestoreHealth' -Arguments $rhArgs
    if (-not $rhOk) {
        Warn 'RestoreHealth did not succeed. The fresh detail is now in C:\Windows\Logs\CBS\CBS.log (copied below) - the "Cannot repair member file" lines name the exact components/source still needed.'
    }

    # 3c. sfc
    if (-not $SkipSfc) {
        Info 'Running sfc /scannow ...'
        & sfc.exe /scannow
        Info "sfc exit code: $LASTEXITCODE"
    }

    # 3d. CheckHealth (after)
    Invoke-Dism -What 'CheckHealth (after)' -Arguments @('/Online','/Cleanup-Image','/CheckHealth') | Out-Null

    # 4a. ResetBase (only if requested)
    if ($ResetBase) {
        if ($rhOk) {
            Invoke-Dism -What 'StartComponentCleanup /ResetBase' -Arguments @('/Online','/Cleanup-Image','/StartComponentCleanup','/ResetBase',"/ScratchDir:$ScratchDir") | Out-Null
        } else {
            Warn 'Skipping ResetBase because RestoreHealth did not report success (repair the store first).'
        }
    }

    # 4b. WinRE
    if ($EnableWinRE) {
        if ($wim) { Enable-WinREImage -Wim $wim -Idx $Index }
        else { Warn 'EnableWinRE requested but no install.wim available to source Winre.wim; skipping.' }
    }

    Info '===== Repair run complete ====='
}
catch {
    Warn "FATAL: $($_.Exception.Message)"
    Warn $_.ScriptStackTrace
}
finally {
    # 5. Preserve the logs that actually contain the detail
    foreach ($f in @('C:\Windows\Logs\CBS\CBS.log','C:\Windows\Logs\DISM\dism.log')) {
        if (Test-Path $f) {
            try { Copy-Item $f (Join-Path $LogDir ("{0}_{1}" -f $stamp,(Split-Path $f -Leaf))) -Force; Info "Saved $(Split-Path $f -Leaf) to $LogDir" } catch {}
        }
    }
    Info "Transcript: $logFile"
    Stop-Transcript | Out-Null
}
