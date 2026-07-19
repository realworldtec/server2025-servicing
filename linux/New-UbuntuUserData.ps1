<#
.SYNOPSIS
    Generate linux\user-data (the REAL, gitignored Ubuntu answer file) from user-data.sample,
    injecting an SSH key pair + authorized_keys from config\ssh\ubuntu and a SHA-512 crypt password
    hash. The Ventoy tokens ($$HOSTNAME$$ / $$LINUXREALNAME$$ / $$LINUXUSER$$) are left UNTOUCHED -
    those are substituted at BOOT by Ventoy, not here.

.DESCRIPTION
    WHY: the answer file needs multi-line secrets (a private key, a multi-line authorized_keys) that
    can't be Ventoy-prompted, and pasting them into YAML by hand gets the indentation wrong. This
    script does the indentation-sensitive assembly for you.

    IT DOES:
      1. Scans -KeyDir for id_* pairs (any type/name: id_rsa, id_ed25519, id_rwtgit, ...). A pair =
         a private file plus a matching <name>.pub.
      2. Prompts you to pick one (or pass -KeyId), e.g. id_rwtgit.
      3. Reads authorized_keys (multi-line; blank lines and #-comments skipped) for the inbound list.
      4. Gets a SHA-512 crypt hash for the account password - generated locally if it can find
         openssl or WSL, otherwise you paste one in.
      5. Writes the result, replacing these sentinels in the template:
            __KEY_ID__  __PRIVATE_KEY__  __PUBLIC_KEY__  __AUTHORIZED_KEYS__  __PASSWORD_HASH__

    THE OUTPUT CONTAINS A PRIVATE KEY AND A PASSWORD HASH. It is .gitignore'd. Copy it to the Ventoy
    stick as \ventoy\autoinstall\user-data. See docs\SSH-KEYS.md and docs\VENTOY.md.

.PARAMETER KeyDir       Folder holding the key pair + authorized_keys. Default config\ssh\ubuntu.
.PARAMETER Template     Source template. Default linux\user-data.sample.
.PARAMETER OutFile      Output. Default linux\user-data.
.PARAMETER KeyId        Key pair to use, e.g. id_rwtgit. Omit to be prompted.
.PARAMETER PasswordHash Pre-computed $6$ crypt hash. Omit to generate/paste interactively.
.PARAMETER Force        Overwrite an existing output file.

.EXAMPLE
    .\linux\New-UbuntuUserData.ps1
    # prompts for the key pair and the password, writes linux\user-data

.EXAMPLE
    .\linux\New-UbuntuUserData.ps1 -KeyId id_rwtgit -PasswordHash '$6$abc$def...' -Force

.NOTES
    Version : 1.0.0
    Project : server2025-servicing
    License : MIT
    Windows PowerShell 5.1+.
#>

[CmdletBinding()]
param(
    [string]$KeyDir,
    [string]$Template,
    [string]$OutFile,
    [string]$KeyId,
    [string]$PasswordHash,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# =====================================================================================
#  Helpers (defined before any use)
# =====================================================================================

# Locate an openssl that can do 'passwd -6' (SHA-512 crypt). Git for Windows bundles one, which is
# the most likely hit on a Windows build host.
function Get-OpensslPath {
    $onPath = Get-Command 'openssl.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\openssl.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\openssl.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# Produce a $6$ SHA-512 crypt hash. PowerShell/.NET has NO native crypt(3), so we shell out to
# openssl (or WSL). Both prompt for the password themselves, so the plaintext never lands in a
# PowerShell variable, the console history, or this script.
function New-Sha512CryptHash {
    $ossl = Get-OpensslPath
    if ($ossl) {
        Write-Host "Generating SHA-512 crypt hash using: $ossl" -ForegroundColor Cyan
        Write-Host 'You will be asked for the password twice.'
        $result = & $ossl passwd -6
        $hash = ($result | Where-Object { $_ -match '^\$6\$' } | Select-Object -First 1)
        if ($hash) { return $hash.Trim() }
        Write-Warning 'openssl did not return a $6$ hash.'
    }
    $wsl = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host 'Trying WSL (openssl passwd -6)...' -ForegroundColor Cyan
        # Invoke via the resolved path (not a bare 'wsl.exe' literal) so the captured stdout clearly
        # lands in $result and never in the function's return stream - same pattern as $ossl above.
        $result = & $wsl.Source -e openssl passwd -6
        $hash = ($result | Where-Object { $_ -match '^\$6\$' } | Select-Object -First 1)
        if ($hash) { return $hash.Trim() }
        Write-Warning 'WSL did not return a $6$ hash.'
    }
    Write-Warning @'
No local way to generate a SHA-512 crypt hash was found.
Generate one elsewhere and paste it below, e.g. on any Linux box (or the Ubuntu live session):
    openssl passwd -6
    mkpasswd --method=SHA-512      # from the 'whois' package
'@
    $pasted = Read-Host 'Paste the $6$... hash'
    if ($pasted -notmatch '^\$6\$') { throw "That does not look like a SHA-512 crypt hash (must start with `$6`$)." }
    return $pasted.Trim()
}

# YAML single-quoted scalar: wrap and double any embedded single quotes.
function ConvertTo-YamlSingleQuoted {
    param([string]$Text)
    return "'" + ($Text -replace "'", "''") + "'"
}

# =====================================================================================
#  Resolve paths
# =====================================================================================
$repo = Split-Path $PSScriptRoot -Parent
if (-not $KeyDir)   { $KeyDir   = Join-Path $repo 'config\ssh\ubuntu' }
if (-not $Template) { $Template = Join-Path $PSScriptRoot 'user-data.sample' }
if (-not $OutFile)  { $OutFile  = Join-Path $PSScriptRoot 'user-data' }

if (-not (Test-Path $Template)) { throw "Template not found: $Template" }
if (-not (Test-Path $KeyDir))   { throw "Key folder not found: $KeyDir" }
if ((Test-Path $OutFile) -and -not $Force) {
    throw "$OutFile already exists. Re-run with -Force to overwrite (it holds your current secrets)."
}

Write-Host "===== Generate Ubuntu user-data (v$ScriptVersion) =====" -ForegroundColor Green
Write-Host "Template : $Template"
Write-Host "Key dir  : $KeyDir"
Write-Host "Output   : $OutFile"

# =====================================================================================
#  1. Discover key pairs
# =====================================================================================
# A pair is any 'id_*' private file (NOT .pub, NOT .sample) that has a matching '<name>.pub'.
$privates = @(Get-ChildItem -Path $KeyDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'id_*' -and $_.Name -notlike '*.pub' -and $_.Name -notlike '*.sample' })

$pairs = @()
foreach ($p in $privates) {
    $pubPath = Join-Path $KeyDir ($p.Name + '.pub')
    if (Test-Path $pubPath) {
        $pairs += [pscustomobject]@{ Id = $p.Name; Private = $p.FullName; Public = $pubPath }
    } else {
        Write-Warning "  '$($p.Name)' has no matching '$($p.Name).pub' - skipping."
    }
}
if ($pairs.Count -eq 0) {
    throw "No usable id_* key pairs in $KeyDir. Copy a *.sample to its real name and paste your key (private + <name>.pub)."
}

if (-not $KeyId) {
    Write-Host "`nKey pairs found:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $pairs.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $pairs[$i].Id) }
    $sel = Read-Host "`nSelect the key ID (number, or type the name e.g. id_rwtgit)"
    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -lt 0 -or $idx -ge $pairs.Count) { throw "Selection out of range: $sel" }
        $KeyId = $pairs[$idx].Id
    } else {
        $KeyId = $sel.Trim()
    }
}

