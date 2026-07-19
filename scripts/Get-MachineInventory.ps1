<#
.SYNOPSIS
    Capture a full inventory of the machine as delivered: hardware, drivers (with optional export of
    the actual driver files), installed apps (Win32 + Store/Appx), runtimes/redistributables, and
    services/startup/optional-features. Writes per-category JSON plus a single self-contained HTML
    report.

.DESCRIPTION
    Intended to run ONCE on the OEM image before it is wiped, so the baseline (and especially the
    matched set of vendor drivers that may not exist on Windows Update) is preserved. It is read-only
    except for the files it writes to the output folder; the driver export (on by default,
    -SkipDriverExport to disable) copies the third-party driver store to disk with pnputil.

    Output folder (created under -OutputRoot):
        MachineInventory_<host>_<timestamp>\
            report.html            single-file report, open in any browser
            data\*.json            one file per category, for diffing against a later build
            drivers\               exported third-party drivers (unless -SkipDriverExport)
            inventory.log          transcript

    Run elevated for complete data (driver export and some driver fields need admin). Windows
    PowerShell 5.1 compatible.

.PARAMETER OutputRoot
    Where the timestamped output folder is created. Default: the current directory.

.PARAMETER SkipDriverExport
    Inventory drivers but do NOT copy the files (faster, smaller, no admin needed for that step).

.PARAMETER OpenReport
    Open report.html when finished.

.EXAMPLE
    .\scripts\Get-MachineInventory.ps1
    # full inventory + driver export into .\MachineInventory_<host>_<stamp>\

.EXAMPLE
    .\scripts\Get-MachineInventory.ps1 -SkipDriverExport -OpenReport

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = (Get-Location).Path,
    [switch]$SkipDriverExport,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (all defined before first use)
# =====================================================================================
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [datetime]::Now }
function Info ($m) { Write-Host   "$(Get-TS)  $m" }
function Warn ($m) { Write-Warning "$(Get-TS)  $m" }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run a collection block safely: a failure in one section warns and yields $null instead of aborting
# the whole inventory.
function Invoke-Section {
    param([string]$Name, [scriptblock]$Script)
    Info "[$Name] collecting..."
    try { & $Script }
    catch { Warn "[$Name] failed: $($_.Exception.Message)"; $null }
}

function Format-GB {
    param($Bytes)
    if ($Bytes -and $Bytes -gt 0) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '' }
}

function ConvertTo-Cell {
    # Render one property value for an HTML cell: join arrays, blank nulls, HTML-encode.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [array]) { $Value = ($Value | Where-Object { $_ -ne $null }) -join '; ' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-HtmlTable {
    # Build an HTML table from an array of objects. Columns default to the first object's properties.
    param($Data, [string[]]$Columns)
    $rows = @($Data) | Where-Object { $null -ne $_ }
    if ($rows.Count -eq 0) { return '<p class="none">(none found)</p>' }
    if (-not $Columns) { $Columns = $rows[0].psobject.Properties.Name }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append('<th>' + (ConvertTo-Cell $c) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) { [void]$sb.Append('<td>' + (ConvertTo-Cell $r.$c) + '</td>') }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $sb.ToString()
}

