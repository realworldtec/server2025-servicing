# Lessons learned

The non-obvious things that make Server 2025 (24H2) media servicing and store repair fail,
and how this tooling handles them. Written so the next person doesn't re-derive them the
hard way.

## Servicing / DISM

**1. Checkpoint cumulative updates change how you apply the LCU.**
Server 2025 CUs can have a prerequisite *checkpoint* CU. For the main OS (`install.wim`),
put the target LCU **and** its checkpoint in one folder and let `Add-WindowsPackage`
discover them — required when you also add features (.NET/NetFx3). For the **boot images**
(`boot.wim`, `winre.wim`), apply **only the single target LCU**.

**2. Never push the checkpoint into `boot.wim`/WinRE.**
WinPE is a stripped image; the checkpoint (an RTM-baseline CU) references components it
doesn't contain → `Add-WindowsPackage` fails with **`0x80073712`** (assembly missing).
WinPE is already at the checkpoint baseline (RTM 26100.1742), so the post-checkpoint target
LCU applies directly. This was the single biggest slipstream failure.

**3. WinRE is not serviced by the LCU.**
`winre.wim` gets the **servicing stack (via the CU)** + **SafeOS Dynamic Update** — the
latest cumulative update does not apply to it. Applying the combined CU to WinRE throws a
benign `0x8007007e` (handled/ignored).

**4. `RestoreHealth` needs a *version-matched* source.**
`0x800f0915` ("repair content could not be found") means the `/Source` doesn't hold the
**exact version** of the corrupt component — not that the source is absent. Match the
source build to the target, and use `/LimitAccess` so DISM doesn't burn time falling back
to a Windows Update path that already can't help.

**5. In-place-upgraded hosts carry orphaned component versions.**
A 2008 R2 → … → 2025 host can hold components at **pre-RTM builds** (we saw
`10.0.26100.1150`) that exist in **no** patched media (the slipstreamed `install.wim` is at
the current build; the FoD ISO is RTM). The **pristine, unmodified RTM ISO** is the source
of last resort for these — it carries the base component versions. Keep it on the shelf.

**6. Verify the source has the payload *before* RestoreHealth.**
Mount the candidate WIM read-only and confirm the `Windows\WinSxS\<component>` folder/files
exist (`Check-Packages.ps1`). Component identities come straight from CBS.log
`(p) CSI Payload Corrupt (n) …` lines. This converts a slow blind failure into a go/no-go.

**7. `ResetBase` only removes *superseded* components.**
If a corrupt component has no newer version installed (it's the only version), ResetBase
won't touch it. Don't expect ResetBase to "clean up" orphaned single-version corruption —
it won't. Also: ResetBase is irreversible (no more update uninstall). And **do not** run it
on an `install.wim` you intend to use as a repair source — it strips the payloads repairs
need. (This is why the slipstream cleans `install.wim` with `StartComponentCleanup` **only**,
no `/ResetBase`.)

**8. The FoD ISO is mandatory for optional/language/FoD repair.**
`install.wim` does **not** contain Features-on-Demand, language features, or many optional
packages. Staged FoDs with absent payloads are a common source of "repairable" state; only
the **Features-on-Demand ISO** (`\LanguagesAndOptionalFeatures`) can supply them. Point
`/Source` there for those.

**9. `sfc` and DISM check different things.**
`sfc /scannow` verifies protected **system files**; DISM CheckHealth/ScanHealth verify the
**component store**. A clean `sfc` with a "repairable" store (as here) is normal — repair
the store first, then run `sfc`.

## Microsoft Update Catalog (the flaky bit)

**10. It's an undocumented, intermittently-failing web endpoint.** Expect transient
"encountered an error", timeouts, and connect failures. Wrap every call in retry/backoff and
honor the **system proxy** (Invoke-WebRequest won't by default; a browser that works while
PowerShell can't = proxy).

**11. Parse the real markup.** The result GUID lives in the **Download `<input id="{GUID}">`**
in the row's last cell — not in an `<a id="…_link">` anchor. The download URLs come from the
`DownloadDialog.aspx` POST and use **prefixed CDN subdomains** (`b1.download.windowsupdate.com`,
`catalog.sf.dl.delivery.mp.microsoft.com`) — match URLs **host-agnostically**, ending in
`.msu`/`.cab`. Download with **BITS** (resumable) rather than a single web request.

## PowerShell gotchas that bit us

**12. Native-command output pollutes a function's return value.** `& dism.exe …` inside a
function is captured into the function output. Pipe it to `Out-Host` so the function returns
only its boolean.

**13. `,$array` return + `@()` at the caller nests the array.** The comma idiom emits the
array as one object; wrapping that in `@()` makes a 1-element array (count always 1) — a
false-positive. Pick one: comma-return *or* caller `@()`, not both.

**14. `Get-WindowsImage -ImagePath X.wim` (no `-Index`) omits `.Version`.** Query each index
individually to read the build. (Broke resume detection until fixed.)

**15. `Export-WindowsImage` appends to an existing target.** Clean stale `install2/boot2/
winre*.wim` before exporting, or you corrupt the output.

**16. Native argument quoting for `oscdimg`.** Passing the El-Torito `-bootdata` string with
embedded quotes through PowerShell to a native exe is unreliable on 5.1; emit a `.cmd` and
let `cmd` handle the quoting.

## Operational

**17. Match media to Patch Tuesday, and keep history.** A repair source must match the
target host's build. Build a patched ISO **every** Patch Tuesday and **archive** each one
(named by build) to a share, so you can always repair a host to whatever build it's on.

**18. Keep three ISOs on the shelf, permanently:** the **RTM ISO** (orphaned-version repairs),
the **FoD ISO** (optional/language repairs), and the **current patched ISO** (in-box repairs).

**19. Snapshot before touching a live store.** Memory-less VM snapshot; keep it until the
repair and any WinRE change are verified and the host has rebooted clean.

**20. Slipstream runs for hours — schedule it, don't babysit it.** Make it resumable and
unattended; run it off-hours the day after Patch Tuesday.
