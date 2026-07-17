# Ubuntu 26.04 LTS dual-boot alongside Windows 11 (Acer Lunar Lake)

This is the Linux half of the golden build. It installs Ubuntu 26.04 LTS into the **128 GB
left unallocated** by the Windows answer file (`unattend/autounattend-Win11.xml`), on the same
Ventoy stick you already use for the Windows install, and sets up a GRUB menu that offers both
Windows and Ubuntu at boot.

The single most important rule is at the top because everything else depends on it:

> **Install Windows FIRST, Ubuntu SECOND.** Windows is destructive (it wipes disk 0 and lays
> down the partition table, deliberately leaving 128 GB free). Ubuntu is installed *into that
> free space* and adds itself to the boot menu without disturbing Windows. Doing it the other
> way round lets Windows Setup overwrite the Linux bootloader.

---

## Why storage is done by hand (read this once)

Every other part of the Ubuntu install is automated by `linux/user-data` — locale, user account,
packages, updates, GRUB/os-prober wiring, reboot. **Partitioning is not**, on purpose.

Subiquity's automated storage model wants an exact, declarative partition list. A layout that
"installs into free space and preserves Windows" cannot be validated without booting this exact
machine, and if it's even slightly wrong it reformats disk 0 and destroys the Windows install you
just spent an hour building. So the answer file stops on — and only on — the storage screen
(`interactive-sections: [storage]`). You spend ninety seconds eyeballing the partition map, and the
one operation that can wipe your data always has human eyes on it. This is the recommended pattern
for autoinstall dual-boot, not a workaround.

If, after you've done this once and confirmed the exact layout, you want to fully automate storage
too, that's a follow-up — remove `storage` from `interactive-sections` and add a matching `storage:`
section. Don't do it blind.

---

## What you need

1. **Windows already installed** from the golden ISO, with the 128 GB reserve present. Confirm it:
   open an admin PowerShell in Windows and run `Get-Partition -DiskNumber 0`. You should see four
   partitions (EFI / MSR-reserved / Windows / Recovery) and, in `diskpart` → `list disk`, ~128 GB of
   free space on disk 0.
2. **Ubuntu 26.04 LTS Desktop ISO** (`ubuntu-26.04-desktop-amd64.iso`), copied to the Ventoy stick.
3. **The Ventoy stick** you already built for Windows. Nothing is reformatted; you just add files.
4. A **wired USB-Ethernet adapter** for the install (you tested this in the live session). Wi-Fi
   during an unattended install is unreliable; plug in Ethernet.

Before you start, in **Windows**: disable Fast Startup so it fully releases the disk and the clock.
Control Panel → Power Options → *Choose what the power buttons do* → uncheck *Turn on fast startup*
(or run `powercfg /h off` from an admin prompt). This prevents a hibernated Windows from locking the
EFI/NTFS partitions when Ubuntu's os-prober looks at them.

---

## Put the files on the stick

Copy these three files from `linux/` onto the **Ventoy partition** (the big exFAT one), keeping this
layout:

```
<Ventoy partition root>/
├── ventoy/
│   ├── ventoy.json            <- from linux/ventoy.json (edit ISO filenames to match!)
│   └── autoinstall/
│       ├── user-data          <- from linux/user-data  (edit timezone + password hash!)
│       └── meta-data          <- from linux/meta-data   (leave as-is)
├── ubuntu-26.04-desktop-amd64.iso
└── Win11-25H2-Pro-Golden.iso  (already there)
```

Two edits before you boot:

- **`ventoy/ventoy.json`** — make each `image` path match the exact ISO filename on your stick.
  Ventoy uses fuzzy matching, but keep them close. The shipped file already lists both the Windows
  and Ubuntu entries so one stick drives both installs.
- **`ventoy/autoinstall/user-data`** — set your `timezone`, and replace the placeholder password
  hash. Generate a real one on any Linux/macOS box (or the Ubuntu live session):

  ```bash
  openssl passwd -6            # prompts twice, prints a $6$... SHA-512 hash
  # or:  mkpasswd --method=SHA-512
  ```

  Paste the whole `$6$...` string as the `password:` value (keep the quotes). Never put a cleartext
  password in this file.

---

