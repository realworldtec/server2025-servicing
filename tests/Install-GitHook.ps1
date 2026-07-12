<#
.SYNOPSIS
    Installs a git pre-commit hook that runs the quality gate. Nothing broken gets committed.

.DESCRIPTION
    Writes .git/hooks/pre-commit. On every `git commit`, the gate runs; a non-zero exit
    aborts the commit. Bypass in an emergency with:  git commit --no-verify

.EXAMPLE
    .\tests\Install-GitHook.ps1

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
#>

[CmdletBinding()]
param()

$repo = Split-Path $PSScriptRoot -Parent
$hookDir = Join-Path $repo '.git\hooks'
if (-not (Test-Path $hookDir)) { throw "Not a git repo (no .git\hooks): $repo" }

$hookPath = Join-Path $hookDir 'pre-commit'
$hook = @'
#!/bin/sh
# server2025-servicing pre-commit: run the PowerShell quality gate.
echo "Running quality gate..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests/Invoke-QualityGate.ps1"
if [ $? -ne 0 ]; then
  echo ""
  echo "COMMIT BLOCKED: quality gate failed. Fix the issues above, or bypass with: git commit --no-verify"
  exit 1
fi
exit 0
'@

Set-Content -Path $hookPath -Value $hook -Encoding ASCII -NoNewline:$false
Write-Host "Installed pre-commit hook: $hookPath"
Write-Host "Every 'git commit' now runs tests\Invoke-QualityGate.ps1 and blocks on failure."
Write-Host "Emergency bypass: git commit --no-verify"
