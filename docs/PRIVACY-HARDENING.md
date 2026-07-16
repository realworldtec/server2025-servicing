# Privacy hardening — baked-in, dev-safe

`harden/Invoke-PrivacyHardening.ps1` + `harden/SetupComplete.cmd` apply a privacy-centric,
de-bloated configuration to a Windows 11 **developer** box — either automatically at install
time (the "baked-in" path you asked for) or standalone for testing.

The guiding rule: **harden without breaking the toolchain.** This is not a kiosk lockdown.

## What it does (and the single control surface)

Everything is gated by the `$H` toggle table at the top of the script. Read that table and you
know exactly what runs; flip any entry to `$false` to skip it. Summary:

Each toggle is an **action**: `$true` = DO IT (turn the feature off / apply), `$false` = leave the
Windows default. (The header comment in the script says this too — no more ambiguous `Telemetry = $true`.)

| Toggle | Default | What it does |
|---|---|---|
| `DisableTelemetry` | on | DiagTrack service off, `AllowTelemetry=0`, CEIP/appraiser scheduled tasks off |
| `DisableAdvertisingAndTips` | on | advertising ID, tailored experiences, Start & lock-screen "suggestions" off |
| `DisableActivityHistory` | on | Timeline / activity-feed upload off |
| `DisableCopilotAndRecall` | on | **Windows Copilot off + Recall (`DisableAIDataAnalysis`) off** — matters on the Copilot+ Acer |
| `DisableWebSearchAndCortana` | on | Bing/web results in Start off, Cortana off |
| `DisableSearchAccounts` | on | Windows Search "find my content" across **Microsoft + Work/School** accounts off (`IsMSACloudSearchEnabled`/`IsAADCloudSearchEnabled`) |
| `DisableWidgets` | on | Widgets / News & Interests off |
| `DisableLocationSpeechInking` | on | location, online speech, **inking/typing personalization + contact harvest** off (`TIPC`, `HarvestContacts`) |
| `DisableConsumerFeatures` | on | "suggested"/auto-installed consumer apps off |
| `DisableStartRecommendations` | on | Start **"Recommended"** section + tips/shortcut recommendations off (`HideRecommendedSection` + `Start_IrisRecommendations`) |
| `ShowFullAppsList` | on | Start **All apps** as a flat alphabetical list, not the 24H2/25H2 category grid (`HideCategoryView`) |
| `DisableProxyAutoDetect` | on | **"Automatically detect settings" / WPAD** auto-proxy off (`DisableWpad`, service kept running) |
| `DisableEdgeNags` | on | Edge first-run, startup boost, shopping/personalization telemetry off |
| `RemoveOneDrive` | on | stops OneDrive auto-install for new profiles + sync policy off (you use NextCloud) |
| `DebloatAppx` | on | removes consumer bloat — provisioned **and** already-installed — **with a KEEP guard** (below) |
| `DisableSMB1` | on | removes the legacy SMB1 protocol (safe, recommended even on dev) |
| `DisableDefenderSampleSubmission` | on | Defender **never auto-submits sample files** |
| `NeuterEdge` | on | Edge background/telemetry/feedback/recommendations off **+ kills the MSN "Times Square" new-tab feed** (`NewTabPageContentEnabled=0`) |
| `HardenFirefox` | on | Mozilla enterprise policy: telemetry / Pocket / Studies / **sponsored top-sites + shortcuts** all off & locked (LibreWolf-like) |
| `InstallFirefox` | on | register a **run-once first-logon** task that installs the baked-in offline Firefox, then self-destructs |
| `EnableRemoteDesktop` | on | RDP **on** (`fDenyTSConnections=0`) + firewall group + **NLA required** |
| `SetNetworkPrivate` | on | unidentified networks treated as **Private**, not Public (Network List Manager policy) |
| `DisableCloudDeliveredProtection` | on | **MAPS/cloud lookups + sample submission off** — real-time scanning stays on. **Reduces protection — your explicit choice.** |
| `NetworkHardening` | **off** | LLMNR / mDNS / NetBIOS off — aggressive; can break local dev discovery |
| `DefenderDevExclusions` | **off** | add Defender folder exclusions for build dirs (edit the list first) |

The two `off`-by-default toggles are the ones I said I'd let you decide rather than guess.
`NetworkHardening` is genuinely useful for a hardened endpoint but LLMNR/mDNS/NetBIOS are exactly
what some local dev/test discovery leans on — turn it on only if you don't. `DefenderDevExclusions`
reduces protection, so it stays off and empty until you list trusted build trees.

## What it deliberately does NOT touch (dev-critical keeps)

- **Windows Update, Microsoft Defender, Remote Desktop, the Windows Time service.** Defender in
  particular stays *on* — you run downloaded code; use `DefenderDevExclusions` for specific build
  folders instead of disabling AV.
