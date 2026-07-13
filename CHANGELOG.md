# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Nothing yet.

## [3.2.0] - 2026-07-13 — product profiles moved out of the script

### Changed — BREAKING (deployment)
- **`$PRODUCTS` is now `config/Products.psd1`.** The profiles used to live inside
  `Slipstream-WindowsMedia.ps1`, which meant that changing which editions get patched — the one
  thing an operator routinely does — required **hand-editing executable code**. A typo in a config
  value could take out the build logic, a merge conflict in the table landed in the same file as
  the servicing steps, and the config was invisible to anyone not reading 1,300 lines of
  PowerShell.

  The file is loaded with `Import-PowerShellDataFile`, which parses in **restricted-language**
  mode: literals, hashtables, arrays, `$true`/`$false`/`$null`. **No commands, no calls, no
  variables.** A config file cannot execute anything — which is the point.

  **Deployment:** `config/Products.psd1` must be present on the build host. The slipstream throws
  a clear error naming the expected path if it is not. `-ConfigPath` overrides the location.

### Added
- **`-ListProducts`** — prints every product the config defines (source ISO, base path, ISO
  prefix, default editions) and exits.
- **Startup validation of every profile, not just the one being built.** Missing/empty required
  fields, non-hashtable profiles, and **wildcards in `DefaultEditions`** are rejected in seconds,
  before anything mounts. The wildcard check matters: names are matched with `-eq`, so `'*Pro*'`
  in the profile silently matched **nothing** — now it is a hard, explanatory error.
- **Quality gate stage 4 (`Invoke-QualityGate.ps1` → v1.3.0): product-config validation.** Same
  checks, plus an assertion that **`Server2025.IsoPrefix` is still `Server2025_Patched`** — the
  detector globs that prefix to archive the monthly build, so renaming it would leave the
  scheduled task "succeeding" while archiving nothing.

### Removed
- **`ValidateSet` on `-Product`.** A hardcoded list in the script would go stale the moment
  someone added a product to the config. `-Product` is now validated at runtime against whatever
  the config defines, and an unknown name prints the valid ones. Adding a new product (e.g. Win11
  26H1) is now a **config-only change** — copy a profile block, edit the strings, no script edit.

## [3.1.0] - 2026-07-13

### Added
- **`docs/EDITIONS.md`** — the missing documentation for `$PRODUCTS.DefaultEditions` and the
  edition resolver. This is the table an operator actually hand-edits, and it had sharp,
  undocumented edges: `$null` means **all** editions (Server 2025 depends on this — its
  `install.wim` is also the `RestoreHealth` repair source, so quietly subsetting it breaks
  repairs, not builds); `DefaultEditions` matches names **exactly** while `-EditionName` matches
  with **wildcards**, so `'*Pro*'` in the profile matches *nothing*; and `-Index`/`-EditionName`
  **replace** the defaults rather than extending them. Covers the resolution order, `-ExcludeN`'s
  standalone-token rule, selection-vs-trim, WinRE sourcing from the first selected index, the
  verified media layouts, and a failure-mode table.
- **`SelectionKey` in the build manifest.** A fingerprint of what was *requested* (switches, plus
  `DefaultEditions` when the default path was taken).

### Fixed
- **Hand-editing `DefaultEditions` would have been silently ignored.** The ALREADY-BUILT guard
  keyed only on build + trim, so after editing the defaults the next run would match the manifest
  from the **old** edition set and report "ALREADY BUILT — nothing to do". The most likely edit an
  operator makes, doing nothing, confidently. The guard now compares `SelectionKey`, so changing
  the defaults (or asking for a different set explicitly) correctly forces a build. This also
  replaces v3.0.0's cruder fix, which simply disabled the guard whenever any selection switch was
  passed — re-running the *same* explicit command now correctly no-ops instead of rebuilding.
- **`-Index` was silent about indexes that don't exist.** `-Index 3,99` patched one edition and
  said nothing; `-EditionName` warned but `-Index` did not. It now warns.

## [3.0.0] - 2026-07-13 — full logic review

Every script was read line-by-line for **logic** defects (the quality gate only catches syntax
and known footguns). This is the result. Several of these were latent time bombs; two would have
silently shipped month-old media with green logs. Major bump: behaviour changes, and the
scheduled task must be re-registered.

### Fixed — CRITICAL

- **`Slipstream-WindowsMedia.ps1` (→ v3.0.0): stale CU packages were reused forever, silently.**
  Nothing ever cleaned `\packages`, and the script skipped the Catalog entirely whenever every
  package folder was non-empty (*"All update packages already staged"*). So the month after a
  successful build: the detector spots a new LCU → launches the slipstream → the slipstream goes
  **offline**, reuses **last month's** `.msu`, and builds the wrong month — while the detector
  stamps `last-built.json` with the **new** build. The new LCU is then marked built and **never
  built again**. With v2.2.0's guard it got worse: instant "ALREADY BUILT", exit 0, no ISO at all.
  Now: the Catalog is **always** probed, the LCU is **always** identified, and staged packages
  are kept only if they *are* that LCU — otherwise they are purged and re-downloaded.