function Save-Json {
    param($Data, [string]$Path)
    try { ($Data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8 }
    catch { Warn "  could not write $Path : $($_.Exception.Message)" }
}

# =====================================================================================
#  Setup
# =====================================================================================
$isAdmin = Test-IsAdmin
$computer = $env:COMPUTERNAME
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir  = Join-Path $OutputRoot ("MachineInventory_{0}_{1}" -f $computer, $stamp)
$dataDir = Join-Path $outDir 'data'
$drvDir  = Join-Path $outDir 'drivers'
foreach ($d in @($outDir, $dataDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

Start-Transcript -Path (Join-Path $outDir 'inventory.log') -Append | Out-Null
Info "===== Machine inventory v$ScriptVersion ====="
Info "Host: $computer   Elevated: $isAdmin   Output: $outDir"
if (-not $isAdmin) { Warn 'Not elevated - driver export and some fields will be limited. Re-run as Administrator for a complete capture.' }

# Fatal handler: trap (not finally) so the transcript-in-finally gate rule stays satisfied.
trap {
    Warn "FATAL: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 1
}

# =====================================================================================
#  1. Hardware
# =====================================================================================
$hardware = [ordered]@{}

$hardware.System = Invoke-Section 'HW/System' {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $bb   = Get-CimInstance Win32_BaseBoard
    [pscustomobject]@{
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        SystemFamily = $cs.SystemFamily
        SerialNumber = $csp.IdentifyingNumber
        UUID         = $csp.UUID
        BaseBoard    = ("{0} {1}" -f $bb.Manufacturer, $bb.Product).Trim()
        BiosVersion  = $bios.SMBIOSBIOSVersion
        BiosVendor   = $bios.Manufacturer
        BiosDate     = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '' }
        TotalRAM     = Format-GB $cs.TotalPhysicalMemory
    }
}

$hardware.OperatingSystem = Invoke-Section 'HW/OS' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $disp = (Get-ItemProperty -Path $cv -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
    $ubr  = (Get-ItemProperty -Path $cv -Name UBR -ErrorAction SilentlyContinue).UBR
    [pscustomobject]@{
        Edition        = $os.Caption
        DisplayVersion = $disp
        Build          = if ($ubr) { "$($os.BuildNumber).$ubr" } else { $os.BuildNumber }
        Architecture   = $os.OSArchitecture
        InstallDate    = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
        RegisteredUser = $os.RegisteredUser
    }
}

$hardware.Processor = Invoke-Section 'HW/CPU' {
    Get-CimInstance Win32_Processor | ForEach-Object {
        [pscustomobject]@{
            Name          = $_.Name
            Cores         = $_.NumberOfCores
            LogicalProcs  = $_.NumberOfLogicalProcessors
            MaxClockMHz   = $_.MaxClockSpeed
            Manufacturer  = $_.Manufacturer
        }
    }
}

$hardware.Memory = Invoke-Section 'HW/Memory' {
    Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        [pscustomobject]@{
            Slot        = $_.BankLabel
            Capacity    = Format-GB $_.Capacity
            SpeedMHz    = $_.ConfiguredClockSpeed
            Manufacturer= $_.Manufacturer
            PartNumber  = ($_.PartNumber -as [string]).Trim()
        }
    }
}

$hardware.Disks = Invoke-Section 'HW/Disks' {
    Get-PhysicalDisk | ForEach-Object {
        [pscustomobject]@{
            FriendlyName = $_.FriendlyName
            MediaType    = $_.MediaType
            BusType      = $_.BusType
            Size         = Format-GB $_.Size
            Health       = $_.HealthStatus
        }
    }
}

$hardware.Graphics = Invoke-Section 'HW/GPU' {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
            Name          = $_.Name
            DriverVersion = $_.DriverVersion
            DriverDate    = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }
            Resolution    = if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } else { '' }
            VideoRAM      = Format-GB $_.AdapterRAM
        }
    }
}

$hardware.Network = Invoke-Section 'HW/Network' {
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { -not $_.Virtual } | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            Description = $_.InterfaceDescription
            MacAddress  = $_.MacAddress
            Status      = $_.Status
            LinkSpeed   = $_.LinkSpeed
            DriverVer   = $_.DriverVersion
        }
    }
}

$hardware.Battery = Invoke-Section 'HW/Battery' {
    Get-CimInstance Win32_Battery | ForEach-Object {
        [pscustomobject]@{
            Name          = $_.Name
            ChargePercent = $_.EstimatedChargeRemaining
            Status        = $_.BatteryStatus
            DesignVoltage = $_.DesignVoltage
        }
    }
}

$hardware.Security = Invoke-Section 'HW/Security' {
    $tpm = try { Get-Tpm -ErrorAction Stop } catch { $null }
    $sb  = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
    [pscustomobject]@{
        TpmPresent    = if ($tpm) { $tpm.TpmPresent } else { 'unknown' }
        TpmReady      = if ($tpm) { $tpm.TpmReady } else { 'unknown' }
        TpmVersion    = if ($tpm) { ($tpm.ManufacturerVersion) } else { '' }
        SecureBootOn  = if ($null -ne $sb) { $sb } else { 'unknown/not-UEFI' }
    }
}

# =====================================================================================
#  2. Drivers  (inventory + optional export)
# =====================================================================================
$drivers = [ordered]@{}

# Per-device signed drivers (comprehensive: every device + its driver metadata).
$drivers.SignedDrivers = Invoke-Section 'DRV/PerDevice' {
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceName } |
        Sort-Object DeviceClass, DeviceName |
        ForEach-Object {
            [pscustomobject]@{
                DeviceName   = $_.DeviceName
                DeviceClass  = $_.DeviceClass
                Provider     = $_.DriverProviderName
                Version      = $_.DriverVersion
                Date         = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }
                Inf          = $_.InfName
                HardwareID   = ($_.HardWareID -as [string])
                Signed       = $_.IsSigned
            }
        }
}