$pair = $pairs | Where-Object { $_.Id -eq $KeyId } | Select-Object -First 1
if (-not $pair) { throw "Key id '$KeyId' not found. Available: $(($pairs.Id) -join ', ')" }
Write-Host "Using key pair: $($pair.Id)" -ForegroundColor Green

# Sanity: the private file should look like a private key, and must NOT be a leftover placeholder.
$privLines = @(Get-Content -LiteralPath $pair.Private)
if (($privLines -join "`n") -notmatch 'BEGIN [A-Z ]*PRIVATE KEY') {
    Write-Warning "  $($pair.Id) does not contain a 'BEGIN ... PRIVATE KEY' header - is it really a private key?"
}
if (($privLines -join "`n") -match 'REPLACE_WITH_YOUR') {
    throw "$($pair.Id) still contains placeholder text (REPLACE_WITH_YOUR...). Paste your real key first."
}
$pubText = (Get-Content -LiteralPath $pair.Public -Raw).Trim()
if ($pubText -match 'REPLACE_WITH_YOUR') { throw "$($pair.Id).pub still contains placeholder text. Paste your real public key first." }

# =====================================================================================
#  2. authorized_keys (multi-line, inbound)
# =====================================================================================
$akPath = Join-Path $KeyDir 'authorized_keys'
if (-not (Test-Path $akPath)) {
    throw "authorized_keys not found: $akPath  (copy authorized_keys.sample to authorized_keys and paste your PUBLIC login keys, one per line)."
}
$akLines = @(Get-Content -LiteralPath $akPath |
    Where-Object { $_.Trim().Length -gt 0 -and $_.Trim() -notlike '#*' } |
    ForEach-Object { $_.Trim() })
