# Incident write-up — CSFILES component-store repair

The case this tooling was built and hardened against. Included as a worked example of the
diagnostic depth required to "fix it properly" rather than reimage.

## Host

- **CSFILES** — Windows Server 2025 Datacenter (Desktop Experience), build **26100.32995**.
- VM on ESXi 8.0 U3 (Dell). **MBR** disk. Lineage: **2008 R2 → … → 2025** in-place upgrades.
- C: expanded 80→128 GB; recovery partition relocated with GParted (left WinRE Disabled).
- Disks C/D/E; scratch on E.

## Symptom

```
DISM /Online /Cleanup-Image /CheckHealth   → The component store is repairable.
DISM /Online /Cleanup-Image /RestoreHealth → 0x800f0915  (repair content could not be found)
```

Online repair failed because Windows Update/WSUS could not supply the payloads.

## Discovery (the depth that mattered)

1. **DISM log** — one `RestoreHealth` (no `/Source`) failing `0x800f0915`; CheckHealth said
   *repairable*. Most other "errors" were benign noise (`Time_InternalToPublic`,
   `WIMGetMountedImageHandle`, and a recurring failed attempt to disable a non-existent
   `Windows-Defender-Default-Definitions` feature).
2. **Pending state** — a reboot flag that appeared to survive a reboot. On close inspection:
   `RebootPending` key **absent**, `SessionsPending TotalSessionPhases = 0`; every flagged
   package was **`Staged`** (normal not-installed FoD state), **none** `InstallPending`. So:
   no stuck transaction.
3. **CBS.log (first pass)** — 289 `CBS_E_INVALID_PACKAGE (0x800f0805)` opens during a scan,
   overwhelmingly **Features-on-Demand / language / optional / role** packages with absent
   payloads. This is what made the store "repairable."
4. **CBS.log (from a sourced RestoreHealth)** — the authoritative summary:

   ```
   Total Detected Corruption:  348
   Total Repaired Corruption:  345
   Unrepairable:                 3   (Missing replacement payload)
   ```

   The three unrepairable files:

   ```
   amd64_bgpncprovider_..._10.0.26100.1150_none_1bf6588586e5a0fb\BgpServerProvider.mof
   amd64_ipamserverwmiv2provider_..._10.0.26100.1150_none_75a867a53ad31572\IPAMServerPSProvider.mof
   amd64_ipamserverwmiv2provider_..._10.0.26100.1150_none_75a867a53ad31572\IPAMServerPSProvider_Uninstall.mof
   ```

## Root cause

Two layers:

- **Bulk corruption (345 files):** staged FoD / language / CloudExperienceHost / optional
  components with absent-or-corrupt payloads — repairable from offline media, but **not**
  from Windows Update on this host.
- **Residual (3 files):** WMI MOF definitions for **BGP** (SDN/Network Controller) and
  **IPAM** — unused roles on a file server — pinned at build **`26100.1150`**, an
  orphaned pre-RTM version carried through the upgrade chain. That exact version exists in
  **no** patched media (patched `install.wim` = 26100.32995; FoD ISO = 26100.1742), so
  RestoreHealth reported *"Missing replacement payload"*. `ResetBase` couldn't help — the
  1150 components were the only version present (not superseded).

## Remediation

1. Built a **patched Server 2025 ISO** (build 26100.32995) via `Slipstream-Server2025.ps1`
   (RTM + 2026-06 LCU KB5094125 + checkpoint KB5043080 + SafeOS KB5094150 + Setup KB5095966
   + .NET KB5087051).
2. Snapshotted the VM (memory-less).
3. Repaired from **dual offline sources** (FoD ISO + patched `install.wim`, index 4,
   `/LimitAccess`): fixed **345 / 348**. `sfc /scannow` clean. 3 files remained (the 1150
   BGP/IPAM MOFs).
4. Mounted the **pristine RTM ISO** (H:), **verified** it carried the exact 26100.1150
   payloads with `Check-Packages.ps1`, then:

   ```
   DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:H:\sources\install.wim:4 /LimitAccess /ScratchDir:E:\DISMscratch
   → The restore operation completed successfully.
   ```
5. **WinRE** re-enabled: `Repair-Server2025Store.ps1 -EnableWinRE -SkipSfc` staged
   `Winre.wim` from the patched image and `reagentc /enable` succeeded (now on
   `partition2\Recovery\WindowsRE`).

## Outcome

```
DISM /Online /Cleanup-Image /ScanHealth   → The operation completed successfully.
DISM /Online /Cleanup-Image /CheckHealth  → No component store corruption detected.
sfc /scannow                              → did not find any integrity violations.
reagentc /info                            → Windows RE status: Enabled
```

Store: **348 → 0**. WinRE: **Disabled → Enabled**. No reimage required.

## Takeaways specific to this host class

- In-place-upgraded servers hoard orphaned component versions; **keep the RTM ISO** to
  repair them.
- Most "repairable" noise on a server is unused **staged FoDs** — the **FoD ISO** resolves
  those; `install.wim` alone cannot.
- **Verify the source** (`Check-Packages.ps1`) before each RestoreHealth so you never eat a
  blind `0x800f0915` again.
- Unused-role residual corruption (BGP/IPAM here) is acceptable to leave if a matching
  source can't be found and `sfc` is clean — revisit only if a future CU actually fails.
