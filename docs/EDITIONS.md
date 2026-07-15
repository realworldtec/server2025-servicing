# Edition selection — `$PRODUCTS.DefaultEditions` and the resolver

The product profiles live in **`config/Products.psd1`** — a data file, *not* the script. You
should never need to open `Slipstream-WindowsMedia.ps1` to change which media gets built, where
it lives, or which editions get patched.

`.psd1` is loaded with `Import-PowerShellDataFile`, which parses in **restricted language** mode:
literals, hashtables, arrays, `$true`/`$false`/`$null`. No commands, no calls, no variables. A
config file cannot execute anything, and a typo in a config value cannot corrupt the build logic.

A wrong edit here is expensive — it is not a crash, it is a four-hour build that patches the wrong
editions, or a silent no-op. So the **quality gate validates this file** (stage 4), and the
slipstream re-validates it at startup: a bad profile fails in **seconds**, before anything mounts.

Everything below is read out of the code as it stands (slipstream v3.2.0), not from memory.

---

## 1. Where it lives

```
config/Products.psd1      <- edit THIS
scripts/Slipstream-WindowsMedia.ps1   <- never needs editing for config
```

`$PRODUCTS` is loaded from that file and is the **only** place product-specific configuration is
allowed to exist — the quality gate (Rule D) fails the build if a product literal leaks into the
script. Each profile carries:

| Field | Meaning |
|---|---|
| `Label` | ISO **volume label** (what Explorer shows when the ISO is mounted). |
| `IsoPrefix` | Output **filename** prefix. **`Server2025_Patched` is load-bearing** — the detector globs it. |
| `BasePath` | Working + output directory. |
| `SourceISO` | RTM media. |
| **`DefaultEditions`** | **The subject of this document.** |
| `PreferRegex` | Disambiguates Server vs client packages in the Catalog. `$null` for Win11. |
| `Lcu*/SafeOs*/Setup*/DotNet*` | Catalog query + include regexes. |

## 2. What `DefaultEditions` actually does

It is the edition set used **when the caller names no editions at all**. That is the case for the
scheduled task, which invokes the slipstream with no selection switches.

In `config/Products.psd1`:

```powershell
'Server2025' = @{
    DefaultEditions = $null      # $null => ALL editions
}
'Win11-25H2' = @{
    DefaultEditions = @(
        'Windows 11 Enterprise'               # index 3
        'Windows 11 Pro'                      # index 5
        'Windows 11 Pro for Workstations'     # index 9
    )
}
```

Two rules that are easy to get wrong:

**`$null` means ALL editions, not "none".** Server 2025 relies on this: the monthly automated build
must patch all four editions, because the resulting `install.wim` doubles as the
`DISM /RestoreHealth /Source` for any Server 2025 host (see `docs/RUNBOOK.md`). If you set
`DefaultEditions` on the Server profile to a subset, **the monthly repair source stops covering
the editions you dropped** — and you will not find out until a repair fails.

**Names are matched EXACTLY (`-eq`), not with wildcards.** This is deliberate and it is *not* the
same rule as `-EditionName`:

| Mechanism | Match | Wildcards? |
|---|---|---|
| `DefaultEditions` (profile) | `-eq` — exact, full string | **No** |
| `-EditionName` (parameter) | `-like` — pattern | **Yes** |

So `'Windows 11 Pro'` in `DefaultEditions` selects **only** Pro. It does **not** drag in
*Pro N*, *Pro Education*, or *Pro for Workstations*. Put `'*Pro*'` in `DefaultEditions` and it
matches **nothing at all** — because `-eq '*Pro*'` is a literal comparison.

A name that isn't in the media is a **warning, not an error**:

```
WARNING: Product default edition 'Windows 11 Pro N' is not present in this media - skipped. (Media layout changed?)
```

If *every* name misses, the selection is empty and the run throws
`Edition selection matched nothing. Run with -ListEditions to see what is available.` — which is
the right outcome, and it happens in seconds, not hours.

## 3. Resolution order (the whole algorithm)

`Resolve-EditionSelection` is the single resolver used by **both** `-DryRun` and the real build —
so what the dry run prints is, by construction, what the build does.

```
1. -AllEditions                    -> every edition in the media
2. -Index / -EditionName           -> the UNION of both (if either is given)
3. $PRODUCTS.DefaultEditions       -> exact-name match  (only if 1 and 2 are absent)
4. (no default configured, $null)  -> every edition in the media

then, subtracted from whatever the above produced:

5. -ExcludeEditionName <patterns>  -> -notlike
6. -ExcludeN                       -> drops 'N' editions
```

Note step 2: **`-Index` and `-EditionName` are a union, and they completely replace
`DefaultEditions`.** Passing `-Index 3` does not mean "the defaults, plus index 3" — it means
"index 3, and nothing else".

### `-ExcludeN` is not a suffix check

```powershell
$_.ImageName -cnotmatch '\bN\b'
```

A **standalone, case-sensitive `N` token**. It has to be, because the N is not always at the end:

```
Windows 11 Pro N for Workstations      <- N in the middle
Windows 11 Pro for Workstations        <- must survive
```

A naive `-notlike '*N*'` would kill both (and `-notlike '* N'` would keep the first). The
case-sensitive `-cnotmatch` also stops a lowercase `n` word ever matching.

## 4. Verified media layouts

Enumerated from the actual ISOs on 2026-07-13:

**Server 2025 RTM — 4 editions**

```
1 Standard                        3 Datacenter
2 Standard (Desktop Experience)   4 Datacenter (Desktop Experience)
```

