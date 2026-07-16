# Execution cheat sheet

Every script, the switches you'll actually use, and the end-to-end workflows. Run everything
**elevated** on the build host (ADK + WinPE installed). Paths assume the repo is at
`C:\Projects\server2025-servicing`.

> **The one file you edit:** `config\Products.psd1`. Which media gets built, where it's archived,
> how many to keep, which editions — all live there. You should rarely need a switch to override it.

---

## TL;DR — the commands you run most

```powershell
# Build ALL products in the config's RunMediaJobs list (what the nightly task runs)
.\scripts\Invoke-MediaJobs.ps1

# Build just one product now
.\scripts\Invoke-MediaJobs.ps1 -Jobs Win11-25H2

# Make a single-edition, hardened, DISK-WIPING deploy ISO from the newest patched Win11-25H2
.\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro' -IncludeUnattend

# Validate everything before you trust a change (run after ANY edit)
.\tests\Invoke-QualityGate.ps1

# See what's built and what each ISO contains
.\scripts\ISO_Inventory.ps1
```

---

## `Slipstream-WindowsMedia.ps1` — the builder (v3.4.x)

Services ONE product's RTM media into a patched, bootable ISO. Probes the catalog, downloads the
LCU + dynamic updates, applies them checkpoint-aware, trims/verifies, archives. ~4 hours for a full
build; **seconds** when the current LCU is already built (the ALREADY-BUILT guard no-ops).

```powershell
# Normal build (edition set + trim come from the profile)
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2

# Look before you leap — no download, no servicing:
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -ListEditions   # what's in the media
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -DryRun         # what WOULD be built
.\scripts\Slipstream-WindowsMedia.ps1 -ListProducts                       # products in the config

# Re-cut the SAME build with a different edition set (bypasses the ALREADY-BUILT guard):
.\scripts\Slipstream-WindowsMedia.ps1 -Product Win11-25H2 -EditionName 'Windows 11 Pro' -Rebuild
```

| Switch | Meaning |
|---|---|
| `-Product <name>` | Which profile to build (default `Server2025`). Names come from the config. |
| `-ConfigPath <path>` | Override the config file (default `..\config\Products.psd1`). |
| `-ListProducts` | Print defined products and exit. |
| `-ListEditions` | Print the editions in the source media and exit (no build). |
| `-DryRun` | Resolve the selection + output index map against the source, print, exit. **Do this before a 4-hour build.** |
| `-Index 3,5` | Patch only these install.wim indexes. |
| `-EditionName '<n>'` | Patch editions matching these `-like` names (union with `-Index`). Exact name = exact match; `*Pro*` is broad. |
| `-ExcludeEditionName '<n>'` | Subtract editions (applied last). |
| `-ExcludeN` | Drop the 'N' editions. |
| `-AllEditions` | Ignore the profile's `DefaultEditions`; take every edition. |
| `-TrimMedia` / `-NoTrim` | Force output = selected editions only / force full mixed-build media. If neither, the profile's `TrimByDefault` decides. |
| `-Rebuild` | Build even if this exact build already exists (use to re-cut a different edition set). |
| `-Fresh` | Ignore any existing `\newMedia`; rebuild from the source ISO. |
| `-ForceDownload` | Re-download packages even if present locally. |
| `-SourceISO` / `-BasePath` / `-IsoLabel` / `-ArchiveRoot` / `-KeepLast` | Per-run overrides of the profile's values. |
| `-KeepNewMedia` | Keep the expanded `\newMedia` after the ISO is built. |
| `-NoProxy` | Force a direct connection (use as SYSTEM with a stale proxy in the SYSTEM WinINET hive). |

---

## `Invoke-MediaJobs.ps1` — the orchestrator (v1.0.0)

Runs the slipstream for each product in the config's `RunMediaJobs`, in order, as child processes.
One product failing doesn't stop the rest. This is what the scheduled task calls.

```powershell
.\scripts\Invoke-MediaJobs.ps1                        # build everything in RunMediaJobs
.\scripts\Invoke-MediaJobs.ps1 -Jobs Win11-25H2       # one product
.\scripts\Invoke-MediaJobs.ps1 -Jobs Server2025,Win11-25H2   # a subset, in this order
```

| Switch | Meaning |
|---|---|
| `-Jobs <names>` | Override `RunMediaJobs` for a one-off run. |
| `-ConfigPath <path>` | Override the config. |
| `-SlipstreamScript <path>` | Override the builder path. |
| `-NoProxy` | Pass `-NoProxy` through to each build. |
| `-LogDir <path>` | Where to write the orchestrator transcript. |

---

## `New-DeployableIso.ps1` — the remaster / deploy image (v1.2.x)

Takes the **newest patched ISO** for a product and remasters it (minutes, no re-servicing) into a
lean **single-edition** ISO with the privacy hardening + Firefox baked in. Optionally bakes the
disk-wiping answer file for a fully unattended install.

