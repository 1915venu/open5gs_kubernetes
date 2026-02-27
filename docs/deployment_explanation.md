# 5G Deployment Scenarios & UPF Flooding

This document explains the two primary deployment architectures evaluated for your 5G attack testing, the specific changes made to achieve the chosen architecture (Option B), and how we successfully utilized `iperf3` for UDP network flooding.

---

## Deployment Architecture Comparison

### Option A: Replica UPF in the Same Cluster
This architecture involves deploying a **secondary (replica) UPF** alongside the primary UPF within the same Kubernetes cluster (and typically the same `open5gs` namespace). The SMF establishes PFCP associations with both UPFs and can route traffic to the replica based on DNS or slicing.

**Why we didn't use this for the attack:**
While deploying a replica UPF tests scaling, running the target UPF in the exact same shared namespace as the Control Plane means an aggressive resource starvation attack (like our UDP flood) could easily bleed over and consume shared Node resources, inadvertently crashing the AMF or SMF. Option B provides harder logical boundaries.

```text
+-------------------------------------------------------------+
|               open5gs (Single Namespace/Cluster)            |
|                                                             |
|   +--------------+      +--------------+                    |
|   | 20x UEs      |      | Control Plane|                    |
|   | (ueransim)   |----->| (AMF, NRF,   |                    |
|   +--------------+      |  UDM, etc)   |                    |
|           |             +--------------+                    |
|           |                    |                            |
|           |  N1/N2             |                            |
|           |                    |                            |
|           |             +--------------+                    |
|           v  N3 (GTP)   |   SMF Core   |                    |
|   +--------------+      +--------------+                    |
|   | gNB          |             |                            |
|   | (ueransim)   |             | N4 (PFCP)                  |
|   +--------------+             |                            |
|      |        |                |                            |
| N3   |        | N3             |                            |
|      v        v                v                            |
| +--------+  +--------+    +--------+                        |
| | UPF 1  |  | UPF 2  |<==>|  SMF   |                        |
| |(Primary)| |(Replica)|    |        |                        |
| +--------+  +--------+    +--------+                        |
|      |        |                                             |
+------|--------|---------------------------------------------+
       | N6     | N6
       v        v
  [ EXTERNAL INTERNET ]
```

### Option B: CP/UP Split Architecture (Active)
This represents a standard 5G **CUPS** (Control and User Plane Separation) deployment. We logically separated the core network by moving the UPF into its own dedicated namespace (`open5gs-upf`).

**Why we chose this:**
By isolating the UPF, we can accurately measure the impact of a data-plane flood attack. The metrics (`kubectl top`) clearly differentiate between the CP overhead and the UP stress.

```text
+-------------------------------------------------------------+
| Cluster-1: Control Plane (Namespace: open5gs)               |
|                                                             |
|   +--------------+      +--------------+                    |
|   | 20x UEs      |----->| AMF Core     |                    |
|   | (ueransim)   |N1/N2 | (Signaling)  |                    |
|   +--------------+      +--------------+                    |
|           |                    |                            |
|           v                    v                            |
|   +--------------+      +--------------+                    |
|   | gNB          |      | SMF Core     |                    |
|   | (ueransim)   |      +--------------+                    |
|   +--------------+             |                            |
|      |  Data Path (N3)         |  Control Path (N4)         |
+------|-------------------------|----------------------------+
       |                         |
       | Cross-Namespace Traffic |
       |                         |
+------|-------------------------|----------------------------+
| Cluster-2: User Plane (Namespace: open5gs-upf)              |
|      v                         v                            |
|   +---------------------------------+                       |
|   |        UPF Data Plane           |                       |
|   +---------------------------------+                       |
|                    |                                        |
+--------------------|----------------------------------------+
                     | N6 Egress
                     v
             [ EXTERNAL INTERNET ]
```

---

## What Additions/Changes Were Made for Option B?

To achieve Option B, we had to solve several cross-namespace communication and routing challenges:

1. **Dedicated Namespace & ConfigMaps:** Created `upf-namespace.yaml` and decoupled the UPF configuration (`upf-configmap.yaml`) from the main Open5GS Helm chart.
2. **Stable Cross-Namespace Networking (ClusterIP over NodePort):**
   - Originally, we tried exposing the UPF to the SMF using a `NodePort` service.
   - **The Bug:** When the SMF sent PFCP requests to the UPF's NodePort IP, the UPF replied directly using its *internal* Pod IP. The SMF cached the wrong IP, causing dropped associations.
   - **The Fix:** We deleted the NodePort and deployed two stable `ClusterIP` services (`open5gs-upf-pfcp` and `open5gs-upf-gtpu`) in the `open5gs-upf` namespace. The SMF configuration was patched to point directly to the UPF's ClusterIP (`10.43.220.219:8805`).
3. **Persisting NAT/IP Tables (`upf-start.sh`):**
   - **The Bug:** The original UPF deployment used an `initContainer` to set up `iptables` NAT rules for egress traffic. However, these rules failed to persist into the main UPF container's execution.
   - **The Fix:** We injected a custom `upf-start.sh` wrapper script via a ConfigMap directly into the *main* UPF container. This script runs as root with `NET_ADMIN` capabilities, sets up the `ogstun` interface, enables `ip_forward`, applies `iptables` NAT rules, and *then* starts the `open5gs-upfd` daemon.

---

## Why didn't `iperf3` work earlier, and how is it working now?

### The Initial Failure (Option A / Early Testing phase)
If you tried to run `iperf3` earlier by using `apt-get install iperf3` inside the UERANSIM or UPF containers, it failed because:
1. Production Docker images (like the `gradiant/open5gs` image we are using) often run the main daemon as a restricted user (non-root) for security.
2. Trying to run `apt-get` on a live container throws a `Permission denied` error because you are not root.

### How we fixed it for the Final Attack
1. **It Was Already Installed:** The specific image tag we are using (`gradiant/open5gs:2.7.5`) actually ships with `iperf3` pre-installed inside the binary path. We didn't need to `apt-get` install it at all!
2. **Direct Execution:** Instead of trying to install it, the `upf_flood_iperf3.sh` script skips the setup phase. It simply executes `iperf3 -s -D` inside the UPF pod to start the server in UDP daemon mode, and spawns 20 concurrent `iperf3 -c ... -u` loops directly from the UERANSIM pod.

By utilizing UDP datagrams (`iperf3 -u`), we bypass TCP's congestion control windowing (which slowed down `curl`), allowing the UEs to blind-fire packets at 100Mbps each, successfully starving the UPF's CPU cycles (spike to 214m).

---

## Flooding Attack Execution & Benchmarks

To validate the resilience and limits of the isolated UPF, we performed two distinct 20-UE network flooding attacks. Each attack was continuously monitored using a custom cluster-metrics wrapper (`kubectl top`) tracking CPU `m` cores and Memory `MiB` at 5-second intervals.

### Test 1: HTTP/TCP Flow (`curl` & `wget`)
- **Action:** 20 UEs continuously downloading 10MB/100MB internet payload files through the UPF.
- **Duration:** 120 seconds.
- **Network Protocol:** TCP.
- **Metrics Result:**
  - **Baseline UPF Overhead:** 1m CPU / 26MiB RAM
  - **Peak UPF Stress:** **~2m CPU** / 26MiB RAM
- **Conclusion:** *Minimal Impact.* TCP's inherent congestion control windowing restricts the UEs from truly blasting the UPF. Open5GS's highly optimized C-based packet pipeline handled the payloads at line-rate with virtually zero stress. Not enough to cause a Denial of Service (DoS) on modern hardware.

### Test 2: UDP Datagram Blast (`iperf3`)
- **Action:** 20 UEs transmitting raw UDP traffic directly to the internal UPF `ogstun` interface at **100 Mbps each** (Total Target: 2 Gbps).
- **Duration:** 45 seconds.
- **Network Protocol:** UDP (bypasses congestion control/ACKs).
- **Metrics Result:**
  - **Baseline UPF Overhead:** 55m CPU / 30MiB RAM
  - **Peak UPF Stress:** **214m CPU** / 30MiB RAM
- **Conclusion:** *Severe CPU Degradation.* By forcing the UPF to process dense, unacknowledged UDP datagrams without flow control, we forced a **~400% CPU spike** purely from frame processing overhead. 
- **Simulating the DoS Impact:** If a hard Kubernetes resource limit (e.g., `limits.cpu: 100m`) had been applied to the UPF deployment, this UDP flood would have immediately caused massive packet un-queueing, resulting in catastrophic packet drop and end-to-end latency degradation for all honest UEs sharing that UPF.
