# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Nothing yet.

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

[Unreleased]: https://example.com/server2025-servicing/compare/v1.2.0...HEAD
[1.2.0]: https://example.com/server2025-servicing/compare/v1.1.1...v1.2.0
[1.1.1]: https://example.com/server2025-servicing/compare/v1.1.0...v1.1.1
[1.1.0]: https://example.com/server2025-servicing/compare/v1.0.0...v1.1.0
[1.0.0]: https://example.com/server2025-servicing/releases/tag/v1.0.0
