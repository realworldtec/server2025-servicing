# Discovery — slipstreaming virtio-win drivers (Proxmox / KVM)

**Status: DISCOVERY ONLY. No code written. Nothing in this document has been executed.**

Every factual claim below is either (a) traced to a primary source and marked **[V]**, or
(b) marked **[U]** — unverified, requiring a check on the build host before it is relied on.
Anything I could not source, I have listed as an open question rather than guessed.

---

## 0. Stop here first — the version you asked for is the one Proxmox warns about

You asked for **virtio-win 0.1.285**, described as latest. Two findings, in order of importance.

**[V] 0.1.285 is genuinely the latest — and also the current `stable`.** The fedorapeople
archive tops out at `virtio-win-0.1.285-1` (published 2025-09-12/15), and both the
`latest-virtio` and `stable-virtio` directories currently point at the same 0.1.285 payload.
So Red Hat ships it as stable. Your version number is correct.

**[V] The Proxmox project explicitly recommends *against* it for Windows Server 2025.** The
Proxmox VE wiki (last edited 26 Jan 2026) states: *"Currently, there are no known issues for
version **virtio-win 0.1.271**"*, and lists under Known Issues:

> **0.1.285: VirtIO SCSI / VirtIO Block — read errors and performance issues with IO-heavy
> Windows Server 2025 VMs.** … reported to cause read errors / performance issues when
> running IO-heavy workloads, particularly seen with a Microsoft SQL Server.
> **virtio-win 0.1.271 seems to be unaffected and could be used as a workaround.**

The upstream bug is `kvm-guest-drivers-windows` issue **#1453**, attributed to commit
`1bbc422`. The mechanism, as described upstream: on modern Storport (which is what Server 2025
has), `StartIo` runs concurrently across CPUs/queues aggressively enough that two threads can
read the same `last_srb_id` and hand out **duplicate SRB IDs**; on completion the driver can
mismatch or fail to find the SRB ("No SRB found for ID"), producing a transient bad read that
SQL Server silently retries — *"a read of the file '\*.mdf' … succeeded after failing 1 time(s)"*
— and, under sustained load, reportedly hangs the SQL service after 2–3 days.

This matters disproportionately here because **the whole point of slipstreaming a driver is
that it lands in the boot path of every VM built from that media.** A bad storage driver
baked into golden media is not a per-VM inconvenience; it is a fleet-wide, silent,
data-path defect that surfaces as "SQL is weird lately."

**[U] There is an unresolved thread on 0.1.292.** Upstream discussion of #1453 mentions
"0.1.285, 0.1.292" as both carrying `1bbc422`. **0.1.292 does not exist in the public
fedorapeople archive** — the newest published build is 0.1.285-1. I could not determine
whether 0.1.292 is an internal/RHEL build, a pre-release, or a misremembered number. This is an
open question, not a fact. Whether #1453 has since been *fixed* in any build I also could not
confirm — the Proxmox wiki as of Jan 2026 still lists it as open, but that page may lag.

**Design consequence (my recommendation):** the driver version must be an **explicit, pinned
parameter with no default of "latest"**, and the pin for anything touching Server 2025 storage
should be **0.1.271** until #1453 is confirmed fixed. An auto-updating driver fetch is the
wrong shape for this problem — it converts an upstream regression into a silent change in your
golden media. This is the opposite of the update-detector pattern we built for the LCU, and
deliberately so.

---

## 1. Signing — what actually loads, and under Secure Boot

**[V] The public virtio-win builds are *not* WHQL-signed.** The build tag is literally
`virtio-win-prewhql-0.1-285`. Per the virtio-win-pkg-scripts README:

- Windows **8+** drivers carry Red Hat's **test signature**.
- Windows **10+** drivers carry a **Microsoft attestation signature**.
- **WHQL-signed builds are only available with a paid RHEL subscription.**

**[V] For our targets this is fine.** Windows 11 and Server 2025 take the *Windows 10+* path,
so the drivers we care about are **attestation-signed by Microsoft** — a real Microsoft
signature, which loads under Secure Boot. The scary Secure Boot warning in the virtio-win
README applies to the **test-signed** (Windows 8-era) drivers, which we are not touching.

**[V]** The ISO therefore also ships a `cert\Virtio_Win_Red_Hat_CA.cer` test certificate. **We
do not need it** for w11/2k25 amd64, and installing it would be a gratuitous trust-store
change. Do not import it.

**[U]** Whether `Add-WindowsDriver` accepts an attestation-signed `.cat` without
`-ForceUnsigned` — I expect yes (it is a valid Microsoft signature), but I have not run it.
**This is the single most likely thing to blow up on first execution**, and it must be tested
on one image before a multi-hour run. See §8.

---

## 2. The virtio-win ISO layout — exactly, from the packaging source