- **`Slipstream-WindowsMedia.ps1`: the resume marker carried no build identity.** It held a
  timestamp and short-circuited *before* the version check. A run that serviced `install.wim` for
  LCU **A** and then died at `oscdimg` left a marker that made the next run — now targeting LCU
  **B** — skip `install.wim` servicing entirely. Result: an ISO whose `install.wim` is a month
  old while `boot.wim`/Setup carry the new LCU. Exit 0. The marker now records the **build**, and
  is ignored (and deleted) when the target differs.

- **`Slipstream-WindowsMedia.ps1`: verification printed the build and never checked it.** The one
  step that could catch every silent-bad-ISO path did nothing with its result. It is now a
  **hard assertion**: the shipped `install.wim` must carry a build ≥ the target LCU, or the run
  **throws** — *before* the manifest is written, so a bad build can never poison the ALREADY-BUILT
  guard and the detector will not stamp state. It also now versions **every** shipped index:
  reading index 1 alone reported the *RTM* build on any non-trimmed subset build.

- **`Repair-Server2025Store.ps1` (→ v1.1.0): always exited 0, even on total failure.** There was
  no `exit` statement in the script at all, and the `catch` swallowed the error — so a failed
  `RestoreHealth`, a pending-reboot abort, "no source found", and a FATAL crash **all reported
  success**. Any wrapper gating on `$LASTEXITCODE` recorded "repaired" for a store that was never
  touched. Now returns 1 on any failure.

- **`Check-Packages.ps1` (→ v1.1.0): reported "all payloads present" for an EMPTY component
  folder.** The no-`-File` branch only tested that the *directory* existed and never touched
  `$allPresent`. That is exactly the false green this tool exists to prevent — `0x800f0915` is a
  missing **payload**, not a missing folder — and it would send you into a multi-hour DISM run
  against a source that cannot repair anything.

### Fixed — HIGH

- **`Watch-Server2025Updates.ps1` (→ v1.2.0) archived an ISO it never verified.** The only check
  was "some ISO exists in the folder". It now requires the slipstream's manifest, and refuses to
  archive or stamp state unless `ActualBuild` ≥ the build it detected.
- **`Slipstream…`: `$Script:LastPickedKB/Build` were clobbered by every later Catalog search.**
  The SafeOS DU, Setup DU and .NET CU searches each overwrote the shared variable, so downstream
  consumers read the **.NET CU's** KB, not the LCU's. Split into `Select-CatalogUpdate` (pick,
  no side effects) + `Save-CatalogPick`; only the LCU call site sets `$Script:TargetKB/TargetBuild`.
- **`Slipstream…`: a stale `.target.json` was trusted blindly.** Hand-staging a newer LCU while an
  old `.target.json` remained would make the guard "already build" a build that never happened.
  The restored identity is now corroborated against the `.msu` files actually on disk.
- **`Slipstream…`: the ALREADY-BUILT guard ignored the edition selection**, so asking for a
  Pro-only ISO right after building an Enterprise-only ISO of the same LCU silently produced
  nothing. It now stands down whenever an explicit selection switch is passed. **`-Rebuild` now
  also invalidates the resume marker** — previously it bypassed only the guard, so the run reused
  the old edition set and silently ignored `-TrimMedia`/`-EditionName`.
- **`Slipstream…`: the resume marker lived inside `\newMedia`** and was deleted just before
  `oscdimg`. An oscdimg or verification failure therefore threw away a fully-serviced
  `install.wim` and cost a **full 4-hour re-service**. It now lives in `$BasePath` and survives.

### Fixed — MEDIUM

- **`-KeepLast 0` deleted every archived ISO, including the one just copied** (`Select-Object
  -Skip 0` skips nothing), then stamped state as a successful build. Now `[ValidateRange(1,999)]`
  in both the detector and the registrar.
- **`Watch…`: `-MonthlyOnly` used exact date equality** against the Catalog's "Last Updated"
  column — which is a *re-publish* date and has been observed a day off. One day of drift meant
  the month's security media was skipped, and because state was never stamped, it skipped again
  every single day thereafter. Now a 7-day patch-Tuesday **window**.
- **`Watch…`: a broken Catalog parser was a permanent, silent no-op.** `exit 0` every day forever,
  green task history, no media. Now counts consecutive misses and **exits 2** after three.
