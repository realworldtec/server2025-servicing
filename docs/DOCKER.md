# Docker on a deployed box

Docker is deliberately kept out of the golden image. It is installed per machine, on demand, with
`scripts/Install-Docker.ps1`. This keeps the baseline minimal and avoids committing every machine to
the WSL2/hypervisor stack.

## Why not in the image

Running Linux containers on Windows needs a Linux kernel, which means the WSL2 backend (or a Hyper-V
VM). Baking that into every image would enlarge the attack surface, add stateful components that do
not belong in a deterministic baseline, and turn on the Windows Hypervisor Platform, which changes how
VMware Workstation runs on the same box. None of that belongs in a hardened golden image, and Docker
installs in a few minutes when a machine actually needs it.

## Install

Run elevated:

```powershell
.\scripts\Install-Docker.ps1
```

It does three things, each skippable:

1. Ensures the WSL2 backend (features + kernel, no distro). A reboot is required the first time these
   features are enabled.
2. Installs Docker Desktop with winget.
3. Applies any config you placed in `docker/config` (see that folder's README).

Useful variants:

```powershell
.\scripts\Install-Docker.ps1 -SkipInstall     # only (re)apply docker/config
.\scripts\Install-Docker.ps1 -SkipWsl         # backend already set up
```

After the reboot, start Docker Desktop and verify:

```powershell
docker run --rm hello-world
```

If you just want a Linux shell without Docker: `wsl --install -d Ubuntu`.

## Licensing and alternatives

Docker Desktop is free for personal use, education, and small business, but a larger organisation
needs a paid subscription. Confirm which applies to you. Two open-source alternatives run Linux
containers over the same WSL2 backend and install the same way — pass a different package id:

```powershell
.\scripts\Install-Docker.ps1 -WingetId RedHat.Podman-Desktop
.\scripts\Install-Docker.ps1 -WingetId SUSE.RancherDesktop
```

Their config layouts differ from Docker Desktop's, so the `docker/config` files apply cleanly only to
the Docker Engine / WSL side (`.wslconfig`, `daemon.json`).

## Relationship to the EnableWsl image flag

`Deploy.psd1` has an `EnableWsl` flag (default `$false`). If you set it, the post-install enables the
WSL and VirtualMachinePlatform features at deploy time, so a machine is already WSL-ready and this
script's step 1 is a no-op. Leaving it off (the default) is fine — this script enables the backend
itself when you run it. Either way, Docker is never in the image.
