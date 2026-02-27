# Option B: CP/UP Split — UPF Flooding Attack + Prometheus/Grafana

## Background

Current state:
- **Single K3s node**: `venu-optiplex-5070` (8 cores, 31GB RAM, IP `10.194.185.167`)
- **Tailscale IP**: `100.67.28.109` (useful for cross-machine networking)
- **Full Open5GS stack** running in `open5gs` namespace (AMF, SMF, UPF, NRF, UDM, AUSF, BSF, NSSF, PCF, SCP, MongoDB)
- **UERANSIM** (gnb + gnb-ues pods) in same `open5gs` namespace
- SMF points to UPF via `open5gs-upf-pfcp` ClusterIP service

> [!IMPORTANT]
> Since there is only **one physical machine**, we simulate Cluster-2 using a **second K3s instance** running on the same machine with a different port/data-dir, OR we separate using namespaces+NodePort. The **cleanest realistic simulation** is: keep CP in `open5gs` namespace, move UPF to a **separate K3s instance** (`k3s-upf`) with its own kubeconfig, exposed via `NodePort` on the host.

> [!NOTE]
> An alternative that avoids a second K3s is to use **K3s namespace isolation** — move UPF to a new namespace `open5gs-upf`, update SMF to talk to it via `NodePort` IP. This is simpler and still demonstrates CP/UP separation cleanly.
> **We will use the namespace isolation approach** since we have one machine — this avoids complex multi-k3s setup while still proving the concept.

## Proposed Architecture

```
venu-optiplex-5070 (10.194.185.167)
│
├── Namespace: open5gs         ← Cluster-1 (Control Plane)
│   AMF, SMF, NRF, UDM, AUSF, BSF, NSSF, PCF, SCP, MongoDB
│   UERANSIM (gnb + ues)
│
└── Namespace: open5gs-upf    ← Cluster-2 (User Plane)
    UPF only
    Exposed via NodePort (GTPU: 2152, PFCP: 8805)
```

SMF in `open5gs` namespace → talks to UPF in `open5gs-upf` namespace via `NodeIP:NodePort`.

## Proposed Changes

---

### Component: UPF Isolation (New Namespace = "Cluster-2")

#### [NEW] UPF Namespace + Deployment in `open5gs-upf`
- Create namespace `open5gs-upf`
- Copy UPF ConfigMap from current `open5gs` namespace
- Update UPF config: bind N3 (GTP-U) and N4 (PFCP) to `eth0` (host IP accessible)
- Deploy UPF pod in `open5gs-upf` namespace
- Expose UPF via **NodePort** services:
  - PFCP (N4): `NodePort 38805`
  - GTP-U (N3): `NodePort 31085`

#### [MODIFY] SMF ConfigMap in `open5gs` namespace
- Change UPF address from `open5gs-upf-pfcp` (ClusterIP) → `10.194.185.167:38805` (NodePort)
- This makes SMF communicate with UPF as if it's in a different cluster

#### [DELETE] UPF from `open5gs` namespace
- Remove existing `open5gs-upf` deployment from the `open5gs` namespace
- Remove its services (`open5gs-upf-gtpu`, `open5gs-upf-pfcp`)

---

### Component: Prometheus + Grafana (Monitoring)

#### [NEW] Prometheus Stack on Cluster-1 (`monitoring` namespace)
- Install `kube-prometheus-stack` via Helm in `monitoring` namespace
- Monitors: all pods in `open5gs` namespace (AMF, SMF CPU/RAM)
- Grafana NodePort exposed at `32000`

#### [NEW] Prometheus Stack on Cluster-2 (`monitoring-upf` namespace)
- Second Prometheus install targeting `open5gs-upf` namespace
- Monitors UPF pod CPU/RAM/network during flood
- Grafana NodePort exposed at `32001`

#### [NEW] Custom UPF Grafana Dashboard
- Dashboard panels: UPF CPU%, UPF Memory, Network RX/TX bytes, Pod restart count

---

### Component: UPF Flooding Attack Script

#### [NEW] `upf_flood.sh`
- Runs `iperf3` or `wget` flood via all `uesimtun` interfaces simultaneously
- Captures `benchmark.sh` metrics during attack
- Records baseline → ramp-up → peak flood → recovery phases

---

## Verification Plan

### Step 1: Verify CP/UP Split Works
```bash
# Check UPF running in new namespace
kubectl get pods -n open5gs-upf

# Check SMF log shows PFCP association with new UPF IP
kubectl logs -n open5gs -l app=smf | grep -i "pfcp\|upf\|association"

# Check UPF log shows PFCP heartbeat from SMF
kubectl logs -n open5gs-upf -l app=upf | grep -i "pfcp\|heartbeat\|association"
```

### Step 2: Verify End-to-End Connectivity Still Works
```bash
# From UERANSIM gnb-ues pod — ping via UE tunnel
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -I uesimtun0 -c 5 8.8.8.8
```

### Step 3: Verify Prometheus Metrics Flow
```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Access: http://localhost:3000 (admin/prom-operator)
# Verify CPU/memory metrics visible for UPF pod
```

### Step 4: UPF Flooding Attack
```bash
# Run flood + benchmark simultaneously
./upf_flood.sh 120

# During flood — check UPF CPU spikes in Grafana
# Check packet drops in UPF logs
kubectl logs -n open5gs-upf -l app=upf | grep -i "drop\|error\|fail"

# Ping test should fail or degrade during flood
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -I uesimtun0 -c 20 8.8.8.8
```

### Step 5: Verify Recovery After Attack
```bash
# Stop flood, wait 30s, re-ping
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -I uesimtun0 -c 5 8.8.8.8
# Should recover to baseline latency
```
