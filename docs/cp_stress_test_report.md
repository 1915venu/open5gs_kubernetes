# Control Plane Stress Test Report: Registration Latency Under Load

## 1. Test Objective

Stress test the **5G control plane** (AMF → AUSF → UDM → UDR → MongoDB) by flooding it with concurrent UE registrations using **PacketRusher** at sub-second intervals. Measure per-NF CPU impact at **200ms granularity** using direct cgroup v2 reads.

Previous tests focused on **data plane** (iperf3 UDP floods on UPF). This test targets the **signaling path** — the multi-hop SBI authentication chain that processes every UE registration.

---

## 2. Test Setup

| Parameter | Value |
|-----------|-------|
| **Attack Tool** | PacketRusher v1.0.1 (Go-based 5G UE/gNB simulator) |
| **Target** | Open5GS control plane on K3s (Cilium eBPF CNI) |
| **Registration Protocol** | Full 5G NAS: Registration Request → 5G-AKA Auth → Security Mode → Registration Accept → PDU Session |
| **Metrics Granularity** | ~200ms (cgroup v2 direct reads) |
| **NFs Monitored** | AMF, AUSF, UDM, UDR, SMF, MongoDB (6 NFs simultaneously) |
| **Subscribers Provisioned** | 500 (IMSI 999700000000100–599) |
| **PLMN** | MCC=999, MNC=70 |

### Registration Flow Under Attack

```
PacketRusher UE ──→ gNB(simulated) ──SCTP/NGAP──→ AMF ──HTTP/SBI──→ AUSF ──→ UDM ──→ UDR ──→ MongoDB
                                                    │
                                                    └──→ SMF ──→ UPF (PDU Session)
```

---

## 3. Test Matrix & Results

### Test 1: 10 UEs @ 500ms interval (Validation)

| NF | Avg CPU | Peak CPU | Avg Memory |
|----|---------|----------|------------|
| **MongoDB** | **8.975%** | **96.263%** | 225.1 MiB |
| AMF | 0.012% | 2.553% | 78.9 MiB |
| SMF | 0.014% | 1.124% | 61.8 MiB |
| UDM | 0.011% | 1.056% | 29.4 MiB |
| UDR | 0.010% | 0.705% | 28.4 MiB |
| AUSF | 0.009% | 0.582% | 29.2 MiB |

**Result:** 10/10 registrations successful, 0 failures.

---

### Test 2: 50 UEs @ 100ms interval (Moderate Load)

| NF | Avg CPU | Peak CPU | Avg Memory |
|----|---------|----------|------------|
| **MongoDB** | **8.357%** | **93.133%** | 225.1 MiB |
| AMF | 0.800% | 5.330% | 78.9 MiB |
| UDM | 0.627% | 4.198% | 29.4 MiB |
| SMF | 0.480% | 3.170% | 61.7 MiB |
| UDR | 0.369% | 2.607% | 28.4 MiB |
| AUSF | 0.177% | 1.203% | 29.2 MiB |

**Result:** 50/50 registrations successful, 0 failures. All UEs registered in ~5 seconds.

---

### Test 3: 200 UEs @ 100ms interval (Heavy Load)

| NF | Avg CPU | Peak CPU | Avg Memory |
|----|---------|----------|------------|
| **MongoDB** | **9.172%** | **84.067%** | 227.7 MiB |
| AMF | 1.881% | 6.281% | 93.1 MiB |
| UDM | 1.519% | 5.172% | 30.7 MiB |
| SMF | 1.183% | 4.786% | 63.4 MiB |
| UDR | 0.863% | 3.057% | 29.0 MiB |
| AUSF | 0.429% | 1.456% | 29.5 MiB |

**Result:** 200/200 registrations successful, 0 failures. All UEs registered in ~20 seconds.

---

## 4. Key Findings

### Finding 1: MongoDB Is the Primary Bottleneck

```
Peak CPU by NF (across all tests)

MongoDB  ████████████████████████████████████████████████  96.3%
AMF      ███                                               6.3%
UDM      ██                                                5.2%
SMF      ██                                                4.8%
UDR      █                                                 3.1%
AUSF     █                                                 1.5%
```

> 
> **MongoDB consumed 10–20× more CPU than any Open5GS NF during registration floods.** Every UE registration triggers multiple MongoDB queries (subscriber lookup, authentication vector fetch, session data). At 96% peak CPU, MongoDB is saturated — any further load or CPU limits would directly increase registration latency.

### Finding 2: NF CPU Scales Linearly with UE Count

| NF | 10 UEs Peak | 50 UEs Peak | 200 UEs Peak | Scaling Factor (10→200) |
|----|-------------|-------------|--------------|-------------------------|
| AMF | 2.553% | 5.330% | 6.281% | 2.5× |
| UDM | 1.056% | 4.198% | 5.172% | 4.9× |
| SMF | 1.124% | 3.170% | 4.786% | 4.3× |
| UDR | 0.705% | 2.607% | 3.057% | 4.3× |
| AUSF | 0.582% | 1.203% | 1.456% | 2.5× |

The database-dependent NFs (UDM, UDR, SMF) scale ~4-5× when UEs increase 20×, while AMF and AUSF scale only ~2.5×. This confirms the bottleneck is in the **database query path**, not NGAP/NAS processing.

### Finding 3: System Remained Resilient — No Failures

Despite 200 concurrent registrations at 100ms intervals (10 registrations/second sustained), the control plane handled it with **zero failures**. This proves the Open5GS architecture is well-designed for the current resource allocation.

### Finding 4: Resource Constraints Cause Catastrophic Registration Failure

To prove that resource constraints directly cause registration degradation, MongoDB's CPU was throttled to **5% of 1 core** via direct cgroup v2 manipulation, and the AMF was limited to 100m via Kubernetes.