- **The appx debloat has an explicit KEEP guard.** A package is removed only if its name matches a
  remove-pattern *and* matches no keep-pattern. Protected: **winget / App Installer, the Store,
  Windows Terminal, WebView2, the VCLibs / UI.Xaml / .NET framework packages**, and useful in-box
  tools (Calculator, Notepad, Paint, Snipping Tool, Camera, Defender UI). So even if a future
  Windows renames something into a remove-match, your toolchain packages can't be collateral.

## Per-user settings apply to the DEFAULT profile

At install time there is no user yet, so per-user tweaks are written into the **Default** user hive
(`C:\Users\Default\NTUSER.DAT`) — every profile created afterward inherits them. Running standalone
on a box that already has your profile? Add `-AlsoCurrentUser` to also apply them to `HKCU`.

### Fixing a box you've ALREADY deployed (and a specialize-timing caveat)

Two things don't fully take on the profile that Setup created during OOBE, even though the script
ran at specialize:

- **Per-user settings** are written to the Default hive *before* that first account exists. On a
  clean deploy the account inherits them — but anything you tweak later, or test on that same
  account, won't reflect a Default-hive-only change.
- **Appx debloat at specialize is flaky** — the Appx stack and Defender aren't always fully up that
  early, so a `Remove-AppxProvisionedPackage` / `Set-MpPreference` can silently no-op. This is the
  most likely reason LinkedIn / WhatsApp / Xbox survived on your first boot. The script now removes
  **both** provisioned *and* already-installed copies (`Get-AppxPackage -AllUsers`), which is more
  robust, but the timing risk at specialize remains.

