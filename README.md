# Azure VNet Lab

Terraform template for a two-tier Azure networking lab with NSG flow logs, Traffic Analytics,
Azure Monitor Agent telemetry, and Connection Monitor.

## Architecture

```
                         Internet
                             |
                  SSH (104.12.106.70/32)
                             |
+-----------------------------------------------------------+
|  Resource Group: nwlab-rg  (eastus2)                      |
|                                                           |
|  +-----------------------------------------------------+  |
|  |  VNet: 10.0.0.0/16                                 |  |
|  |                                                     |  |
|  |  +-----------------------+                          |  |
|  |  |  frontend-subnet      |                          |  |
|  |  |  10.0.1.0/24          |                          |  |
|  |  |  NSG: allow SSH/22    |                          |  |
|  |  |                       |                          |  |
|  |  |   +---------------+   |                          |  |
|  |  |   | VM1 (nginx)   +<--+--- Public IP (Static)   |  |
|  |  |   | Standard_D2s  |   |                          |  |
|  |  |   | AMA | NW Agent|   |                          |  |
|  |  |   +-------+-------+   |                          |  |
|  |  +-----------|-----------+                          |  |
|  |              | TCP:80 / ICMP (Connection Monitor)   |  |
|  |  +-----------|-----------+                          |  |
|  |  |  backend-subnet       |                          |  |
|  |  |  10.0.2.0/24          |                          |  |
|  |  |  NSG: allow HTTP/80   |                          |  |
|  |  |       from frontend   |                          |  |
|  |  |                       |                          |  |
|  |  |   +---------------+   |                          |  |
|  |  |   | VM2 (nginx)   |   |                          |  |
|  |  |   | Standard_D2s  |   |                          |  |
|  |  |   | AMA | NW Agent|   |                          |  |
|  |  |   +---------------+   |                          |  |
|  |  +-----------------------+                          |  |
|  +-----------------------------------------------------+  |
|                                                           |
|  +----------------------+   +------------------------+    |
|  | Network Watcher      |   | Storage Account        |    |
|  | - VNet Flow Logs v2  +-->| (flow log retention)   |    |
|  | - Connection Monitor |   +------------------------+    |
|  +----------+-----------+                                 |
|             |                                             |
|  +----------v------------------------------------------+  |
|  | Log Analytics Workspace (nwlab-law, 30-day)         |  |
|  | - Traffic Analytics (NetworkMonitoring solution)    |  |
|  | - DCR: Perf counters + Syslog (both VMs)           |  |
|  | - Connection Monitor results (TCP:80 + ICMP)        |  |
|  +-----------------------------------------------------+  |
+-----------------------------------------------------------+
```

## Resources provisioned

| Resource | Details |
|---|---|
| VNet | `10.0.0.0/16`, two subnets |
| frontend-subnet | `10.0.1.0/24`, NSG allows SSH from one source IP |
| backend-subnet | `10.0.2.0/24`, NSG allows HTTP/80 from frontend only |
| VM1 (frontend) | Ubuntu 22.04, Standard_D2s_v3, public static IP, nginx/iperf3/tcpdump |
| VM2 (backend) | Ubuntu 22.04, Standard_D2s_v3, private only, nginx/iperf3/tcpdump |
| VNet Flow Logs | JSON v2, 7-day retention, Traffic Analytics enabled (60 min interval) |
| Log Analytics | PerGB2018 SKU, 30-day retention |
| Azure Monitor Agent | Installed on both VMs via extension |
| Data Collection Rule | Perf counters (CPU, mem, disk, net) + Syslog at Warning+ |
| Network Watcher Agent | Installed on both VMs for Connection Monitor |
| Connection Monitor | frontend→backend TCP:80 and ICMP every 30s; optional homelab endpoint |

## Usage

```bash
terraform init
terraform apply -var='ssh_public_key=<your-pubkey>'

# Optional: include a homelab endpoint in Connection Monitor
terraform apply \
  -var='ssh_public_key=<your-pubkey>' \
  -var='homelab_public_ip=<your-ip>'
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `location` | `eastus2` | Azure region |
| `prefix` | `nwlab` | Prefix for all resource names |
| `admin_username` | `azureuser` | VM admin user |
| `ssh_public_key` | _(required)_ | SSH public key for VM access |
| `homelab_public_ip` | `""` | Optional homelab IP for hybrid path monitoring |