## Install

1. Boot the Acer from the Ventoy stick (F12 → the USB; firmware must be UEFI, Secure Boot on is fine
   — Ubuntu 26.04 boots signed via shim).
2. In the Ventoy menu, pick **`ubuntu-26.04-desktop-amd64.iso`**.
3. Ventoy shows an auto-install prompt — choose the **user-data** template (it's the default;
   it auto-selects after the 10-second timeout).
4. The installer runs unattended until the **storage / "How do you want to install Ubuntu?"** step,
   where it stops for you.

### The storage screen — the only part you drive

Choose **Manual / "Something else"** (not "Erase disk", not "Install alongside" — you want explicit
control). You'll see disk 0 (`nvme0n1`) with the partitions Windows created plus a block of free
space. Do exactly this:

| Partition        | Size     | What to do                                                                 |
| ---------------- | -------- | -------------------------------------------------------------------------- |
| `nvme0n1p1` EFI  | 512 MB   | **Reuse.** Set *Use as: EFI System Partition*. **Do NOT tick "Format".**    |
| `nvme0n1p2` MSR  | 16 MB    | Leave alone. (May not even show; it's Microsoft-reserved.)                  |
| `nvme0n1p3` Win  | balance  | **NEVER TOUCH.** This is Windows C:.                                        |
| `nvme0n1p4` Recov| ~1026 MB | **NEVER TOUCH.** Windows recovery.                                          |
| free space       | ~128 GB  | **Create your Ubuntu partition here** (see below).                          |

In the **free space**, create one partition:

- **Size:** the whole 128 GB (leave a little if you like, but the default swapfile means you don't
  need a swap partition).
- **Type:** ext4.
- **Mount point:** `/`.

Set **"Device for boot loader installation"** to the disk itself (`nvme0n1`) or the EFI partition —
on UEFI the installer writes GRUB into the ESP you marked above. Then continue.

> Sanity check before you hit Install: the summary must show **format** actions **only** on your new
> ext4 `/` partition. If it lists formatting `p1`, `p3`, or `p4`, stop and fix it — that would harm
> Windows.

5. The install finishes on its own and reboots. Pull the stick when prompted.

---

## First boot — the GRUB menu

On reboot you should land in the **GRUB** menu with entries for **Ubuntu** and **Windows Boot
Manager**. The answer file already enabled os-prober and ran `update-grub`, so Windows should be
listed.

If Windows is **not** in the menu, boot Ubuntu and run:

```bash
sudo os-prober          # should print the Windows Boot Manager it found
sudo update-grub        # regenerates the menu
```

(If os-prober finds nothing, make sure Windows Fast Startup is off — a hibernated Windows hides its
partition — then re-run the two commands.)

### If the firmware boots straight into Windows (no GRUB)

Some firmware re-orders itself and puts Windows first. From Ubuntu (or a live session):

```bash
sudo efibootmgr                       # list boot entries + current order
sudo efibootmgr -o <ubuntu>,<windows> # put 'ubuntu' (GRUB) first; use the 4-digit BootXXXX ids
```

Or just use the Acer **F12** one-time boot menu and pick *ubuntu* until you reorder it.

---

## Two dual-boot niceties

- **Clock skew.** Windows keeps the hardware clock in local time; Linux expects UTC, so the two can
  fight over the time. Fix it once, from Ubuntu:

  ```bash
  timedatectl set-local-rtc 1 --adjust-system-clock   # match Windows' local-time convention
  ```

- **Secure Boot.** Nothing to do — Lunar Lake needs no out-of-tree GPU/Wi-Fi drivers, so there are no
  unsigned kernel modules and no MOK enrolment. Ubuntu boots signed under Secure Boot as-is.

---

## Honest status

I could not build the ISO, boot the Acer, or run this installer — so treat this as a **reviewed
draft, not a validated run.** The mechanics (Ventoy `auto_install`, cloud-init `user-data` +
`meta-data`, `interactive-sections: [storage]`, os-prober/GRUB) are grounded in current Ventoy and
Ubuntu autoinstall docs, and storage is deliberately kept in your hands so the one destructive step
is never automated blind. The place to be careful is the storage screen; the sanity check above is
your seatbelt.
