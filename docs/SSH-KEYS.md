# SSH keys on both builds (Windows + Ubuntu)

Each machine gets **two things** in the user's `~/.ssh`:

- an **identity keypair** (`id_ed25519` + `.pub`) so the box can SSH **out** (git, servers), and
- **`authorized_keys`** — the public key(s) allowed to SSH **in**, with the SSH server enabled.

"Two sets" = one keypair for the Windows user, one for the Ubuntu user. You supply the key material;
placeholders are shipped so nothing real is ever committed. Real keys are `.gitignore`d.

---

## Generate the keys (if you don't have them)

On any Linux/macOS box, or Windows with OpenSSH:

```bash
ssh-keygen -t ed25519 -C "windows@acer" -f ./win_id_ed25519      # Windows machine's keypair
ssh-keygen -t ed25519 -C "ubuntu@acer"  -f ./ubuntu_id_ed25519   # Ubuntu machine's keypair
```

The `authorized_keys` you place is whatever **public** key you want to log in *with* (typically the
`.pub` of your everyday workstation/laptop, not the machine's own key).

---

## Windows — drop files, the build bakes them in

Populate this folder (it's `.gitignore`d — copy each `.sample` to the real name and paste your key):

```
config/ssh/windows/
├── authorized_keys      <- public key(s) allowed to SSH IN
├── id_ed25519           <- the Windows box's PRIVATE identity key (outbound)
└── id_ed25519.pub       <- its public half
```

`New-DeployableIso.ps1` (v1.6.0+) detects `id_ed25519` there and bakes the three files into the image
at `\Windows\Setup\Files\ssh\`. At first logon, `Invoke-PostInstall.ps1` (v1.1.0+):

- copies the identity keypair into `C:\Users\Admin\.ssh\` and locks its ACLs (user + SYSTEM only);
- installs the **OpenSSH Server** feature, sets `sshd` to Automatic, starts it, opens TCP 22;
- writes the inbound keys to **`C:\ProgramData\ssh\administrators_authorized_keys`** — *not* `~/.ssh`;
- wipes the staged private key from `\Windows\Setup\Files\ssh\` afterward.

**The admin gotcha (why it's ProgramData):** Windows `sshd` ships a rule that, for any account in the
Administrators group, reads inbound keys **only** from `administrators_authorized_keys` and ignores
`~/.ssh/authorized_keys`. The deploy account (`Admin`) is an administrator, so inbound key auth only
works from that ProgramData file, with ACLs restricted to Administrators + SYSTEM. The post-install
handles this for you; it's the #1 reason "my key works on Linux but not Windows."

To point at a different key folder or account, pass `-SshKeySource <path>` to `New-DeployableIso.ps1`
(default `config\ssh\windows`); the target account is `Admin` to match the answer file's `LocalAccount`.

---

## Generating the SHA-512 password hash on Windows

**PowerShell has no equivalent of `mkpasswd --method=SHA-512`.** That format is glibc's `crypt(3)`
`$6$` scheme — not a plain SHA-512 digest — and neither PowerShell nor .NET implements it. (Python's
`crypt` module doesn't help either: it's Unix-only and was removed in 3.13.) So you shell out to
something that does. In order of convenience:

1. **openssl** — `openssl passwd -6`. If you have **Git for Windows**, you already have it at
   `C:\Program Files\Git\usr\bin\openssl.exe`. This is the usual winner.
2. **WSL** — `wsl -e openssl passwd -6`, or `wsl -e mkpasswd -m sha-512` (needs the `whois` package).
3. **Paste one in** — generate on any Linux box or the Ubuntu live session and paste it.

`New-UbuntuUserData.ps1` tries 1, then 2, and falls back to prompting you to paste. In every case the
tool prompts for the password itself, so the plaintext never lands in a PowerShell variable, your
console history, or any file — only the resulting `$6$…` hash does.

**None of these three is a hard requirement, and WSL is not installed by default.** They are a
convenience ladder: if you have `openssl` the script uses it; if not, it tries WSL; if neither is
present it simply asks you to paste a hash you made elsewhere. A build host with no `openssl` and no
WSL still works. Run `.\tests\Test-Prerequisites.ps1` to see which (if any) are present; see
`docs/PREREQUISITES.md` for the full required-vs-optional list.

## Ubuntu — generate the answer file with the script

Put your key material in `config/ssh/ubuntu/` (all `.gitignore`d — copy each `.sample` to its real
name). Key files may be named descriptively; the tooling discovers `id_*` pairs rather than assuming
an algorithm:

```
config/ssh/ubuntu/
├── authorized_keys      <- PUBLIC login keys, ONE PER LINE (blank lines and #comments ignored)
├── id_rwtgit            <- a private key (any name, any type)
└── id_rwtgit.pub        <- its public half (required — a pair is private + <name>.pub)
```

Then:

```powershell
.\linux\New-UbuntuUserData.ps1
```

It lists the pairs it found, asks which key ID to use (e.g. `id_rwtgit`), reads `authorized_keys`,
obtains the password hash, and writes `linux/user-data` — doing the indentation-sensitive YAML
assembly that makes hand-pasting a private key error-prone. Non-interactive form:

```powershell
.\linux\New-UbuntuUserData.ps1 -KeyId id_rwtgit -PasswordHash '$6$...' -Force
```

It refuses to overwrite without `-Force`, rejects leftover `REPLACE_WITH_YOUR` placeholders, and
errors out if a **private** key ever appears in `authorized_keys`. Crucially it leaves the Ventoy
tokens (`$$HOSTNAME$$`, `$$LINUXREALNAME$$`, `$$LINUXUSER$$`) **untouched** — those are substituted at
boot, not at generation — and verifies they survived.

## Ubuntu — or paste into the answer file by hand

Ubuntu's keys live **inline** in `linux/user-data` (there's no build step for it — you edit the file
that goes on the stick). Two places, both already stubbed with placeholders:

- **Inbound:** the `ssh: authorized-keys:` list — paste your public login key(s).
- **Outbound:** the two `write_files:` blocks — paste the private key body and its `.pub`.

`install-server: true` stands up `openssh-server`, and a `runcmd` fixes `~/.ssh` ownership/perms so
`sshd`'s StrictModes is satisfied. The username in the paths is `bert`; change it if you change
`identity.username`.

(`config/ssh/ubuntu/` exists only if you'd like to keep the Ubuntu key files together on disk — no
script reads it.)

---

## Security posture (read once)

Baking a private key into the Windows deploy image means **the deploy ISO now carries a secret.** That
ISO is already a private, self-contained artifact (it bakes Office and Acrobat too), so treat it
accordingly: keep the stick physically controlled, and never commit the real key files (the
`.gitignore` covers them). The source keys live only in `config/ssh/windows/` (gitignored) and the
staged copy is wiped from the installed box after first logon. If you'd rather the golden ISO stay
secret-free, leave `config/ssh/windows/` empty (SSH baking auto-disables) and drop keys by hand
post-install. For the Ubuntu side the same applies: the private key sits in `linux/user-data`, which
rides the stick, not git.

---

## Verify before you trust it

These changes touch two PowerShell scripts I could not run from here, and the Windows OpenSSH server +
ACL behavior is runtime-only. Before relying on it:

1. Run the quality gate: `.\tests\Invoke-QualityGate.ps1` (must pass, as always).
2. On a throwaway VM built from the deploy ISO, after first logon confirm:
   - `Get-Service sshd` is **Running**;
   - `icacls C:\ProgramData\ssh\administrators_authorized_keys` shows only Administrators + SYSTEM;
   - `ssh Admin@<box>` with your inbound key works;
   - `C:\Users\Admin\.ssh\id_ed25519` exists with locked ACLs.
   To re-run the post-install on a live box without rebuilding: `Invoke-PostInstall.ps1 -Force`.
3. Ubuntu: after install, `systemctl status ssh` is active and `ssh -i ~/.ssh/id_ed25519 ...` works.

Until that VM test passes, treat the Windows SSH path as **UNVERIFIED**.
