# Installing Windows 11 on ESXi without vCenter — the answer file

## The actual problem (it isn't the ISO)

The patched Win11 ISO is fine. What stopped the install is that **Windows 11 Setup refuses to run
without TPM 2.0**, and your ESXi VM has no virtual TPM. That is a *platform* gap, not a media
defect — and it has nothing to do with slipstreaming, Rufus, or Winhance.

Two ways out:

1. **Give the VM a vTPM.** On standalone ESXi this is genuinely awkward. A vTPM needs a *key
   provider*, and the built-in **Native Key Provider requires the host to be in a cluster** — i.e.
   vCenter. It *is* technically possible to add a vTPM to a VM on a lone ESXi host by managing the
   encryption keys manually through PowerCLI APIs, **but those keys are not persisted across host
   reboots** — after every reboot you'd have to re-add them or the VM won't power on. For a lab,
   that's not worth it.

2. **Tell Setup to skip the check.** This is the pragmatic route, and it's what
   `unattend/autounattend-Win11.xml` does. It writes the `LabConfig` bypass keys
   (`BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`, …) *before* Setup's compatibility
   gate runs — the same trick Rufus applies to USB media, just delivered through an answer file so
   it also works from an attached ISO and runs fully unattended.

> **Trade-off, stated honestly:** bypassing the TPM means no TPM for the OS to bind to, so
> BitLocker/device-encryption auto-provisioning won't seal to hardware and Windows will consider
> itself "unsupported" (no guaranteed feature updates via Windows Update; you patch it yourself,
> which is what this whole project already does). Fine for a lab; think twice for anything you'd
> call production.

## What the answer file does

`unattend/autounattend-Win11.xml` — read the header comment in the file; the essentials:

- **Bypasses** TPM / Secure Boot / RAM / storage / CPU checks (LabConfig, windowsPE pass).
- **Wipes disk 0** (via a `diskpart` script in windowsPE) and creates a clean UEFI/GPT layout with a
  **dedicated recovery partition** plus **128 GB left unallocated at the end for a Linux dual-boot**:
  EFI 512 MB + MSR 16 MB + Windows (balance) + Recovery 1026 MB + 128 GB free (recovery is hidden, with
  the correct type GUID + GPT attributes, and sits immediately after C: so WinRE servicing can still
  grow it). Portable to any disk size. **It destroys disk 0 with no prompt** — only attach it to a VM
  (or machine) you mean to install fresh. *(A plain `DiskConfiguration` can't set the recovery
  partition's GPT attributes, which is why this uses diskpart; `InstallTo` targets partition 3 =
  Windows.)* The 128 GB reserve is set by two numbers in the diskpart line (`shrink desired=132098
  minimum=132096` and `create partition primary size=1026`); the comment above that line documents how
  to resize it or remove it (for a Windows-only box, use `shrink desired=1026 minimum=1024` and drop
  `size=1026`).
- **Selects the edition by NAME** (`/IMAGE/NAME` = `Windows 11 Pro` by default, matched to the Pro
  KMS GVLK `W269N-WFGWX-YVC9B-4J6C9-T83GX`; keep the two on the same edition), *not* by
  index — so it keeps working whether your media is **trimmed** (renumbered) or **full**. This
  sidesteps the whole "index 3 became index 1 after trim" hazard. Confirm the exact names in your
  media with `.\scripts\ISO_Inventory.ps1 -Product Win11-25H2`.
- **Skips OOBE** — no Microsoft account, no network gate — and creates a **local administrator**.
- Sets en-US locale and a time zone (change it).

Before you use it, edit three things (all flagged in the file): the **local Admin password**
(`CHANGE-ME`), the **TimeZone**, and — if you don't want Enterprise — the **edition name** and its
matching product key.

## Getting the answer file to Setup

Windows Setup automatically reads `autounattend.xml` from the **root of any attached
removable/optical drive**. The clean way — which keeps your golden patched ISO untouched — is a
tiny second ISO that carries only the answer file, attached as a **second CD/DVD** on the VM.

Build it on the management host with the ADK's `oscdimg` (already installed for the slipstream):

```powershell
$src = 'C:\Projects\server2025-servicing\unattend'      # folder containing autounattend-Win11.xml
# the file MUST be named autounattend.xml at the ISO root:
Copy-Item "$src\autounattend-Win11.xml" "$env:TEMP\ans\autounattend.xml" -Force
$oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
& $oscdimg -u2 -udfver102 -lUNATTEND "$env:TEMP\ans" 'D:\PatchedImages\Win11-unattend.iso'
```

Then, on the VM:

1. Firmware = **EFI** (VM Options → Boot Options). Win11 requires UEFI.
2. Attach **two** CD/DVD drives: (1) your patched `Win11_25H2_Patched_*.iso`, (2)
   `Win11-unattend.iso`.
3. Boot from the patched ISO. When Setup starts it finds `autounattend.xml` on the second disc and
   runs the whole install unattended — no F6, no "can't run Windows 11", no MSA.

> **Why not bake the answer file into the golden ISO?** Because it wipes disk 0 with no prompt.
> Baked in, *every* boot of that media — including an accidental one, or a future interactive
> install — would silently destroy the target disk. Keeping it on a separate, clearly-named disc
> makes the destructive behaviour opt-in. If you still want it baked in for a dedicated
> deploy-only image, do it knowingly on a copy, never on your archived repair-source media.

