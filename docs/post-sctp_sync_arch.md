# Architectural Analysis: Synchronized Distributed 5G Registration Attack

This document provides a comprehensive technical breakdown of **Method 3 (Post-SCTP Synchronization)**, the resulting network footprint vulnerabilities, the roadmap for evasion, and a detailed PCAP timing analysis proving the efficacy of the attack.

---

## 1. Technical Approach: Post-SCTP Synchronization (Method 3)
Traditional scripts attempt to synchronize execution by using bash `sleep`, and then starting the process. However, this includes the SCTP handshake and NG Setup procedure in the timing window, introducing massive network jitter (~200ms-400ms).

Method 3 "primes" the attack by moving the synchronization barrier into the Go runtime *after* the connection phase. 
1. The gNodeBs are allowed to establish their SCTP associations and complete the `NG Setup` with the AMF **first**. 
2. The UEs are held at a "Starting Line" inside the Go compiler.
3. Once the synchronized timestamp (UTC) is reached, all UEs are released simultaneously over the pre-established sockets.

### Architectural Patches
To make this architecture work and prevent connection collisions, multiple layers of the stack were patched:

| Component | Modification | Purpose |
| :--- | :--- | :--- |
| **Go Source (NTP Barrier)** | Patched [ngap/service.go](file:///home/venu/Desktop/5G-Registration-Attack/distributed-attack/PacketRusher/internal/control_test_engine/gnb/ngap/service.go) and `internal/control_test_engine/ue/ue.go`. | Moved the NTP barrier into the Go loop to allow pre-connection before the sync trigger. |
| **Go Source (Dynamic Binding)** | Patched `sctp.DialSCTPExt` logic to bind to `nil` (`0.0.0.0`). | Enabled the OS to dynamically assign ephemeral SCTP source ports on the host network, avoiding port conflicts when multiple pods shared the Host IP interface. |
| **Entrypoint (Identity Collision)** | Created a dynamic `sed`-based configuration injector reading `$POD_INDEX`. | Converted a read-only `ConfigMap` into a unique, per-pod identity (`MSIN`, `GNB_ID`, `GNB_Port`). This prevented the AMF from dropping connections due to duplicate cell tower IDs. |
| **Manifest (DNS Bypass)** | Directly addressed the AMF Pod IP (`10.0.0.216`) inside `hostNetwork: true`. | Bypassed the K8s CoreDNS and CNI latency jitter, ensuring the lowest possible latency path directly to the AMF application layer. |

---

## 2. PCAP Timing Analysis
By utilizing Method 3, we eliminated the gNodeB setup delay. This allowed all 50 UEs across 5 distributed pods to flood the AMF starting exactly at the sub-second barrier.

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

## 3. The "Single IP" Vulnerability Analysis
Because all 5 pods used `hostNetwork` on a single physical Ubuntu host to achieve the 58ms jitter, every single packet carried the exact same source IP (`10.194.172.92` or `10.0.0.49`). A security-conscious AMF or perimeter firewall would see 50 UE registrations arriving in 100ms from one unified IP and could immediately drop it as a **Distributed Registration DoS Attack**.

If the AMF implements a simple **Rate Limiter** or **IP Blacklist** on the `N2` interface, it would stop this specific single-machine deployment completely. 

### The Defense Dilemma
However, this architecture directly mimics a real-world scenario of a **High-Density Public Area** (like a sports stadium or airport) where one massive physical gNodeB (with one IP) legitimately represents thousands of UEs. Blocking that single IP creates a "Defense Dilemma" for Telecom Operators by potentially isolating thousands of legitimate subscribers to stop the attack.

---

## 4. Further Work & Roadmap
To take this research further and bypass constraints like the single-IP vulnerability, the following roadmap is proposed:

### Phase 1: Multi-Node IP Diversity (Evasion)
Deploy the Kubernetes cluster across 3-4 physical worker nodes. Use `topologySpreadConstraints` to ensure attack pods land on different physical hosts. This forces the AMF to see registrations from multiple distinct source IPs, completely defeating simple IP-based blacklists.

### Phase 2: AMF/Database Stress Testing (Scalability)
Increase the load from 50 UEs to 250+ UEs. The goal is to find the database breaking point—specifically the MongoDB write-lock latency when hundreds of UEs update their `last_registration` timestamp and retrieve authentication vectors simultaneously.

### Phase 3: Data-Plane & IoT Simulation (Full Core Stress)
Modify [PacketRusher](file:///home/venu/PacketRusher) to initiate **PDU Session Establishment** immediately after registration, simulating a massive influx of IoT devices waking up and requesting internet access. This extends the stress test from the Control Plane (AMF) to the Session Management Function (SMF) and User Plane Function (UPF).

### Phase 4: Smart Jitter (Obfuscation)
A 58ms window is almost "too perfect" and is easily flagged as synthetic machine traffic by advanced intrusion detection systems. Introduce a "Smart Jitter" (e.g., 1-5 seconds using a Gaussian distribution) to make the attack mimic a human "Flash Event" (like a train arriving at a station) rather than a mathematically precise botnet execution.