if ($akLines.Count -eq 0) { throw "$akPath contains no key lines (only blanks/comments)." }
if ($akLines -match 'REPLACE_WITH_YOUR') { throw "$akPath still contains placeholder keys. Paste your real public keys first." }
foreach ($k in $akLines) {
    if ($k -match 'PRIVATE KEY') { throw "$akPath appears to contain a PRIVATE key. Only public keys belong there." }
}
Write-Host "authorized_keys: $($akLines.Count) inbound key(s)" -ForegroundColor Green

# =====================================================================================
#  3. Password hash
# =====================================================================================
if (-not $PasswordHash) { $PasswordHash = New-Sha512CryptHash }
if ($PasswordHash -notmatch '^\$6\$') { throw "PasswordHash must be a SHA-512 crypt hash starting with `$6`$." }

# =====================================================================================
#  4. Substitute (indentation-aware for the multi-line blocks)
# =====================================================================================
$outLines = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-Content -LiteralPath $Template)) {

    if ($line -match '__PRIVATE_KEY__') {
        # Expand to the key's own lines, each at the sentinel's indentation (YAML literal block).
        $indent = [regex]::Match($line, '^\s*').Value
        foreach ($k in $privLines) { $outLines.Add($indent + $k) }
        continue
    }
    if ($line -match '__AUTHORIZED_KEYS__') {
        # Expand the single list item into one item per key, at the sentinel's indentation.
        $indent = [regex]::Match($line, '^\s*').Value
        foreach ($k in $akLines) { $outLines.Add($indent + '- ' + (ConvertTo-YamlSingleQuoted -Text $k)) }
        continue
    }

    # Single-line sentinels: plain inline replacement.
    $new = $line
    if ($new -match '__PUBLIC_KEY__')   { $new = $new -replace "'__PUBLIC_KEY__'", (ConvertTo-YamlSingleQuoted -Text $pubText) }
    if ($new -match '__PASSWORD_HASH__'){ $new = $new.Replace('__PASSWORD_HASH__', $PasswordHash) }
    if ($new -match '__KEY_ID__')       { $new = $new.Replace('__KEY_ID__', $pair.Id) }
    $outLines.Add($new)
}

# Strip the "THIS IS THE COMMITTED SAMPLE" banner - the output is the real file, not the sample.
$text = ($outLines -join "`n")
$text = $text -replace '(?ms)^# ={10,}\r?\n# \*\*\* THIS IS THE COMMITTED SAMPLE.*?^# ={10,}\r?\n', ''

Set-Content -Path $OutFile -Value $text -Encoding UTF8
Write-Host "`nWrote: $OutFile" -ForegroundColor Green

# =====================================================================================
#  5. Post-checks
# =====================================================================================
$written = Get-Content -LiteralPath $OutFile -Raw
$leftovers = [regex]::Matches($written, '__[A-Z_]+__') | ForEach-Object { $_.Value } | Sort-Object -Unique
if ($leftovers) { Write-Warning "Unsubstituted sentinels remain: $($leftovers -join ', ')" }
else { Write-Host 'All sentinels substituted.' -ForegroundColor Green }

# The Ventoy tokens MUST survive - they are expanded at boot, not here.
foreach ($tok in @('$$HOSTNAME$$', '$$LINUXREALNAME$$', '$$LINUXUSER$$')) {
    if ($written -notmatch [regex]::Escape($tok)) { Write-Warning "Ventoy token $tok is missing from the output." }
}

Write-Host @"

NEXT STEPS
  1. Set 'timezone' in $OutFile if you have not already.
  2. Copy it to the Ventoy stick as:  \ventoy\autoinstall\user-data
     (with linux\meta-data beside it as \ventoy\autoinstall\meta-data)
  3. This file contains a PRIVATE KEY and a password hash. It is .gitignore'd - keep it that way.
"@ -ForegroundColor Yellow
