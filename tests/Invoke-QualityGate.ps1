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
      * A product literal ('Server2025', 'Win11', ...) used OUTSIDE the $PRODUCTS profile
        table in a multi-product script. Whatever it configures will be wrong for every other
        -Product. (Real bug: the output ISO was named Server2025_Patched_*.iso on a Win11
        build - correct media, wrong name, and it would have been archived under the wrong
        product.) Literals inside Write-* console text are ignored - a product name in a
        LOG LINE is fine; a product name in a VALUE is the bug.
      * Add-WindowsPackage -PackagePath pointing at a FOLDER (a $*_FOLDER / $*_DIR variable).
        Checkpoint CUs must be DISCOVERED by DISM from the folder beside the target, never
        applied explicitly; naming the folder applies them explicitly and fails 0x80070228.
        Microsoft: "run DISM /add-package with the latest .msu file as the sole target".
        (Real bug: killed a 25H2 build 30 minutes in.) $*_PATH vars are FILES and are fine.

.PARAMETER Path
    Repo root to scan. Defaults to the parent of this script.

.PARAMETER InstallAnalyzer
    Install PSScriptAnalyzer (CurrentUser) if missing.

.EXAMPLE
    .\tests\Invoke-QualityGate.ps1
.EXAMPLE
    .\tests\Invoke-QualityGate.ps1 -InstallAnalyzer

.NOTES
    Version : 1.2.0
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

    # --- Rule E: Add-WindowsPackage -PackagePath pointing at a FOLDER ---------------
    # Microsoft's checkpoint-CU method (catalog-checkpoint-cumulative-updates, step 3) is:
    # put the target LCU + all prior checkpoints in one folder, then run /add-package with
    # "the latest .msu file as the SOLE TARGET". DISM discovers the checkpoints itself.
    # Passing the FOLDER makes DISM apply the checkpoint EXPLICITLY -> 0x80070228,
    # "An error occurred applying the Unattend.xml file from the .msu package."
    # Cost when this regressed: ~30 min of servicing before it threw.
    foreach ($cmd in @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Add-WindowsPackage'
    }, $true))) {
        for ($k = 0; $k -lt $cmd.CommandElements.Count - 1; $k++) {
            $el = $cmd.CommandElements[$k]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el.ParameterName -eq 'PackagePath') {
                $val = $cmd.CommandElements[$k + 1].Extent.Text
                # Only a variable whose name ENDS in _FOLDER / _DIR is a folder.
                # NOT *_PATH: $SAFE_OS_DU_PATH / $DOTNET_CU_PATH are single .msu/.cab FILES and
                # are correct as -PackagePath targets. (v1.1.0 flagged them - false positive.)
                if ($val -match '(?i)^\$\w*_(folder|dir)$') {
                    Write-Host ("  WARN  {0}:{1}  Add-WindowsPackage -PackagePath {2} looks like a FOLDER" -f `
                        $f.Name, $cmd.Extent.StartLineNumber, $val) -ForegroundColor Yellow
                    Write-Host "        Checkpoint CUs must be DISCOVERED, not applied explicitly. Pass the single" -ForegroundColor Yellow
                    Write-Host "        target LCU .msu; leave the checkpoints beside it. Folder => 0x80070228." -ForegroundColor Yellow
                }
            }
        }
    }

    # --- Rule D: product-specific literal leaking outside the $PRODUCTS table -------
    # v2.1.3: the output ISO name was hardcoded "Server2025_Patched_{0}.iso", so a Win11
    # build emitted an ISO named Server2025_*. In a multi-product script, EVERY product
    # detail must come from the $PRODUCTS profile. A bare product token anywhere else
    # (outside param()/ValidateSet, which is legitimately a list of product names) means a
    # detail was baked in and will be wrong for the other products.
    $prodTable = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq 'PRODUCTS'
    }, $true))

    if ($prodTable.Count -gt 0) {
        # Offset ranges we're allowed to name products in: the table itself + the param block.
        $safe = @()
        foreach ($t in $prodTable) { $safe += , @($t.Extent.StartOffset, $t.Extent.EndOffset) }
        $pb = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $false)
        if ($pb) { $safe += , @($pb.Extent.StartOffset, $pb.Extent.EndOffset) }

        $strs = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Value -match '(?i)server\s?20\d\d|win(dows)?[\s_-]?1[01]'
        }, $true))

        foreach ($s in $strs) {
            $off = $s.Extent.StartOffset
            $inSafe = $false
            foreach ($r in $safe) { if ($off -ge $r[0] -and $off -le $r[1]) { $inSafe = $true; break } }

            # A product name in CONSOLE TEXT is fine (help text, log lines, usage examples).
            # A product name in a VALUE is the bug - it configures something, and will be wrong
            # for every other -Product. Skip literals whose enclosing command is a Write-*.
            # (v1.1.0 flagged a -Index/-EditionName usage hint printed by Write-Output.)
            if (-not $inSafe) {
                $p = $s.Parent
                while ($p) {
                    if ($p -is [System.Management.Automation.Language.CommandAst] -and
                        $p.GetCommandName() -match '^(?i)Write-(Output|Host|Warning|Verbose|Debug|Information)$') {
                        $inSafe = $true
                        break
                    }
                    $p = $p.Parent
                }
            }

            if (-not $inSafe) {
                Write-Host ("  WARN  {0}:{1}  product literal '{2}' outside `$PRODUCTS" -f `
                    $f.Name, $s.Extent.StartLineNumber, $s.Value) -ForegroundColor Yellow
                Write-Host "        Multi-product script: this will be WRONG for every other -Product." -ForegroundColor Yellow
                Write-Host "        Move it to the profile table and read it from `$P.<Field>." -ForegroundColor Yellow
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
