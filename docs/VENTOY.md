# Ventoy: one stick, every install

This is the single reference for how the USB stick is built and configured. Ventoy is the piece
that lets **one** stick carry the Windows golden ISO, the Ubuntu 26.04 ISO, a Kali live ISO, and the
unattended templates for all of them — and boot any of them from a menu, without ever re-flashing
the drive or rebuilding an ISO.

If you only remember one thing: **you copy ISOs onto the stick like ordinary files, and a single
control file — `/ventoy/ventoy.json` — tells Ventoy how to drive the unattended installs.**

---

## Why Ventoy (vs. a plain flashed USB)

A normal bootable USB is *one* ISO, flashed, destroying whatever was there. To automate Setup you'd
have to rebuild the ISO with the answer file baked in. Ventoy inverts that:

- The stick is a normal filesystem. Drop as many ISOs on it as fit; Ventoy shows a boot menu.
- The **Auto Installation plugin** injects your unattended template (Windows `autounattend.xml`,
  Ubuntu cloud-init `user-data`) into the chosen ISO *at boot time* — the ISO itself is never
  modified. So the same untouched golden ISO is both a normal installer and an unattended one.
- **Variable expansion** prompts you for per-machine values (computer name, admin password) at boot,
  so one template serves many machines and no secret has to be stored on disk.

That's why there's no "config ISO" step in the Ventoy flow. (The separate `New-UnattendIso.ps1`
config-ISO path still exists, but it's for **non-Ventoy** targets — e.g. attaching the answer file
as a 2nd CD-ROM to an ESXi VM. On the Acer, Ventoy replaces it.)

---

## One-time: build the stick

1. Download Ventoy for your OS from ventoy.net (Windows: `Ventoy2Disk.exe`; Linux:
   `Ventoy2Disk.sh` or the WebUI; there's also a GUI).
2. Insert the USB stick (**this erases it** — Ventoy repartitions the drive; back up anything on it).
3. In Ventoy2Disk, before clicking Install:
   - **Option → Partition Style → GPT** (the Acer is UEFI).
   - **Option → Secure Boot Support → enabled** (so the stick boots with the Acer's Secure Boot on;
     see the enrollment step below).
   - Optionally **Option → Partition Configuration** to leave reserved space at the end (only if you
     want a second data partition; not required).
4. Install. Ventoy creates two partitions:
   - a large **exFAT** partition labelled `Ventoy` — this is where your ISOs and the `/ventoy`
     config folder go;
   - a tiny (~32 MB) FAT partition labelled `VTOYEFI` — Ventoy's own bootloader. Leave it alone.

**Updating Ventoy later** (new version): run Ventoy2Disk → **Update**. This refreshes only the
bootloader; **your ISOs and config are preserved.** You do not rebuild the stick to add or swap ISOs
— just copy files.

---

## What goes where on the stick

Everything lives on the big `Ventoy` (exFAT) partition:

```
Ventoy/  (exFAT data partition)
├── Win11-25H2-Pro-Golden.iso            <- the golden Windows ISO (Build-GoldenImage.ps1 output)
├── ubuntu-26.04-desktop-amd64.iso       <- Ubuntu installer
├── kali-linux-2026.x-live-amd64.iso     <- Kali (boots LIVE; no template needed)
└── ventoy/
    ├── ventoy.json                      <- THE control file (all plugins)
    ├── autounattend-Win11.xml           <- Windows answer file (auto_install template)
    └── autoinstall/
        ├── user-data                    <- Ubuntu autoinstall (auto_install template)
        └── meta-data                    <- required NoCloud companion to user-data
```

ISOs can sit at the root or in subfolders; the paths just have to match `ventoy.json`. The config
**must** be under `/ventoy/`. exFAT handles the >4 GB Windows ISO fine.

---

## `ventoy.json` — the control file

Location: **`/ventoy/ventoy.json`** on the data partition. It's the umbrella config for every Ventoy
plugin (auto-install, theme, password, persistence, …). It's strict JSON, so **no comment syntax** —
but Ventoy ignores keys it doesn't recognise, so `"//": "..."` entries act as harmless comments
(that's the trick used in this repo's `linux/ventoy.json`). You can also edit it with **VentoyPlugson**,
the official GUI editor, if you'd rather not hand-write JSON.

The one plugin you care about is `auto_install`:

```json
{
    "auto_install": [
        {
            "image": "/Win11-25H2-Pro-Golden.iso",
            "template": "/ventoy/autounattend-Win11.xml",
            "autosel": 1,
            "timeout": 10
        },
        {
            "image": "/ubuntu-26.04-desktop-amd64.iso",
            "template": "/ventoy/autoinstall/user-data",
            "autosel": 1,
            "timeout": 10
        }
    ]
}
```

| Key        | Meaning                                                                                          |
| ---------- | ------------------------------------------------------------------------------------------------ |
| `image`    | Path to the ISO on the stick. Fuzzy-matched, but keep filenames distinct. Edit to match reality. |
| `template` | Path to the unattended script on the stick (string, or an **array** for a pick-menu of several). |
| `autosel`  | Which template is pre-selected at the prompt. `0` = boot with **no** template (plain install).   |
| `timeout`  | Seconds the auto-install prompt waits before taking `autosel`.                                   |

Kali isn't listed here on purpose — with no `auto_install` entry it just boots live, which is what
you want for occasional use.

---

## Variable expansion — per-machine values, prompted at boot

Ventoy (1.0.77+) expands `$$NAME$$` tokens inside a template right before boot, popping a prompt for
each one. It substitutes into an **in-memory copy** — the file on the stick is never modified — then
hands that to the installer. This is how one template serves many machines while storing no secrets.

**Rules that actually bite:** at most **one variable per line**; the file must be **UTF-8**; names
can't start with `VT_` (reserved for Ventoy's built-ins like `$$VT_WINDOWS_DISK_1ST_NONUSB$$`, which
this project doesn't need since the answer file partitions disk 0 explicitly with diskpart). Note the
delimiter is **two** dollar signs on each side — `$COMPUTERNAME$$` will silently *not* expand and the
literal text ends up in your config.

### Windows — `autounattend-Win11.xml`

| Variable               | Lands in                              | Notes                                              |
| ---------------------- | ------------------------------------- | -------------------------------------------------- |
| `$$COMPUTERNAME$$`     | `<ComputerName>` (specialize)         | Names the box **during specialize** — no rename + reboot. Max 15 chars, no spaces. |
| `$$ADMINUSER$$`        | `LocalAccount/Name`                   | The local admin account name.                       |
| `$$ADMINDISPLAYNAME$$` | `LocalAccount/DisplayName`            | Cosmetic display name.                              |
| `$$ADMINPWD$$`         | `LocalAccount/Password/Value`         | **No cleartext stored anywhere** — typed at deploy. |
| `$$RESERVESPACE$$`     | the diskpart selector (Order 9)       | `1` = reserve 128 GB for Linux, `0` = whole disk.   |

**How `$$RESERVESPACE$$` works.** The diskpart chain is a single long line, and Ventoy permits only one
variable per line — so the reserve size can't be computed inline. Instead the answer file writes **two
complete layout scripts** unconditionally (`X:\dp_reserve.txt` and `X:\dp_full.txt`), and one selector
line picks between them:

```
cmd /c if "$$RESERVESPACE$$"=="1" (diskpart /s X:\dp_reserve.txt) else (diskpart /s X:\dp_full.txt)
```

Both layouts stay explicit and reviewable instead of being generated by arithmetic, and there's a
**fail-safe**: if the file is ever booted without the Ventoy template the token doesn't expand, the
comparison fails, and it falls through to the no-reserve layout — never a surprise 128 GB hole. To
reserve a different size, edit layout A's two numbers (`shrink desired=(N*1024+1026)`,
`minimum=(N*1024+1024)`), leaving `size=1026` alone.

