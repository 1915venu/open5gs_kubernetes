# 5G Distributed Registration Attack: Detailed Scaling Analysis

## 1. Test Environment

| Component | Specification |
|---|---|
| **Physical Host** | Dell Optiplex 5070, Intel Core i7-9700 (8 cores, no HT), 32 GB RAM |
| **Operating System** | Ubuntu 24.04 LTS |
| **Kubernetes** | RKE2 (single-node cluster) |
| **5G Core** | Open5GS v2.7.5 (Helm chart, `open5gs` namespace) |
| **Attack Tool** | PacketRusher (modified Go source) |
| **Container Runtime** | containerd (via RKE2) |
| **Synchronization** | NTP time barrier injected into PacketRusher source code |



### Key Modifications to PacketRusher
1. **NTP Barrier:** All pods synchronize to a target epoch timestamp before launching UEs, ensuring sub-200ms coordinated execution.
2. **Dynamic SCTP Binding:** Patched [ngap/service.go](file:///home/venu/Desktop/5G-Registration-Attack/distributed-attack/PacketRusher/internal/control_test_engine/gnb/ngap/service.go) to force dynamic ephemeral port allocation (`loc = nil`), enabling multiple SCTP connections per pod.
3. **Multi-gNodeB Support:** Rewrote [test-multi-ues-in-queue.go](file:///home/venu/Desktop/5G-Registration-Attack/distributed-attack/PacketRusher/internal/templates/test-multi-ues-in-queue.go) to spawn `NUM_GNB_PER_POD` independent gNodeB instances per pod, each opening a separate SCTP socket.
4. **Direct AMF IP Mapping:** Bypassed Kubernetes ClusterIP (kube-proxy drops SCTP) by dynamically fetching AMF pod IPs and distributing attacker pods via modulo assignment.

---

## 2. Methodology

All experiments use the following controlled protocol:

1. **Cleanup:** Delete all previous attacker pods and jobs.
2. **PCAP Capture:** Start `tcpdump` on SCTP port `38412`.
3. **Deploy:** Launch N attacker pods via Kubernetes Indexed Job with a 60-second NTP barrier.
4. **Wait:** All pods hold until the NTP barrier fires (±200ms synchronization).
5. **Collect:** After 15 seconds of processing time, extract:
   - Per-pod `Authentication request` log counts (3 logs per successful UE: InitialUEMessage, AuthenticationResponse, SecurityModeComplete)
   - PCAP timing window (first to last `InitialUEMessage` packet)
   - Pod barrier timestamps (synchronization jitter)
6. **Success Rate:** `TOTAL_AUTH_LOGS / 3 / TOTAL_UES × 100`



## 3. Test 1 — Baseline: 1 AMF, 1 Socket per Pod

The simplest possible configuration. Each pod opens exactly 1 SCTP connection carrying all 100 UEs sequentially.

| Parameter | Value |
|---|---|
| **Attacker Pods** | 10 |
| **UEs per Pod** | 100 |
| **Sockets per Pod** | 1 |
| **Total SCTP Connections** | 10 |
| **AMF Replicas** | 1 |
| **AUSF/UDM** | 1 each |
| **PCAP File** | `rerun1_clean_1amf.pcap` |

### Results

| Metric | Value |
|---|---|
| **Pod Sync Window** | 115 ms |
| **PCAP Packet Window** | 320 ms |
| **Total Auth Logs** | 1956 |
| **Success Rate** | **65.2%** (652 / 1000) |

### Per-Pod Breakdown

| Pod | Auth Logs | UEs Registered |
|---|---|---|
| pod-0 | 297 | 99 |
| pod-1 | 192 | 64 |
| pod-2 | 243 | 81 |
| pod-3 | 198 | 66 |
| pod-4 | 165 | 55 |
| pod-5 | 186 | 62 |
| pod-6 | 192 | 64 |
| pod-7 | 195 | 65 |
| pod-8 | 144 | 48 |
| pod-9 | 144 | 48 |



---

## 4. Test 2 — Adding a 2nd AMF

Identical to Test 1, except `open5gs-amf` scaled to 2 replicas. This is the only change.

| Parameter | Value |
|---|---|
| **Attacker Pods** | 10 |
| **UEs per Pod** | 100 |
| **Sockets per Pod** | 1 |
| **Total SCTP Connections** | 10 |
| **AMF Replicas** | **2** |
| **AUSF/UDM** | 1 each |
| **PCAP File** | `rerun2_clean_2amf.pcap` |

### Results

| Metric | Value |
|---|---|
| **Pod Sync Window** | 969 ms |
| **PCAP Packet Window** | 1177 ms |
| **Total Auth Logs** | 2208 |
| **Success Rate** | **73.6%** (736 / 1000) |

### Per-Pod Breakdown

| Pod | Auth Logs | UEs Registered |
|---|---|---|
| pod-0 | 300 | 100  |
| pod-1 | 300 | 100  |
| pod-2 | 300 | 100  |
| pod-3 | 300 | 100  |
| pod-4 | 81 | 27 |
| pod-5 | 132 | 44 |
| pod-6 | 42 | 14 |
| pod-7 | 279 | 93 |
| pod-8 | 174 | 58 |
| pod-9 | 300 | 100  |

### Analysis

Adding a 2nd AMF improved the success rate from **65.2% → 73.6% (+8.4%)**. The CPU processing load is now split across 2 AMF event loops. However, the OS scheduler jitter widened dramatically from 115ms to 969ms because 2 AMF pods + 10 attacker pods create more context-switching pressure.

## 5. Test 3 — 2 Sockets per Pod

Same 2-AMF core as Test 2, but each pod now opens **2 SCTP sockets**, splitting the 100-UE payload into 2 × 50 UEs.

| Parameter | Value |
|---|---|
| **Attacker Pods** | 10 |
| **UEs per Pod** | 100 (50 per socket) |
| **Sockets per Pod** | **2** |
| **Total SCTP Connections** | **20** |
| **AMF Replicas** | 2 |
| **PCAP File** | `run3_experiment_2amf_2sockets.pcap` |

### Results

| Metric | Value |
|---|---|
| **Pod Sync Window** | 63 ms |
| **PCAP Packet Window** | 267 ms |
| **Total Auth Logs** | 2100 |
| **Success Rate** | **70.0%** (700 / 1000) |

### Per-Pod Breakdown

| Pod | Auth Logs | UEs Registered |
|---|---|---|
| pod-0 | 273 | 91 |
| pod-1 | 210 | 70 |
| pod-2 | 231 | 77 |
| pod-3 | 204 | 68 |
| pod-4 | 216 | 72 |
| pod-5 | 195 | 65 |
| pod-6 | 222 | 74 |
| pod-7 | 183 | 61 |
| pod-8 | 219 | 73 |
| pod-9 | 147 | 49 |

### Analysis
Adding a 2nd socket per pod **decreased** the success rate slightly (73.6% → 70.0%). The key insight is in the synchronization window: it tightened from **969ms → 63ms**. The Go runtime spawned a 2nd goroutine per pod to manage the parallel socket, which also tightened OS scheduling. Because the 1000 UEs now hit the 2 AMFs in an almost perfectly simultaneous 63ms window (versus a leisurely 969ms spread), the AMF CPUs became perfectly saturated with zero breathing room between requests.



---

## 6. Test 4 — 4 Sockets per Pod

Pushing the socket parallelism to 4 per pod, splitting 100 UEs into 4 × 25 per socket.

| Parameter | Value |
|---|---|
| **Attacker Pods** | 10 |
| **UEs per Pod** | 100 (25 per socket) |
| **Sockets per Pod** | **4** |
| **Total SCTP Connections** | **40** |
| **AMF Replicas** | 2 |
| **PCAP File** | `run4_experiment_2amf_4sockets.pcap` |

### Results

| Metric | Value |
|---|---|
| **Pod Sync Window** | 136 ms |
| **PCAP Packet Window** | 347 ms |
| **Total Auth Logs** | 2661 |
| **Success Rate** | **88.7%** (887 / 1000) |

### Per-Pod Breakdown

| Pod | Auth Logs | UEs Registered |
|---|---|---|
| pod-0 | 300 | 100 |
| pod-1 | 171 | 57 |
| pod-2 | 300 | 100  |
| pod-3 | 300 | 100 |
| pod-4 | 267 | 89 |
| pod-5 | 171 | 57 |
| pod-6 | 300 | 100  |
| pod-7 | 279 | 93 |
| pod-8 | 273 | 91 |
| pod-9 | 300 | 100  |

### Analysis
Pushing to 40 parallel SCTP streams demolished the HoL blocking bottleneck. With only 25 UEs per socket, each queue is shallow enough for the AMF's event loop to drain completely before the `T3450` timer expires. The success rate jumped from **70.0% → 88.7% (+18.7%)**.



---

## 7. Test 5 — 15 Pods 

Testing whether increasing pods beyond 10 (while maintaining 4 sockets/pod) could improve results by adding more OS scheduling jitter.

| Parameter | Value |
|---|---|
| **Attacker Pods** | **15** |
| **UEs per Pod** | 67 |
| **Sockets per Pod** | 4 |
| **Total SCTP Connections** | **60** |
| **AMF Replicas** | 2 |
| **PCAP File** | `run5_experiment_15pods.pcap` |

### Results

| Metric | Value |
|---|---|
| **Pod Sync Window** | 294 ms |
| **Total Auth Logs** | 2094 |
| **Success Rate** | **69.4%** (698 / 1005) |

### Analysis
Performance dropped catastrophically from **88.7% → 69.4%**. Running 15 pods × 4 sockets = 60 parallel SCTP streams exceeded the hardware's thread scheduling capacity. 


---

## 8. Summary Matrix

| Test | Pods | Sockets/Pod | Total Sockets | AMFs | Success Rate | Sync Window |
|---|---|---|---|---|---|---|
| **Test 1** | 10 | 1 | 10 | 1 | **65.2%** | 115 ms |
| **Test 2** | 10 | 1 | 10 | 2 | **73.6%** | 969 ms |
| **Test 3** | 10 | 2 | 20 | 2 | **70.0%** | 63 ms |
| **Test 4** | 10 | 4 | 40 | 2 | **88.7%** | 136 ms |
| **Test 5** | 15 | 4 | 60 | 2 | **69.4%** | 294 ms |

---

## 9. Key Findings

### Finding 1: SCTP Head-of-Line Blocking is the Primary Bottleneck
Open5GS AMF uses a single-threaded event loop to process SCTP connections sequentially. When a socket carries 100 UEs, UEs at position 50+ in the queue time out before the AMF reaches them. Splitting the payload across 4 sockets (25 UEs each) eliminated this bottleneck and produced the highest success rate (88.7%).

### Finding 2: Adding AMFs Helps, But With Diminishing Returns
Adding a 2nd AMF improved success by +8.4% (Test 1 → Test 2), but benefits plateau because the single backend AUSF/UDM becomes the new bottleneck under high AMF counts. Our earlier (excluded) tests showed that scaling to 5+ AMFs actually degraded performance because the AMFs flood the solitary AUSF with simultaneous HTTP2 SBI requests, creating an "SBI Storm."

### Finding 3: OS Synchronization Jitter 
- **Too tight** (63ms, Test 3): The AMF CPUs are perfectly saturated with zero processing headroom → lower success rate.
- **Too wide** (969ms, Test 2): Late-arriving pods miss the processing window → uneven distribution.
- **Optimal** (136ms, Test 4): Enough natural stagger for the AMF to begin processing early arrivals before late arrivals land.

### Finding 4: 40 SCTP Sockets is the Hardware Ceiling
On an 8-core CPU, 40 simultaneous SCTP connections (10 pods × 4 sockets) represents the maximum parallelism before the OS scheduler's context-switching overhead exceeds the processing gains. Pushing to 60 sockets (15 pods × 4) reduced success from 88.7% → 69.4%.



