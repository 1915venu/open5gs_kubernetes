# Multus CNI Integration — Dedicated UPF N3/N4/N6 Interfaces

## Background

Currently the UPF pod has a single `eth0` interface (+ `ogstun` TUN for UE subnets). All PFCP (N4), GTP-U (N3), and egress (N6) traffic share this one interface.

Adding **Multus CNI** will give the UPF three dedicated secondary interfaces:
- `net1` → **N3** (GTP-U data plane, from gNB)
- `net2` → **N4** (PFCP control plane, from SMF)
- `net3` → **N6** (egress to internet, optional)

This enables per-interface traffic metrics in Grafana and a cleaner flood proof.

## Master Interface Choice

We have two options for the MACVLAN master:

| Option | Interface | State | Notes |
|---|---|---|---|
| **A** | `cni0` (K3s bridge) | UP | Available, all pods use it — risk of interference |
| **B** | `demo-oai` (OAI bridge) | DOWN (no carrier) | Pre-existing, isolated, safe to repurpose |
| **C** | `eno1` (physical NIC) | DOWN (no cable) | Best option if cable plugged in |

**Recommended: Option B (`demo-oai`)** — bring it up and use it as isolated MACVLAN master. No risk of disrupting existing CNI traffic.

> [!IMPORTANT]
> Since `demo-oai` has no carrier, MACVLAN sub-interfaces will work internally on the same host (intra-node) but will not reach external physical networks. This is fine for our single-node test scenario.

## Proposed Changes

---

### Component 1: Install Multus CNI

#### [NEW] Multus CNI DaemonSet
- Deploy Multus using the official "thick" daemonset manifest
- K3s stores CNI configs at `/var/lib/rancher/k3s/agent/etc/cni/net.d/` — Multus must write its config here

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```

---

### Component 2: Bring Up `demo-oai` Bridge

#### [MODIFY] Host Network Config
Bring up the `demo-oai` bridge and assign it a subnet for MACVLAN parent:

```bash
sudo ip link set demo-oai up
sudo ip addr add 192.168.100.1/24 dev demo-oai
```

---

### Component 3: NetworkAttachmentDefinitions (NADs)

#### [NEW] `nad-n3.yaml` (GTP-U Data Plane)
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: open5gs-n3
  namespace: open5gs-upf
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "demo-oai",
      "mode": "bridge",
      "ipam": {
        "type": "static",
        "addresses": [{"address": "192.168.100.10/24"}]
      }
    }
```

#### [NEW] `nad-n4.yaml` (PFCP Control Plane)
- Same master `demo-oai`, IP `192.168.100.11/24`

#### [NEW] `nad-n6.yaml` (Internet Egress)
- Same master `demo-oai`, IP `192.168.100.12/24`

---

### Component 4: Patch UPF Deployment

#### [MODIFY] `upf-deployment.yaml`
Add Multus annotation to attach the three NADs:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: open5gs-n3, open5gs-n4, open5gs-n6
```

#### [MODIFY] `upf-configmap.yaml` (upf.yaml)
Update UPF config to bind interfaces to the new named addresses:
```yaml
upf:
  pfcp:
    server:
    - address: 192.168.100.11   # N4 interface
  gtpu:
    server:
    - address: 192.168.100.10   # N3 interface
```

#### [MODIFY] SMF ConfigMap
Update PFCP address to the new N4 NAD IP:
```yaml
upf:
- address: 192.168.100.11
  port: 8805
```

---

## Verification Plan

### Step 1: Verify Multus Installed
```bash
kubectl get pods -n kube-system | grep multus
kubectl get net-attach-def -n open5gs-upf
```

### Step 2: Verify UPF Has 3 Extra Interfaces
```bash
kubectl exec -n open5gs-upf deploy/open5gs-upf -- ip addr show
# Should show: eth0, net1 (N3), net2 (N4), net3 (N6), ogstun
```

### Step 3: Verify N4 PFCP Association
```bash
kubectl logs -n open5gs deploy/open5gs-smf | grep -i "pfcp\|association\|192.168.100.11"
```

### Step 4: Re-run iPerf3 Flood with Per-Interface Metrics
Run `upf_flood_iperf3.sh` + capture `/proc/net/dev` for `net1` (N3) during flood:
```bash
kubectl exec -n open5gs-upf deploy/open5gs-upf -- cat /proc/net/dev
# Compare net1 RX bytes during baseline vs flood
```

### Challenges and Workarounds Discovered

#### 1. K3s CNI Path and Binary Isolation
**Issue:** Multus thick-plugin pod crash-loops default configuration because it looks for CNI configurations in `/etc/cni/net.d` and binaries in `/opt/cni/bin`, which are standard Kubernetes locations but not K3s default locations.
**Fix:** 
- Created a symlink from `/var/lib/rancher/k3s/agent/etc/cni/net.d` to `/etc/cni/net.d`.
- Patched the Multus daemonset's `volumeMount` for `cni-bin-dir` to point directly to `/var/lib/rancher/k3s/data/cni/` on the host to ensure `flannel` binaries were available to the Multus chroot. Note: I also had to manually extract the standard `bridge` and `macvlan` CNI binaries into this directory.

#### 2. MACVLAN Sub-Interface Instability
**Issue:** The user initially tried attaching the MACVLAN sub-interfaces directly to `demo-oai` (a bridge interface created for OAI experiments) or `eth0`. `demo-oai` was in a `NO-CARRIER` state, causing the sub-interfaces to inherit this down state. Creating them on `eth0` can sometimes intercept or confuse the primary Kubernetes pod routing.
**Fix:** Created a persistent pseudo-device (`dummy-n3n4`) specifically to act as an `UP/LOWER_UP` master for all MACVLAN sub-interfaces.

#### 3. Open5GSM UPF Binding Sequence
**Issue:** When the UPF deployment was annotated for Multus, the standard Open5GS initialization script immediately tried to execute the UPF binary. However, Multus dynamically injects `net1` and `net2` slightly after the primary `eth0` is ready. The UPF daemon would hit a fatal `bind()` error failing to find the configured `192.168.100.x` IP addresses and crashloop.
**Fix:** Injected a `while loop` bash script inside `/opt/open5gs/etc/open5gs/upf-start.sh` to explicitly wait for `ip a show net2` and `ip a show net1` to succeed before passing execution to `open5gs-upfd`.

#### 4. Flannel Asymmetric Routing with Multus (PFCP Drop)
**Issue:** Moving the PFCP (N4) interface back from MACVLAN to the standard K3s Flannel overlay (`eth0`) caused the SMF to infinitely spam `invalid step[0] type[6]` and `Retry association with peer failed`. 
**Cause:** The UPF was configured with `dev: eth0` but the SMF was contacting the UPF via its K8s ClusterIP (`10.43.220.219`). Because the UPF pod possessed multiple NICs (thanks to Multus), when it attempted to reply to the SMF's ClusterIP-routed packet, the routing table caused a source IP mismatch or asymmetric return path, and the SMF rejected the association responses.
**Fix:** Explicitly configured the SMF `pfcp.client.upf.address` to target the physical Flannel **Pod IP** of the UPF (`10.42.0.92`) instead of the `open5gs-upf-pfcp` Service ClusterIP, forcing symmetric Pod-to-Pod overlay routing.