- **`Watch…`** archived the build log from the wrong directory (the slipstream writes to
  `<BasePath>\logs`, not the detector's `-LogDir`); now also archives the manifest beside the ISO
  and prunes orphaned manifests. `-File` added to all `Get-ChildItem` globs.
- **`Register-SlipstreamSchedule.ps1` (→ v1.3.0):** a trailing backslash in any path argument
  (`-ShareRoot 'D:\PatchedImages\'`) produced `..."D:\PatchedImages\"` — `CommandLineToArgvW`
  reads `\"` as an escaped quote, so the quoted region never closed and every later parameter was
  swallowed. The task registered cleanly and misbehaved at 02:00. Paths are now `TrimEnd('\')`ed.
- **`Register…`:** the hard-coded `-SourceISO` default made the "omit it" path unreachable and
  **refused to register the task at all** on any host without that exact ISO path. Now defaults to
  empty. `-RunAsUser 'NT AUTHORITY\SYSTEM'` no longer prompts for an impossible password.
  `$PSScriptRoot` replaces `$MyInvocation.MyCommand.Path`.
- **`Check-Packages…`:** `-Filter` matched 8.3 short names (`*.mof` matches `payload.mofdata` via
  `PAYLOA~1.MOF`) — a **false FOUND** in a go/no-go gate. Now uses `-like`. `Dismount-WindowsImage`
  in `finally` is guarded so a locked mount can no longer flip a clean run to exit 1.
- **`Slipstream…`:** Catalog pick now tie-breaks on KB number within a month. Previously a month
  containing both an out-of-band CU and the Patch-Tuesday LCU was resolved by `Sort-Object`
  stability — i.e. arbitrarily — so it could spend four hours slipstreaming the wrong CU.
- **`Slipstream…`:** the final `Stop-Transcript` was unguarded, under `ErrorActionPreference=Stop`
  with a `trap` that exits 1 — a throw there would have turned a good 4-hour build into a failure,
  and the detector would have rebuilt it the next day. Guarded; explicit `exit 0` added.

## [2.1.4] - 2026-07-13

### Fixed
- **BUILD FAILURE: `0x80070228` — "An error occurred applying the Unattend.xml file from the
  .msu package"** when servicing `install.wim`. `Slipstream-WindowsMedia.ps1` (→ v2.1.4) passed
  the **CU folder** to `Add-WindowsPackage -PackagePath`, on the belief that this let DISM
  "auto-discover" the checkpoint CU. That belief was wrong, and it is the opposite of what
  Microsoft documents.

  Microsoft's method
  ([catalog-checkpoint-cumulative-updates](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates),
  step 3) is: put the target LCU **and all prior checkpoint CUs** in one folder with no other
  `.msu`, then *"run `DISM /add-package` with the **latest `.msu` file as the sole target**."*
  DISM discovers the checkpoints sitting **beside** the target and applies them in order, in one
  go. Naming the folder instead makes DISM enumerate and apply **each** `.msu` explicitly — and
  applying a checkpoint MSU explicitly fails with `0x80070228` / Win32 `552` ("The passed ACL did
  not contain the minimum required information").

  This has been broken for every LCU since **2025-05** and is confirmed by others against the
  identical file (`windows11.0-kb5043080-x64_9534496…msu`) in
  [MS Q&A 3855149](https://learn.microsoft.com/en-us/answers/questions/3855149/check-please-on-windows11-0-kb5043080-x64-95344967).
  It surfaced here on the Win11-25H2 build of 2026-07-12 (KB5094126 + checkpoint KB5043080) —
  **~30 minutes into the run**, after WinRE had already been serviced.

  `$TARGET_LCU_FILE` is now the sole `-PackagePath` target for **all three** images. The
  checkpoint is still downloaded and must still be present in `$CU_FOLDER` — it is required,
  just never named. `$CU_FOLDER` still contains *only* the LCU + checkpoints (Setup DU, SafeOS DU
  and the .NET CU live in their own folders), which satisfies Microsoft's step 1.

### Added
- **Quality gate Rule E** (`tests/Invoke-QualityGate.ps1` → v1.2.0): flags
  `Add-WindowsPackage -PackagePath <$*_FOLDER / $*_DIR>`. Checkpoint CUs must be *discovered*,
  never applied explicitly.

### Fixed (quality gate — false positives in v1.1.0)
- **Rule E** matched on the substring `PATH` in the *variable name*, flagging
  `$SAFE_OS_DU_PATH` and `$DOTNET_CU_PATH` — which are single `.msu`/`.cab` **files** and are
  correct as `-PackagePath` targets. Now only a variable whose name **ends** in `_FOLDER` or
  `_DIR` trips it.
- **Rule D** flagged a product name inside a `Write-Output` usage hint. A product literal in
  **console text** is fine; only a literal in a **value** can misconfigure another `-Product`.
  Literals whose enclosing command is a `Write-*` are now ignored.

## [2.1.3] - 2026-07-13

### Fixed
- **Output ISO filename was hardcoded to the Server product.** `Slipstream-WindowsMedia.ps1`
  (→ v2.1.3) built the output path as `"Server2025_Patched_{0}.iso"` regardless of `-Product`,
  so a Win11-25H2 build produced
  `D:\Win11_25H2_Patching\Server2025_Patched_<stamp>.iso` — a correctly-built ISO with a
  misleading name (the *volume label* was right; only the filename lied). Caught by a `-DryRun`.
  The name is now derived from a new **`IsoPrefix`** field on each `$PRODUCTS` profile:

  | Product      | Output ISO |
  |--------------|------------|
  | `Server2025` | `Server2025_Patched_<stamp>.iso`  *(unchanged — see below)* |
  | `Win11-25H2` | `Win11_25H2_Patched_<stamp>.iso` |
  | `Win11-24H2` | `Win11_24H2_Patched_<stamp>.iso` |

  **`Server2025`'s prefix is load-bearing and must not change:**
  `Watch-Server2025Updates.ps1` locates and archives the finished build by globbing
  `Server2025_Patched_*.iso`. Renaming it would silently break the scheduled task (build
  succeeds, archive finds nothing). A comment on the profile records this coupling. A future
  Win11 detector must glob its own product's `IsoPrefix`.

### Removed
- **`scripts/Slipstream-Server2025.ps1`** — retired in 2.1.0 but never actually deleted, and
  `README.md` / `docs/RUNBOOK.md` still told you to run it. It carried the old hardcoded ISO
  name and none of the edition-selection work. Deleted; both docs now point at
  `Slipstream-WindowsMedia.ps1 -Product Server2025`.

### Docs
- README: documented edition selection/trim, the `-ListEditions` → `-DryRun` → build habit,
  and — importantly — that **`-TrimMedia` renumbers `install.wim`**, so any *index-based*
  consumer (`autounattend.xml` `/IMAGE/INDEX`, MDT/SCCM, WDS, `dism /apply-image /index:N`)
  must be updated from `EditionMap_<stamp>.json`. Also recorded that `boot.wim` (WinPE/Setup)
  is a separate file and is **not** affected by the renumbering.

## [2.1.2] - 2026-07-13

### Fixed
- **GATE FAIL (syntax): `Unexpected attribute 'SuppressMessageAttribute'`.** In 2.1.1 the
  suppression attribute was placed **above** `function Get-FileResilient`, which is not a legal
  attribute position in PowerShell. A `SuppressMessageAttribute` must sit **inside** the
  function, attached to the `param()` block. Moved; noted in a comment so it is not repeated.

  Worth recording plainly: this was a **syntax error introduced while trying to silence a linter
  warning** - the AST parse caught it before the script ever ran. Second consecutive release in
  which the quality gate stopped an author defect at the door rather than on a production host.

## [2.1.1] - 2026-07-13

Fixes found by the v1.3.0 quality gate on the v2.1.0 code. The gate caught a bug the author
introduced - which is exactly why it exists.

### Fixed
- **GATE FAIL: `Stop-Transcript` inside a `finally` AND outside it** (the new
  `-ListEditions`/`-DryRun` block). Same class of defect that turned a clean `exit 0` into `1`
  in the detector (see 1.2.4). The `finally` now only dismounts the ISO; the transcript is
  stopped by a single guarded call outside it.
- **`PSReviewUnusedParameter` x5 was a real design smell, not noise.**
  `Resolve-EditionSelection` was reaching up into script scope for `-Index` / `-EditionName` /
  `-ExcludeEditionName` / `-ExcludeN` / `-AllEditions`. It worked (dynamic scoping) but was
  fragile and untestable. The parameters are now packed into an explicit `$SELECTION` contract
  built once and passed to the resolver, so both `-DryRun` and the real pass provably share it.
- **`PSReviewUnusedParameter` on `Get-FileResilient`** is a genuine false positive (PSSA does
  not trace into the scriptblock passed to `Invoke-Retry`). Documented in code with a
  `SuppressMessageAttribute` + justification rather than silently ignored.

Result: a clean gate - AST parse OK, no analyzer warnings, project rules pass.

## [2.1.0] - 2026-07-13

Edition selection was too blunt to trust. Reworked it.

### Fixed
- **`Win11-24H2` default `-SourceISO`** corrected to the real filename:
  `D:\Win11RTM\en-us_windows_11_business_editions_version_24h2_x64_dvd_59a1851e.iso`.
- **Wildcard selection was a trap.** `-EditionName '*Pro*'` silently matched SIX editions
  (Pro, Pro N, Pro Education, Pro Education N, Pro for Workstations, Pro N for Workstations).
  Exact names now behave exactly (`'Windows 11 Pro'` does NOT match `'Windows 11 Pro N'`), and
  wildcards are documented as broad.

### Added
- **`DefaultEditions` in `$PRODUCTS`** - per-product default selection using EXACT ImageNames,
  overridable by `-Index` / `-EditionName`. Verified against the real media:
  - `Server2025`  -> `$null` (all 4; the scheduled task relies on this)
  - `Win11-25H2` / `Win11-24H2` -> Enterprise, Pro, Pro for Workstations
    (both Win11 ISOs share an IDENTICAL index->name layout: 1 Education .. 10 Pro N for Workstations)
- **`-ExcludeEditionName`** - subtract `-like` patterns from the selection, applied last.
  e.g. `-EditionName '*Pro*' -ExcludeEditionName '*Education*'`
- **`-ExcludeN`** - drop the N editions. Matches a **standalone, case-sensitive `N` token**,
  because the N is not always trailing: *"Windows 11 Pro **N** for Workstations"*.
- **`-AllEditions`** - ignore the product default and take everything.
- **`-DryRun`** - resolve the selection against the SOURCE media, print which editions get
  patched AND the resulting output index map, then exit. No download, no servicing. Preview
  before committing to a multi-hour build.

### Changed
- Selection resolved by a single `Resolve-EditionSelection` function used by BOTH `-DryRun` and
  the real servicing pass, so a dry run can never disagree with the build. Resolution order:
  `-AllEditions` -> `-Index`/`-EditionName` (union) -> product `DefaultEditions` -> all;
  then `-ExcludeEditionName` and `-ExcludeN` are subtracted.
- `Show-EditionPlan` prints the full source list with PATCH markers plus the source->output
  index map, and warns on mixed-build media.

## [2.0.0] - 2026-07-13

**BREAKING**: `scripts/Slipstream-Server2025.ps1` is retired and replaced by
**`scripts/Slipstream-WindowsMedia.ps1`** (v2.0.0), a multi-product script.
**Delete the old file and re-register the scheduled task** (its action embeds an absolute path):

```powershell
.\scheduled-task\Register-SlipstreamSchedule.ps1 -KeepLast 12
```

### Added
- **`-Product`** profile table (`Server2025` | `Win11-25H2` | `Win11-24H2`) - the single place
  Catalog naming lives. Per-product defaults for `-SourceISO`, `-BasePath`, `-IsoLabel`.
  VERIFIED against the live Catalog: Server uses *"Microsoft server operating system version
  24H2"*; Windows 11 uses *"Windows 11**,** version 25H2"* (note the comma). `Win11-24H2`
  regexes are tolerant but **UNVERIFIED**.
- **Edition selection**: `-ListEditions` (mount source ISO, print index/name/size, exit -
  downloads nothing), `-Index 3,5,9`, `-EditionName '*Enterprise*'` (union of both).
- **`-TrimMedia`**: output `install.wim` contains ONLY the selected editions. Indexes are
  renumbered 1..N; the source->output map is printed AND written to
  `<LogDir>\EditionMap_<stamp>.json`.
- Without `-TrimMedia`, unselected editions are carried over **UNPATCHED** - the script now
  emits a loud **MIXED-BUILD MEDIA** warning, because such a wim is unsafe as a RestoreHealth
  source for a patched host.

### Fixed
- **WinRE is now sourced from the first SELECTED edition**, not hardcoded index 1. Patching a
  subset that excluded index 1 would previously have serviced WinRE from an edition that was
  never exported.
- **Product-aware preference filter.** The old code unconditionally preferred titles matching
  `server operating system`; on a Windows 11 search that filters out **every** result. Now
  driven by the profile's `PreferRegex` ($null for client media).
- **Resume detection is product-agnostic.** Replaced the hardcoded `10.0.26100.1742` RTM
  baseline (Server-only) with a comparison against the TARGET build parsed from the LCU's
  Catalog title.

### Changed
- `Watch-Server2025Updates.ps1` (-> v1.1.0) and `Register-SlipstreamSchedule.ps1` (-> v1.2.0)
  now point at `Slipstream-WindowsMedia.ps1` and pin it to `-Product Server2025`. The detector's
  own Catalog query remains Server-specific; a Windows 11 detector would be a separate task with
  its own state file (not yet implemented).

### Not verified
- The Windows 11 servicing path has **not been executed** - only parsed. The Catalog strings are
  verified against the live Catalog; the DISM servicing of Win11 media follows the identical
  code path already proven on Server 2025.

## [1.3.1] - 2026-07-13

First release where every script has been **parsed by a real PowerShell parser** (the v1.3.0
quality gate, run on a Windows host). All 7 scripts pass the AST parse and the project rules.

### Changed
- **`scripts/Slipstream-Server2025.ps1`** (-> v1.0.4), **`scripts/Watch-Server2025Updates.ps1`**
  (-> v1.0.6), **`scripts/Repair-Server2025Store.ps1`** (-> v1.0.1) - replaced all 8 empty
  `catch {}` blocks (flagged by `PSAvoidUsingEmptyCatchBlock`) with explicit handlers that state
  *why* the failure is tolerated and surface it via `Write-Verbose` / `Write-Warning`:
  cleanup-trap dismounts, the DownloadDialog debug dump, the locked-CBS.log copy, an unreadable
  state file (now warns and treats the host as never-built), and the guarded `Stop-Transcript`.

  Rationale: a gate that always prints warnings is a gate people stop reading. A **clean
  baseline** means the *next* warning is signal.

### Verified (not assumed)
- `PSReviewUnusedParameter` on `Get-FileResilient` is a **false positive**: `$Url`/`$OutFile`
  are used inside the scriptblock passed to `Invoke-Retry`, which PSScriptAnalyzer does not
  trace into. The scriptblock closes over the defining scope; confirmed by the real build, which
  downloaded KB5094125 and its checkpoint successfully. No change made.

## [1.3.0] - 2026-07-13

Quality tooling. Motivation: the assistant that authored much of this code **cannot execute
PowerShell** (no `pwsh` in its sandbox, package sources blocked). Every script it produced was
therefore shipped *unparsed*, and several real bugs reached production hosts as a result
(a comment swallowing a closing brace; `try/catch` piped into `Out-File`; a double
`Stop-Transcript` silently turning `exit 0` into `1`; native `dism.exe` stdout polluting a
function's return value; `return ,$x` + `@()` nesting an array). Brace-counting was presented as
validation and was not.

The remedy is to move real validation to a machine that has a real parser.

### Added
- **`tests/Invoke-QualityGate.ps1`** (v1.0.0) - three-layer gate:
  1. **AST parse** of every `.ps1` via `[System.Management.Automation.Language.Parser]` - the
     real parser; catches every syntax error a heuristic cannot.
  2. **PSScriptAnalyzer** (`-InstallAnalyzer` bootstraps it).
  3. **Project rules** targeting the exact footguns this codebase has hit: `Stop-Transcript`
     both inside and outside a `finally`; the `return ,$var` comma-wrap idiom; native `*.exe`
     calls inside a function without `| Out-Null` / `| Out-Host`.
  Exit 0 = pass, 1 = fail. Suitable for CI.
- **`tests/Install-GitHook.ps1`** (v1.0.0) - installs a `pre-commit` hook so nothing that fails
  the gate can be committed (`git commit --no-verify` to bypass).
- **`CONTRIBUTING.md`** - documents the constraint and the required VERIFIED / UNVERIFIED
  labelling protocol for AI-authored changes.

## [1.2.4] - 2026-07-13

### Fixed
- **`scripts/Watch-Server2025Updates.ps1`** (-> v1.0.5) - the detector returned **exit code 1**
  on its normal "No new build ... Nothing to do." path, so Task Scheduler reported `0x1`
  (failure) for a perfectly healthy no-op run.

  Cause: the early-exit paths called `Stop-Transcript` and then `exit 0`. In PowerShell, `exit`
  inside a `try` still runs the `finally`, which called `Stop-Transcript` a **second** time. The
  redundant call throws "The host is not currently transcribing", and with
  `$ErrorActionPreference = 'Stop'` a terminating error raised in a `finally` block **overrides
  the script's exit code** - turning `exit 0` into `1`. The transcript had already closed, which
  is why the error never appeared in the log.

  Fix: the `finally` block is now the sole owner of the transcript (guarded with try/catch); the
  early-exit paths just `exit 0`.

### Notes
- The widened retry budget from 1.2.3 proved itself on first contact: three consecutive
  transient "Unable to connect to the remote server" failures, then a successful Catalog poll
  ~2.5 minutes in. The old 4 x 15s budget would have aborted.

## [1.2.3] - 2026-07-13

### Changed
- **`scripts/Watch-Server2025Updates.ps1`** (-> v1.0.4) - widened the Catalog retry budget from
  **4 x 15s (~1 min)** to **8 x 30s (~4 min)**. The endpoint is demonstrably flaky (transient
  "Unable to connect to the remote server"), and its DNS returns AAAA records whose IPv6 path is
  not always routable from a given host. Because a failed poll is non-fatal (exit 0, retry
  tomorrow), a short blip previously cost a full day of detection latency.

### Notes
- Investigated a SYSTEM-context failure on the management host. Root cause was **transient
  network**, not policy: as SYSTEM, DNS/TCP443/HTTPS to the Catalog all succeed; firewall
  `DefaultOutboundAction = NotConfigured` (allow), no proxy (`ProxyEnable=0`, WinHTTP direct),
  no security agent. The `-NoProxy` switch added in 1.2.2 remains available but was not the fix.

## [1.2.2] - 2026-07-13

Proxy handling under the SYSTEM account. Symptom: the detector, running as SYSTEM from the
scheduled task, failed with `Invoke-WebRequest: "Unable to connect to the remote server"` on a
host with **no proxy in the environment**, while the same request worked interactively.

Cause: `[System.Net.WebRequest]::GetSystemWebProxy()` resolves against the **calling account's**
WinINET settings. Under SYSTEM that's `HKU\S-1-5-18`, *not* the interactive user's hive — so a
stale `ProxyEnable`/`ProxyServer` there makes the scripts dial a dead proxy.

### Added
- **`-NoProxy`** switch on **`Slipstream-Server2025.ps1`** (→ v1.0.3),
  **`Watch-Server2025Updates.ps1`** (→ v1.0.3) and **`Register-SlipstreamSchedule.ps1`**
  (→ v1.1.3). Forces `DefaultWebProxy = $null` (direct connection) and skips detection
  entirely. The detector passes it through to the slipstream, and the registration script
  bakes it into the task arguments.

### Fixed
- **`Watch-Server2025Updates.ps1`** now **logs its proxy decision** ("Detected system proxy: X"
  / "No system proxy detected; using a DIRECT connection"). Previously the detector made the
  decision silently, so the log gave no way to tell which branch it took — the Slipstream
  logged this, the detector did not.

## [1.2.1] - 2026-07-13

### Changed
- **`scripts/Slipstream-Server2025.ps1`** (→ v1.0.2) — renamed the internal helper
  `Ensure-SinglePackage` → **`Resolve-SinglePackage`**. `Ensure` is not an approved PowerShell
  verb, so PSScriptAnalyzer (and the VS Code PowerShell extension) flagged it with
  `PSUseApprovedVerbs`. `Resolve` is approved and matches the existing `Resolve-FodSource` /
  `Resolve-InstallWim` / `Resolve-Index` naming. Internal function only — no parameter or
  behaviour change.

Audited every `Verb-Noun` function across the repo; this was the only unapproved verb.

## [1.2.0] - 2026-07-13

Relocated all build-host defaults to a dedicated data volume (`D:`). **Breaking for anyone
relying on the old `C:\Installs\...` defaults** — pass `-SourceISO` / `-BasePath` /
`-ShareRoot` explicitly if your layout differs.

### Changed
- **`scripts/Slipstream-Server2025.ps1`** (→ v1.0.1)
  - `-SourceISO` default: `C:\Installs\Server2025RTM\…` → **`D:\Server2025RTM\…`**
  - `-BasePath`  default: `C:\Installs\Server2025Patching` → **`D:\Server2025Patching`**
- **`scripts/Watch-Server2025Updates.ps1`** (→ v1.0.2)
  - `-OutputDir` default → **`D:\Server2025Patching`**
- **`scheduled-task/Register-SlipstreamSchedule.ps1`** (→ v1.1.2)
  - `-ShareRoot` default → **`D:\PatchedImages`** (no longer mandatory)
  - `-OutputDir` default → **`D:\Server2025Patching`**
  - `-SourceISO` default → **`D:\Server2025RTM\SW_DVD9_…X23-81891.ISO`**
- README / RUNBOOK updated to the `D:` layout.

### Unchanged (deliberately)
- **Repair-side defaults stay on `E:`** (`-ScratchDir E:\DISMscratch`,
  `-LogDir E:\Server2025Repair\logs`, Check-Packages `-MountPath E:\wimcheck`). Those are
  **target-host** paths (the server being repaired), not build-host paths, and are unaffected
  by the build host's volume layout. Override per target as needed.
- **Mounted-ISO drive letters are resolved dynamically** (`Mount-IsoGetDrive`; the repair
  script scans all volumes for the FoD folder / `install.wim`). Adding a `D:` volume shifts
  which letter a mounted ISO receives, but no script hardcodes one, so nothing breaks.

## [1.1.1] - 2026-07-13

Path-correctness fixes found while installing the scheduled task from a git working copy
(`C:\Projects\server2025-servicing`). No behavioural change to the servicing logic.

### Fixed
- **`scripts/Watch-Server2025Updates.ps1`** (→ v1.0.1) — the detector previously invoked the
  slipstream with **no arguments**, silently relying on the slipstream's built-in default
  `-SourceISO` / `-BasePath`. It now passes **`-BasePath $OutputDir`** and (when supplied)
  **`-SourceISO`** explicitly, so the build never depends on hardcoded defaults matching the
  host. Added a `-SourceISO` parameter, validated up front (fails fast if the RTM ISO is
  missing, instead of hours into a build).
- **`scheduled-task/Register-SlipstreamSchedule.ps1`** (→ v1.1.1) — added `-SourceISO`
  passthrough with existence validation, and a warning when it's omitted.

### Notes
- Relative defaults (`-WatchScript` / `-SlipstreamScript`) resolve from the *script's own*
  location (`$PSScriptRoot`-style), so a repo cloned anywhere (e.g. `C:\Projects\...`) works
  unchanged. Absolute paths are baked into the registered task — **re-register if you move
  the repo**.
- `-ShareRoot` may be a plain local folder (e.g. `C:\PatchedImages`). A local path avoids the
  UNC/SYSTEM pitfall, where the task running as SYSTEM authenticates to a share as the machine
  account. Size the volume for `KeepLast x ~8.6 GB` plus the slipstream's ~30-40 GB working set.

## [1.1.0] - 2026-07-09

Changed the update cadence from a fixed calendar trigger to availability-driven detection.

### Added
- **`scripts/Watch-Server2025Updates.ps1`** (v1.0.0) — daily detector: lightweight Catalog
  poll for the newest Server 2025 24H2 x64 LCU, compared to a JSON state marker; launches the
  slipstream only when the build is newer, then archives the ISO (+ retention) and stamps the
  marker. Idempotent; Catalog hiccups are non-fatal. `-MonthlyOnly` restricts to the
  2nd-Tuesday security LCU (ignores out-of-band).

### Changed
- **`scheduled-task/Register-SlipstreamSchedule.ps1`** (→ v1.1.0) — now registers the detector
  on a **daily** trigger (cmdlet-based) instead of a fixed 2nd-Wednesday build. Archive and
  retention moved into the detector. `-MonthlyOnly` and `-RunAsUser` passthrough.
- README / RUNBOOK updated to describe availability-driven detection.

### Rationale
- Patch Tuesday is deterministic, but Catalog *availability* can lag and out-of-band updates
  don't follow the calendar. Polling the Catalog for the LCU's presence (the authoritative
  signal, via the same code path the slipstream already uses) is more robust than scraping a
  release-date page and rewriting a task's trigger date.

## [1.0.0] - 2026-07-09

First tracked release. Baseline validated end-to-end building a patched Server 2025 ISO
(build 26100.32995) and repairing a live, long-upgraded Datacenter host (348 → 0 store
corruptions) plus WinRE re-enable.

### Slipstream-Server2025.ps1

Added
- Self-contained Microsoft Update Catalog client (no external PowerShell module): search
  → DownloadDialog → **BITS** download from `download.windowsupdate.com` CDN, all with
  retry/backoff and proxy awareness.
- **Checkpoint-cumulative-update handling** for Server 2025: the whole CU folder (target
  LCU + prerequisite checkpoint) is applied to `install.wim`; **only the single target
  LCU** is applied to `boot.wim`/WinRE.
- Full media servicing per Microsoft's ordered sequence: WinRE (SSU + SafeOS DU),
  `install.wim` (all editions, .NET 3.5 + .NET CU), `boot.wim`, Setup DU, then UEFI+BIOS
  ISO rebuild via ADK `oscdimg`, then verification of the patched build.
- **Resume**: detects an already-serviced `install.wim` (marker file + per-index version
  check) and skips the multi-hour rebuild; `-Fresh` forces a full rebuild.
- Offline fallback: uses pre-staged `.msu`/`.cab` when the Catalog is unreachable, and
  skips the Catalog probe entirely when all packages are already staged.

Fixed (issues found during hardening)
- Catalog search parser matched the **Download `<input>` GUID** in the results table, not
  a non-existent `<a id="…_link">` anchor.
- Download-URL regex is **host-agnostic** (Microsoft serves from prefixed subdomains such
  as `b1.download.windowsupdate.com` / `catalog.sf.dl.delivery.mp.microsoft.com`).
- `boot.wim` no longer receives the checkpoint CU (caused `0x80073712`, assembly missing).
- Removed value-returning-function output pollution; hardened `oscdimg` invocation via a
  generated `.cmd` for reliable native-argument quoting; ISO drive-letter mount retry.
- Resume version check queries each index individually (the summary form omits `.Version`).

### Repair-Server2025Store.ps1

Added
- Online `RestoreHealth` from **dual offline sources** (FoD ISO + patched `install.wim`)
  with `/LimitAccess` and a configurable `/ScratchDir`.
- Pending-reboot / pending-package guard; edition→index auto-detection; CheckHealth
  before/after; optional `-EnableWinRE` (stages `Winre.wim` from `install.wim`, then
  `reagentc /enable`) and optional `-ResetBase`.
- Copies `CBS.log` / `dism.log` beside the transcript for post-run diagnosis.

Fixed
- DISM output routed to the host (`Out-Host`) so the wrapper returns a clean boolean.
- Dropped `PendingFileRenameOperations` from the blocker check (false-positive on healthy
  hosts); removed the `,$reasons` return idiom that nested with the caller's `@()` and
  produced a `System.Object[]` false-positive block.

### Check-Packages.ps1

Added
- Pre-flight verification that a WIM index contains specific WinSxS component payloads
  before using it as a `RestoreHealth` source — prevents blind `0x800f0915` failures.

### docs / automation

Added
- `docs/RUNBOOK.md`, `docs/LESSONS-LEARNED.md`, `docs/INCIDENT-csFiles.md`.
- `scheduled-task/Register-SlipstreamSchedule.ps1` — monthly 2nd-Wednesday build + archive.

[Unreleased]: https://example.com/server2025-servicing/compare/v2.1.2...HEAD
[2.1.2]: https://example.com/server2025-servicing/compare/v2.1.1...v2.1.2
[2.1.1]: https://example.com/server2025-servicing/compare/v2.1.0...v2.1.1
[2.1.0]: https://example.com/server2025-servicing/compare/v2.0.0...v2.1.0
[2.0.0]: https://example.com/server2025-servicing/compare/v1.3.1...v2.0.0
[1.3.1]: https://example.com/server2025-servicing/compare/v1.3.0...v1.3.1
[1.3.0]: https://example.com/server2025-servicing/compare/v1.2.4...v1.3.0
[1.2.4]: https://example.com/server2025-servicing/compare/v1.2.3...v1.2.4
[1.2.3]: https://example.com/server2025-servicing/compare/v1.2.2...v1.2.3
[1.2.2]: https://example.com/server2025-servicing/compare/v1.2.1...v1.2.2
[1.2.1]: https://example.com/server2025-servicing/compare/v1.2.0...v1.2.1
[1.2.0]: https://example.com/server2025-servicing/compare/v1.1.1...v1.2.0
[1.1.1]: https://example.com/server2025-servicing/compare/v1.1.0...v1.1.1
[1.1.0]: https://example.com/server2025-servicing/compare/v1.0.0...v1.1.0
[1.0.0]: https://example.com/server2025-servicing/releases/tag/v1.0.0
