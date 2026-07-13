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
$ScriptVersion = '1.1.0'

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
                # -File, and -like rather than -Filter. -Filter goes through the Win32 name
                # matcher, which also matches 8.3 SHORT names: '*.mof' would match
                # payload.mofdata (short name PAYLOA~1.MOF). For a go/no-go gate, a false
                # FOUND is the worst possible outcome. -like does no short-name matching.
                $hit = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $f })
                if ($hit.Count -gt 0) { $hit | ForEach-Object { Write-Host ("  FOUND  {0}  ({1} bytes)" -f $_.FullName, $_.Length) } }
                else { Write-Warning "  MISSING file '$f' in $c"; $allPresent = $false }
            }
        } else {
            # A component DIRECTORY that exists but is EMPTY used to print nothing, leave
            # $allPresent = $true, and report "all requested payloads present". That is exactly
            # the false green this tool exists to prevent: 0x800f0915 is a missing PAYLOAD, not
            # a missing folder. The operator would then commit to a multi-hour DISM run against
            # a source that cannot repair anything.
            $files = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) {
                Write-Warning "EMPTY component (folder present, NO payload): $c"
                $allPresent = $false
                continue
            }
            $files | Select-Object -First 20 | ForEach-Object {
                Write-Host ("  FOUND  {0}  ({1} bytes)" -f $_.Name, $_.Length)
            }
        }
    }
} finally {
    # Guarded: with $ErrorActionPreference='Stop', a dismount failure (a handle held on the
    # mount dir by AV or Explorer is routine) throws OUT OF the finally, the exit line below
    # never runs, and the process exits 1 - making a clean "all present" run indistinguishable
    # from a crash, while leaving the WIM mounted so the next run dies at Mount-WindowsImage.
    try { Dismount-WindowsImage -Path $MountPath -Discard | Out-Null }
    catch {
        Write-Warning "Dismount failed: $($_.Exception.Message)"
        Write-Warning "Run: Clear-WindowsCorruptMountPoint   (the image is still mounted at $MountPath)"
        $allPresent = $false
    }
}

if ($allPresent) { Write-Host "RESULT: all requested payloads present - this image is a valid RestoreHealth /Source." -ForegroundColor Green }
else { Write-Warning "RESULT: one or more payloads are missing - do NOT rely on this image for those components." }

# Exit code: 0 = all present, 2 = something missing (usable in automation)
exit ([int](-not $allPresent) * 2)