```powershell
# Single Pro edition + hardening, answer file baked (WIPES DISK 0 on boot):
.\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro' -IncludeUnattend

# Same but attach the answer file separately later (image not disk-wiping on its own):
.\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro'

# Offline build host (supply Firefox instead of downloading):
.\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro' -IncludeUnattend -FirefoxSetup C:\stage\FirefoxSetup.exe
```

| Switch | Meaning |
|---|---|
| `-Product <name>` | Source profile (default `Win11-25H2`). |
| `-EditionName '<n>'` | The one edition to keep (default `Windows 11 Pro`). By NAME, so trimming can't pick wrong. |
| `-IncludeUnattend` | Bake `autounattend.xml` at the ISO root → **fully unattended, WIPES DISK 0**. Off by default. |
| `-UnattendPath <path>` | Answer file to bake (default `..\unattend\autounattend-Win11.xml`). |
| `-NoHarden` | Skip injecting the hardening into the image. |
| `-HardenDir <path>` | Folder with `SetupComplete.cmd` + `Invoke-PrivacyHardening.ps1` (default `..\harden`). |
| `-NoFirefox` | Don't bake the Firefox installer. |
| `-FirefoxSetup <path>` | Use a supplied installer instead of downloading. |
| `-FirefoxUrl <url>` | Override the download URL (default = Mozilla latest x64 en-US). |
| `-SkipCurrencyCheck` | Skip the "is the source built with the current LCU?" warning. |
| `-SourceIso` / `-OutputIso` / `-WorkDir` | Override auto-found source / output name / scratch dir. |
| `-KeepWork` | Keep the work dir (default: delete). |

> **Currency guard:** on run it reads the source ISO's manifest LCU and compares to the catalog's
> current LCU. `Currency OK` = current; a `CURRENCY WARNING` means the source predates the latest
> LCU (rebuild the product first). Warning only — it never blocks.

---

## `Register-SlipstreamSchedule.ps1` — the nightly task (v2.0.0)

Registers the daily task that runs `Invoke-MediaJobs.ps1`. Idempotent (re-run to update). What gets
built is controlled by `RunMediaJobs` in the config — change the config, no re-registration needed.

```powershell
.\scheduled-task\Register-SlipstreamSchedule.ps1                    # daily 02:00, as SYSTEM
.\scheduled-task\Register-SlipstreamSchedule.ps1 -Time 01:30 -NoProxy
Start-ScheduledTask -TaskName 'Server2025-Servicing-MediaJobs'      # dry-run it now
```

| Switch | Meaning |
|---|---|
| `-Time <HH:mm>` | Daily run time (default `02:00`). |
| `-NoProxy` | Register the task with `-NoProxy`. |
| `-RunAsUser <who>` | `SYSTEM` (default) or a domain account (prompts for a password). |
| `-ExecutionTimeLimitHours <n>` | Task time limit (default `20` — several multi-hour builds back to back). |
| `-ConfigPath` / `-JobRunner` / `-TaskName` | Overrides. |

> As SYSTEM, a UNC `ArchiveRoot` is hit as the **machine account** (`DOMAIN\HOST$`), not you.

---

## `Invoke-PrivacyHardening.ps1` — the hardening (v1.4.x)

Privacy/de-bloat for a Win11 dev box. Normally runs itself during Setup (specialize, as SYSTEM);
run it standalone to test or to fix a box that's already deployed. Toggles live in the `$H` table at
the top of the script (`$true` = do it / turn the feature off).

```powershell
# Test on a real box (also applies per-user settings to YOUR current profile):
powershell -NoProfile -ExecutionPolicy Bypass -File .\harden\Invoke-PrivacyHardening.ps1 -AlsoCurrentUser

# Re-run on a box that's already been hardened once (override the .applied marker):
.\harden\Invoke-PrivacyHardening.ps1 -Force -AlsoCurrentUser
```

| Switch | Meaning |
|---|---|
| `-AlsoCurrentUser` | Also apply per-user tweaks to `HKCU` (not just the Default hive). Use when running on an already-set-up box. |
| `-Force` | Re-run even if the `.applied` marker is present. |
| `-LogPath <path>` | Override the transcript path (default `C:\ProgramData\PrivacyHardening\hardening_<stamp>.log`). |

