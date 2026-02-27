# Multus CNI Integration: Detailed Technical Breakdown

This document provides an in-depth explanation of the Multus CNI integration implemented in our 5G testbed, detailing the exact components added, the critical K3s-specific network fixes required, the operational commands used, and how this architecture maps to industry-grade deployments.

---

## 1. What is Multus and What is its Use?

In a standard Kubernetes environment, every Pod is restricted to a **single network interface** (typically `eth0`). All traffic—management, signaling, and data payload—competes for bandwidth on this single virtual pipe.

**The Use Case:** Real-world 5G hardware (like a physical UPF appliance) uses multiple physical ports to physically separate Control Plane (signaling) from User Plane (data traffic) for security, Quality of Service (QoS), and monitoring. 

**What Multus Achieves:** Multus is a "meta-plugin" CNI that breaks the single-interface rule. It allowed us to inject multiple virtual network interfaces into the isolated UPF Pod, mimicking a multi-homed hardware appliance. We configured:
*   `eth0` (K3s Overlay): Dedicated to the massive N3 GTP-U packet floods from the UEs.
*   `net1` & `net2` (MACVLANs): Dedicated strictly for N4 PFCP signaling and N6 internet egress.

---

## 2. What Exactly Was Added?

To build this architecture, we added four core components to the cluster:

1.  **Multus DaemonSet:** The core Multus controller installed across the cluster.
2.  **A Host Master Interface (`dummy-n3n4`):** A virtual interface created on the base Linux host to act as the parent bridge for the UPF's virtual MACVLAN connections.
3.  **Network Attachment Definitions (NADs):** Custom Kubernetes Resources (`upf-nads.yaml`) that instructed Multus on how to carve out the `192.168.100.x` subnets for the UPF.
4.  **Deployment Annotations:** We modified the UPF's Kubernetes Deployment YAML to ask Multus for these specific interfaces upon boot.

---

## 3. The Challenges & The Custom Fixes Implemented

Integrating Multus into K3s (which uses non-standard filesystem paths) for a complex 5G workload required four critical engineering fixes:

### Fix A: K3s Pathing & Binary Isolation
*   **The Problem:** Multus crash-looped because it was looking for standard Kubernetes networking paths (`/etc/cni/net.d` and `/opt/cni/bin`), but K3s stores these in a proprietary location (`/var/lib/rancher/k3s/agent/...`).
*   **The Fix:** We created host-level symlinks to trick Multus, and patched its DaemonSet volumes to mount the deeply nested K3s binary directory directly into the Multus pod so it could find the underlying `macvlan` executable.

### Fix B: MACVLAN Master Instability
*   **The Problem:** We initially tried to attach the UPF's new interfaces to a dormant bridge (`demo-oai`). Because that bridge had no physical connection (`NO-CARRIER` state), the UPF interfaces inherited the down state and failed to route.
*   **The Fix:** We executed host commands to spawn a permanent, always-up pseudo-device (`dummy-n3n4`) to serve as a perfectly stable parent for the MACVLAN sub-interfaces.

### Fix C: The UPF Initialization Race Condition
*   **The Problem:** Open5GS boots very quickly. When the UPF container started, it immediately tried to bind to `192.168.100.11` (its new N4 interface). However, Multus takes about ~1.5 seconds to inject the `net1` interface into the pod. The UPF crashed instantly with a `bind() failed` error.
*   **The Fix:** We overwrote the UPF's startup script. We injected a continuous `while loop` that commands the container to sleep and wait until `ip a show net1` successfully returns before it launches the `open5gs-upfd` daemon.

### Fix D: Asymmetric Routing (PFCP Drops)
*   **The Problem:** After assigning the UPF multiple IP addresses, the SMF started spamming `Retry association with peer failed`. Because the UPF now had complex routing tables via Multus, when the SMF talked to the UPF's Kubernetes Service IP (`ClusterIP`), the UPF replied using a different source IP. The SMF viewed this as a spoofed packet and dropped it.
*   **The Fix:** We hardcoded the UPF's exact internal Pod IP (`10.42.0.x`) directly into the SMF's configuration, forcing symmetrical, point-to-point signaling.

---

## 4. The Commands Used

Here are the primary commands orchestrated to assemble this testbed:

**1. Installing the Multus CNI Controller:**
```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```

**2. Creating the stable Host Master Interface:**
```bash
sudo ip link add dummy-n3n4 type dummy
sudo ip link set dummy-n3n4 up
```

**3. Applying the NADs (Network Constraints):**
```bash
kubectl apply -f upf-nads.yaml
```
*(This YAML contained the `macvlan` type definitions requesting static `192.168.100.x` IP provisioning).*

**4. Verifying Interface Injection Inside the UPF Pod:**
```bash
kubectl exec -n open5gs-upf deploy/open5gs-upf -- ip addr show
```
*(This confirmed the presence of `eth0`, `net1`, `net2`, and `ogstun`).*

---

## 5. Next Steps: Industry-Grade Deployment Architecture

While this K3s deployment perfectly proved the logical concepts of CUPS and interface isolation, taking this to a production telecom (Industry-Grade) environment requires abandoning standard network overlays entirely:

1.  **Bypass the Linux Kernel (SR-IOV & DPDK):** Standard MACVLAN still relies heavily on the Linux kernel's networking stack, which introduces high CPU overhead (as seen in our 214m UDP CPU spike). Industry deployments utilize **SR-IOV** (Single Root I/O Virtualization) to slice a physical Network Interface Card (NIC) at the hardware level, passing the virtual slice directly into the Pod. Combined with **DPDK** (Data Plane Development Kit), the UPF reads packets directly from memory, completely bypassing the Linux kernel. This allows routing at strict physical line-rates (e.g., millions of packets per second with negligible CPU usage).
2.  **BGP Routing (Cilium/Calico):** Instead of static IPs and asymmetric routing workarounds, production clusters use BGP-aware CNIs to dynamically advertise the UPF's session subnets directly to Top-of-Rack (ToR) physical switches.
3.  **Multi-Node MEC Distribution:** The localized namespace isolation would be replaced with physical geographic isolation. The AMF/SMF would sit in strictly controlled regional data centers, while the UPFs would be deployed out to Multi-Access Edge Computing (MEC) clusters physically co-located near the gNB cell towers to guarantee ultra-low latency.