Not from memory. This is read out of `virtio-win-pkg-scripts` (`util/filemap.py`,
`make-virtio-win-rpm-archive.py`, `virtio-win.spec`).

**[V] Primary layout is `<Driver>\<os>\<arch>\`** — e.g. `NetKVM\2k25\amd64\netkvm.inf`,
`vioscsi\w11\amd64\vioscsi.inf`.

**[V] OS folder tokens** (`SUPPORTED_OSES`): `xp, 2k3, 2k8, 2k8R2, w7, w8, w8.1, 2k12, 2k12R2,
w10, 2k16, 2k19, w11, 2k22, 2k25`. Arches: `x86`, `amd64` (and `ARM64` for some).

**[V] Server 2025 and Windows 11 share the *same binaries*.** In `DRIVER_OS_MAP`, the single
build output `Win11/amd64` is copied to **both** `w11/amd64` **and** `2k25/amd64`. The catalog
signature strings confirm the same kernel target: `w11/amd64 → v.1.0.0._.X.6.4._.2.4.H.2` and
`2k25/amd64 → S.e.r.v.e.r._.v.1.0.0._.X.6.4._.2.4.H.2` — both 24H2. So Server 2025 and
Windows 11 24H2/25H2 take identical driver bits, just from different folders.

**[V] There is a second, *derived* tree on the ISO that will bite a naive recursive add.**
`create_auto_symlinks()` hard-links **viostor and vioscsi only** into a flattened
`<arch>\<os>\` tree — i.e. `amd64\2k25\viostor.inf` **and** `amd64\2k25\vioscsi.inf` sitting in
the *same* directory (`AUTO_ARCHES` maps `x86 → i386`). This is the "load driver, browse here"
convenience tree.

> **Trap:** `Add-WindowsDriver -Driver <ISO root> -Recurse` would add **every driver for every
> Windows version from XP to 2k25, in every architecture**, *and* pick up the duplicate
> viostor/vioscsi copies from the auto tree. It is exactly the kind of shortcut that appears to
> work and quietly bloats the driver store. **We must enumerate explicit per-driver /
> per-OS / per-arch folders.**

**[V] The ISO carries its own machine-readable manifest: `data\info.json`.** Generated by
`generate_version_manifest()`, one record per INF:

```json
{ "arch": "amd64", "driver_version": "<DriverVer from the INF>",
  "inf_path": "vioscsi/2k25/amd64/vioscsi.inf",
  "name": "<DeviceDesc>", "windows_version": "2k25" }