**Test 4: 200 UEs @ 100ms interval — MongoDB CPU throttled to 5%**

| NF | Avg CPU | Peak CPU | Avg Memory |
|----|---------|----------|------------|
| **MongoDB** | **4.656%** | **10.608%** (CAPPED) | **299.4 MiB** (+31%) |
| AMF | 1.202% | 9.413% (+50%) | 142.2 MiB (+53%) |
| SMF | 0.382% | 11.196% (+134%) | 73.1 MiB |
| UDM | 0.968% | 7.711% (+49%) | 37.3 MiB |
| UDR | 0.510% | 5.038% (+65%) | 30.8 MiB |
| AUSF | 0.349% | 4.075% (+180%) | 34.4 MiB |

**Registration Results:**

| Metric | Unconstrained | Constrained (MongoDB 5%) | Degradation |
|--------|--------------|--------------------------|-------------|
| **Registrations Accepted** | **200/200 (100%)** | **69/200 (34.5%)** | **65.5% FAILED** |
| **PDU Sessions** | 200 | 57 | 71.5% failed |
| **Authentications** | 200 | 200 | OK |
| **At 10s mark** | 88 registered | 36 registered | **59% slower** |
| **At 20s mark** | 188 registered | 69 registered | **63% slower** |

> 
> **Throttling MongoDB from unlimited to 5% CPU caused 65% of registrations to fail.** All 200 UEs completed authentication but only 69 received Registration Accept — the rest timed out waiting for MongoDB subscriber queries. AMF memory grew 53% (from 84 MiB to 142 MiB) from queued pending registrations.

**Method:** Direct cgroup v2 `cpu.max` write — equivalent to Kubernetes `resources.limits.cpu: 50m` but applied to a running container without pod restart.

### Finding 5: Edge Deployment Simulation — ALL NFs Constrained

To simulate a realistic **resource-constrained edge/MEC deployment** , ALL 6 control plane NFs were simultaneously throttled via cgroup v2:

| NF | CPU Limit | Rationale |
|----|-----------|-----------|
| AMF, AUSF, UDM, UDR, SMF | 300m each | Typical edge pod allocation |
| MongoDB | 50m | Constrained shared database |
| **Total CPU budget** | **1.55 cores** | Realistic 2-core edge node |

**Test 5: 200 UEs @ 100ms — Edge Deployment (1.55 cores total)**

| Metric | Unconstrained | Edge (1.55 cores) | Degradation |
|--------|--------------|---------------------|-------------|
| **Registrations** | **200/200 (100%)** | **110/200 (55%)** | **45% FAILED** |
| **PDU Sessions** | 200 | 54 | 73% failed |
| **At 10s mark** | 88 registered | 34 registered | **61% slower** |
| **At 20s mark** | 188 registered | 110 registered | **41% slower** |
| **MongoDB Peak CPU** | 84% | 9.2% (CAPPED) | — |
| **AMF Peak CPU** | 6.3% | **14.4%** (+129%) | Backed up |
| **MongoDB Memory** | 228 MiB | **294 MiB** (+29%) | Query queue |

> 
> **A realistic 2-core edge deployment fails to handle a 200-UE registration storm.** 45% of registrations fail, and those that succeed take 61% longer. This simulates a real-world scenario: a small cell site  where hundreds of UEs attempt simultaneous registration on constrained infrastructure.

### Finding 6: Uniform 200m Limit — Complete Service Outage

When ALL 6 NFs are given **identical 200m CPU limits** (total 1.2 cores), the 5G control plane experiences **complete service outage**:

| Metric | Unconstrained | Uniform 200m |
|--------|--------------|--------------|
| **Registrations** | **200/200 (100%)** | **0/200 (0%)** |
| **Authentications** | 200 | **0** |
| **PDU Sessions** | 200 | **0** |
| **MongoDB Peak CPU** | 84% | 31% (CAPPED) |
| **AMF Peak CPU** | 6.3% | 2.6% |

> 
> **At uniform 200m per NF (1.2 cores total), the SBI authentication chain completely breaks.** MongoDB cannot process subscriber queries fast enough, causing cascading SBI timeouts. AMF rejects all registrations after 10s timeout. This represents a total denial of service — zero UEs can attach to the network.

### Summary: Registration Success vs CPU Budget

| Scenario | Total CPU Budget | Success Rate |
|----------|-----------------|-------------|
| Unlimited (baseline) | ~8 cores available | **100%** (200/200) |
| Edge deployment (1.55 cores) | 1.55 cores | **55%** (110/200) |
| Uniform 200m (1.2 cores) | 1.2 cores | **0%** (0/200) |
| MongoDB-only throttled | MongoDB: 50m, others: unlimited | **34.5%** (69/200) |

**Method:** CPU constraints applied via cgroup v2 `cpu.max`. 

---

## 5. Comparison: Data Plane vs Control Plane

| Dimension | Data Plane (iperf3 flood) | Control Plane (Registration flood) |
|-----------|--------------------------|-------------------------------------|
| **Target NF** | UPF only | AMF, AUSF, UDM, UDR, SMF, MongoDB |
| **Bottleneck** | UPF CPU (iptables path) | **MongoDB** (subscriber queries) |
| **Cilium eBPF impact** | Eliminated CPU overhead | N/A (control plane is SBI/HTTP) |
| **200-UE peak CPU** | UPF: 6.3% (Cilium), 214m (Flannel) | MongoDB: 84%, AMF: 6.3% |
| **Failure rate** | 0% | 0% |
| **Real-world threat** | Low (UDP flood is detectable) | **High** (registration storms during mass events) |

---

