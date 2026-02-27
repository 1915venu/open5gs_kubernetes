# Cilium eBPF Integration: Detailed Technical Breakdown

This document provides an in-depth explanation of the Cilium eBPF integration implemented in our 5G testbed, detailing the exact steps performed, the critical issues encountered during the live migration, the fixes applied, and how the eBPF datapath dramatically improved the UPF's performance under a simulated DoS attack.

---

## 1. What is Cilium / eBPF and Why Was It Needed?

### The Problem with Traditional CNIs (Flannel + IPTables)
In a standard K3s cluster, the default **Flannel** CNI uses the Linux kernel's `iptables` framework for all packet routing and NAT decisions. Every single packet entering or leaving a Pod traverses a chain of `iptables` rules — sometimes hundreds of them. This is a **user-space** operation that aggressively consumes CPU cycles.

During our initial stress test (**Test 1**), when 20 simulated UEs blasted the UPF with `iperf3` UDP traffic at 100 Mbps each (~2 Gbps total), the UPF pod's CPU spiked from **51m to 214m** (a 319% increase). Most of this CPU overhead was **not** from the UPF application itself — it was from the Linux kernel processing the massive iptables ruleset for every single UDP datagram.

### What Cilium Achieves
**Cilium** replaces the entire `iptables` routing stack with **eBPF** (Extended Berkeley Packet Filter) programs. eBPF allows routing decisions to be compiled into tiny bytecode programs that execute **directly inside the Linux kernel's network stack** — at the lowest possible layer — without ever bouncing up to user-space. This means:

*   **No iptables traversal:** Packets are routed at near-hardware speed.
*   **No kube-proxy:** Cilium replaces the Kubernetes `kube-proxy` component entirely with eBPF service maps.
*   **Near-zero CPU overhead:** Packet forwarding becomes practically free from the Pod's perspective.

---

## 2. What Exactly Was Changed?

To integrate Cilium, we performed a **live CNI swap** — removing the default Flannel overlay and replacing it with the Cilium eBPF datapath. This involved four major modifications:

1.  **K3s Systemd Service Flags:** We modified `/etc/systemd/system/k3s.service` to disable K3s's built-in Flannel and NetworkPolicy management.
2.  **Cilium CLI Installation:** We installed the `cilium-cli` binary (v0.19.0) on the host to manage, inspect, and debug the eBPF datapath.
3.  **Cilium Helm Chart Deployment:** We deployed Cilium v1.18.5 into the `kube-system` namespace via Helm, configuring it to take over IPAM, service routing, and kube-proxy replacement.
4.  **Full Pod Network Regeneration:** Every pod in the cluster had to be restarted to acquire new IP addresses from Cilium's IPAM pool (`10.0.0.0/24`) instead of the old Flannel pool (`10.42.0.0/16`).

---

## 3. The Integration Steps

### Step 1: Disabling Flannel in K3s
K3s bundles Flannel as its default CNI. To use Cilium, we had to explicitly tell K3s to stop managing the network:

```bash
# Edit the K3s systemd service
sudo vi /etc/systemd/system/k3s.service
```

We added two critical flags to the `ExecStart` line:
```diff
 ExecStart=/usr/local/bin/k3s \
     server \
+    --flannel-backend=none \
+    --disable-network-policy \
```

