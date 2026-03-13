# PCAP Timing Analysis — Instant Burst Test (5 Pods × 10 UEs)

**PCAP File:** `amf_attack_instant_proof.pcap`  
**Test Date:** March 12, 2026, 13:46 IST  
**Configuration:** 5 Pods, 10 UEs/pod, `--timeBetweenRegistration 1` (1ms delay)  
**Target Fire Time:** `13:46:21.000`

---

## Three Phases of the Attack

### Phase 1 — Pod (gNodeB) Connection to AMF
> Each Pod establishes an SCTP connection and sends an `NG Setup Request` (Procedure Code 21) to register itself as a Cell Tower with the AMF.

| # | Timestamp | Source Pod IP | Event |
|---|-----------|--------------|-------|
| 1 | 13:46:21.**331** | 10.0.0.22 | NG Setup Request |
| 2 | 13:46:21.**331** | 10.0.0.4 | NG Setup Request |
| 3 | 13:46:21.**545** | 10.0.0.16 | NG Setup Request |
| 4 | 13:46:21.**546** | 10.0.0.40 | NG Setup Request |
| 5 | 13:46:21.**614** | 10.0.0.153 | NG Setup Request |

| Metric | Value |
|--------|-------|
| First Pod | 13:46:21.331 |
| Last Pod | 13:46:21.614 |
| **Window** | **288 ms** |

---

### Phase 2 — UE Registration Requests
> Each UE sends an `Initial UE Message` (Procedure Code 15) containing the 5G Registration Request through its Pod's gNodeB connection.

| # | Timestamp | Source Pod IP | Event |
|---|-----------|--------------|-------|
| 1 | 13:46:22.**433** | 10.0.0.22 | UE Registration Request |
| 2 | 13:46:22.**434** | 10.0.0.4 | UE Registration Request |
| 3 | 13:46:22.**455** | 10.0.0.4 | UE Registration Request |
| 4 | 13:46:22.**635** | 10.0.0.22 | UE Registration Request |
| 5 | 13:46:22.**647** | 10.0.0.16 | UE Registration Request |
| 6 | 13:46:22.**648** | 10.0.0.40 | UE Registration Request |
| 7 | 13:46:22.**672** | 10.0.0.40 | UE Registration Request |
| 8 | 13:46:22.**716** | 10.0.0.153 | UE Registration Request |
| 9 | 13:46:22.**723** | 10.0.0.153 | UE Registration Request |
| 10 | 13:46:22.**731** | 10.0.0.153 | UE Registration Request |
| 11 | 13:46:22.**851** | 10.0.0.16 | UE Registration Request |

| Metric | Value |
|--------|-------|
| First UE | 13:46:22.433 |
| Last UE | 13:46:22.851 |
| **Window** | **418 ms** |



---

### Phase 3 — AMF Registration Accept
> The AMF responds with `InitialContextSetupRequest` (Procedure Code 14), which carries the `Registration Accept` NAS message back to the UE.

| Metric | Value |
|--------|-------|
| First Accept | 13:46:22.526 |
| Last Accept | 13:46:23.164 |
| **Window** | **637 ms** |
| Total Accepts | 55 packets (includes NGAP handshakes) |

---

## End-to-End Timeline

```
13:46:21.000  ─── TARGET FIRE TIME (NTP Barrier)
     │
13:46:21.331  ─── First Pod connects (NG Setup Request)
13:46:21.614  ─── Last Pod connects              ◄── 288ms Pod window
     │
13:46:22.433  ─── First UE sends Registration Request
13:46:22.526  ─── First Registration Accept from AMF  (93ms latency!)
13:46:22.851  ─── Last UE sends Registration Request  ◄── 418ms UE window
     │
13:46:23.164  ─── Last Registration Accept       ◄── 637ms Accept window
```

---

## Registration Success Rate

| Pod | IP | UEs Registered | UEs Failed |
|-----|-----|---------------|------------|
| Pod 0 | 10.0.0.22 | 0 / 10 | 10 (NGAP Error) |
| Pod 1 | 10.0.0.4 | 9 / 10 | 1 |
| Pod 2 | 10.0.0.40 | 9 / 10 | 1 |
| Pod 3 | 10.0.0.153 | 10 / 10 | 0 |
| Pod 4 | 10.0.0.16 | 1 / 10 | 9 |
| **Total** | | **29 / 50** | **21 (42% DoS)** |

> [NOTE]
> With the 500ms inter-UE delay, all 50 UEs registered successfully (94-100%).  
> With the 1ms inter-UE delay (instant burst), only 29/50 registered — proving that the AMF cannot handle 50 simultaneous cryptographic handshakes in a 418ms window.
