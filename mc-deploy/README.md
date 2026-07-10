# On-Demand Minecraft Servers

Deploy/destroy Minecraft servers via GitHub Actions, running on your k8s homelab.

## How it works

- Each server gets its own namespace (`mc-<name>`), a Longhorn PVC for the world
  (kept even after the server is destroyed - Retain policy), and a LoadBalancer
  Service on a fixed internal IP.
- Up to 5 servers can run at once (expandable - see "Adding more slots" below).
- Since you don't have a domain, each slot maps to a specific external port on
  your public IP. The deploy script auto-picks a free slot.
- A self-hosted GitHub Actions runner lives in your cluster and does the actual
  `kubectl apply` work - no cluster credentials ever leave your network.

## One-time setup

### 1. Expand your MetalLB pool (if needed)
You already have `192.168.10.241-192.168.10.250` allocated, with `.241` used by
ingress-nginx. That leaves `.242-.250` - plenty for the 5 slots below. No change
needed unless you've allocated more elsewhere.

### 2. Create 5 port forwards in OPNsense (one-time, ~5 min)
Go to **Firewall > NAT > Port Forward > Add**, and create 5 rules like this
(repeat for each row):

| Interface | Protocol | Dest. Port | Redirect IP     | Redirect Port | Description   |
|-----------|----------|------------|------------------|----------------|---------------|
| WAN       | TCP      | 25565      | 192.168.10.242   | 25565          | mc-slot-1     |
| WAN       | TCP      | 25566      | 192.168.10.243   | 25565          | mc-slot-2     |
| WAN       | TCP      | 25567      | 192.168.10.244   | 25565          | mc-slot-3     |
| WAN       | TCP      | 25568      | 192.168.10.245   | 25565          | mc-slot-4     |
| WAN       | TCP      | 25569      | 192.168.10.246   | 25565          | mc-slot-5     |

For each rule, set **Filter rule association** to "Add associated filter rule"
so the WAN-side allow rule gets created automatically. Click **Apply Changes**
after adding all 5.

This is a one-time setup. The GitHub Action never touches OPNsense - it just
picks a free slot from this pre-wired pool.

### 3. Deploy the self-hosted runner
Edit `k8s/github-runner.yaml`:
- Set `REPO_URL` to your actual GitHub repo URL
- Set `ACCESS_TOKEN` (in the Secret) to a GitHub PAT with `repo` scope
  (classic token) - generate at https://github.com/settings/tokens

Then:
```bash
kubectl apply -f k8s/github-runner.yaml
kubectl get pods -n github-runner -w
```
Confirm it registers under your repo's **Settings > Actions > Runners**.

### 4. Push this repo to GitHub
Commit and push this whole structure (`.github/workflows/`, `k8s/`, `scripts/`)
to the repo you pointed the runner at.

## Using it

Go to your repo's **Actions** tab:

- **"Deploy Minecraft Server"** - fill in a server name, MC version, mod loader,
  and mod URLs (comma-separated, optional). Click **Run workflow**. Takes a
  few minutes (longer for modded - downloading everything fresh). The job
  summary will show the exact `IP:port` to hand out to friends.

- **"Destroy Minecraft Server"** - enter the server name, run it. The server
  and its k8s resources are removed; the world data stays on disk (Longhorn
  Retain) in case you want it later.

## Adding more slots

To go beyond 5 concurrent servers:
1. Add another OPNsense port forward rule (next free WAN port -> a new MetalLB IP)
2. Add the new IP/port pair to `SLOT_IPS` / `SLOT_PORTS` in `scripts/deploy-minecraft.sh`
3. Expand the MetalLB pool if you're out of free IPs in `.242-.250`

## Notes / things worth knowing

- **Your public IP can change** (Optimum gives a dynamic IP). Since there's no
  domain, you'll need to re-share the IP if it changes - the deploy script
  always prints the *current* public IP at deploy time, so it's accurate at
  that moment.
- **First boot is slow for modded servers** - downloading mod jars + world gen
  can take several minutes. The workflow waits up to 10 minutes before giving up.
- **Memory**: default is 4G per server. Watch total memory usage on
  `k8s-node-02` if running multiple servers at once - you only have one worker
  node right now.
- **Future upgrade path**: if you ever get a domain, `mc-router` can replace
  this whole port-based slot system with clean hostnames
  (`survival.yourdomain.com`) all sharing port 25565 - worth revisiting then.
