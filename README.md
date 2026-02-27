# Open5GS 5G Core on K3s — Stress Testing with Cilium eBPF & Multus CNI

A complete 5G core network (Open5GS) deployed on K3s with CUPS (Control/User Plane Separation), Multus CNI for multi-interface isolation, and Cilium eBPF for optimized datapath routing. Includes automated UPF stress testing scripts and sub-second metrics capture.

## Architecture

```
venu-optiplex-5070 (K3s Single Node)
│
├── Namespace: open5gs          ← Control Plane
│   AMF, SMF, NRF, UDM, AUSF, BSF, NSSF, PCF, SCP, MongoDB
│   UERANSIM (gNB + 20 UEs)
│
└── Namespace: open5gs-upf     ← User Plane (Isolated)
    UPF with Multus interfaces:
    ├── eth0  (Cilium eBPF)  → 10.0.0.102    (N3 Data Plane)
    ├── net1  (Multus MACVLAN) → 192.168.100.10 (N3 GTP-U)
    ├── net2  (Multus MACVLAN) → 192.168.100.11 (N4 PFCP)
    ├── net3  (Multus MACVLAN) → 192.168.100.12 (N6 Egress)
    └── ogstun (Open5GS)      → 10.45.0.1      (UE Tunnel)
```

## Key Results

| Architecture | UPF Peak CPU (20 UEs × 100Mbps iperf3 flood) |
|---|---|
| Flannel + IPTables | **214m** |
| Flannel + Multus | **1-2m** |
| **Cilium eBPF + Multus** | **0.8m** (99.6% reduction) |

## Repository Structure

```
├── k8s-manifests/
│   ├── open5gs/           # SMF ConfigMap (Control Plane)
│   ├── open5gs-upf/       # UPF Deployment, ConfigMap, Services, NADs
│   └── multus/            # Network Attachment Definitions
├── scripts/
│   ├── upf_flood.sh       # HTTP/wget flood attack script
│   ├── upf_flood_iperf3.sh # iperf3 UDP flood attack script
│   ├── cadvisor_metrics.sh # Sub-second (200ms) cgroup metrics logger
│   └── benchmark.sh       # Basic benchmark script
├── configs/
│   └── rollback/          # Working rollback configs (pre-Cilium)
└── docs/
    ├── architecture_diagram.md
    ├── cilium_detailed_explanation.md
    ├── cilium_test_report.md
    ├── multus_detailed_explanation.md
    ├── comprehensive_5g_stress_test_report.md
    ├── commands_reference.md
    └── ...
```

## Quick Start

```bash
# 1. Deploy Open5GS on K3s (Helm)
helm install open5gs gradiant/open5gs -n open5gs --create-namespace

# 2. Isolate UPF into separate namespace
kubectl apply -f k8s-manifests/open5gs-upf/

# 3. Install Multus + NADs
kubectl apply -f k8s-manifests/multus/upf-nads.yaml

# 4. Install Cilium (replace Flannel)
helm install cilium cilium/cilium --version 1.18.5 -n kube-system

# 5. Run stress test
./scripts/upf_flood_iperf3.sh 60

# 6. Capture sub-second metrics
sudo ./scripts/cadvisor_metrics.sh open5gs-upf upf 60 200
```

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture Diagram](docs/architecture_diagram.md) | Visual breakdown with Mermaid diagrams |
| [Cilium Integration](docs/cilium_detailed_explanation.md) | eBPF integration steps, issues, and fixes |
| [Multus Integration](docs/multus_detailed_explanation.md) | Multi-interface setup, K3s path fixes |
| [Stress Test Report](docs/comprehensive_5g_stress_test_report.md) | All 3 test results (Flannel vs Multus vs Cilium) |
| [Sub-Second Test](docs/cilium_test_report.md) | 200ms cAdvisor metrics capture during attack |
| [Commands Reference](docs/commands_reference.md) | All deployment & debugging commands |

## Tech Stack

- **Kubernetes:** K3s v1.31
- **5G Core:** Open5GS
- **Radio Simulator:** UERANSIM (20 UEs)
- **CNI:** Cilium v1.18.5 (eBPF) + Multus (MACVLAN)
- **Metrics:** cgroup v2 direct reads (200ms resolution)
