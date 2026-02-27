# 5G Deployment Evolution & Testing Plan

This document outlines the evolutionary steps to upgrade the current CUPS and Multus-enabled 5G testbed. 

**Phase 1** focuses strictly on software-level enhancements that can be executed **immediately on the current `venu-optiplex-5070` machine** without purchasing specialized telecom hardware or additional servers.
**Phase 2** outlines the hardware-dependent "Industry-Grade" upgrades required for a true commercial rollout.

---

## Phase 1: Software-Only Enhancements (Current Machine)

These enhancements require zero physical hardware upgrades and can be deployed onto your existing K3s cluster.

### A. Advanced Data Plane Routing (eBPF / Cilium)
*   **The Problem:** The current Flannel overlay and standard MACVLAN bridges rely heavily on `iptables` and the traditional Linux networking stack, which is slow for 5G traffic.
*   **The Enhancement:** Replace Flannel with **Cilium CNI**. Cilium uses **eBPF (Extended Berkeley Packet Filter)** to inject routing logic directly into the lowest levels of the Linux kernel. It bypasses `iptables` entirely, significantly speeding up packet traversal through the UPF pod without needing SR-IOV hardware.

### B. Strict QoS Enforcement & CPU Pinning
*   **The Problem:** During the `iperf3` flood, the UPF CPU spiked to 214m, but it never throttled because there were no strict limits applied.
*   **The Enhancement:** Implement **Guaranteed Quality of Service (QoS)** in Kubernetes.
    *   Set strict `resources.limits.cpu` and `resources.requests.cpu` (e.g., exactly `500m`) for the `open5gs-upf` Deployment.
    *   Enable Kubernetes' `--cpu-manager-policy=static` on the K3s node. This "pins" the UPF container to a dedicated physical CPU core on your machine, preventing other pods from stealing its cycles.
    *   **The Test:** Re-run the `iperf3` flood until you hit that hard 500m limit, and scientifically measure the packet drop percentage caused definitively by Linux `cgroups` CPU throttling.

### C. Traffic Shaping (Network QoS)
*   **The Problem:** Right now, all 20 UEs compete equally for bandwidth. If one UE downloads a massive file, it can crowd out the others.
*   **The Enhancement:** Implement Linux **Traffic Control (`tc`)** or Kubernetes Network Policies against the `net1` / `net2` Multus interfaces to artificially enforce rate limits. For example, cap UE1 at 10 Mbps and UE2 at 50 Mbps, proving you can manage tenant Service Level Agreements (SLAs) natively in software.

### D. Chaos Engineering
*   **The Problem:** We know the architecture isolates the N3 and N4 pathways, but we haven't tested failure recovery.
*   **The Enhancement:** Install **Chaos Mesh** (a CNCF project) into your K3s cluster. Use it to randomly "kill" the UPF pod, force artificial network latency (jitter) onto the `net2` PFCP MACVLAN interface, or entirely drop N4 packets silently.
    *   **The Test:** Observe how quickly the SMF detects the dead UPF (via PFCP heartbeats), spins down the session, and how long it takes for a new UPF pod to spin up and accept the GTP-U data tunnels again.

---

## Phase 2: Ultimate Industry-Grade Upgrades (Requires New Hardware)

To break the 10-Gigabit or 100-Gigabit routing barrier, telecom data centers abandon standard PC hardware for specialized silicon.

### A. Hardware Acceleration (SR-IOV & DPDK)
*   **Hardware Required:** Intel XL710/X710 or Mellanox ConnectX NICs.
*   **The Enhancement:** **SR-IOV** physically slices the silicon of the Network Card into "Virtual Functions" and maps those physical slice directly into the UPF pod. The UPF runs **DPDK** code to read the packets straight off the silicon buffer instantly. The host CPU never sleeps, and the Linux kernel is never touched, reducing routing latency to virtually zero.

### B. Dynamic Networking (BGP Route Advertisement)
*   **Hardware Required:** physical Top-of-Rack (ToR) Switch capable of BGP routing.
*   **The Enhancement:** Instead of hardcoding static IP subnets into Open5GS config maps, the K3s cluster uses BGP to dynamically advertise the newly spun-up UPF routes directly to the physical network switch.

### C. Geographical Distribution (MEC)
*   **Hardware Required:** A secondary physical Edge server.
*   **The Enhancement:** Implement **Multi-Access Edge Computing (MEC)**. Leave the Control Plane (AMF/SMF) in a centralized cloud server, and deploy the User Plane (UPF) on a tiny physical server bolted directly to the cell tower. This physical separation guarantees the data payload travels the shortest physical distance possible to the internet, achieving the ultra-low millisecond latency promised by 5G.
