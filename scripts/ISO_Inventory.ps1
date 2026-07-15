<#
.SYNOPSIS
    Read-only inventory of every media source defined in config\Products.psd1: the editions
    inside each source install.wim, which ones the profile patches by default, whether that
    build would be trimmed, and what is currently sitting in each ArchiveRoot.

.DESCRIPTION
    Traverses the SAME product config the slipstream uses, so what you see here is exactly what
    a build would act on. Mounts each source ISO READ-ONLY, enumerates install.wim, marks each
    edition PATCH / (skip) against the profile's DefaultEditions using the SAME exact-name rule
    the resolver uses, and prints the source->output index map a trimmed build would produce.

    Nothing is downloaded, mounted read/write, serviced, or modified. Safe to run any time,
    including while a build is in progress (it mounts the RTM source, not the working images).

.PARAMETER Product
    Limit the report to one product. Default: every product in the config.

.PARAMETER ConfigPath
    Product config data file. Default: ..\config\Products.psd1.

.PARAMETER SkipArchive
    Don't scan ArchiveRoot folders (faster; skips the "archived builds" section).

.EXAMPLE
    .\scripts\ISO_Inventory.ps1
.EXAMPLE
    .\scripts\ISO_Inventory.ps1 -Product Win11-25H2

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Read-only. Does not require the ADK. Elevation is only needed to mount an ISO (Mount-DiskImage).
#>