## Boot-order gotcha: the CD won't boot on a VM that already has Windows

**Symptom:** you set the CD/DVD first in the VM's boot order, power on, and instead of the installer
you get **no "Press any key to boot from CD…" prompt at all** — the VM boots straight into the
existing install (or just sits there). You wipe the disk (e.g. gparted, `diskpart clean`) and *then*
the install starts. Infuriating, and it looks like the ISO is broken. It isn't.

**Why:** on **UEFI**, firmware doesn't just walk a device order — it walks **NVRAM boot entries**.
The moment Windows is installed it writes a `Windows Boot Manager` entry, and that entry outranks
the CD/DVD **even when you've put the CD-ROM first in the firmware's device list**. So the firmware
boots the existing OS off disk and never tries the CD — which is exactly why you never see the
keypress prompt (the prompt only appears when the firmware actually hands off to the optical boot
sector). Wiping the partition table deletes the EFI bootloader, the competing entry disappears, and
the firmware finally falls through to the DVD.

**This image wipes disk 0 on boot anyway,** so its intended target is a *blank* disk — and a blank
disk has no competing boot entry, so the CD boots first-try with no drama. Two ways to avoid the
manual wipe on repeat redeploys:

- **Cleanest for a throwaway VM:** delete the virtual disk and add a fresh empty one (or just
  delete and recreate the VM). Nothing on disk to compete → the CD boots immediately.
- **Keep the disk:** on power-on use **ESXi → VM Options → Boot Options → Force EFI setup** (applies
  to the next boot only), then in the EFI **Boot Manager** pick the DVD-ROM explicitly. One-time, no
  wipe. You can also raise the **Boot Delay** (e.g. 5000 ms) to give yourself time to catch it.

Rule of thumb: a **blank/detached disk** sidesteps this entirely; a disk carrying a prior Windows
install will always fight you until you either wipe it or force the boot device.

## Do you even need to slipstream Win11? (your "thinking out loud")

Fair question, and the answer is **probably not, for a lab** — with one correction to the premise.

**Microsoft does not publish continuously-patched Win11 ISOs.** The business/consumer ISO from the
Microsoft site (or via the Media Creation Tool / UUP) is refreshed only occasionally and typically
**lags the current LCU by weeks to months**. So "download it already patched" isn't quite real —
a fresh download still pulls the month's cumulative update on first Windows Update.

So it comes down to *when* the media has to be current:

| Situation | Best path |
|---|---|
| Lab VM with internet, you'll Windows Update it anyway | **Stock MS ISO + this answer file + WU.** Slipstreaming buys you little. |
| Golden image that must be current **at deploy time** with no WU round-trip | **Slipstream** (what this project does). |
| Offline / air-gapped | **Slipstream** — there's no WU to lean on. |
| Server 2025 | **Slipstream stays.** Licensed media, and its `install.wim` doubles as your `RestoreHealth` repair source — that parity is the whole point. |

In other words: keep the slipstream for **Server 2025** (unchanged) and for any Win11 media you
need current *offline*. For everyday lab Win11 VMs, a stock ISO plus this answer file is a
perfectly good, much faster path — you skip the ~4-hour build entirely. You can even drop
`Win11-25H2` / `Win11-24H2` from `RunMediaJobs` in the config if you decide you don't need patched
Win11 media on a schedule; the profiles stay for the occasions you do.

## Debloat / customization (Rufus & Winhance)

Neither the answer file nor the slipstream debloats — deliberately. The "magic" you're seeing in
those tools is two separable things:

- **The requirement bypass** (Rufus, and the LabConfig keys above). That's what unblocks ESXi, and
  you now have it in a form you control.
- **Debloat + user-experience tuning** (Winhance, and the same author's *UnattendedWinstall*).
  [Winhance](https://github.com/memstechtips/Winhance) is a **post-install** GUI app: run it on the
  freshly-installed VM to remove Store apps, strip telemetry, set privacy/UI/power preferences,
  etc. It can also *generate an autounattend.xml from your selections* and build custom ISOs via
  its WIMUtil — so if you want debloat baked in rather than applied after, generate that answer
  file with Winhance/UnattendedWinstall and merge its `oobeSystem`/`FirstLogonCommands` choices
  into this one (this file is intentionally minimal so it's easy to extend).

Recommended flow for a lab VM: **stock (or patched) ISO + this answer file → clean unattended
install → run Winhance once** to debloat/customize. Keep the two concerns separate; each stays
simple and auditable.

## Sources

- [William Lam — vTPM on ESXi without vCenter (manual key management; not persisted across reboots)](https://williamlam.com/2023/10/support-for-virtual-trusted-platform-module-vtpm-on-esxi-without-vcenter-server.html)
- [Broadcom KB — "The host does not support Native Key Provider" (NKP needs a cluster)](https://knowledge.broadcom.com/external/article/369538/cannot-add-vtpm-on-virtual-machine-or-en.html)
- [Windows OS Hub — install Windows 11 on unsupported hardware (LabConfig bypass, current for 24H2/25H2)](https://woshub.com/windows-11-unsupported-hardware-no-tpm-secure-boot/)
- [Winhance — Windows Enhancement Utility (post-install debloat; autounattend generator)](https://github.com/memstechtips/Winhance)
- [UnattendedWinstall — the answer-file generator behind Winhance's baked-in customization](https://github.com/memstechtips/UnattendedWinstall)
