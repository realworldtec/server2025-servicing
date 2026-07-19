# docker/config

Config that `scripts/Install-Docker.ps1` applies after installing Docker. Each file is optional. To
use one, copy the `.sample` to its real name and edit it; the script applies real names only and
treats `*.sample` as templates.

| File | Applied to | Purpose |
|------|-----------|---------|
| `.wslconfig` | `%USERPROFILE%\.wslconfig` | Resource limits for the WSL2 VM (Docker's Linux backend) |
| `daemon.json` | `%ProgramData%\Docker\config\daemon.json` | Docker Engine settings (BuildKit, log rotation, GC) |
| `settings-store.json` | `%APPDATA%\Docker\settings-store.json` | Docker Desktop app settings (add your own sample) |

Contributions welcome — drop additional samples here as `<name>.sample`.

Do **not** commit secrets. In particular, `~/.docker/config.json` holds registry credentials; keep it
out of this folder and out of git. `daemon.json` and `.wslconfig` are not secrets.

`daemon.json` must be strict JSON with keys Docker recognises — no comment keys; the Docker daemon
rejects unknown keys. Validate with `python -m json.tool daemon.json` before applying.

## Network address space (keep Docker off production)

Production uses `172.16.0.0/16` and `172.17.0.0/16`. Docker's defaults collide with that, so the
sample repoints everything into `172.20.0.0/14`:

| Setting in `daemon.json` | Value | What it controls | Default (the conflict) |
|--------------------------|-------|------------------|------------------------|
| `bip` | `172.20.0.1/24` | the built-in `docker0` bridge | `172.17.0.0/16` — **directly on production 172.17** |
| `default-address-pools[].base` | `172.20.0.0/14` | subnets for user/compose networks | `172.17.0.0/16 … 172.30.0.0/16` |
| `default-address-pools[].size` | `24` | size of each allocated network | `24` |

The critical point: `default-address-pools` only governs *user-defined* networks (compose,
`docker network create`). It does **not** move `docker0` — `bip` does. Set both or docker0 stays on
172.17.

Address math: `172.20.0.0/14` spans `172.20.0.0`–`172.23.255.255` (i.e. 172.20–172.23), so it avoids
172.16–172.19 entirely. With `size 24` that's up to ~1024 `/24` networks. `docker0` takes the first
`/24` (`172.20.0.0/24`); Docker allocates user networks from the rest and skips any subnet already in
use, so `bip` sitting inside the pool base is not a conflict.

Mapping from your IaC variables:

```
DOCKER_POOL_BASE="172.20.0.0/14"   ->  default-address-pools[0].base
DOCKER_POOL_SIZE="24"              ->  default-address-pools[0].size
DOCKER_CIDR="172.20.0.0/14"        ->  same as base (docker0 bip is the first /24 of it)
```

### Also watch WSL2's own NAT

Docker Desktop runs its engine inside the WSL2 VM, and **WSL2 itself** creates a `vEthernet (WSL)`
NAT adapter with a *dynamically chosen* `172.x` subnet that can also land on 172.16/172.17 and
conflict — independent of anything in `daemon.json`. On Windows 11 22H2+ the clean fix is mirrored
networking (`networkingMode=mirrored` in `.wslconfig`), which drops the separate NAT and mirrors the
host's interfaces. Evaluate it before enabling: it changes some `localhost`/port-forwarding behaviour,
and confirm your Docker Desktop version is happy with it. The `.wslconfig.sample` has the line ready
to uncomment.
