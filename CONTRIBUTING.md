# Working on this repo (and working with an AI assistant on it)

## The hard constraint

The AI assistant that authored much of this code **cannot execute PowerShell**. It has a Linux
sandbox with no `pwsh` and no way to install one. That means:

> **No script it hands you has ever been parsed by a PowerShell parser.**

Brace-counting, eyeballing, and "looks right" are not verification. Several real bugs shipped
because they were presented as verified when they were not:

| Bug | Why a heuristic missed it |
|---|---|
| Comment swallowed a closing `}` | brace counters count braces inside comments |
| `try {} catch {} \| Out-File` | not a syntax-tree-aware check |
| Double `Stop-Transcript` turned `exit 0` into `1` | semantic, not syntactic |
| `& dism.exe` polluted a function's return value | semantic |
| `return ,$x` + `@()` nested the array | semantic |

## Therefore: run the gate. Always.

```powershell
.\tests\Invoke-QualityGate.ps1 -InstallAnalyzer   # first time
.\tests\Invoke-QualityGate.ps1                    # every time after
```

It does the three things the assistant cannot:
1. **Real AST parse** of every `.ps1` (catches all syntax errors).
2. **PSScriptAnalyzer** (approved verbs, bad practice).
3. **Project rules** for the specific footguns this codebase has actually hit.

Make it automatic:

```powershell
.\tests\Install-GitHook.ps1     # blocks any commit that fails the gate
```

## Protocol when accepting AI-authored changes

Require the assistant to state, per change:

- **VERIFIED** — what was actually checked, and by what means (e.g. "fetched the live HTML and
  matched the parser against it", "ran the regex against a real sample").
- **UNVERIFIED** — what is an assumption (e.g. "not parsed by PowerShell", "cmdlet output shape
  assumed, not confirmed").

If a change is labelled UNVERIFIED, it does not go near a production host until the gate passes.

Prefer **small diffs with a stated verification method** over large "hardened" rewrites. Most of
the pain in this project came from confident-sounding bulk edits that had never been parsed.

## Before touching a live server

1. Run the gate.
2. VM snapshot (memory-less).
3. Run the change against a lab host if one exists.
4. Keep the snapshot until the change is verified and the host has rebooted clean.
