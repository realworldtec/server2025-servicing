<#
.SYNOPSIS
    Quality gate for this repo. Run it BEFORE trusting any script change - especially any
    change that arrived from an AI assistant, which cannot execute PowerShell and therefore
    cannot have verified its own syntax.

.DESCRIPTION
    Five layers, fastest first:

      1. AST PARSE  - the real PowerShell parser. Catches every syntax error: a comment that
                      swallowed a closing brace, a try/catch piped into Out-File, an unclosed
                      string. This is the layer that a "brace counter" cannot replace.
      2. PSSCRIPTANALYZER - unapproved verbs, uninitialised vars, common bad practice.
      3. PROJECT RULES - static checks for the specific footguns that have actually bitten
                      this codebase (see below). Cheap insurance against repeat offences.
      4. PRODUCT CONFIG - validates config\Products.psd1: it parses as restricted-language
                      data, every profile has the required fields, no DefaultEditions entry
                      contains a wildcard (they are matched with -eq, so a wildcard matches
                      NOTHING - silently), and Server2025.IsoPrefix is unchanged (the detector
                      globs it to archive the monthly build). This is the file operators edit,
                      so a bad edit must fail HERE, in seconds - not four hours into a build.
      5. ANSWER FILES - validates every *.xml: it must be well-formed, and for a Windows
                      unattend file (root <unattend>), RunSynchronous/RunAsynchronous may appear
                      ONLY under the Microsoft-Windows-Setup or Microsoft-Windows-Deployment
                      components, and every <settings pass="..."> must name a real pass. A
                      RunSynchronous placed under Microsoft-Windows-Shell-Setup is well-formed XML
                      but an INVALID answer file: Setup rejects it at specialize with 0x80220001
                      ("Setting is not defined in this component") and boot-loops the installer.
                      (Real bug: the Win11 answer file shipped with the hardening trigger under
                      Shell-Setup; AST/PSSA don't look at XML, so a green gate let it through.)

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
      * A script-local function CALLED (at top level) before it is DEFINED. PowerShell runs
        top-to-bottom, so this throws "not recognized" at runtime - invisible to AST parse and
        PSSA. (Real bug: Get-TS used above its definition after a v3.4.0 code move.)

.PARAMETER Path
    Repo root to scan. Defaults to the parent of this script.

.PARAMETER InstallAnalyzer
    Install PSScriptAnalyzer (CurrentUser) if missing.

.PARAMETER CheckPreReq
    Also run tests\Test-Prerequisites.ps1 (host tool availability: oscdimg/ADK, elevation, optional
    tools). Opt-in: stages 1-5 validate the SCRIPTS regardless of host; this extra stage validates the
    MACHINE. A missing REQUIRED prerequisite fails the gate.

.EXAMPLE
    .\tests\Invoke-QualityGate.ps1
.EXAMPLE
    .\tests\Invoke-QualityGate.ps1 -InstallAnalyzer
.EXAMPLE
    .\tests\Invoke-QualityGate.ps1 -CheckPreReq       # also verify this host can run a build

.NOTES
    Version : 1.8.0
    Project : server2025-servicing
    Exit code 0 = pass, 1 = fail. Suitable for a git pre-commit hook or CI.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$InstallAnalyzer,
    [switch]$CheckPreReq
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
Write-Host "[1/5] PowerShell AST parse" -ForegroundColor Cyan
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
Write-Host "[2/5] PSScriptAnalyzer" -ForegroundColor Cyan
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
Write-Host "[3/5] Project rules" -ForegroundColor Cyan

# A stage that prints NOTHING when it passes is indistinguishable from a stage that silently
# did nothing - a skipped file, a `continue` that swallowed everything, a rule that never fired
# because its AST predicate was wrong. Every other stage reports what it checked; so does this
# one now. Count what we scan, count what we find, and say so.
$rulesScanned  = 0
$rulesFindings = 0

foreach ($f in $files) {
    # Don't lint the gate with its own rules. Rule D exists to catch product literals leaking
    # into a script that CONSUMES the product config; this file VALIDATES that config, so the
    # literals it asserts on (e.g. the load-bearing 'Server2025_Patched' prefix) are the whole
    # point. Without this, stage 3 flags stage 4 - which is noise, and noise is how a gate
    # becomes something you skim past.
    if ($f.FullName -eq $PSCommandPath) { continue }

    $rulesScanned++
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
            $rulesFindings++
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
            $rulesFindings++
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
                $rulesFindings++
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
                    $rulesFindings++
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
                $rulesFindings++
                Write-Host ("  WARN  {0}:{1}  product literal '{2}' outside `$PRODUCTS" -f `
                    $f.Name, $s.Extent.StartLineNumber, $s.Value) -ForegroundColor Yellow
                Write-Host "        Multi-product script: this will be WRONG for every other -Product." -ForegroundColor Yellow
                Write-Host "        Move it to the profile table and read it from `$P.<Field>." -ForegroundColor Yellow
            }
        }
    }

    # --- Rule F: script-local function CALLED before it is DEFINED -----------------
    # PowerShell executes top-to-bottom, so a call to a function above its `function` line
    # throws at RUNTIME: "The term 'X' is not recognized". The AST parses fine and PSSA is
    # silent, so this sailed past a green gate and died on first run (Get-TS, used by a block
    # that had been moved above its definition). Precise + cheap: collect every local function's
    # definition offset, then flag any CALL to one of those names at an earlier offset.
    $funcDefs = @{}
    foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        # First definition wins (a function can legitimately be redefined later).
        if (-not $funcDefs.ContainsKey($fn.Name)) { $funcDefs[$fn.Name] = $fn.Extent.StartOffset }
    }
    if ($funcDefs.Count -gt 0) {
        foreach ($call in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $cn = $call.GetCommandName()
            if (-not ($cn -and $funcDefs.ContainsKey($cn) -and ($call.Extent.StartOffset -lt $funcDefs[$cn]))) { continue }

            # ONLY top-level calls matter. A call NESTED inside a function body is deferred until
            # that function is invoked - by which point all later definitions have loaded - so a
            # forward reference between functions (A calls B, B defined below A) is legal and must
            # NOT be flagged. Walk ancestors: if any is a function definition, skip.
            $nested = $false
            $anc = $call.Parent
            while ($anc) {
                if ($anc -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }
                $anc = $anc.Parent
            }
            if ($nested) { continue }

            $rulesFindings++
            Write-Host ("  FAIL  {0}:{1}  '{2}' is CALLED (at top level) before it is defined." -f `
                $f.Name, $call.Extent.StartLineNumber, $cn) -ForegroundColor Red
            Write-Host "        PowerShell runs top-to-bottom: this throws 'not recognized' at runtime." -ForegroundColor Red
            Write-Host "        Move the function definition above its first use." -ForegroundColor Red
            $failures++
        }
    }
}

if ($rulesFindings -eq 0) {
    Write-Host ("  ok    no findings ({0} script(s) scanned; rules A-F)" -f $rulesScanned) -ForegroundColor Green
} else {
    Write-Host ("  {0} finding(s) across {1} script(s)." -f $rulesFindings, $rulesScanned) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4. Product config data file (config\Products.psd1)
# ---------------------------------------------------------------------------
# This is the file operators hand-edit, so a bad edit must fail HERE - in seconds - and not
# four hours into a build. Same validation the slipstream applies at startup.
Write-Host ""
Write-Host "[4/5] Config files (Products + Deploy)" -ForegroundColor Cyan
$cfg = Join-Path $Path 'config\Products.psd1'
if (-not (Test-Path $cfg)) {
    Write-Host "  FAIL  config\Products.psd1 not found - the slipstream cannot run without it." -ForegroundColor Red
    $failures++
} else {
    $cfgRoot = $null
    try {
        $cfgRoot = Import-PowerShellDataFile -Path $cfg -ErrorAction Stop
    } catch {
        Write-Host ("  FAIL  config\Products.psd1 is not valid PowerShell data: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "        It must be ONE hashtable of literals - no commands, variables or expressions." -ForegroundColor Red
        $failures++
    }
    # Schema: nested (@{ RunMediaJobs=...; Products=@{...} }) or legacy flat (@{ 'Server2025'=... }).
    $cfgProducts = if ($cfgRoot -and $cfgRoot.ContainsKey('Products')) { $cfgRoot.Products } else { $cfgRoot }

    # RunMediaJobs (nested schema only): every name listed must be a defined product, or the
    # scheduled task would try to build a product that does not exist.
    if ($cfgRoot -and $cfgRoot.ContainsKey('RunMediaJobs')) {
        foreach ($j in @($cfgRoot['RunMediaJobs'])) {
            if (-not ($cfgProducts -and $cfgProducts.ContainsKey($j))) {
                $failures++
                Write-Host ("  FAIL  RunMediaJobs lists '{0}', which is not a defined product." -f $j) -ForegroundColor Red
            }
        }
    }

    if ($cfgProducts) {
        $required = @('Label','IsoPrefix','BasePath','SourceISO','LcuQuery','LcuInclude',
                      'SafeOsQuery','SafeOsInclude','SetupQuery','SetupInclude',
                      'DotNetQuery','DotNetInclude')
        $bad = 0
        foreach ($name in ($cfgProducts.Keys | Sort-Object)) {
            $prof = $cfgProducts[$name]
            $errs = @()
            if ($prof -isnot [hashtable]) { $errs += 'not a hashtable' }
            else {
                foreach ($f in $required) {
                    if (-not $prof.ContainsKey($f)) { $errs += "missing '$f'" }
                    elseif ([string]::IsNullOrWhiteSpace([string]$prof[$f])) { $errs += "'$f' is empty" }
                }
                # KeepLast: 0 means Select-Object -Skip 0, which skips NOTHING - it would prune
                # the ISO archived seconds earlier. Optional, but if present it must be >= 1.
                if ($prof.ContainsKey('KeepLast') -and $null -ne $prof['KeepLast']) {
                    $kl = 0; [void][int]::TryParse([string]$prof['KeepLast'], [ref]$kl)
                    if ($kl -lt 1) { $errs += "KeepLast must be >= 1 (0 prunes the build you just made)" }
                }
                if ($prof.ContainsKey('DefaultEditions') -and $null -ne $prof['DefaultEditions']) {
                    foreach ($e in @($prof['DefaultEditions'])) {
                        # Names are matched with -eq. A wildcard here matches NOTHING, silently.
                        if ("$e" -match '[\*\?]') { $errs += "DefaultEditions '$e' contains a wildcard (matched with -eq => matches NOTHING)" }
                    }
                }
                # TrimByDefault, if present, must be a real boolean - 'yes'/'true' as a STRING is
                # truthy in a way that would silently trim when the operator did not mean to.
                if ($prof.ContainsKey('TrimByDefault') -and $prof['TrimByDefault'] -isnot [bool]) {
                    $errs += "TrimByDefault must be `$true or `$false (got a $($prof['TrimByDefault'].GetType().Name))"
                }
            }
            if ($errs.Count -gt 0) {
                $bad++
                Write-Host ("  FAIL  [{0}] {1}" -f $name, ($errs -join '; ')) -ForegroundColor Red
            } else {
                $def = if ($null -eq $prof['DefaultEditions']) { 'ALL editions' } else { "$(@($prof['DefaultEditions']).Count) edition(s)" }
                $arc = if ([string]::IsNullOrWhiteSpace([string]$prof['ArchiveRoot'])) { 'no archive' } else { "-> $($prof['ArchiveRoot']) keep $($prof['KeepLast'])" }
                $trm = if ([bool]$prof['TrimByDefault']) { 'trim' } else { 'full' }
                Write-Host ("  ok    {0,-12} {1}_<stamp>.iso  ({2}, {3}; {4})" -f $name, $prof['IsoPrefix'], $def, $trm, $arc) -ForegroundColor Green
            }
        }
        if ($bad -gt 0) { $failures++ }

        # The detector globs 'Server2025_Patched_*.iso' to find and archive the monthly build.
        # Rename that prefix and the scheduled task keeps "succeeding" while archiving nothing.
        if ($cfgProducts.ContainsKey('Server2025') -and $cfgProducts['Server2025']['IsoPrefix'] -ne 'Server2025_Patched') {
            $failures++
            Write-Host "  FAIL  Server2025.IsoPrefix must be 'Server2025_Patched'." -ForegroundColor Red
            Write-Host "        Watch-Server2025Updates.ps1 archives the build by globbing 'Server2025_Patched_*.iso'." -ForegroundColor Red
            Write-Host "        Changing it makes the scheduled task silently archive nothing." -ForegroundColor Red
        }
    }
}

# ---- config\Deploy.psd1: golden-image deploy profiles (optional) ----
# Same idea as Products.psd1: the file an operator edits must fail HERE, in seconds, not partway
# into a 12 GB golden build. Validates: parses as data; DefaultProfile names a real profile; every
# profile has Product + EditionName; the Product is defined in Products.psd1; and an install that's
# switched on names its installer (Office->OfficeOdt, Acrobat->AcrobatIso).
$dcfg = Join-Path $Path 'config\Deploy.psd1'
if (Test-Path $dcfg) {
    $droot = $null
    try { $droot = Import-PowerShellDataFile -Path $dcfg -ErrorAction Stop }
    catch {
        Write-Host ("  FAIL  config\Deploy.psd1 is not valid PowerShell data: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $failures++
    }
    if ($droot) {
        $dprofs = if ($droot.ContainsKey('Profiles')) { $droot.Profiles } else { $droot }
        if ($droot.ContainsKey('DefaultProfile') -and -not ($dprofs -and $dprofs.ContainsKey([string]$droot.DefaultProfile))) {
            $failures++
            Write-Host ("  FAIL  Deploy.psd1 DefaultProfile '{0}' is not a defined profile." -f $droot.DefaultProfile) -ForegroundColor Red
        }
        if ($dprofs) {
            foreach ($pname in ($dprofs.Keys | Sort-Object)) {
                $p = $dprofs[$pname]
                $e = @()
                if ($p -isnot [hashtable]) { $e += 'not a hashtable' }
                else {
                    foreach ($req in @('Product','EditionName')) {
                        if (-not $p.ContainsKey($req) -or [string]::IsNullOrWhiteSpace([string]$p[$req])) { $e += "missing '$req'" }
                    }
                    if ($p.ContainsKey('Product') -and $cfgProducts -and -not $cfgProducts.ContainsKey([string]$p['Product'])) {
                        $e += "Product '$($p['Product'])' is not defined in Products.psd1"
                    }
                    if ($p.ContainsKey('Office')  -and [bool]$p['Office']  -and [string]::IsNullOrWhiteSpace([string]$p['OfficeOdt'])) { $e += "Office on but OfficeOdt empty" }
                    if ($p.ContainsKey('Acrobat') -and [bool]$p['Acrobat'] -and [string]::IsNullOrWhiteSpace([string]$p['AcrobatIso'])) { $e += "Acrobat on but AcrobatIso empty" }
                }
                if ($e.Count -gt 0) {
                    $failures++
                    Write-Host ("  FAIL  Deploy[{0}] {1}" -f $pname, ($e -join '; ')) -ForegroundColor Red
                } else {
                    Write-Host ("  ok    Deploy[{0,-16}] {1} / {2}" -f $pname, $p['Product'], $p['EditionName']) -ForegroundColor Green
                }
            }
        }
    }
} else {
    Write-Host "  ok    no config\Deploy.psd1 (deploy profiles are optional)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. Answer files (unattend XML): well-formedness + component/pass sanity
# ---------------------------------------------------------------------------
# AST + PSSA never look at XML, so a schema-invalid answer file ships on a green gate. The bug that
# motivated this stage: the specialize hardening trigger (<RunSynchronous>) sat under
# Microsoft-Windows-Shell-Setup, which does not define it. Windows Setup rejected the whole file at
# the specialize pass with 0x80220001 ("Setting is not defined in this component") and boot-looped
# the installer. RunSynchronous/RunAsynchronous belong ONLY to Microsoft-Windows-Setup (windowsPE)
# or Microsoft-Windows-Deployment (specialize/auditUser).
Write-Host ""
Write-Host "[5/5] Answer files (XML)" -ForegroundColor Cyan
# Also validate *.xml.sample templates (an operator copies them to a live .xml, so a malformed
# sample = a malformed answer file waiting to happen).
$xmlFiles = @(Get-ChildItem -Path $Path -Recurse -File |
              Where-Object { $_.Name -match '(?i)\.xml(\.sample)?$' -and $_.FullName -notlike '*\.git\*' })
$validPasses = @('windowsPE','offlineServicing','generalize','specialize','auditSystem','auditUser','oobeSystem')
$runOwners   = @('Microsoft-Windows-Setup','Microsoft-Windows-Deployment')
$xmlScanned  = 0
$xmlFindings = 0
if ($xmlFiles.Count -eq 0) {
    Write-Host "  ok    no XML files to check" -ForegroundColor Green
}
foreach ($x in $xmlFiles) {
    $xmlScanned++
    $doc = New-Object System.Xml.XmlDocument
    try {
        $doc.Load($x.FullName)
    } catch {
        $failures++; $xmlFindings++
        Write-Host ("  FAIL  {0} - not well-formed XML: {1}" -f $x.Name, $_.Exception.Message) -ForegroundColor Red
        continue
    }
    # Apply the unattend rules only to actual answer files (root <unattend>). Any other XML is just
    # checked for well-formedness above.
    if (-not $doc.DocumentElement -or $doc.DocumentElement.LocalName -ne 'unattend') {
        Write-Host ("  ok    {0} (well-formed; not an unattend file)" -f $x.Name) -ForegroundColor Green
        continue
    }
    $fileBad = 0
    # (a) every <settings pass="..."> must name a real configuration pass (a typo is ignored by
    #     Setup - the whole pass silently never runs).
    foreach ($s in @($doc.GetElementsByTagName('settings'))) {
        $pass = $s.GetAttribute('pass')
        if ($pass -and ($validPasses -notcontains $pass)) {
            $failures++; $xmlFindings++; $fileBad++
            Write-Host ("  FAIL  {0}: <settings pass=`"{1}`"> is not a real pass." -f $x.Name, $pass) -ForegroundColor Red
            Write-Host  ("        Valid: {0}." -f ($validPasses -join ', ')) -ForegroundColor Red
        }
    }
    # (b) RunSynchronous / RunAsynchronous only under Microsoft-Windows-Setup or -Deployment.
    foreach ($comp in @($doc.GetElementsByTagName('component'))) {
        $cname = $comp.GetAttribute('name')
        $runNodes = @($comp.GetElementsByTagName('RunSynchronous')) + @($comp.GetElementsByTagName('RunAsynchronous'))
        if ($runNodes.Count -gt 0 -and ($runOwners -notcontains $cname)) {
            $failures++; $xmlFindings++; $fileBad++
            Write-Host ("  FAIL  {0}: Run(a)synchronous under component '{1}'." -f $x.Name, $cname) -ForegroundColor Red
            Write-Host  "        That element belongs to Microsoft-Windows-Setup or -Deployment only." -ForegroundColor Red
            Write-Host  "        Setup rejects the file at specialize (0x80220001) and boot-loops the installer." -ForegroundColor Red
        }
    }
    if ($fileBad -eq 0) {
        Write-Host ("  ok    {0} (well-formed unattend; components + passes valid)" -f $x.Name) -ForegroundColor Green
    }
}
if ($xmlFindings -gt 0) {
    Write-Host ("  {0} finding(s) across {1} XML file(s)." -f $xmlFindings, $xmlScanned) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# (optional) Prerequisites - HOST tool availability (opt-in with -CheckPreReq)
# ---------------------------------------------------------------------------
# Stages 1-5 check the SCRIPTS. This one checks the MACHINE: is oscdimg (ADK) installed, are we
# elevated, etc. It is opt-in because a correct repo on a not-yet-provisioned host is still a correct
# repo - but when you ask for it, a missing REQUIRED tool fails the gate so you find out before a build.
if ($CheckPreReq) {
    Write-Host ""
    Write-Host "[+] Prerequisites (host)" -ForegroundColor Cyan
    $preReqScript = Join-Path $PSScriptRoot 'Test-Prerequisites.ps1'
    if (-not (Test-Path $preReqScript)) {
        Write-Host "  SKIPPED - Test-Prerequisites.ps1 not found beside the gate." -ForegroundColor Yellow
    } else {
        # Take the LAST pipeline value: the prereq script Write-Hosts its table (host stream) and
        # returns a single boolean, but [-1] is robust even if it ever emits more.
        $preOk = @(& $preReqScript)[-1]
        if ($preOk -ne $true) {
            $failures++
            Write-Host "  a REQUIRED prerequisite is missing (see the table above)." -ForegroundColor Red
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
