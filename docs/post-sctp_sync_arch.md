# Synchronized Distributed 5G Registration Attack

This document provides a technical breakdown of Post-SCTP Synchronization method, and a detailed PCAP timing analysis proving the efficacy of the attack.

---

## 1. Technical Approach: Post-SCTP Synchronization 
Our old script attempts to synchronize execution by using bash `sleep`, and then starting the process. However, this includes the SCTP handshake and NG Setup procedure in the timing window, introducing massive network jitter (~200ms-400ms).

It primes the attack by moving the synchronization barrier into the Go runtime *after* the connection phase. 
1. The gNodeBs are allowed to establish their SCTP associations and complete the `NG Setup` with the AMF **first**. 
2. The UEs are held at a "Starting Line" inside the Go compiler.
3. Once the synchronized timestamp (UTC) is reached, all UEs are released simultaneously over the pre-established sockets.

### Architectural Patches
To make this attack work without the pods crashing into each other, we made four key changes to the system:

| Component | What We Changed | Why We Did It |
| :--- | :--- | :--- |
| **Go Code (Timer)** | Put the countdown timer inside the Go source code instead of the bash script. | This lets the pods connect to the AMF *before* the timer hits zero, removing connection delays from the attack window. |
| **Go Code (Ports)** | Changed the code so it doesn't force a specific starting port. | When all pods share the same host IP, they would crash fighting over the same port. This lets the Linux OS automatically give each pod a unique port. |
| **Startup Script** | Used math and the Pod's Index number to auto-generate unique IDs (IMSI, GNB_ID) on startup. | If 5 pods try to connect acting like the exact same cell tower, the AMF drops them. This tricks the AMF into thinking 5 distinct cell towers are connecting. |
| **Network Config** | Bypassed Kubernetes networking and pointed the attack straight at the AMF's direct IP address. | Kubernetes networking adds 10-50 milliseconds of random delay to packets. Bypassing it ensures maximum speed and accuracy. |


---

## 2. PCAP Timing Analysis
By utilizing this method, we eliminated the gNodeB setup delay. This allowed all 50 UEs across 5 distributed pods to flood the AMF starting exactly at the sub-second barrier.

**Test Date:** March 15, 2026, 18:23 UTC (23:53 IST)  
**Target Fire Time:** `18:23:11.000`

### UE Registration Request Timeline (Initial UE Messages)
> Each UE sends an `Initial UE Message` (Procedure Code 15). All 50 UEs triggered successfully within a tiny window.

| Wave | Timestamp (Epoch) | Delta from First | UEs in Wave | Success |
|---|---|---|---|---|
| 1 | 18:23:11.**316** | 0.0 ms | 1 | 1 / 1 |
| 2 | 18:23:11.**341** | 25.7 ms | 10 | 10 / 10 |
| 3 | 18:23:11.**348** | 32.3 ms | 6 | 6 / 6 |
| 4 | 18:23:11.**351** | 35.1 ms | 1 | 1 / 1 |
| 5 | 18:23:11.**360** | 44.8 ms | 3 | 3 / 3 |
| 6 | 18:23:11.**370** | 54.2 ms | 1 | 1 / 1 |
| 7 | 18:23:11.**373** | 57.7 ms | 1 | 1 / 1 |
| 8 | 18:23:11.**375** | 59.1 ms | 9 | 9 / 9 |
| 9 | 18:23:11.**403** | 87.8 ms | 9 | 9 / 9 |
| 10 | 18:23:11.**418** | 102.1 ms | 9 | 9 / 9 |

### Detailed Timing Comparison

```
18:23:11.000  ─── TARGET FIRE TIME (NTP Barrier)
     │
18:23:11.315  ─── Node 2 Fired (Earliest Pod)
18:23:11.373  ─── Node 3 Fired (Latest Pod)
     │
     ◄───────────────── 58ms Pod Synchronization Window ─────────────────►
     │
18:23:11.316  ─── First UE Registration Pkt (PCAP)
18:23:11.418  ─── Last UE Registration Pkt (PCAP)
     │
     ◄─────────────── 102.1ms UE Packet Request Window ───────────────►
```

**Result:** The AMF handled 50 simultaneous registrations in 102.1ms with a **100% success rate** without a single failure, demonstrating that the bottlenecks in previous tests were network-layer (SCTP/CNI) rather than application-layer (AMF/MongoDB).

---

