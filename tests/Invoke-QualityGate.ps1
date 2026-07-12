<#
.SYNOPSIS
    Quality gate for this repo. Run it BEFORE trusting any script change - especially any
    change that arrived from an AI assistant, which cannot execute PowerShell and therefore
    cannot have verified its own syntax.

.DESCRIPTION
    Three layers, fastest first:

      1. AST PARSE  - the real PowerShell parser. Catches every syntax error: a comment that
                      swallowed a closing brace, a try/catch piped into Out-File, an unclosed
                      string. This is the layer that a "brace counter" cannot replace.
      2. PSSCRIPTANALYZER - unapproved verbs, uninitialised vars, common bad practice.
      3. PROJECT RULES - static checks for the specific footguns that have actually bitten
                      this codebase (see below). Cheap insurance against repeat offences.

    Project rules currently enforced:
      * Stop-Transcript appearing BOTH inside a finally block and outside it. A redundant
        Stop-Transcript throws, and a terminating error in finally OVERRIDES the exit code -
        silently turning 'exit 0' into 1. (Real bug: detector reported 0x1 on clean no-ops.)
      * 'return ,$var' (the comma-wrap idiom). Harmless alone, but combined with @() at the
        call site it NESTS the array, making .Count always 1. (Real bug: false-positive guard.)
      * Native command (& foo.exe) inside a function without | Out-Null / | Out-Host. Native
        stdout is captured into the function's return value. (Real bug: DISM output polluted
        a boolean return.)

.PARAMETER Path
    Repo root to scan. Defaults to the parent of this script.

.PARAMETER InstallAnalyzer
    Install PSScriptAnalyzer (CurrentUser) if missing.

.EXAMPLE
    .\tests\Invoke-QualityGate.ps1
.EXAMPLE
    .\tests\Invoke-QualityGate.ps1 -InstallAnalyzer

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    Exit code 0 = pass, 1 = fail. Suitable for a git pre-commit hook or CI.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$InstallAnalyzer
)

if (-not $Path) { $Path = Split-Path $PSScriptRoot -Parent }
$failures = 0

$files = @(Get-ChildItem -Path $Path -Recurse -Filter *.ps1 -File |
           Where-Object { $_.FullName -notlike '*\.git\*' })

Write-Host ""
Write-Host "Quality gate - $($files.Count) script(s) under $Path" -ForegroundColor Cyan
Write-Host ("=" * 70)

# ---------------------------------------------------------------------------
# 1. AST parse (the real parser)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[1/3] PowerShell AST parse" -ForegroundColor Cyan
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    } catch {
        Write-Host ("  FAIL  {0} - parser threw: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red
        $failures++
        continue
    }
    if ($errors -and $errors.Count -gt 0) {
        $failures++
        Write-Host ("  FAIL  {0}" -f $f.Name) -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("        line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    } else {
        Write-Host ("  ok    {0}" -f $f.Name) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 2. PSScriptAnalyzer
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/3] PSScriptAnalyzer" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    if ($InstallAnalyzer) {
        Write-Host "  installing PSScriptAnalyzer (CurrentUser)..."
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Host "  SKIPPED - not installed. Re-run with -InstallAnalyzer." -ForegroundColor Yellow
    }
}
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
    $exclude = @(
        'PSAvoidUsingWriteHost',                    # deliberate: console UX in these tools
        'PSAvoidUsingPlainTextForPassword',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
    $issues = @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Severity Error, Warning -ExcludeRule $exclude -ErrorAction SilentlyContinue)
    if ($issues.Count -gt 0) {
        foreach ($i in $issues) {
            $colour = if ($i.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
            Write-Host ("  {0,-7} {1}:{2}  {3}" -f $i.Severity, (Split-Path $i.ScriptPath -Leaf), $i.Line, $i.RuleName) -ForegroundColor $colour
        }
        if (@($issues | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0) { $failures++ }
    } else {
        Write-Host "  ok    no errors or warnings" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 3. Project-specific rules (the bugs that actually bit us)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/3] Project rules" -ForegroundColor Cyan

foreach ($f in $files) {
    $ast = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    } catch { continue }
    if (-not $ast) { continue }

    # --- Rule A: Stop-Transcript both inside AND outside a finally block ---------
    $stops = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Stop-Transcript'
    }, $true))

    if ($stops.Count -gt 0) {
        $inFinally = 0
        $outside   = 0
        foreach ($s in $stops) {
            $isIn = $false
            $p = $s.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.TryStatementAst] -and $p.Finally) {
                    $fb = $p.Finally.Extent
                    if ($s.Extent.StartOffset -ge $fb.StartOffset -and $s.Extent.EndOffset -le $fb.EndOffset) {
                        $isIn = $true
                        break
                    }
                }
                $p = $p.Parent
            }
            if ($isIn) { $inFinally++ } else { $outside++ }
        }
        if ($inFinally -gt 0 -and $outside -gt 0) {
            $failures++
            Write-Host ("  FAIL  {0}: Stop-Transcript appears in a finally block AND outside it." -f $f.Name) -ForegroundColor Red
            Write-Host "        A redundant Stop-Transcript throws; a terminating error in finally overrides" -ForegroundColor Red
            Write-Host "        the exit code (clean 'exit 0' becomes 1). Let finally own the transcript." -ForegroundColor Red
        }
    }

    # --- Rule B: 'return ,$var' comma-wrap idiom ---------------------------------
    $text = Get-Content $f.FullName -Raw
    $lines = $text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*return\s*,\s*\$') {
            Write-Host ("  WARN  {0}:{1}  'return ,`$var' - if the caller wraps this in @(), the array NESTS" -f $f.Name, ($i + 1)) -ForegroundColor Yellow
            Write-Host "        (.Count becomes 1 regardless). Use plain 'return `$var' + @() at the call site." -ForegroundColor Yellow
        }
    }

    # --- Rule C: native command inside a function, output not suppressed ----------
    $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($fn in $funcs) {
        $cmds = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -and ($n.GetCommandName() -match '\.exe$')
        }, $true))
        foreach ($c in $cmds) {
            $pipe = $c.Parent   # PipelineAst
            $pipeText = if ($pipe) { $pipe.Extent.Text } else { $c.Extent.Text }
            if ($pipeText -notmatch 'Out-Null|Out-Host|Out-File|\>') {
                Write-Host ("  WARN  {0}:{1}  native '{2}' inside function '{3}' without | Out-Host/Out-Null" -f `
                    $f.Name, $c.Extent.StartLineNumber, $c.GetCommandName(), $fn.Name) -ForegroundColor Yellow
                Write-Host "        Native stdout is captured into the function's RETURN VALUE." -ForegroundColor Yellow
            }
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 70)
if ($failures -eq 0) {
    Write-Host "QUALITY GATE: PASS" -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host ("QUALITY GATE: FAIL ({0} blocking issue(s))" -f $failures) -ForegroundColor Red
    Write-Host ""
    exit 1
}