```

This is a gift. Rather than hardcoding a driver list (which rots every release), the script can
**read `info.json` from the mounted virtio ISO and derive the exact set of INFs for a given
`(windows_version, arch)`** — self-validating, version-proof, and it gives us a real dry-run
("here are the 14 INFs I will inject, at these versions") instead of a hopeful `-Recurse`.
I want to build it this way.

---

## 3. What actually exists for `2k25/amd64` and `w11/amd64`

From `DRIVER_OS_MAP`. Both tokens have identical coverage:

| Driver | Purpose | Boot-critical? |
|---|---|---|
| `viostor` | VirtIO **Block** disk | **Yes** (if VM uses VirtIO Block) |
| `vioscsi` | VirtIO **SCSI** disk | **Yes** (Proxmox default: *VirtIO SCSI single*) |
| `NetKVM` | VirtIO network | No (but wanted in WinPE) |
| `Balloon` | memory ballooning (+ `blnsvr.exe`) | No |
| `vioserial` | virtio serial — **the channel qemu-guest-agent uses** | No |
| `viorng` | entropy source | No |
| `vioinput` | input devices | No |
| `viogpudo` | VirtIO **display** | No |
| `pvpanic` / `pvpanic-pci` | guest panic notification | No |
| `qemufwcfg`, `fwcfg` | QEMU fw_cfg | No |
| `qemupciserial` | PCI serial | No |
| `smbus` | SMBus | No |
| `sriov` (`vioprot`) | SR-IOV protocol | No |
| `viomem` | virtio-mem hotplug | No |
| `viofs` | virtio-fs shared filesystem | No — **see caveat** |
| `viosock` | vsock | No |

**[V] `qxldod` does NOT exist for `w11` / `2k25`** — its map stops at `w10`/`2k16`/`2k19`. Any
"inject all the drivers" list copied from a Windows-10-era blog post will reference qxldod and
find nothing. Display on our targets is **`viogpudo`**.

**[V] `viofs` caveat:** the file list is `viofs.inf/.sys/.cat` **plus `virtiofs.exe`**. virtio-fs
on Windows also requires **WinFsp**, which is a separate product and is **not** on the virtio ISO
(it appears only as `winfsp-master-sources.zip` in the *source* RPM). Injecting the viofs INF
alone gives you a device with no working filesystem. **Recommend: exclude `viofs` from the
default set.**

**[V] The guest agent is not a driver.** `guest-agent\qemu-ga-x86_64.msi`,
`virtio-win-gt-x64.msi`, and `virtio-win-guest-tools.exe` are installers. They cannot be
injected with DISM. Getting them onto the installed OS is a *separate* problem (see §7,
open question).

---

## 4. Where drivers have to go — three images, three different reasons

Our media has three servicing targets, and they are not interchangeable:

| Image | Why it needs drivers | What to inject |
|---|---|---|
| `boot.wim` (idx 1 = WinPE, idx 2 = **Setup**) | Without a storage driver, Setup's disk-selection screen shows **"We couldn't find any drives."** This is the classic Proxmox-Windows-install failure. | **Storage only** (`vioscsi`, `viostor`) + optionally `NetKVM`. Keep it lean — boot.wim is loaded into RAM. |
| `install.wim` (each selected edition) | Stages drivers into the **driver store** of the installed OS, so the OS boots and has working NIC/balloon/serial from first boot. | The **full** selected set. |
| `winre.wim` (inside each edition at `\Windows\System32\Recovery\winre.wim`) | Without storage drivers, **WinRE cannot see the disk** — "Reset this PC", startup repair, and offline recovery all fail on the exact platform where you most need them. Routinely forgotten. | **Storage only** (`vioscsi`, `viostor`). |

**[U] Ordering within our existing pipeline:** drivers must be added **after** the LCU servicing
and **before** the `Export-WindowsImage` / commit of each image. The reasoning is that the LCU
can replace servicing-stack and driver-related binaries, and we want the driver store written
into the final committed state. I have not found a Microsoft statement that mandates this order
for offline driver add specifically — treat as a design decision, not a documented rule.

**Note:** this maps cleanly onto the existing loop. `winre.wim` is already serviced once (from
the first *selected* index) and copied into every exported edition, so WinRE drivers come along
for free with no extra mount cycles.

---

## 5. Alternative mechanism — `$WinPEDriver$` (worth knowing, not what I'd choose)

**[V]** Windows Setup automatically scans a `$WinPEDriver$` folder at the root of accessible
drives during the **windowsPE** pass and installs what it finds. Microsoft documents this —
and also documents its **limitations** (there is a Learn article titled exactly
*"Limitations of $WinPeDriver$"*). The key one: *the drive must be accessible during Setup and
must not itself require a storage driver to be loaded first.*

On Proxmox that condition normally holds (the install ISO is attached as an IDE/SATA CD-ROM, so
it is readable without virtio). It is a legitimate approach, and it has the appeal of *not*
modifying boot.wim at all.

**I would still inject into `boot.wim` instead**, because `$WinPEDriver$` makes the outcome
depend on how the VM's CD-ROM happens to be attached at install time, which is exactly the kind
of environmental coupling that turns into a support ticket six months later. We can offer
`$WinPEDriver$` as an *additional* belt-and-braces copy at near-zero cost — it's just a folder
on the ISO — but the boot.wim injection should be the load-bearing mechanism.

---

## 6. How this collides with the existing project — the real risks

This is the part that actually costs you time if we get it wrong.

**6.1 — Repair-source purity (the one I care about most).** `docs/RUNBOOK.md` and
`Repair-Server2025Store.ps1` treat the patched `install.wim` as a **DISM `/Source` for
`RestoreHealth`**. That is what fixed csFiles. A driver-injected `install.wim` adds third-party
driver packages to the image's driver store. **[U]** I believe this does not compromise its use
as a component-store repair source — component matching is by component version, and driver
packages are a separate mechanism — but **I have not verified it, and I am not willing to hand
you an ISO that might quietly degrade your one known-good repair path.**

> **Recommendation: the driver-injected ISO is a *different artifact* with a *different name*,
> built by an explicit switch, and archived separately.** The Server 2025 repair-source ISO
> stays driver-free. This costs a build; it protects the thing that already works.

**6.2 — Detector / archive glob collision.** `Watch-Server2025Updates.ps1` finds and archives
the finished build by globbing **`Server2025_Patched_*.iso`** (this is why v2.1.3 kept that
prefix load-bearing). A driver-injected Server 2025 build **must not** match that glob, or the
scheduled task will archive the wrong artifact as the month's repair source. It needs its own
`IsoPrefix` (e.g. `Server2025_Proxmox_Patched_`) — or the detector needs an explicit,
product-scoped glob. **Either way this is a required change, not optional.**

**6.3 — The resume marker will happily reuse a driver-free `install.wim`.** Our resume logic
keys on the **build version** of the serviced image. Adding `-Drivers` to an otherwise-identical
command **does not change the build version**, so a re-run would find the marker, skip
servicing, and ship an ISO **with no drivers in it** — while reporting success. This is a real
trap and exactly the class of bug that has cost you hours. **The resume marker must incorporate
the driver set/version (or `-Drivers` must force a rebuild).**

**6.4 — Trim/index interaction: none.** Driver injection is per-mounted-image and orthogonal to
the `install.wim` renumbering. `EditionMap_<stamp>.json` semantics are unchanged.

**6.5 — Runtime and size.** Each image gains a mount/inject/commit cycle. **[U]** I have no
measured figure; the honest answer is "minutes per image, not hours," and the driver payload for
one OS/arch is small (single-digit MB). But given the history here, I will not quote a number I
have not measured.

---

## 7. Open questions — I need answers before I write code

1. **[U] Does `Add-WindowsDriver` accept the attestation-signed virtio `.cat` without
   `-ForceUnsigned`?** Must be proven on one image before any long run.
2. **[U] Does a driver-injected `install.wim` remain a valid `RestoreHealth /Source`?**
   (Mitigated by 6.1's separate-artifact recommendation regardless of the answer.)
3. **[U] Is #1453 fixed in any shipping build, and does 0.1.292 exist publicly?** Currently the
   evidence says: no fix confirmed, 0.1.292 not in the public archive.
4. **[U] How do you want the guest agent / guest tools handled?** They're MSIs, not drivers.
   Options: leave them out (install manually / by your config management), or stage them on the
   ISO and invoke via `SetupComplete.cmd`. **I have not verified how `$OEM$` / `SetupComplete.cmd`
   behaves on plain media-based Setup without an answer file** — I will not guess at it.
5. **Which Proxmox disk bus do your VMs actually use?** VirtIO SCSI (Proxmox default) → `vioscsi`
   is the boot-critical one. VirtIO Block → `viostor`. Injecting both is cheap and I'd default to
   both, but the answer changes which one *matters*.

---

## 8. Proposed shape (for approval — not implemented)

Sketch only, so you can shoot holes in it before I spend your time:

- **New product-profile fields**, so nothing about drivers is hardcoded outside `$PRODUCTS`
  (this is now enforced by quality-gate Rule D):
  `DriverOsToken` (`2k25` for Server2025, `w11` for both Win11 profiles), `DriverArch` (`amd64`).
- **New parameters:** `-VirtioIso <path>` (explicit; no auto-download, no "latest"),
  `-DriverSet Storage|Standard|All` (default **Standard** = storage + NetKVM + Balloon +
  vioserial + viorng + vioinput + viogpudo + pvpanic; **excludes viofs**, see §3),
  `-IncludeDriver` / `-ExcludeDriver` for overrides.
- **Enumeration driven by `data\info.json`**, not a hardcoded list — with a hard failure if a
  requested driver has no entry for the `(os, arch)` pair, rather than silently injecting nothing.
- **A driver-aware `-DryRun`** that prints every INF, its `DriverVer`, and which of the three
  images it will be injected into — *before* anything mounts. Given the history of this project,
  the dry run is the deliverable that matters most.
- **A distinct `IsoPrefix`** for driver-injected builds, so the Server repair-source automation
  cannot pick it up (§6.2), and a **resume marker that includes the driver set** (§6.3).
- **A version guard:** if `-VirtioIso` resolves to 0.1.285 *and* the product is Server2025 *and*
  the driver set includes storage → **warn loudly, and require `-AcceptKnownIssue1453`** to
  proceed. I would rather annoy you at second 30 than have you find out via SQL Server in three
  months.

---

## 9. My recommendation, stated plainly

Build it, but **pin to 0.1.271, not 0.1.285**, for anything whose storage path touches Server
2025 — and make the version an explicit, non-defaulting parameter so this decision is always
made consciously. Keep the driver-injected media as a **separate artifact** from the repair-source
ISO. And prove the `Add-WindowsDriver` signature behaviour on a single image before committing to
a multi-edition run.

## Sources

- [virtio-win-pkg-scripts README (signing, downloads)](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md)
- [virtio-win-pkg-scripts `util/filemap.py` (DRIVER_OS_MAP, FILELISTS, SUPPORTED_OSES)](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/util/filemap.py)
- [virtio-win-pkg-scripts `make-virtio-win-rpm-archive.py` (info.json, auto-symlink tree)](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/make-virtio-win-rpm-archive.py)
- [virtio-win.spec (build tag `virtio-win-prewhql-0.1-285`, shipped driver list)](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/virtio-win.spec)
- [Proxmox VE wiki — Windows VirtIO Drivers (0.1.271 recommendation; 0.1.285 known issue)](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers)
- [kvm-guest-drivers-windows issue #1453 — vioscsi read-retry on Server 2025](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1453)
- [fedorapeople archive-virtio (0.1.285-1 is newest; latest == stable)](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/)
- [Microsoft Learn — Limitations of $WinPeDriver$](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/limitations-dollar-sign-winpedriver-dollar-sign)