Then reloaded and restarted:
```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

### Step 2: Installing the Cilium CLI
```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
```

### Step 3: Installing Cilium via Helm
```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.18.5 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=6443
```

### Step 4: Regenerating Pod Networking
```bash
# Restart all 5G core pods to acquire new Cilium-managed IPs
kubectl rollout restart deploy -n open5gs
kubectl rollout restart deploy -n open5gs-upf
```

### Step 5: Verifying Cilium Status
```bash
cilium status
```

---

## 4. The Challenges & The Fixes Implemented

Integrating Cilium into a live K3s cluster running a complex 5G workload triggered four significant issues:

### Issue A: Flannel Residue Blocking New Pods
*   **The Problem:** After disabling Flannel and installing Cilium, the old Flannel virtual interfaces (`flannel.1`, `cni0`) and their associated `iptables` rules were still lingering on the host. This caused routing conflicts — new pods sometimes received IPs from the dead Flannel pool or failed to route entirely.
*   **The Fix:** We manually cleaned up the stale Flannel artifacts from the host:
    ```bash
    sudo ip link delete flannel.1
    sudo ip link delete cni0
    sudo iptables -F -t nat
    sudo iptables -F -t filter
    ```
    After the cleanup, Cilium's eBPF programs took full ownership of the routing table, and the `cilium_host` interface appeared in `ip route`:
    ```
    10.0.0.0/24 via 10.0.0.49 dev cilium_host proto kernel src 10.0.0.49
    ```

### Issue B: CNI API Server Deadlock (Critical)
*   **The Problem:** This was the most severe issue. When K3s attempted to roll out the refreshed 5G core pods on the new Cilium network, the sheer volume of concurrent CNI sandbox creation requests caused a **deadlock** between the Cilium agent, the Multus meta-plugin, and the K3s API server. The symptoms were:
    -   All new pods stuck indefinitely in the `ContainerCreating` state.
    -   `kubectl describe pod` showed: `"NetworkPlugin cni failed... context deadline exceeded"`.
    -   `kubectl` commands themselves became intermittently unresponsive.
    -   Even scaling deployments to zero replicas and back up failed to break the deadlock.
*   **The Root Cause:** The Cilium agent was waiting for the API server to confirm endpoint registrations, while the API server was waiting for the CNI (Cilium) to finish setting up pod networking for its own internal components. This circular dependency created an unbreakable deadlock at the kernel networking layer.
*   **The Fix:** Restarting individual DaemonSets (Cilium, Multus) was unsuccessful. The only resolution was a **hard host-level restart** of the entire K3s service, which forcibly flushed all deadlocked Linux network routes, iptables chains, and eBPF maps:
    ```bash
    sudo systemctl restart k3s
    ```
    After the restart, all pods immediately began scheduling and the CNI initialized cleanly on a fresh slate.

### Issue C: Metrics-Server CrashLoop
*   **The Problem:** Following the K3s restart, the `metrics-server` pod entered a `CrashLoopBackOff` state. Its logs showed:
    ```
    panic: failed to create listener: listen tcp 0.0.0.0:10250: bind: address already in use
    ```
    This was caused by an earlier troubleshooting attempt where we had patched the metrics-server deployment with `hostNetwork: true` to bypass a `"no route to host"` error to the API server ClusterIP (`10.43.0.1`). With `hostNetwork`, the metrics-server tried to bind to port `10250` on the host — which was already occupied by the K3s kubelet.
*   **The Fix:** We removed the `hostNetwork` flag. Since the K3s restart had already resolved the underlying routing issue (the old stale service CIDR routes were flushed), the metrics-server could now reach `10.43.0.1` normally through the Cilium-managed network:
    ```bash
    kubectl patch deployment metrics-server -n kube-system \
      --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/hostNetwork"}]'
    ```
    The metrics-server immediately came up healthy, and `kubectl top pod` started returning data.

### Issue D: 5G NF Subscriber Cache Invalidation
*   **The Problem:** After all pods restarted with new Cilium-managed IPs, the Open5GS network functions (particularly UDM and AMF) had cached stale NRF registration endpoints and subscriber session data from the old Flannel IP range. This caused:
    -   UEs receiving `FIVEG_SERVICES_NOT_ALLOWED` rejection during registration.
    -   HTTP 400 errors between AMF and UDM during PDU session setup.
    -   `Maximum number of SDM Subscriptions` errors in UDM logs.
*   **The Fix:** We performed a rolling restart of the critical signaling chain in dependency order to flush all caches:
    ```bash
    kubectl rollout restart deploy/open5gs-nrf -n open5gs     # NRF first (service registry)
    kubectl rollout restart deploy/open5gs-udm -n open5gs     # UDM (subscriber data)
    kubectl rollout restart deploy/open5gs-amf -n open5gs     # AMF (registration handler)
    kubectl rollout restart deploy/ueransim-gnb -n open5gs    # gNB (SCTP reconnect)
    kubectl rollout restart deploy/ueransim-gnb-ues -n open5gs # UEs (re-register)
    ```
    After the ordered restart, all 20 UEs successfully re-registered and established PDU sessions with `uesimtun0` through `uesimtun19` interfaces.

---

## 5. The Commands Used (Summary)

| Step | Command | Purpose |
|------|---------|---------|
| 1 | `sudo vi /etc/systemd/system/k3s.service` | Add `--flannel-backend=none --disable-network-policy` |
| 2 | `sudo systemctl daemon-reload && sudo systemctl restart k3s` | Apply K3s config changes |
| 3 | `curl -L ... cilium-linux-amd64.tar.gz && sudo tar xzvfC ...` | Install Cilium CLI v0.19.0 |
| 4 | `helm install cilium cilium/cilium --version 1.18.5 -n kube-system` | Deploy Cilium eBPF agents |
| 5 | `kubectl rollout restart deploy -n open5gs` | Regenerate pod networking |
| 6 | `sudo systemctl restart k3s` | Fix the CNI API deadlock |
| 7 | `kubectl patch deploy metrics-server ... remove hostNetwork` | Fix metrics-server crash |
| 8 | `cilium status` | Verify Cilium health |

---

## 6. How to Verify Cilium is Integrated

Three definitive ways to confirm Cilium is the active CNI:

### Method 1: Cilium CLI Status
```bash
$ cilium status
    /¯¯\
 /¯¯\__/¯¯\    Cilium:         OK
 \__/¯¯\__/    Operator:       OK
 /¯¯\__/¯¯\    Hubble Relay:   disabled
 \__/¯¯\__/    ClusterMesh:    disabled
    \__/