> Log + evidence: `C:\ProgramData\PrivacyHardening\` (`hardening_*.log`, `.applied`,
> `firefox_install.log`). If that folder is absent after a deploy, the hardening never ran.

---

## `Invoke-QualityGate.ps1` — the gate (v1.6.x)

Five layers: AST parse, PSScriptAnalyzer, project rules (A–F), product config, answer-file XML.
**Run after any script or config edit** — exit 0 = pass, 1 = fail (suitable for a pre-commit hook).

```powershell
.\tests\Invoke-QualityGate.ps1                    # validate the whole repo
.\tests\Invoke-QualityGate.ps1 -InstallAnalyzer   # first run: install PSScriptAnalyzer (CurrentUser)
```

| Switch | Meaning |
|---|---|
| `-Path <dir>` | Repo root to scan (default = the parent of the tests folder). |
| `-InstallAnalyzer` | Install PSScriptAnalyzer if missing. |

---

## `New-UnattendIso.ps1` — answer-file-only ISO (v1.0.0)

Wraps `autounattend-Win11.xml` into a tiny second ISO to attach as a 2nd CD — the clean way to run
the answer file **without** baking it into (and disk-wiping) your golden media.

```powershell
.\unattend\New-UnattendIso.ps1                                   # defaults: autounattend-Win11.xml -> Win11-unattend.iso
.\unattend\New-UnattendIso.ps1 -AnswerFile C:\path\my.xml -OutputIso D:\PatchedImages\my-unattend.iso
```

| Switch | Meaning |
|---|---|
| `-AnswerFile <path>` | Source answer file (default `autounattend-Win11.xml` beside the script). |
| `-OutputIso <path>` | Output ISO (default beside the answer file). |
| `-Label <text>` | ISO volume label (default `UNATTEND`). |

---

## Utilities

**`ISO_Inventory.ps1`** — report what's built and what each ISO contains (read-only).

```powershell
.\scripts\ISO_Inventory.ps1                        # every product
.\scripts\ISO_Inventory.ps1 -Product Win11-25H2    # one product
.\scripts\ISO_Inventory.ps1 -SkipArchive           # faster; skip ArchiveRoot scan
```

**`Repair-Server2025Store.ps1`** — DISM component-store repair for a Server 2025 host, using a
patched `install.wim` as the `RestoreHealth` source (this is why Server2025 must stay full/all-editions).

```powershell
.\scripts\Repair-Server2025Store.ps1 -InstallWim D:\PatchedImages\Server2025_Patched_...iso -Index 4
```

| Switch | Meaning |
|---|---|
| `-InstallWim <path>` | Patched WIM (or mounted ISO's `install.wim`) to repair from. |
| `-Index <n>` | Which edition index in that WIM to use as the source. |
| `-FodSource <path>` | Features-on-Demand source, if needed. |
| `-ResetBase` | `dism /StartComponentCleanup /ResetBase` after repair. |
| `-EnableWinRE` | Re-enable WinRE afterward. |
| `-SkipSfc` | Skip the `sfc /scannow` pass. |
| `-Force` | Don't prompt. |
| `-ScratchDir` / `-LogDir` | Override scratch/log dirs. |

---

## End-to-end workflows

**Monthly / nightly patched media (hands-off):** the scheduled task runs `Invoke-MediaJobs.ps1`
→ each product in `RunMediaJobs` builds (or no-ops if current) → archives to `ArchiveRoot`, pruning
to `KeepLast`. Change what's built by editing `RunMediaJobs`; nothing to re-register.

**Make a Win11 Pro deploy VM:**

1. Ensure a current build exists: `.\scripts\Invoke-MediaJobs.ps1 -Jobs Win11-25H2` (fast no-op if already current).
2. `.\scripts\New-DeployableIso.ps1 -EditionName 'Windows 11 Pro' -IncludeUnattend` → single-edition, hardened, disk-wiping ISO. Watch for `Currency OK`.
3. In ESXi: **blank/detached disk** (see the boot-order gotcha in `UNATTEND-Win11-ESXi.md`), firmware = EFI, attach the ISO, power on.
4. Unattended install runs; hardening fires at specialize; Firefox installs at first logon (self-removing task).
5. Verify: `C:\ProgramData\PrivacyHardening\` exists; `about:policies` in Firefox; `slmgr /ato` to activate against KMS.

**After ANY edit to a script or the config:** `.\tests\Invoke-QualityGate.ps1` → then a `-DryRun`
(slipstream) or `-ListEditions` before committing to a long build.

---

## Gotchas worth memorizing

- **Config first.** `config\Products.psd1` drives almost everything; switches are for one-offs.
- **`-DryRun` before every real build.** Four hours is a long time to discover a wrong edition set.
- **`-IncludeUnattend` WIPES DISK 0** with no prompt. Deploy-only, throwaway targets.
- **A prior Windows install fights the CD boot** on UEFI — blank/detach the disk or Force EFI setup (see the ESXi doc).
- **Currency:** if `New-DeployableIso` warns the source is behind, rebuild the product first — don't ship a cycle-old image.
- **`Server2025.IsoPrefix` must stay `Server2025_Patched`** — the archiver globs it. Renaming = silent archive-nothing.
- **Run the gate after edits.** It now also validates the answer file XML (a misplaced `RunSynchronous` = boot loop).
