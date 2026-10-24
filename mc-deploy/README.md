# On-Demand Minecraft Servers

Spin up any Minecraft server on the homelab cluster from the **Actions** tab: Java (vanilla,
Paper, Purpur, Fabric, Forge, NeoForge, Quilt, or a Modrinth modpack) or Bedrock. The run
opens the router port itself and tells you the address to give friends.

## Buttons

| Workflow | What it does |
|---|---|
| **Deploy Minecraft Server** | New server (or brings back a kept world with the same name) |
| **Destroy Minecraft Server** | Removes it and closes its router port. The world is **kept** unless you tick *delete world* |
| **List Minecraft Servers** | Running servers, their addresses, and kept worlds |

The deploy's job summary has the line that matters: **Friends connect to `x.x.x.x:port`**.

### Deploy options

- **edition**: `java` or `bedrock`.
- **type** (Java): `vanilla`, `paper`, `purpur`, `fabric`, `forge`, `neoforge`, `quilt`, or
  `modrinth` for a modpack (put its Modrinth slug or URL in **modpack**, e.g.
  `fabulously-optimized`).
- **mc_version**: e.g. `1.21.1` or `latest`. Old versions get the right Java automatically
  (Java 8 below 1.17, Java 17 below 1.20.5).
- **mods**: comma-separated. Jar URLs and/or Modrinth project names (`lithium,sodium`). Paper and
  Purpur treat URLs as plugins.
- **memory** (`4G`), **world_size** (`10Gi`, ignored when reusing a world), **public**
  (untick for a LAN-only server).

## How it works

- Each server gets a namespace `mc-<name>`, a Deployment running
  [itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server) or
  [itzg/minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server), and
  a world volume.
- **Every server shares one LAN IP, `192.168.10.242`**, on its own port: Java TCP 25565-25579,
  Bedrock UDP 19132-19146 (15 of each at once). The lowest free port is picked automatically.
- **Router:** when public, the deploy runs `homelab-port open`, which adds a port forward on
  OPNsense through its API, and destroy closes it. Setup and details: `homelab-k8s/docs/PORTS.md`.
- **Worlds** live on the `longhorn-retain` storage class: deleting the server keeps the volume
  (labelled `mc-world=<name>`), and deploying the same name re-attaches it. Kept worlds are
  backed up nightly with the rest of the cluster.
- Jobs run on the in-cluster runner (`runs-on: [self-hosted, homelab-k8s]`), which already has
  `kubectl` access; the runner itself is managed in `homelab-k8s`, not here.

## Notes

- **Your public IP can change** (Optimum's is dynamic). The deploy prints the current one; once
  there's a domain, friends can use a name instead.
- **First boot of modpacks is slow** (downloads + world gen). The deploy waits up to 20 minutes.
- **Capacity:** the worker has 4 CPU cores and 30 GB RAM shared with everything else. Each
  server reserves half a core and its memory setting.
- `k8s/github-runner.yaml` is the old runner manifest, kept for reference only.