**Windows 11 24H2 and 25H2 — 10 editions, identical layout in both**

```
 1 Education                2 Education N
 3 Enterprise               4 Enterprise N
 5 Pro                      6 Pro N
 7 Pro Education            8 Pro Education N
 9 Pro for Workstations    10 Pro N for Workstations
```

Do not trust these numbers forever. **Always confirm against the media you actually have:**

```powershell
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -ListEditions
```

## 5. Selecting is not the same as trimming

These are **two independent decisions**, and conflating them is the most common misunderstanding:

| | `install.wim` contains | Unselected editions |
|---|---|---|
| selection only | **all** editions | shipped **UNPATCHED** (still RTM) |
| selection + `-TrimMedia` | **only** the selected editions | not shipped at all |

Without trimming you get **mixed-build media** — some editions patched, some at RTM, in one
ISO. The script warns about this loudly. It is occasionally what you want; usually it is not.

**`TrimByDefault` decides when you don't.** Because a subset build almost always wants trimmed
output, each profile carries a `TrimByDefault` flag. When you pass **neither** `-TrimMedia` nor
`-NoTrim`, that flag decides. The Win11 profiles set it `$true`; `Server2025` sets it `$false`
(its `DefaultEditions` is `$null` = all editions, so there is nothing to trim). Effective trim:

```
-TrimMedia   -> trim        (explicit, wins)
-NoTrim      -> full media  (explicit, wins)
neither      -> the profile's TrimByDefault
```

This is why the July build that omitted `-TrimMedia` still needs the switch *removed only if you
want full media* — with `TrimByDefault = $true`, a bare `-Product Win11-25H2` now trims by
default. The startup banner prints `Trim media : YES/no` so you can see the decision before the
build commits to it.

`-TrimMedia` **renumbers** the surviving editions (3, 5, 9 → 1, 2, 3). Anything that picks an
edition **by index** must be updated: `autounattend.xml` (`/IMAGE/INDEX`), MDT/SCCM task
sequences, WDS, `dism /apply-image /index:N`. Every build writes
`logs\EditionMap_<stamp>.json` with the source→output map. Interactive Setup is unaffected — it
enumerates editions at run time.

## 6. Things that key off the *first selected* index

**WinRE** is serviced **once**, from `$selIdx[0]` — the **lowest-numbered selected** edition — and
the resulting `winre.wim` is copied into **every** serviced edition. WinRE is edition-agnostic, so
this is correct; but it means the first selected edition is the one whose recovery image is
actually built. (This was previously hardcoded to index 1, which was wrong the moment index 1
stopped being a selected edition.)

**`boot.wim` (WinPE/Setup) is a separate file** and is **not** affected by any of this — it is not
inside `install.wim` and it is not renumbered. Trimming cannot break the ISO's boot chain.

## 7. Editing `DefaultEditions` safely

```powershell
# 0. What products are defined?
.\scripts\Slipstream-WindowsMedia.ps1 -ListProducts

# 1. See what is actually in the media.
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -ListEditions

# 2. Edit DefaultEditions in config\Products.psd1  (NOT the script).
#    Exact names, copied verbatim from the -ListEditions output. One per line.

# 3. Validate the config - seconds, catches wildcards / missing fields / bad syntax.
.\tests\Invoke-QualityGate.ps1

# 4. Prove the edit does what you think - BEFORE committing four hours.
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -TrimMedia -DryRun

# 5. Build.
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -TrimMedia
```

Adding a whole new product (say Win11 26H1) is now a **config-only** change: copy a profile block,
change the strings. No `ValidateSet` to update, no script edit — `-Product` is validated against
whatever the config defines, and an unknown name prints the list of valid ones.

`-DryRun` mounts the source ISO read-only, resolves the selection through the *same* resolver the
build uses, prints the source→output index map, and exits. It downloads nothing and services
nothing. **There is no reason to ever edit this table without running it.**

### The already-built guard understands your edit

The build manifest (`<iso>.json`) records a **`SelectionKey`** — a fingerprint of what was asked
for, including `DefaultEditions` when the default path was taken. The ALREADY-BUILT guard only
treats a prior build as a match when the key is identical.

So: **edit `DefaultEditions`, and the next run rebuilds** rather than saying "nothing to do". Ask
for a different edition set explicitly, and it builds that too. Ask for exactly what you built
last time, and it no-ops in seconds. (Before this existed, hand-editing the defaults would have
been silently ignored — the guard would have matched the manifest from the *old* set.)

## 8. Failure modes, and what they look like

| What you did | What happens |
|---|---|
| `DefaultEditions = @('*Pro*')` | **Rejected by the quality gate and at startup** — names are matched with `-eq`, so a wildcard matches nothing. (It used to just silently select nothing.) |
| Misspelled a name | Warning: *"Product default edition '…' is not present in this media - skipped."* Build proceeds with the rest. **Check the dry run.** |
| Set a subset on `Server2025` | Monthly build stops covering the dropped editions — and that ISO is the **repair source**. No error. This is the dangerous one. |
| Subset without `-TrimMedia` | Mixed-build media: unselected editions ship at RTM. Loud warning. |
| `-Index 3` expecting defaults + 3 | You get **only** index 3. `-Index`/`-EditionName` replace the defaults, they do not extend them. |
| `-Index 99` | Warning: index does not exist. (It used to be silent.) |
| Edited defaults, run says ALREADY BUILT | Should no longer happen — `SelectionKey` covers it. If it does, `-Rebuild` forces the build and tells me the key logic is wrong. |
