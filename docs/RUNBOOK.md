# Runbook — Server 2025 servicing

Operational procedures for building patched media and repairing a live host. Assumes an
elevated PowerShell 5.1+ session and the prerequisites in the [README](../README.md).

---

## 1. Build the monthly patched ISO

**When:** automatically, whenever a new LCU publishes. `Watch-Server2025Updates.ps1` runs
**daily at 02:00** on the management/build host, polls the Update Catalog, and launches the
slipstream only when the latest available build is newer than the last one built (state
marker at `<OutputDir>\state\last-built.json`). Register it once with
[`Register-SlipstreamSchedule.ps1`](../scheduled-task/Register-SlipstreamSchedule.ps1)
(add `-MonthlyOnly` to ignore out-of-band releases). Dry-run:
`Start-ScheduledTask -TaskName 'Server2025-Update-Watch'`.

**To build on demand (bypasses the detector):**

```powershell
.\scripts\Slipstream-WindowsMedia.ps1 -Product Server2025
```

What it does, unattended: downloads the current LCU (+ checkpoint), SafeOS DU, Setup DU and
.NET CU; extracts the RTM ISO; services WinRE, all four `install.wim` editions, and
`boot.wim`; refreshes Setup files; rebuilds a UEFI+BIOS ISO with `oscdimg`; verifies the
patched build. Output: `D:\Server2025Patching\Server2025_Patched_<stamp>.iso`.

