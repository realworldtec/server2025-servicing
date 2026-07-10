<#
.SYNOPSIS
    Verifies that a Windows image (install.wim) actually contains specific WinSxS
    component payloads BEFORE you run DISM /RestoreHealth against it as a /Source.

.DESCRIPTION
    RestoreHealth fails with 0x800f0915 ("repair content could not be found") when the
    /Source doesn't hold the *exact version* of the corrupt component. This tool mounts
    the image read-only and confirms the component folder(s) and (optionally) file(s)
    are present, so you get a definitive go / no-go instead of a blind, slow failure.

    Get the component identity strings from CBS.log lines of the form:
        (p) CSI Payload Corrupt (n)  amd64_<component>_<key>_<ver>_none_<hash>\<file>

.PARAMETER WimPath
    Path to the image, e.g. H:\sources\install.wim (the pristine RTM media is often the
    right source for orphaned pre-RTM component versions).

.PARAMETER Index
    Image index to inspect. Default 4 (Windows Server 2025 Datacenter Desktop Experience).

.PARAMETER Component
    One or more WinSxS component folder names to look for (the 'amd64_..._none_<hash>' part).

.PARAMETER File
    Optional specific file name(s) to confirm inside each component folder (e.g. *.mof).

.PARAMETER MountPath
    Temp read-only mount point. Default E:\wimcheck.

.EXAMPLE
    .\Check-Packages.ps1 -WimPath H:\sources\install.wim -Index 4 `
        -Component 'amd64_bgpncprovider_31bf3856ad364e35_10.0.26100.1150_none_1bf6588586e5a0fb',
                   'amd64_ipamserverwmiv2provider_31bf3856ad364e35_10.0.26100.1150_none_75a867a53ad31572'

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WimPath,
    [int]$Index = 4,
    [Parameter(Mandatory)][string[]]$Component,
    [string[]]$File,
    [string]$MountPath = 'E:\wimcheck'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

if (-not (Test-Path $WimPath)) { throw "Image not found: $WimPath" }
if (-not (Test-Path $MountPath)) { New-Item -ItemType Directory -Path $MountPath -Force | Out-Null }

Write-Host "Check-Packages v$ScriptVersion : $WimPath (index $Index)"
$allPresent = $true
Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $MountPath -ReadOnly | Out-Null
try {
    foreach ($c in $Component) {
        $dir = Join-Path "$MountPath\Windows\WinSxS" $c
        if (-not (Test-Path $dir)) {
            Write-Warning "MISSING component: $c"
            $allPresent = $false
            continue
        }
        if ($File) {
            foreach ($f in $File) {
                $hit = Get-ChildItem $dir -Filter $f -ErrorAction SilentlyContinue
                if ($hit) { $hit | ForEach-Object { Write-Host ("  FOUND  {0}  ({1} bytes)" -f $_.FullName, $_.Length) } }
                else { Write-Warning "  MISSING file '$f' in $c"; $allPresent = $false }
            }
        } else {
            Get-ChildItem $dir -File | Select-Object -First 20 | ForEach-Object {
                Write-Host ("  FOUND  {0}  ({1} bytes)" -f $_.Name, $_.Length)
            }
        }
    }
} finally {
    Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
}

if ($allPresent) { Write-Host "RESULT: all requested payloads present - this image is a valid RestoreHealth /Source." -ForegroundColor Green }
else { Write-Warning "RESULT: one or more payloads are missing - do NOT rely on this image for those components." }

# Exit code: 0 = all present, 2 = something missing (usable in automation)
exit ([int](-not $allPresent) * 2)
