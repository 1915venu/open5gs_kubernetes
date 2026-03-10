# CPU Constraint Test Report
## MongoDB-Fixed + Uniform NF Throttling

### Test Setup
- **Workload**: 200 UEs @ 100ms interval (registration storm)
- **MongoDB**: Fixed at **500m** (safe allocation) for all constrained tests
- **NFs throttled**: AMF, AUSF, UDM, UDR, SMF (uniformly)
- **Method**: cgroup v2 direct write (`cpu.max`)


---

### Results Summary

| Test | MongoDB CPU | NF CPU (each) | Total Budget | Registrations | Outcome |
|------|-------------|---------------|-------------|---------------|---------|
| **T1 Baseline** | Unlimited | Unlimited | ~8 cores | **200/200** ✅ | Reference |
| **T2 Generous** | 500m | 500m | 3.0 cores | **200/200** ✅ | No impact |
| **T3 Moderate** | 500m | 200m | 1.5 cores | **200/200** ✅ | No impact |
| **T4 Tight** | 500m | 100m | 1.0 cores | **200/200** ✅ | No impact |
| **T5 Extreme** | 500m | 50m | 750m | **200/200** ✅ | No impact |

> **Key Finding**: ALL 5 scenarios achieved 200/200 registrations at identical pace (~30 seconds). The 5G NFs are NOT the bottleneck — they need very little CPU for signaling. With MongoDB given adequate resources, even 750m total CPU handles 200 UE registrations perfectly.

---

### Peak CPU Per NF (Measured from cgroup v2 metrics)

| NF | T1 (Unlimited) | T2 (500m) | T3 (200m) | T4 (100m) | T5 (50m) |
|----|----------------|-----------|-----------|-----------|----------|
| **MongoDB** | **145.1%** | 64.9% | 65.4% | 65.9% | 68.3% |
| AMF | 6.6% | 7.1% | 6.7% | 6.4% | 6.7% |
| UDM | 6.6% | 6.7% | 7.2% | 6.0% | 7.0% |
| SMF | 7.8% | 7.3% | 7.7% | 7.0% | 6.8% |
| UDR | 4.5% | 4.5% | 4.8% | 4.0% | 4.4% |
| AUSF | 1.4% | 1.4% | 1.4% | 1.4% | 1.4% |

### Key Observations

1. **MongoDB is capped at 500m but still serves fine**: In T1 (unlimited), MongoDB bursts to 145%. With a 500m cap, it stays around 65% — and registrations are unaffected. This means 500m gives MongoDB sufficient headroom for 200 UE registrations.

2. **NFs use negligible CPU**: The highest NF peak is SMF at 7.8% of 1 core (~78m). Even at the 50m limit (T5), the NFs didn't hit the ceiling because:
   - The CFS scheduling period allows bursting within the 100ms window
   - The NF CPU usage is bursty (short spikes during message processing)
   - Average CPU usage is only 0.7-1.0% — the peaks are very brief

3. **Previous failures were NOT caused by NF CPU starvation**: The earlier tests that showed 0/200 and 65/200 registrations were caused by:
   - **MongoDB being throttled** (50m = 5%, far below its 84-145% peak requirement)
   - **UDM SDM subscription table exhaustion** (4096 limit not being cleared between tests)
   - **NOT by NF CPU constraints**

4. **Minimum viable CPU budget**: The 5G control plane can handle 200 UE registrations with:
   - MongoDB: 500m (critical minimum)
   - Each NF: 50m (with plenty of margin)
   - **Total: 750m (< 1 core!)**

---

### Degradation Point Testing

To find exactly where the 5G control plane NFs fail, ran a specialized degradation suite, aggressively reducing the NF CPU budgets until failure.

| Test | MongoDB CPU | NF CPU (each) | Total Budget | Registrations | Outcome |
|------|-------------|---------------|-------------|---------------|---------|
| **D1**  | 500m | 40m | 700m | **200/200** ✅ | No impact.  |
| **D2** | 500m | 30m | 650m | **200/200** ✅ | No impact. NFs' peak CPUs were smoothly clamped at ~4.5% |
| **D3** | 500m | 20m | 600m | **200/200** ✅ | No impact. NFs perfectly smoothed out the bursts (max peak ~3.7%) |
| **D4** | 500m | 10m | 550m | **341/200** ❌ | **Total Collapse**. Severe throttling caused constant timeouts, packet drops, and runaway registration retries. |

> **Degradation Conclusion**: The 5G control plane NFs manage to perfectly handle 200 UE registrations down to an incredibly low **20m per NF** (2% of a core). Once forced down to **10m per NF** (1% of a core), they are starved beyond operation, causing the registration chain to break and creating a packet retry storm.

#### PCAP Delay Analysis at 10m Failure (D4)
A host-level packet capture was taken exactly at the 10m failure boundary to observe the breakdown of the Service Based Interface (SBI) interactions. Because of the massive 10m CPU throttling, HTTP/2 streams could not even assemble properly, but TCP-level stream analysis revealed catastrophic timeouts:

| Network Function | Avg Latency (ms) | Max Latency (ms) | Note |
|------------------|------------------|------------------|------|
| **AMF** | 0.23 ms | 0.48 ms | AMF remained resilient and fast |
| **NRF** | 0.19 ms | 0.25 ms | NRF remained unaffected |
| **UDR** | 4,003 ms | 50,037 ms | **Complete breakdown** |
| **UDM** | 4,765 ms | 50,036 ms | **Complete breakdown** |
| **AUSF** | 4,842 ms | 38,741 ms | **Complete breakdown** |
| **SMF** | 11,600 ms | 63,799 ms | **Severe breakdown** |
| **SCP** | 12,319 ms | 63,799 ms | **Proxy/Routing completely choked** |

**Conclusion of the 10m Failure:** At exactly 1% CPU allowance (10m), the AMF (the entry point receiving NGAP traffic) survives, but the internal HTTP2 microservices (SCP, SMF, AUSF, UDM, UDR) completely freeze. They suffer processing delays ranging from 4 to 12 seconds on average, with maximum lockups reaching up to 63 seconds. This immediately triggers NAS timeouts at UERANSIM, causing a massive flood of retry packets (341 retries for 200 UEs) that further crushes the already-starved CPUs.

---