### Ubuntu — `linux/user-data`

The same mechanism works on the cloud-init template:

| Variable            | Lands in                                    |
| ------------------- | ------------------------------------------- |
| `$$HOSTNAME$$`      | `identity.hostname`                         |
| `$$LINUXREALNAME$$` | `identity.realname`                         |
| `$$LINUXUSER$$`     | `identity.username`, the `~/.ssh` paths, and the ownership `runcmd` |

Two YAML-specific wrinkles worth knowing. Values are **quoted** (`hostname: "$$HOSTNAME$$"`) so
whatever you type stays a valid scalar. And `write_files:` has no `owner:` field, because
`owner: user:user` would need the variable **twice on one line**; ownership is instead done in a
`runcmd` that substitutes once into a shell variable and reuses it:

```yaml
- [ bash, -c, "U=$$LINUXUSER$$; install -d -m 700 -o $U -g $U /home/$U/.ssh; chown -R $U:$U /home/$U/.ssh" ]
```

**The password is deliberately not parametrised on Linux.** Subiquity requires a pre-computed SHA-512
crypt hash, and typing a 100-character `$6$…` string at a boot prompt is miserable. Keep the hash in
your gitignored `user-data` (a hash isn't cleartext, and it contains no `$$` pair so Ventoy ignores it).
`linux/user-data.sample` is the committed placeholder-only template.

---

## Secure Boot on the Acer (one-time enrollment)

With Secure Boot support enabled at stick-creation, the **first** boot of the stick on the Acer shows
a blue MOK (Machine Owner Key) screen: choose **Enroll key → Continue → Yes**, and confirm. This
trusts Ventoy's key once; subsequent boots go straight to the menu. Secure Boot can stay **on** the
whole time — Ubuntu and Kali boot via signed shim, and the Windows install is unaffected.

(Note for client work: some hardened environments distrust Ventoy's boot shim. That's a policy
consideration for someone else's machine, not your own laptop.)

---

## The deploy flow, end to end

1. **Boot** the Acer from the stick (F12 → the USB entry; firmware = UEFI).
2. If prompted, do the **MOK enrollment** once (above).
3. The **Ventoy menu** lists your ISOs. Pick one.
4. **Windows:** pick `Win11-25H2-Pro-Golden.iso` → the auto-install prompt appears → the answer-file
   template is pre-selected (`autosel: 1`) → Ventoy prompts for `COMPUTERNAME` / `ADMINPWD` if you've
   tokenised them → Setup **wipes disk 0**, lays down the partition layout (incl. the 128 GB Linux
   reserve), installs Pro, runs the privacy hardening at specialize, and finishes the Firefox / Office
   / Acrobat installs at first logon.
5. **Ubuntu (after Windows):** reboot from the stick → pick `ubuntu-26.04-desktop-amd64.iso` → its
   `user-data` template runs everything unattended **except** the storage screen, where you place
   Ubuntu into the 128 GB free space by hand (see `linux/README-dualboot.md`). GRUB then offers both
   OSes.
6. **Kali (any time):** pick the Kali ISO → it boots **live**, no install. Add persistence if you want
   settings/files to survive reboots (below).

Remove the stick when an installer asks you to.

---

## Kali live + persistence (optional)

Copy the Kali live ISO onto the stick and it boots live with no further config. To make changes
persist across reboots, use Ventoy's **persistence plugin**: create a persistence backing file
(Ventoy ships `CreatePersistentImg.sh`, or use a prebuilt `.dat`), drop it on the stick, and add a
`persistence` block to `ventoy.json` mapping the Kali ISO to that `.dat`. Live-USB Kali is slower
than an NVMe install but leaves zero footprint on the laptop — the right trade for occasional
internal tests.

---

## Maintenance quick reference

| Task                          | How                                                                        |
| ----------------------------- | -------------------------------------------------------------------------- |
| Add / swap an ISO             | Copy the `.iso` onto the `Ventoy` partition; delete the old one.            |
| Change an unattended template | Edit the file under `/ventoy/` (or `/ventoy/autoinstall/`). No rebuild.     |
| Change deploy behaviour       | Edit `/ventoy/ventoy.json` (or use VentoyPlugson).                          |
| Update Ventoy itself          | Ventoy2Disk → **Update**. ISOs and config are preserved.                    |
| Rename the machine at deploy  | Use `$$COMPUTERNAME$$` in the answer file; Ventoy prompts at boot.          |
| Keep the admin password off disk | Use `$$ADMINPWD$$` in the answer file; Ventoy prompts at boot.           |

---

## File map: repo → stick

| Repo file                              | Copy to (on the stick)                 | Role                                   |
| -------------------------------------- | -------------------------------------- | -------------------------------------- |
| `Build-GoldenImage.ps1` output ISO     | `/Win11-25H2-Pro-Golden.iso`           | Windows golden installer               |
| `unattend/autounattend-Win11.xml`      | `/ventoy/autounattend-Win11.xml`       | Windows answer file (auto_install)     |
| `linux/user-data` (gitignored; copy from `.sample`) | `/ventoy/autoinstall/user-data` | Ubuntu autoinstall + SSH keys   |
| `linux/meta-data`                      | `/ventoy/autoinstall/meta-data`        | NoCloud companion (required)           |
| `linux/ventoy.json`                    | `/ventoy/ventoy.json`                  | Ventoy control file (both OSes)        |
| (download) Ubuntu 26.04 desktop ISO    | `/ubuntu-26.04-desktop-amd64.iso`      | Ubuntu installer                       |
| (download) Kali live ISO               | `/kali-linux-2026.x-live-amd64.iso`    | Kali (live, no template)               |

---

## Gotchas

- **The answer file is `.gitignore`d.** It's your real, per-machine copy (it may hold a cleartext
  password, or `$$ADMINPWD$$`). Copy it from `unattend/autounattend-Win11.xml.sample` the first time.
  Only the `.sample` is committed.
- **`ventoy.json` is strict JSON.** A trailing comma or a real `//` line (not a `"//"` key) breaks
  parsing and the auto-install prompt silently won't appear. Validate it (`python -m json.tool` or
  VentoyPlugson) after editing.
- **Fuzzy image matching** means two similarly-named ISOs can collide. Keep filenames distinct.
- **Windows first, Ubuntu second** (Windows Setup would overwrite the Linux bootloader otherwise).
- **The internal TF/SD slot may not be a bootable device** in the Acer's firmware. Confirm in the F12
  menu before relying on a card as a boot target; the USB stick always works.
- **No auto-install prompt at boot?** Check: file is under `/ventoy/`, `ventoy.json` is valid JSON,
  and the `image` path matches the ISO filename.
- **A variable didn't expand?** It's almost always the delimiter — it must be `$$NAME$$`, two dollars
  each side. `$NAME$$` looks right at a glance and silently passes through as literal text.
- **Two variables on one line** is not allowed; Ventoy handles at most one per line. If you need a
  value twice, substitute once into a shell/script variable and reuse that (see the Ubuntu `runcmd`).
- **Don't write `$$TOKENS$$` in comments.** Ventoy substitutes by plain text search and doesn't know
  what a comment is, so tokens in prose get expanded too — and a comment line listing several of them
  breaks the one-per-line rule. Both answer files spell the names without `$` delimiters in prose.
