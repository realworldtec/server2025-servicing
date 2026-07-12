# server2025-servicing

Tooling to keep **Windows Server 2025 (24H2, build 26100)** installation media and
component stores current and healthy:

- **`Slipstream-Server2025.ps1`** — builds a fully-patched, bootable Server 2025 ISO from
  the RTM media plus the latest cumulative/dynamic updates (auto-downloaded from the
  Microsoft Update Catalog, or pre-staged offline).
- **`Repair-Server2025Store.ps1`** — repairs a live server's component store from offline
  media (`install.wim` + Features-on-Demand ISO), with optional WinRE re-enable and
  ResetBase cleanup.
- **`Check-Packages.ps1`** — verifies a WIM actually contains the exact component payloads
  a `RestoreHealth` needs, *before* you run it (turns a blind failure into a go/no-go).
- **`Watch-Server2025Updates.ps1`** — daily detector that polls the Catalog and launches the
  slipstream only when a newer LCU actually publishes (idempotent; handles out-of-band).

Version **1.2.1** — see [CHANGELOG.md](CHANGELOG.md).

> **Paths:** all build-host defaults live on a **data volume (`D:`)** — RTM ISO in
> `D:\Server2025RTM`, working/output in `D:\Server2025Patching`, ISO archive in
> `D:\PatchedImages`. Override with `-SourceISO` / `-BasePath` / `-ShareRoot` if your layout
> differs. Mounted-ISO drive letters are always resolved dynamically — never hardcoded.

## Why this exists

Windows Update on a stranded/offline or long-upgraded server can't always repair itself
(`DISM /RestoreHealth` returns `0x800f0915` when it can't reach or match repair content).
The reliable path is **offline, version-matched media**: a patched `install.wim` at the
*same build* as the target, plus the FoD ISO for optional/language payloads. Producing that
media by hand every month is slow and error-prone, so it's scripted here — and, because it
must match each Patch Tuesday, it's meant to run on a schedule with archived history.

## Repository layout

```
server2025-servicing/
├── README.md
├── CHANGELOG.md
├── .gitignore                       # excludes ISOs, WIMs, .msu/.cab, logs, scratch
├── scripts/
│   ├── Slipstream-Server2025.ps1    # build patched ISO
│   ├── Repair-Server2025Store.ps1   # repair a live host's store (+WinRE)
│   ├── Check-Packages.ps1           # verify a WIM has needed payloads pre-repair
│   └── Watch-Server2025Updates.ps1  # daily detector -> triggers build on new LCU
├── docs/
│   ├── RUNBOOK.md                   # step-by-step operational procedures
│   ├── LESSONS-LEARNED.md           # the non-obvious gotchas, with fixes
│   └── INCIDENT-csFiles.md          # the real case this tooling was hardened against
└── scheduled-task/
    └── Register-SlipstreamSchedule.ps1  # registers the daily detector + archive
```

> **Do not commit media.** `.gitignore` excludes `*.iso`, `*.wim`, `*.msu`, `*.cab`, logs,
> and the working folders. This repo is scripts + docs only; ISOs live on a share (below).

## Requirements

- Windows 10/11 or Server **build host** with the **Windows ADK + WinPE add-on** installed
  (default path). PowerShell 5.1+, run **elevated**.
- ~30–40 GB free for the slipstream working set; internet access to the Update Catalog
  (or pre-staged `.msu`/`.cab` files for air-gapped builds).
- For repair: the patched `install.wim`, the Server 2025 **Features-on-Demand ISO**, and —
  for orphaned pre-RTM component versions — the **original RTM ISO**.

## Quick start

**Build this month's patched ISO:**

```powershell
.\scripts\Slipstream-Server2025.ps1
```

Output: `D:\Server2025Patching\Server2025_Patched_<stamp>.iso`. Re-runs auto-resume
if a prior run already serviced `install.wim`; add `-Fresh` to force a clean rebuild.

**Repair a live server's store (mount patched ISO = F:, FoD ISO = G:):**

```powershell
.\scripts\Repair-Server2025Store.ps1 -FodSource G:\LanguagesAndOptionalFeatures `
    -InstallWim F:\sources\install.wim -Index 4
```

Then, if WinRE needs re-enabling: add `-EnableWinRE -SkipSfc`. See
[docs/RUNBOOK.md](docs/RUNBOOK.md) for the full decision tree, including the RTM-source
fallback for orphaned component versions.

## Update detection & cadence

Rather than guessing at a calendar date, a **daily detector** polls the Update Catalog and
builds only when a **newer LCU actually publishes** — so the patched ISO appears the day the
CU lands (and it naturally covers out-of-band releases). Runs on a decoupled management host.

- `Watch-Server2025Updates.ps1` runs **daily at 02:00**; it's a fast no-op on days with
  nothing new, and launches the slipstream only when the Catalog shows a build newer than the
  last one built (tracked in a small JSON state marker — idempotent, never double-builds).
- Finished ISOs are archived to `-ShareRoot` with a retention policy (default: keep 12). Point
  repairs at the archived ISO matching the target host's build.
- `-MonthlyOnly` restricts builds to the 2nd-Tuesday security LCU (ignores OOB) if preferred.

Register it (on the management/build host):

```powershell
.\scheduled-task\Register-SlipstreamSchedule.ps1 `
    -ShareRoot 'D:\PatchedImages' `
    -SourceISO 'D:\Server2025RTM\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO' `
    -KeepLast 12
# -MonthlyOnly ignores out-of-band releases.
```

**`-ShareRoot` sizing:** archive = `KeepLast x ~8.6 GB` (12 ≈ 103 GB), plus the slipstream's
~30–40 GB working set. A **local folder** (as above) is simplest — share it afterwards if
needed. If you point it at a **UNC**, the task runs as SYSTEM and hits the share as the
*machine account*, so either grant `DOMAIN\HOST$` access or register with
`-RunAsUser 'CORP\svc-imaging'`.

**Prereqs on that host:** Windows ADK + WinPE add-on (for `oscdimg`), and the RTM ISO at
`-SourceISO`.

Dry-run any time with `Start-ScheduledTask -TaskName 'Server2025-Update-Watch'` and watch
`…\logs\Watch_*.log`.

## Also keep on the shelf

- **RTM ISO** (`SW_DVD9_Win_Server_STD_CORE_2025_24H2_...`) — the only reliable source for
  component versions older than RTM that in-place-upgraded hosts can carry (see the
  incident write-up). Archive it alongside the patched ISOs.
- **Features-on-Demand ISO** (`...languages_and_optional_features...`) — required to repair
  staged FoD / language / optional packages; `install.wim` alone does **not** contain them.

## License

MIT (see headers). Internal operational tooling — review before use in your environment.
