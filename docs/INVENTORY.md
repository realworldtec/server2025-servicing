# Machine inventory

`scripts/Get-MachineInventory.ps1` captures the full state of a machine as delivered: hardware,
drivers, installed applications, runtimes, services, startup items, and optional features. Run it
once on the OEM image before wiping it. The main reason to do this is drivers. The vendor image is
the one place a matched set of Lunar Lake drivers exists, and some of them are not on Windows Update.

## What it collects

Hardware covers system make/model/serial, BIOS, CPU, memory modules, disks, graphics, network
adapters, battery, TPM, and Secure Boot state.

Drivers are captured two ways. `Win32_PnPSignedDriver` gives a per-device list with versions, dates,
INF names, and hardware IDs. `pnputil /enum-drivers` gives the third-party driver store list, which
is the set the export copies. By default the script also runs `pnputil /export-driver` to save the
actual driver files, so they can be reinjected into the golden image later.

Applications cover Win32 programs from the registry Uninstall keys, Store/Appx packages including
provisioned ones, and a runtimes list (Visual C++ redistributables, .NET Framework, .NET runtimes,
and similar).

System configuration covers services, startup items, enabled optional features, and installed
capabilities.

## Running it

Run from an elevated PowerShell. Elevation is required for the driver export and for some driver
fields.

```powershell
.\scripts\Get-MachineInventory.ps1
```

Options:

- `-OutputRoot <path>` sets where the output folder is created. Default is the current directory.
- `-SkipDriverExport` inventories drivers but does not copy the files. Faster and needs no admin.
- `-OpenReport` opens the HTML report when finished.

## Output

The script creates `MachineInventory_<host>_<timestamp>\` containing:

- `report.html` — a single self-contained report. Open it in any browser.
- `data\*.json` — one file per category (`hardware.json`, `drivers_signed.json`,
  `drivers_thirdparty.json`, `apps_win32.json`, `apps_appx.json`, `runtimes.json`, `services.json`,
  `startup.json`, `features.json`, `capabilities.json`). Use these to diff the Home baseline against
  the golden Pro build later.
- `drivers\` — the exported third-party driver store, unless `-SkipDriverExport` was used.
- `inventory.log` — the run transcript.

## Reusing the exported drivers

The exported `drivers\` folder holds one subfolder per driver package, each with its `.inf`, `.sys`,
and `.cat` files. To add them to the golden image offline, mount the image and run
`Add-WindowsDriver -Path <mount> -Driver <drivers folder> -Recurse`, or apply them on a live machine
with `pnputil /add-driver <drivers folder>\*.inf /subdirs /install`. Keep drivers that match the
target hardware; a full OEM export includes packages you may not need.

## Status

This script has not been run from the build environment, which has no PowerShell. Structure and
syntax were checked statically. Run `tests\Invoke-QualityGate.ps1` before relying on it, and expect
to confirm the first real run on the target.
