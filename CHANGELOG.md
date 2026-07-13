# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Nothing yet.

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

[Unreleased]: https://example.com/server2025-servicing/compare/v2.0.0...HEAD
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
