<#
.SYNOPSIS
    Build a tiny secondary ISO carrying autounattend.xml at its root, to attach as a 2nd CD/DVD.
    Windows Setup auto-reads autounattend.xml from the root of any attached optical media, so this
    keeps your golden install ISO untouched (and non-destructive) while still automating Setup.

.DESCRIPTION
    Copies the answer file to a staging dir AS 'autounattend.xml' (the name Setup looks for),
    then wraps it into a data ISO with oscdimg. No boot info needed - it's just a data disc.

.PARAMETER AnswerFile   Source answer file. Default ..\unattend\autounattend-Win11.xml.
.PARAMETER OutputIso    Output ISO. Default: <AnswerFile dir>\Win11-unattend.iso.
.PARAMETER Label        Volume label. Default 'UNATTEND'.

.EXAMPLE
    .\unattend\New-UnattendIso.ps1
    # -> unattend\Win11-unattend.iso  (attach as a 2nd CD-ROM alongside the install ISO)

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Needs oscdimg (Windows ADK + WinPE add-on).
#>

[CmdletBinding()]
param(
    [string]$AnswerFile,
    [string]$OutputIso,
    [string]$Label = 'UNATTEND'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

function Get-Oscdimg {
    $cands = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $hit = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $hit) { throw "oscdimg.exe not found - install the Windows ADK + WinPE add-on." }
    return $hit
}

$here = $PSScriptRoot
if (-not $AnswerFile) { $AnswerFile = Join-Path $here 'autounattend-Win11.xml' }
if (-not (Test-Path $AnswerFile)) { throw "Answer file not found: $AnswerFile" }
if (-not $OutputIso)  { $OutputIso  = Join-Path (Split-Path $AnswerFile -Parent) 'Win11-unattend.iso' }

$oscdimg = Get-Oscdimg
$stage = Join-Path $env:TEMP ("unattend_iso_{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    # MUST be named autounattend.xml at the root for Setup to find it.
    Copy-Item $AnswerFile (Join-Path $stage 'autounattend.xml') -Force
    if (Test-Path $OutputIso) { Remove-Item $OutputIso -Force }

    $cmd  = Join-Path $stage '_build.cmd'
    $line = "`"$oscdimg`" -u2 -udfver102 -l`"$Label`" `"$stage`" `"$OutputIso`""
    @("@echo off", $line, "exit /b %ERRORLEVEL%") | Set-Content -Path $cmd -Encoding Ascii
    & $env:SystemRoot\System32\cmd.exe /c "`"$cmd`""
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)." }
    Write-Host "Built: $OutputIso  (New-UnattendIso v$ScriptVersion; attach as a 2nd CD-ROM next to the install ISO; set VM firmware = EFI)"
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