**To retroactively harden the box that's already running** (fastest verify loop — do this on the
current test VM before rebuilding the ISO):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\harden\Invoke-PrivacyHardening.ps1 -Force -AlsoCurrentUser
```

`-Force` overrides the `.applied` marker; `-AlsoCurrentUser` applies the per-user settings to your
current logon (not just Default). Reboot after. Once you're happy with the result, rebuild the deploy
ISO so *new* deployments bake in the same v1.4.0 behavior.

## Baking it in — two things: place the script, then trigger it

**Place it:** `scripts\New-DeployableIso.ps1` injects `Invoke-PrivacyHardening.ps1` (+
`SetupComplete.cmd`) directly into `install.wim` at `\Windows\Setup\Scripts` (mount → copy →
dismount /Save) — exactly how you'd bake into a sysprep'd image, and more reliable than a
`sources\$OEM$` folder (which needs `<UseConfigurationSet>`, flaky on 24H2).

**Trigger it** — the answer file already does, the right way:

The shipped `autounattend-Win11.xml` runs the hardening from a **`RunSynchronousCommand` in the
specialize pass**. This is the universal trigger and it's why:

- **It runs as SYSTEM during Setup, BEFORE OOBE / any logon** — so it needs **no `<AutoLogon>` /
  `LogonCount`** and no credentials on disk. (You spotted this: `FirstLogonCommands` only fire when
  someone *logs in*, which for hands-off means enabling AutoLogon for a cycle. Specialize sidesteps
  the whole problem.)
- **It's immune to the OEM-firmware-key skip.** That skip applies only to `SetupComplete.cmd` /
  `OOBE.cmd`, so it works on the **Acer** (OEM key in firmware) exactly as on a VM.
- **It's self-guarding:** the command is `if exist … Invoke-PrivacyHardening.ps1 …`, so on plain
  stock media (no injected script) it's a no-op — the answer file stays reusable everywhere.

`SetupComplete.cmd` is kept as a **secondary** trigger for the case of booting the deploy ISO
*without* the answer file (interactive install): it auto-runs on machines with no firmware key, and
is skipped on OEM-key machines. Having both is safe because the script writes an **idempotency
marker** (`C:\ProgramData\PrivacyHardening\.applied`) on first run and no-ops thereafter (`-Force`
overrides).

> **Not fixed by a product key.** The SetupComplete skip is triggered by the OEM key in **firmware**
> (the ACPI **MSDM** table), which Setup reads directly. No answer-file key (GVLK or otherwise)
> removes or masks it — a GVLK only controls edition + activation. That's why the *specialize*
> trigger, not SetupComplete, is the one that matters on the Acer.

**Summary of triggers:**

| Trigger | Runs as | When | OEM-key machine (Acer) | Needs logon/AutoLogon |
|---|---|---|---|---|
| **specialize `RunSynchronousCommand`** (shipped) | SYSTEM | during Setup, pre-OOBE | **works** | no |
| `SetupComplete.cmd` (secondary) | SYSTEM | post-Setup, pre-logon | **skipped** | no |
| `FirstLogonCommands` | first admin user | at first logon | works | **yes** (auto-login for hands-off) |
| manual | you | any time | works | n/a |

## Browsers: Firefox only, hardened

Two separate pieces — **policy** (baked in, no network) and **install** (needs network):

**Policy is already handled by `HardenFirefox`.** Firefox reads enterprise policy from
`HKLM\SOFTWARE\Policies\Mozilla\Firefox`, so the hardening writes the LibreWolf-style baseline
*now* — before Firefox exists — and it takes effect the instant Firefox is installed: telemetry off,
Pocket off, Studies off, sponsored top-sites/Pocket off, default-browser-agent off, tracking
protection (incl. cryptomining + fingerprinting) on, onboarding/"what's new"/recommendation nags
off. `NeuterEdge` does the reciprocal on Edge (background mode, metrics, feedback, shopping,
recommendations all off) — full *uninstall* of Edge Stable is only officially supported in the EEA,
so outside it we neuter rather than remove.

**Install is baked in — offline, deferred to first logon.** `New-DeployableIso.ps1` downloads the
latest x64 offline installer **on the build host** (which has internet) and injects it into the
image at `C:\Windows\Setup\Files\FirefoxSetup.exe`. The hardening (running at specialize) does **not**
install it there — installers are happier once the OS is fully settled — instead it **registers a
run-once scheduled task** (`PrivacyHardening-InstallFirefox`, at logon, as SYSTEM) that:

1. installs Firefox silently (`/S`) from the local baked installer — **no network** (good for the
   Acer before wifi / USB-ethernet is up),
2. then **removes the task and its own helper script** (self-destruct), logging to
   `C:\ProgramData\PrivacyHardening\firefox_install.log`.

So it fires exactly once, on the first logon, and leaves nothing behind. Because the deploy ISO is
rebuilt each patch cycle, the baked Firefox is never more than a cycle stale.

- `New-DeployableIso.ps1 -FirefoxSetup <path>` uses a supplied installer instead of downloading
  (for an offline build host). `-NoFirefox` skips baking it.
- If the installer isn't present at first boot (e.g. `-NoFirefox`, or a standalone hardening run),
  `InstallFirefox` is a no-op — the Mozilla **policy** still applies whenever Firefox is installed.
  You can always install it later: `winget install --exact --id Mozilla.Firefox`.

To make Firefox the **default** browser you can't just flip a registry key — modern Windows
hash-protects per-user default associations. The two reliable routes:

- **Per-image (all new users):** build a default-associations XML (`dism /online
  /Export-DefaultAppAssociations:C:\assoc.xml` on a reference box where Firefox is already default,
  then `dism /image:<mount> /Import-DefaultAppAssociations:C:\assoc.xml` when remastering). This
  needs Firefox's ProgId, so capture it from a machine that already has Firefox.
- **Ad hoc:** set it once via Settings → Default apps after install.

If you want it fully automated, say the word and I'll add a `-DefaultBrowser` path to
`New-DeployableIso.ps1` that imports an associations XML into the image — but it needs that XML
captured from a box where Firefox is installed and set default, so it's a two-step you'd seed once.

## Defender — real-time scanning stays on, cloud lookups off

Two related toggles, both **on**:

- `DisableDefenderSampleSubmission` sets `SubmitSamplesConsent = Never Send (2)` — no automatic
  upload of sample files.
- `DisableCloudDeliveredProtection` additionally sets `MAPSReporting = 0` and the enforcing
  `Spynet\SpynetReporting = 0`. You **explicitly asked** for cloud-delivered protection off.

Defender's **real-time engine stays on** — files are still scanned locally. What's off is the cloud
lookup / MAPS reporting path. Be aware this genuinely **reduces protection** on a box that runs
downloaded code: cloud-delivered protection is what catches brand-new threats before local
signatures exist. It's your call and it's honored; flip `DisableCloudDeliveredProtection` to `$false`
if you'd rather keep the cloud on and only stop sample uploads.

## Test it first (on your real Windows box)

It's a normal elevated script — dry-eyes it on a throwaway VM or your test machine before baking:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\harden\Invoke-PrivacyHardening.ps1 -AlsoCurrentUser
```

Read `C:\ProgramData\PrivacyHardening\hardening_<stamp>.log` — every change (and every KEEP) is
logged. Reboot after.

## Notes for your specific machines

- **The Acer (Copilot+, Intel Core Ultra 9 288V, NPU):** `CopilotAndRecall` is the reason this
  matters more here than on the VM — it's the exact hardware Recall targets. Also remember **Home
  cannot host RDP**; the Pro upgrade you flagged is *required* for RDP-in, and keep NLA on.
- **VS 2022 telemetry is separate** from anything here — opt out in the installer's diagnostic-data
  setting and via the IDE (Help → Send Feedback → Settings), it's not a Windows toggle.

## Reversibility

Most changes are registry policies and can be reversed by deleting the values (or setting them back
to `1`/default). Removed provisioned appx packages are gone from *new* profiles but can be
reinstalled from the Store or via `winget`/`Add-AppxPackage`. SMB1 can be re-added with
`Enable-WindowsOptionalFeature`. Keep a VM snapshot before the first bake-in run if you want a
clean rollback.