# Third-party driver store packages (the OEM oemNN.inf set - what the driver export copies).
$drivers.ThirdPartyStore = Invoke-Section 'DRV/Store' {
    $raw = & pnputil.exe /enum-drivers 2>&1
    $items = @()
    $cur = $null
    foreach ($line in $raw) {
        $t = ($line -as [string]).Trim()
        if ($t -match '^Published Name\s*:\s*(.+)$') {
            if ($cur) { $items += $cur }
            $cur = [ordered]@{ PublishedName = $Matches[1].Trim() }
        } elseif ($cur -and $t -match '^Original Name\s*:\s*(.+)$')  { $cur.OriginalName = $Matches[1].Trim() }
          elseif ($cur -and $t -match '^Provider Name\s*:\s*(.+)$')  { $cur.Provider     = $Matches[1].Trim() }
          elseif ($cur -and $t -match '^Class Name\s*:\s*(.+)$')     { $cur.Class        = $Matches[1].Trim() }
          elseif ($cur -and $t -match '^Driver Version\s*:\s*(.+)$') { $cur.DriverVersion = $Matches[1].Trim() }
    }
    if ($cur) { $items += $cur }
    $items | ForEach-Object { [pscustomobject]$_ }
}

# Export the actual driver files so they can be reinjected later.
$driverExport = [pscustomobject]@{ Attempted = $false; Path = ''; Result = 'skipped' }
if (-not $SkipDriverExport) {
    if ($isAdmin) {
        try {
            New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
            Info '[DRV/Export] pnputil /export-driver * (third-party driver store)...'
            & pnputil.exe /export-driver '*' $drvDir 2>&1 | Out-Null
            $count = @(Get-ChildItem -Path $drvDir -Directory -ErrorAction SilentlyContinue).Count
            $driverExport = [pscustomobject]@{ Attempted = $true; Path = $drvDir; Result = "exported $count driver package folder(s)" }
            Info "  $($driverExport.Result)"
        } catch {
            $driverExport = [pscustomobject]@{ Attempted = $true; Path = $drvDir; Result = "FAILED: $($_.Exception.Message)" }
            Warn "  driver export failed: $($_.Exception.Message)"
        }
    } else {
        $driverExport = [pscustomobject]@{ Attempted = $false; Path = ''; Result = 'skipped - not elevated' }
        Warn '[DRV/Export] skipped - re-run as Administrator to export driver files.'
    }
} else {
    Info '[DRV/Export] skipped (-SkipDriverExport).'
}
$drivers.Export = $driverExport

# =====================================================================================
#  3. Apps  (Win32, Store/Appx, runtimes)
# =====================================================================================
$apps = [ordered]@{}

$apps.Win32 = Invoke-Section 'APP/Win32' {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        ForEach-Object {
            [pscustomobject]@{
                Name            = $_.DisplayName
                Version         = $_.DisplayVersion
                Publisher       = $_.Publisher
                InstallDate     = $_.InstallDate
                InstallLocation = $_.InstallLocation
                SystemComponent = [bool]$_.SystemComponent
            }
        } | Sort-Object Name -Unique
}

$apps.Appx = Invoke-Section 'APP/Appx' {
    $prov = @{}
    foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) { $prov[$p.DisplayName] = $true }
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name         = $_.Name
            Version      = $_.Version
            Publisher    = ($_.Publisher -replace '^CN=', '' -replace ',.*$', '')
            Provisioned  = [bool]$prov[$_.Name]
            NonRemovable = [bool]$_.NonRemovable
            SignatureKind= $_.SignatureKind
        }
    }
}