[CmdletBinding()]
param(
    [string]$Product,
    [string]$ConfigPath,
    [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
function TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }

# ---- Load the config (same rules the slipstream applies) ----------------------
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\Products.psd1' }
if (-not (Test-Path $ConfigPath)) { throw "Product config not found: $ConfigPath" }
try { $CONFIG = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop }
catch { throw "Product config is not valid PowerShell data: $ConfigPath`n$($_.Exception.Message)" }
if ($CONFIG -and $CONFIG.ContainsKey('Products')) { $PRODUCTS = $CONFIG.Products } else { $PRODUCTS = $CONFIG }   # nested or legacy flat
if (-not $PRODUCTS -or $PRODUCTS.Keys.Count -eq 0) { throw "Product config defines no products: $ConfigPath" }

$targets = if ($Product) {
    if (-not $PRODUCTS.ContainsKey($Product)) {
        throw "Unknown -Product '$Product'. Defined: $(($PRODUCTS.Keys | Sort-Object) -join ', ')"
    }
    @($Product)
} else {
    @($PRODUCTS.Keys | Sort-Object)
}

Write-Host ""
Write-Host "ISO inventory  (config: $ConfigPath)  v$ScriptVersion" -ForegroundColor Cyan
Write-Host ("=" * 78)

# Mount an ISO read-only and return its drive letter (e.g. 'F'), or $null on failure.
function Mount-IsoReadOnly {
    param([string]$Path)
    $img = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru
    Start-Sleep -Milliseconds 500
    $vol = ($img | Get-Volume)
    if (-not $vol.DriveLetter) { $vol = (Get-DiskImage -ImagePath $Path | Get-Volume) }
    return [string]$vol.DriveLetter
}

foreach ($name in $targets) {
    $prof = $PRODUCTS[$name]
    Write-Host ""
    Write-Host ("### {0}" -f $name) -ForegroundColor White
    Write-Host ("    Source ISO : {0}" -f $prof.SourceISO)
    $defaults    = @($prof.DefaultEditions)                       # $null -> empty array
    $allEditions = ($null -eq $prof.DefaultEditions)
    $trim        = [bool]$prof.TrimByDefault
    Write-Host ("    Defaults   : {0}" -f $(if ($allEditions) { 'ALL editions' } else { $defaults -join ', ' }))
    Write-Host ("    TrimByDefault : {0}" -f $trim)
    Write-Host ("    Archive    : {0}  (keep {1})" -f $(if ([string]::IsNullOrWhiteSpace([string]$prof.ArchiveRoot)) { '(none)' } else { $prof.ArchiveRoot }), $prof.KeepLast)

    if (-not (Test-Path $prof.SourceISO)) {
        Write-Host "    SOURCE ISO NOT FOUND ON THIS HOST - cannot enumerate editions." -ForegroundColor Yellow
        continue
    }

    $drive = $null
    try {
        $drive = Mount-IsoReadOnly -Path $prof.SourceISO
        if (-not $drive) { Write-Host "    Could not resolve a drive letter for the mounted ISO." -ForegroundColor Yellow; continue }
        $wim = "$drive`:\sources\install.wim"
        if (-not (Test-Path $wim)) { Write-Host "    No \sources\install.wim on the mounted ISO." -ForegroundColor Yellow; continue }

        # Per-index Get-WindowsImage: the no -Index form omits .Version.
        $imgs = @(
            foreach ($im in (Get-WindowsImage -ImagePath $wim)) {
                Get-WindowsImage -ImagePath $wim -Index $im.ImageIndex
            }
        ) | Sort-Object ImageIndex

        # Which editions the DEFAULT build would patch (same exact-name rule as the resolver).
        $selected = if ($allEditions) { $imgs } else { @($imgs | Where-Object { $defaults -contains $_.ImageName }) }
        $selIdx   = @($selected | ForEach-Object { $_.ImageIndex })

        Write-Host ("    install.wim: {0} edition(s), build {1}" -f $imgs.Count, ($imgs[0].Version))
        Write-Host ""
        Write-Host ("    {0,-4} {1,-6} {2}" -f 'Idx', 'Def', 'Edition')
        Write-Host ("    {0,-4} {1,-6} {2}" -f '---', '---', '-------')
        foreach ($im in $imgs) {
            $mark = if ($selIdx -contains $im.ImageIndex) { 'PATCH' } else { '' }
            $colour = if ($mark) { 'Green' } else { 'Gray' }
            Write-Host ("    {0,-4} {1,-6} {2}" -f $im.ImageIndex, $mark, $im.ImageName) -ForegroundColor $colour
        }

        # What the DEFAULT build would emit.
        Write-Host ""
        if ($selected.Count -eq 0) {
            Write-Host "    Default build would patch NOTHING (DefaultEditions matched no edition in this media)." -ForegroundColor Yellow
        } elseif ($trim) {
            Write-Host "    Default build (TrimByDefault) output install.wim - source -> output:" -ForegroundColor Cyan
            $newIx = 0
            foreach ($im in $selected) { $newIx++; Write-Host ("      [{0,2}] -> [{1,2}]  {2}" -f $im.ImageIndex, $newIx, $im.ImageName) }
        } else {
            Write-Host ("    Default build (no trim) ships all {0} edition(s); {1} patched, the rest stay RTM (mixed build)." -f $imgs.Count, $selected.Count) -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ("    ERROR enumerating: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        if (Test-Path $prof.SourceISO) {
            Dismount-DiskImage -ImagePath $prof.SourceISO -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # ---- Archive contents ----------------------------------------------------
    if (-not $SkipArchive -and -not [string]::IsNullOrWhiteSpace([string]$prof.ArchiveRoot) -and (Test-Path $prof.ArchiveRoot)) {
        $built = @(Get-ChildItem $prof.ArchiveRoot -Filter "$($prof.IsoPrefix)_*.iso" -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
        Write-Host ""
        Write-Host ("    Archived builds in {0}: {1} (keep {2})" -f $prof.ArchiveRoot, $built.Count, $prof.KeepLast)
        foreach ($b in ($built | Select-Object -First 10)) {
            $mfp = "$($b.FullName).json"
            $ab  = if (Test-Path $mfp) { (Get-Content $mfp -Raw | ConvertFrom-Json).ActualBuild } else { '?' }
            Write-Host ("      {0}  {1,7:N1} GB  build {2}" -f $b.LastWriteTime.ToString('yyyy-MM-dd'), ($b.Length/1GB), $ab) -ForegroundColor Gray
        }
        if ($built.Count -gt $prof.KeepLast) {
            Write-Host ("      (retention keeps the newest {0}; {1} older would be pruned on the next build)" -f $prof.KeepLast, ($built.Count - $prof.KeepLast)) -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host ("=" * 78)
Write-Host "Inventory complete (read-only; nothing changed)." -ForegroundColor Green
Write-Host ""
