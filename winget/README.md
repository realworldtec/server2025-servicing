# winget role packages

Application sets installed on demand after deployment with `scripts/Install-Packages.ps1`. Nothing
here is baked into the golden image; the baseline stays minimal and these are pulled current by winget.

## Use

Elevated, after first logon (winget is unreliable as SYSTEM, so this is a you-run-it step):

```powershell
.\scripts\Install-Packages.ps1 -Role dev            # or admin, or pentest
.\scripts\Install-Packages.ps1 -Role admin -ListOnly   # preview, install nothing
```

## Manifests

One JSON file per role: `dev.json`, `admin.json`, `pentest.json`. Format:

```json
{
  "role": "dev",
  "description": "...",
  "packages": [
    { "id": "Git.Git" },
    { "id": "Microsoft.VisualStudio.2022.Community", "vsconfig": "vs/dev.vsconfig" },
    { "id": "SomePkg", "override": "--extra-installer-arg" }
  ]
}
```

- `id` — the winget PackageIdentifier.
- `vsconfig` — VS only; path (relative to this folder) to a `.vsconfig` whose workloads get installed.
- `override` — optional extra arguments passed to the package's own installer.

Contributions welcome — edit these lists or add role files. You can also generate a manifest from a
reference machine with `winget export -o reference.json` and cherry-pick ids from it.

**Verify the IDs.** The ids here are curated starting points, not guaranteed current — winget ids do
change. Confirm one with `winget search "<name>"` before relying on it. A wrong id just fails that one
package (the script warns and moves on); it does not stop the run.

## Visual Studio workloads (`vs/dev.vsconfig`)

`dev.vsconfig` lists the VS workloads/components to install, so VS Community comes down with your set
instead of the default multi-GB install. Edit it to your spec. The easiest way to author one: in the
Visual Studio Installer, configure the workloads you want, then **More -> Export configuration** to
produce a `.vsconfig`, and drop it here.

The installer path must be **space-free** (the repo at `C:\Projects\server2025-servicing` is fine).
If the repo lives under a path with spaces, `Install-Packages.ps1` skips the `--config` (to avoid
fragile argument quoting) and installs VS with default workloads; apply the `.vsconfig` by hand in
that case.

### Full VS setup (workloads + git globals + Options)

For the complete, repeatable VS setup, use `scripts/Setup-VisualStudio.ps1`: it installs VS with the
`.vsconfig`, applies git globals, and imports your Tools -> Options from a `.vssettings`. Export that
file once from a tuned VS (**Tools -> Import and Export Settings -> Export**) and drop it here as
`vs/<name>.vssettings`; the setup script imports it automatically. See `docs/VS2022-Community-Setup.md`,
including the Copilot suppression steps that matter after a VS update.

## Docker

Docker is its own script (`scripts/Install-Docker.ps1`, `docs/DOCKER.md`) because it also manages the
WSL2 backend and network address pools. It is intentionally not in these manifests.