$apps.Runtimes = Invoke-Section 'APP/Runtimes' {
    $list = New-Object System.Collections.Generic.List[object]
    # VC++ redistributables + other runtimes, pulled from the Win32 set by name.
    $rx = 'Visual C\+\+|\.NET|Runtime|Redistributable|ASP\.NET|Windows App Runtime|WebView2|Java|Python'
    foreach ($a in @($apps.Win32)) {
        if ($a.Name -match $rx) {
            $list.Add([pscustomobject]@{ Component = $a.Name; Version = $a.Version; Publisher = $a.Publisher; Source = 'Installed program' })
        }
    }
    # .NET Framework version from the NDP release key.
    try {
        $ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        if ($ndp.Release) { $list.Add([pscustomobject]@{ Component = '.NET Framework (v4)'; Version = $ndp.Version; Publisher = 'Microsoft'; Source = "NDP release $($ndp.Release)" }) }
    } catch { Write-Verbose 'no NDP v4 key' }
    # .NET (Core) runtimes, if the dotnet host is present.
    $dn = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dn) {
        $rt = & dotnet --list-runtimes 2>&1
        foreach ($line in $rt) {
            if ($line -match '^(\S+)\s+(\S+)\s') { $list.Add([pscustomobject]@{ Component = $Matches[1]; Version = $Matches[2]; Publisher = 'Microsoft'; Source = 'dotnet --list-runtimes' }) }
        }
    }
    $list
}

# =====================================================================================
#  4. Services, startup, optional features
# =====================================================================================
$sysconfig = [ordered]@{}

$sysconfig.Services = Invoke-Section 'SYS/Services' {
    Get-CimInstance Win32_Service | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name      = $_.Name
            Display   = $_.DisplayName
            State     = $_.State
            StartMode = $_.StartMode
            Account   = $_.StartName
            Path      = $_.PathName
        }
    }
}

$sysconfig.Startup = Invoke-Section 'SYS/Startup' {
    Get-CimInstance Win32_StartupCommand | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            Command  = $_.Command
            Location = $_.Location
            User     = $_.User
        }
    }
}

$sysconfig.OptionalFeatures = Invoke-Section 'SYS/Features' {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop |
        Where-Object { $_.State -eq 'Enabled' } |
        Sort-Object FeatureName |
        ForEach-Object { [pscustomobject]@{ FeatureName = $_.FeatureName; State = "$($_.State)" } }
}

$sysconfig.Capabilities = Invoke-Section 'SYS/Capabilities' {
    Get-WindowsCapability -Online -ErrorAction Stop |
        Where-Object { $_.State -eq 'Installed' } |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = "$($_.State)" } }
}

# =====================================================================================
#  Write per-category JSON
# =====================================================================================
Info 'Writing per-category JSON...'
Save-Json $hardware              (Join-Path $dataDir 'hardware.json')
Save-Json $drivers.SignedDrivers (Join-Path $dataDir 'drivers_signed.json')
Save-Json $drivers.ThirdPartyStore (Join-Path $dataDir 'drivers_thirdparty.json')
Save-Json $apps.Win32            (Join-Path $dataDir 'apps_win32.json')
Save-Json $apps.Appx             (Join-Path $dataDir 'apps_appx.json')
Save-Json $apps.Runtimes         (Join-Path $dataDir 'runtimes.json')
Save-Json $sysconfig.Services    (Join-Path $dataDir 'services.json')
Save-Json $sysconfig.Startup     (Join-Path $dataDir 'startup.json')
Save-Json $sysconfig.OptionalFeatures (Join-Path $dataDir 'features.json')
Save-Json $sysconfig.Capabilities     (Join-Path $dataDir 'capabilities.json')