Notes:
- **Runtime is hours** — see [§1.1 Timing & throughput](#11-timing--throughput-reference) for
  measured numbers and how to plan a `RunMediaJobs` pass. A failed run leaves the serviced
  `install.wim` in `\newMedia`; simply re-running **resumes** past it. `-Fresh` forces a clean
  rebuild.
- **Offline / air-gapped:** pre-stage the four packages under
  `D:\Server2025Patching\packages\{CU,SafeOS_DU,Setup_DU,DotNet_CU}\` and run;
  the Catalog is skipped automatically when everything is staged.
- **Archive** the finished ISO to the share and keep history (the scheduled task does this).
  Keep the **RTM ISO** and **FoD ISO** on the same share — you'll need them for repairs.

Verify success: the log ends with `ISO created … (N GB)` and a verification block showing
`Patched install.wim (index 1) build version: 10.0.26100.<current>`.

### 1.1 Timing & throughput (reference)

Measured on the build host (VM, **6 vCPU** — DISM pins ~4 during servicing — single working
volume on `D:`). **Storage is not the limiter here:** `D:` is Dell Ent **NVMe P5600** U.2 SSDs
behind a **PERC H755N** in **RAID-5, write-back** — i.e. already a high-end tier. Real run,
**Win11-25H2, 3 editions, trimmed**, July 2026 (KB5101650 → 26200.8875): **≈ 3 h 51 m** wall,
packages pre-staged.

Where the time goes (per that run):

| Phase | Time | Notes |
|---|---|---|
| Catalog probe + (download if needed) | ~2 min | LCU ~1.5 min each; pre-staged DUs skip |
| Copy source media → `\newMedia` | ~25 s | |
| WinRE servicing (**once**, reused for all editions) | ~5 min | SSU + SafeOS DU |
| **install.wim, per edition** | **~60–75 min each** | the dominant cost — see below |
| Export trimmed install.wim | < 1 min | single-instanced, near-instant |
| boot.wim (both indexes) | ~25 min | |
| oscdimg (build ISO) | ~1 min | |
| Verification (mount + package list) | ~4 min | |
| Archive to `ArchiveRoot` (local → local) | seconds | ~8 s for ~8 GB on the same volume |

**The per-edition install.wim work is ~90% of the wall clock**, and it is roughly **linear in
edition count**. Within each edition the big items are the LCU add (~18 min), the
`StartComponentCleanup` (~5 min), and the commit/`Dismount -Save` (~35–45 min). Trimming does
**not** speed servicing — every *selected* edition is still fully serviced; trimming only makes
the final export and the ISO smaller.

**Extrapolation for planning:**

- **Server 2025** (4 editions, not trimmed) ≈ **5–5.5 h**.
- **Win11** (3 editions, trimmed) ≈ **3.5–4 h** each.
- A full `RunMediaJobs` pass (`Server2025` → `Win11-25H2` → `Win11-24H2`) runs the builds
  **back-to-back**, so ≈ **12–14 h** on a new-LCU month. This is why the scheduled task starts at
  **02:00** and its `ExecutionTimeLimit` is **20 h**. On a month with nothing new, each product
  is an ALREADY-BUILT no-op and the whole pass is a couple of minutes.

**Hardware notes — this time is close to the workload floor, not a hardware shortfall.** The
≈3 h 51 m above was on NVMe (P5600 / H755N / RAID-5 write-back), so the build is **not** starved
for I/O. The cost is **DISM's per-image servicing itself** — CBS transaction processing and WIM
recompression on `Dismount -Save`, which is largely single-threaded and serialized per image.
Consequences:

- **More vCPU past ~4 buys little.** DISM won't parallelize a single image's servicing; the extra
  cores sit idle during the long commit phase (which is why the box "pegs at 4").
- **Faster disk buys little from here.** On NVMe the servicing phase is CPU/algorithm-bound, not
  bandwidth-bound. On *slow* storage (spinning disk, a busy shared datastore) disk would dominate
  — but that is not this host.
- **RAID-5 vs RAID-10:** RAID-5 carries a small-write parity penalty (read-modify-write), which
  this workload does hit during CBS churn. Write-back cache + NVMe largely masks it, and moving to
  RAID-10 would help random writes — but because the bottleneck is DISM's serial work, don't
  expect it to move the ~4 h wall time much. It's a resilience/latency choice more than a
  build-speed one.
- **RAM is not a constraint.**

Net: to cut wall-clock, the levers that actually work are **building fewer editions**
(`TrimByDefault` already limits *output*, but every *selected* edition is still serviced — so
patch only the editions you deploy) and **not rebuilding when nothing changed** (the ALREADY-BUILT
guard). The raw per-edition servicing time is essentially fixed by DISM on any modern host.

---

## 2. Repair a live host's component store

**Symptom:** `DISM /Online /Cleanup-Image /CheckHealth` reports *"The component store is
repairable"*, and `/RestoreHealth` (online) fails with `0x800f0915` because Windows Update
can't supply the payloads.

### 2.0 Safety first (VMs)

Take a **memory-less** snapshot (quiesce optional) before changing anything. Keep it until
the repair **and** any WinRE change are verified and the host has rebooted clean, then
delete it.

### 2.1 Pre-flight

Confirm nothing is mid-servicing (the script also guards this):

```powershell
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
@(Get-WindowsPackage -Online | Where-Object PackageState -match 'Pending').Count
```

Want `False / False / 0`. If a real pending reboot exists, reboot and re-check first.

### 2.2 Mount sources & run the repair

Mount the **patched ISO** (matching the host's build) and the **FoD ISO**. Then, with the
host's edition index (Datacenter Desktop = index 4 on the standard MLF media):

```powershell
.\scripts\Repair-Server2025Store.ps1 `
    -FodSource G:\LanguagesAndOptionalFeatures `
    -InstallWim F:\sources\install.wim -Index 4
```

Non-destructive: reads from the ISOs, repairs the store, runs `sfc /scannow`, re-checks.
Success = `RestoreHealth completed (0)` and CheckHealth *"No component store corruption
detected."*

### 2.3 If RestoreHealth still reports missing payloads (0x800f0915)

This means the corrupt component is at a **version not present** in the patched
`install.wim` or FoD ISO — classic on **in-place-upgraded** hosts carrying pre-RTM
component versions (e.g. `10.0.26100.1150`). Find the exact components in
`C:\Windows\Logs\CBS\CBS.log`:

```
(p) CSI Payload Corrupt (n)  amd64_<component>_..._10.0.26100.1150_none_<hash>\<file>.mof
Repair failed: Missing replacement payload.
```

The reliable source for those is the **pristine, unmodified RTM ISO** (it carries the base
component versions). Mount it (e.g. `H:`) and **verify before running**:

```powershell
.\scripts\Check-Packages.ps1 -WimPath H:\sources\install.wim -Index 4 `
    -Component 'amd64_bgpncprovider_31bf3856ad364e35_10.0.26100.1150_none_1bf6588586e5a0fb',
               'amd64_ipamserverwmiv2provider_31bf3856ad364e35_10.0.26100.1150_none_75a867a53ad31572' `
    -File '*.mof'
```

If it reports the payloads present, repair from the RTM source directly:

```powershell
DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:H:\sources\install.wim:4 `
     /LimitAccess /ScratchDir:E:\DISMscratch
DISM /Online /Cleanup-Image /ScanHealth
DISM /Online /Cleanup-Image /CheckHealth
```

If `Check-Packages` reports **MISSING** (the RTM media doesn't carry that build either) and
the components belong to **unused roles** (e.g. BGP/SDN, IPAM on a file server), you have two
acceptable outcomes:
1. **Accept** — `sfc` is clean and the components are dormant; the "repairable" flag is
   cosmetic for unused roles. Revisit only if a future CU actually fails.
2. **Remove** the orphaned staged packages (with the snapshot as safety net), after
   confirming the roles aren't installed:
   ```powershell
   Get-WindowsFeature | Where-Object { $_.Installed -and $_.Name -match 'IPAM|RemoteAccess|Routing|NetworkController' }
   ```

### 2.4 Confirm health

```powershell
DISM /Online /Cleanup-Image /ScanHealth      # authoritative fresh scan
DISM /Online /Cleanup-Image /CheckHealth      # expect: No component store corruption detected
sfc /scannow                                  # expect: no integrity violations
```

---

## 3. WinRE re-enable (if Disabled)

Common after recovery-partition surgery (e.g. GParted on MBR). Do it **after** the store is
healthy:

```powershell
.\scripts\Repair-Server2025Store.ps1 `
    -FodSource G:\LanguagesAndOptionalFeatures `
    -InstallWim F:\sources\install.wim -Index 4 -EnableWinRE -SkipSfc
```

It stages `Winre.wim` from the patched `install.wim` if missing, then `reagentc /enable`.
Confirm with `reagentc /info` → *Windows RE status: Enabled*. On MBR disks with a moved
recovery partition, `/enable` needs a valid type-`0x27` WinRE partition; if it warns, WinRE
stays Disabled (recoverable) — fix the partition and retry.

---

## 4. Optional cleanup (ResetBase)

Once the store is confirmed healthy, on upgrade-heavy hosts you can prune the superseded
chain and shrink WinSxS:

```powershell
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:E:\DISMscratch
```

**Irreversible** — removes the ability to uninstall currently-installed updates. Do it as a
deliberate, separate step, not bundled with a repair.

---

## 5. Close-out

- Reboot; confirm the host comes up clean and `CheckHealth` is still clean.
- Delete the VM snapshot.
- Record the build the host is now on and which source ISO repaired it.
