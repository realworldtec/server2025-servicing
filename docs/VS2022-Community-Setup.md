# Visual Studio 2022 Community Setup

This page covers installing Visual Studio 2022 Community on a fresh Windows VM
with minimal bloat and Copilot suppressed, alongside VS Code.

Both editors can coexist. The scripts in this repo support both via the `-Editor` parameter
(`VSCode` or `VisualStudio`).

> **Version note.** "Visual Studio 2022" is the entire **17.x** line. Updating (e.g. to 17.14) stays
> on 2022 - it is a newer minor of the same product, not a different edition, so there is no reason to
> refuse updates to "stay on 2022". Your **Tools -> Options settings persist across updates** (theme,
> preview features, git globals, the Copilot-badge hide - none of it is reset). The only thing a newer
> 17.x reintroduces is the Copilot *component*, which is why the suppression steps below matter after
> an update. See [Copilot suppression](#copilot-suppression).

---

## Scripted setup (recommended)

`scripts/Setup-VisualStudio.ps1` does the repeatable parts in one run: installs VS with the pinned
workload set, applies git globals, and imports your Tools -> Options via a `.vssettings` file.

```powershell
.\scripts\Setup-VisualStudio.ps1
# configure an existing install only:
.\scripts\Setup-VisualStudio.ps1 -SkipInstall -Settings .\winget\vs\RealWorldTec.vssettings
```

What is fully scripted: install + workloads, git globals, and almost all of Tools -> Options (via
`.vssettings`). What is not: a few newer toggles `.vssettings` does not round-trip, and durable Copilot
disabling (an ADMX/Group Policy - see below). The manual install walkthrough below still applies if you
prefer the UI.

---

## Installation

Download the installer from [visualstudio.microsoft.com](https://visualstudio.microsoft.com/vs/community/),
or install non-interactively:

```powershell
# Workloads CAN be pre-selected non-interactively with a .vsconfig via --override --config:
winget install -e --id Microsoft.VisualStudio.2022.Community `
  --override "--quiet --norestart --config C:\Projects\server2025-servicing\winget\vs\dev.vsconfig"
```

(The `--config` path must be space-free; `Setup-VisualStudio.ps1` guards this and falls back to default
workloads if it is not.) When installing from the UI instead, select only what you need on the
**Workloads** screen.

### Workload: .NET desktop development

> See [images/VSCommunity.png](images/VSCommunity.png) for the exact workload and
> optional component selections. The same set lives in `winget/vs/dev.vsconfig`.

**Included (cannot be deselected):**
- .NET desktop development tools
- .NET Framework 4.7.2 development tools
- C# and Visual Basic

**Optional - check these:**
- Development tools for .NET
- .NET Framework 4.8 development tools
- Just-In-Time debugger
- Blend for Visual Studio

**Optional - leave these unchecked:**
- Entity Framework 6 tools
- .NET profiling tools
- IntelliCode
- ML.NET Model Builder
- **GitHub Copilot** <- do not install
- **GitHub Copilot app modernization for .NET** <- do not install
- F# desktop language support
- PreEmptive Protection - Dotfuscator
- .NET Framework 4.6.2-4.7.1 development tools
- .NET Portable library targeting pack
- Windows Communication Foundation
- SQL Server Express 2019 LocalDB
- MSIX Packaging Tools
- JavaScript diagnostics
- Windows App SDK C# Templates
- Live Share
- .NET Framework 4.8.1 development tools

> **Why exclude Copilot at install time?**
> Installing the Copilot components adds background services, menu badges, and account
> prompts that appear throughout the IDE even if you never activate a subscription.
> It is significantly cleaner to exclude them at install time than to suppress them
> after the fact.

---

## Reproduce all Tools -> Options settings (`.vssettings`)

The cleanest way to script the settings below is to configure one VS the way you want, export a
`.vssettings`, and import it on every other machine.

1. In a tuned VS: **Tools -> Import and Export Settings -> Export selected environment settings**.
2. Save the `.vssettings` and drop it in `winget/vs/` (e.g. `winget/vs/RealWorldTec.vssettings`).
3. `Setup-VisualStudio.ps1` imports it automatically (or run `devenv /ResetSettings "<file>"`).

This reproduces the theme, preview-feature choices, the Copilot-badge hide, source-control UI toggles,
and editor preferences in one step. A handful of newer toggles do not round-trip through `.vssettings`;
set those by hand once (they persist across updates).

The manual settings below are documented for reference and for anything the export misses.

---

## Post-install configuration

Open Visual Studio, then go to **Tools -> Options** for each section below.

### Environment -> General

> See [images/environment-general.png](images/environment-general.png)

| Setting | Value |
|---|---|
| Color Theme | Dark |
| Separate font settings from color theme selection | checked |
| Use Windows High Contrast settings | checked |
| Apply title case styling to menu bar | checked |
| Use compact menu and search bar | checked |
| **Hide Copilot menu badge** | **checked** |

### Environment -> Extensions

| Setting | Value |
|---|---|
| Install updates automatically | checked |
| Allow synchronous autoload of extensions | unchecked |

Leave **Additional Extension Galleries** and **MCP Registries** empty unless you have a specific need.

### Environment -> Preview Features

Enable for performance/usability: Detect 32-bit assembly load failures; Enable Build Acceleration by
default; Enable Multi-Project Launch Profiles; Extension Manager UI Refresh; Load projects faster; Pull
Request Comments; Solution Load Cancellation; Support for Multi-root Workspaces; preview Windows Forms
out-of-process designer; project cache to speed up solution load.

Leave unchecked: new .NET 9+ Mono debugger for WASM; new .NET Mono debugger for MAUI; Initialize editor
parts asynchronously during solution load; Use previews of the .NET SDK.

### Source Control -> Plug-in Selection

| Setting | Value |
|---|---|
| Current source control plug-in | **Git** |

### Source Control -> Git Global Settings

> These mirror the git globals set at the command line; VS reads the same `~/.gitconfig`, so
> `Setup-VisualStudio.ps1`'s `git config --global` calls and this screen stay in sync.

| Setting | Value |
|---|---|
| User name | RealWorldTec |
| Email | realworldtec@gmail.com |
| Default location | C:\Projects |
| Default branch name | main |
| Prune remote branches during fetch | True |
| Rebase local branch when pulling | False |
| Enable download of author images from 3rd party source | unchecked |
| Commit changes after merge by default | checked |
| Enable push --force-with-lease | unchecked |

---

## Copilot suppression

Do this after any update that reintroduces Copilot. Two layers - remove the components, then a policy
to keep it off through future updates.

### 1. Remove the components

VS Installer -> **Modify** -> **Individual components** -> search `copilot` -> uncheck **GitHub
Copilot**, **GitHub Copilot Chat**, and **GitHub Copilot Completions** -> **Modify**. (Current VS ships
three Copilot components, not two.) Restart, and hide the status badge from the Copilot icon if it
lingers.

### 2. Keep it off across updates (ADMX / Group Policy)

Removing the components works today, but the durable way to keep Copilot off is Microsoft's Group
Policy, which is registry-backed:

1. Download the [Visual Studio Administrative Templates (ADMX/ADML)](https://www.microsoft.com/en-us/download/details.aspx?id=104405)
   into `C:\Windows\PolicyDefinitions`.
2. `gpedit.msc` -> **Computer Configuration > Administrative Templates > Visual Studio > Copilot
   Settings** -> set the disable policy. Per Microsoft: 17.10+ disables Copilot entirely or per-account,
   17.13+ can disable **Copilot Free**, 17.14.16+ can disable **Agent Mode**.
3. Restart Visual Studio.

Sources: [Admin controls for GitHub Copilot](https://learn.microsoft.com/en-us/visualstudio/ide/visual-studio-github-copilot-admin?view=vs-2022),
[Manage GitHub Copilot installation and state](https://learn.microsoft.com/en-us/visualstudio/ide/visual-studio-github-copilot-install-and-states?view=visualstudio).

> **Baking it into the golden image:** the ADMX policy writes a registry value under
> `HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\...`, which could go straight into
> `harden/Invoke-PrivacyHardening.ps1` so every dev box ships Copilot-suppressed. Microsoft does not
> publish the raw value name (it is inside the ADMX), so extract it once: apply the policy via gpedit,
> then `reg export "HKLM\SOFTWARE\Policies\Microsoft\VisualStudio" vs-copilot.reg` and read the value.
> That verified key can then be wired into the hardening.

---

## Winget install reference

```powershell
winget install Microsoft.VisualStudioCode -e
winget install Microsoft.VisualStudio.2022.Community -e   # add --override "--config <vsconfig>" to pin workloads
```