# =====================================================================================
#  Build the HTML report
# =====================================================================================
Info 'Building HTML report...'
$sys = $hardware.System
$os  = $hardware.OperatingSystem
$css = @'
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:1.5rem;color:#1c1c1c;background:#fafafa}
 h1{margin:0 0 .2rem 0} h2{margin-top:0}
 .sub{color:#666;margin-bottom:1rem}
 .card{background:#fff;border:1px solid #ddd;border-radius:6px;padding:.8rem 1rem;margin:.6rem 0}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:.4rem 1.2rem}
 .grid div span{color:#666;display:block;font-size:.8rem}
 details{background:#fff;border:1px solid #ddd;border-radius:6px;margin:.6rem 0}
 summary{cursor:pointer;padding:.6rem 1rem;font-weight:600}
 table{border-collapse:collapse;width:100%;font-size:.82rem}
 th,td{border:1px solid #e2e2e2;padding:.3rem .5rem;text-align:left;vertical-align:top}
 th{background:#f0f0f0;position:sticky;top:0}
 tbody tr:nth-child(even){background:#fafafa}
 .none{color:#999;padding:.6rem 1rem}
 .count{color:#888;font-weight:400}
</style>
'@

function New-Section {
    param([string]$Title, $Data, [string[]]$Columns, [switch]$Open)
    $n = @($Data).Count
    $openAttr = if ($Open) { ' open' } else { '' }
    "<details$openAttr><summary>$Title <span class='count'>($n)</span></summary>" + (New-HtmlTable -Data $Data -Columns $Columns) + '</details>'
}

$sbHtml = New-Object System.Text.StringBuilder
[void]$sbHtml.Append("<!doctype html><html><head><meta charset='utf-8'><title>Machine inventory - $computer</title>$css</head><body>")
[void]$sbHtml.Append("<h1>Machine inventory: $computer</h1>")
[void]$sbHtml.Append("<div class='sub'>Captured $(Get-TS) &middot; inventory script v$ScriptVersion &middot; elevated: $isAdmin</div>")

# Summary card
[void]$sbHtml.Append("<div class='card'><div class='grid'>")
foreach ($pair in @(
    @('Make / model', ("{0} {1}" -f $sys.Manufacturer, $sys.Model)),
    @('Serial',       $sys.SerialNumber),
    @('CPU',          (@($hardware.Processor)[0].Name)),
    @('RAM',          $sys.TotalRAM),
    @('OS edition',   $os.Edition),
    @('OS build',     ("{0} ({1})" -f $os.Build, $os.DisplayVersion)),
    @('BIOS',         ("{0} {1}" -f $sys.BiosVersion, $sys.BiosDate))
)) {
    [void]$sbHtml.Append("<div><span>$(ConvertTo-Cell $pair[0])</span>$(ConvertTo-Cell $pair[1])</div>")
}
[void]$sbHtml.Append('</div></div>')

# Hardware detail tables
[void]$sbHtml.Append('<h2>Hardware</h2>')
[void]$sbHtml.Append((New-Section 'Processor'         $hardware.Processor -Open))
[void]$sbHtml.Append((New-Section 'Memory modules'    $hardware.Memory -Open))
[void]$sbHtml.Append((New-Section 'Disks'             $hardware.Disks -Open))
[void]$sbHtml.Append((New-Section 'Graphics'          $hardware.Graphics -Open))
[void]$sbHtml.Append((New-Section 'Network adapters'  $hardware.Network -Open))
[void]$sbHtml.Append((New-Section 'Battery'           $hardware.Battery))
[void]$sbHtml.Append((New-Section 'TPM / Secure Boot' @($hardware.Security) -Open))

# Drivers
[void]$sbHtml.Append('<h2>Drivers</h2>')
[void]$sbHtml.Append("<div class='card'>Driver export: <b>$(ConvertTo-Cell $driverExport.Result)</b>$(if ($driverExport.Path){" &rarr; " + (ConvertTo-Cell $driverExport.Path)})</div>")
[void]$sbHtml.Append((New-Section 'Third-party driver store (exportable)' $drivers.ThirdPartyStore -Open))
[void]$sbHtml.Append((New-Section 'All signed drivers (per device)'       $drivers.SignedDrivers))

# Apps
[void]$sbHtml.Append('<h2>Applications &amp; runtimes</h2>')
[void]$sbHtml.Append((New-Section 'Win32 programs'              $apps.Win32 -Open))
[void]$sbHtml.Append((New-Section 'Store / Appx packages'       $apps.Appx))
[void]$sbHtml.Append((New-Section 'Runtimes / redistributables' $apps.Runtimes -Open))

# System config
[void]$sbHtml.Append('<h2>Services, startup &amp; features</h2>')
[void]$sbHtml.Append((New-Section 'Optional features (enabled)' $sysconfig.OptionalFeatures -Open))
[void]$sbHtml.Append((New-Section 'Capabilities (installed)'    $sysconfig.Capabilities))
[void]$sbHtml.Append((New-Section 'Startup items'              $sysconfig.Startup -Open))
[void]$sbHtml.Append((New-Section 'Services'                   $sysconfig.Services))

[void]$sbHtml.Append('</body></html>')

$reportPath = Join-Path $outDir 'report.html'
Set-Content -LiteralPath $reportPath -Value $sbHtml.ToString() -Encoding UTF8

# =====================================================================================
#  Done
# =====================================================================================
Info "===== Inventory complete ====="
Info "Report : $reportPath"
Info "Data   : $dataDir"
if ($driverExport.Attempted) { Info "Drivers: $($driverExport.Path)" }
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }

if ($OpenReport) { try { Start-Process $reportPath } catch { Warn "could not open report: $($_.Exception.Message)" } }
exit 0