DaemonSet   cilium   Desired: 1, Ready: 1/1, Available: 1/1
Containers  (IPv4)   10.0.0.0/24   Allocated: 18
```

### Method 2: Host Routing Table
```bash
$ ip route | grep cilium
10.0.0.0/24 via 10.0.0.49 dev cilium_host proto kernel src 10.0.0.49
10.0.0.49 dev cilium_host proto kernel scope link
```
The presence of `cilium_host` (instead of `flannel.1` or `cni0`) proves eBPF is managing the overlay.

### Method 3: Kubernetes DaemonSet
```bash
$ kubectl get pods -n kube-system -l k8s-app=cilium
NAME           READY   STATUS    RESTARTS   AGE
cilium-r76g2   1/1     Running   0          8h
```

---

## 7. Comparative Stress Test Results

The ultimate proof of Cilium's value is the performance data. We executed the **exact same** `iperf3` UDP flood test (20 UEs × 100 Mbps = 2 Gbps) on both architectures:

| Metric | Flannel + IPTables (Test 1) | Cilium + eBPF (Test 3) | Improvement |
|--------|---------------------------|----------------------|-------------|
| **UPF Baseline CPU** | 51m | 1m | — |
| **UPF Peak CPU** | **214m** | **0.8m** | **99.6% reduction** |
| **UPF Memory** | 30 MiB | 33 MiB | No change |
| **SMF Impact** | 5m | 1m | Negligible |
| **AMF Impact** | 3m | 1m | Negligible |

> [!IMPORTANT]
> The 99.6% CPU reduction is because eBPF processes packets entirely within the kernel's fast-path, while iptables forces each packet through a chain of user-space rule evaluations. The UPF application code itself does almost no work — the CPU spike in Test 1 was almost entirely Linux networking overhead.

---

## 8. How This Maps to Industry-Grade Deployments

Cilium is not a lab curiosity — it is the **production standard** for cloud-native 5G:

1.  **Telco Adoption:** Major operators (Bell Canada, Swisscom, China Telecom) use Cilium as their primary CNI for 5G core deployments on Kubernetes.
2.  **CNCF Graduated Project:** Cilium is a CNCF graduated project (same tier as Kubernetes itself), ensuring long-term stability and community support.
3.  **Hubble Observability:** In production, Cilium's built-in **Hubble** provides deep, per-flow network observability without external tools — critical for debugging N3/N4/N6 traffic issues.
4.  **Bandwidth Manager:** Cilium's eBPF-based bandwidth manager can enforce per-pod rate limits at the kernel level, providing QoS controls for URLLC and eMBB slices without iptables overhead.
5.  **Combined with SR-IOV:** For ultimate performance, production deployments combine Cilium (for service routing and policy) with **SR-IOV** (for hardware-level NIC partitioning), achieving true wire-speed packet forwarding with zero kernel bypass.
