# Implementation Plan: Advanced Data Plane Routing (eBPF / Cilium)

## Goal
Replace the default K3s `flannel` CNI with **Cilium**. Cilium leverages **eBPF** (Extended Berkeley Packet Filter) to bypass the traditional Linux `iptables` routing stack, inserting routing logic directly into the lowest levels of the Linux kernel. This will significantly reduce the CPU overhead for the N3 User Plane traffic during flood attacks, without requiring specialized SR-IOV physical hardware.

## User Review Required
> [!WARNING]
> This is a moderately destructive cluster operation. Replacing the core CNI requires restarting the K3s service and will temporarily drop all existing Pod networking until Cilium successfully initializes. We will have to restart the Open5GS and UERANSIM pods afterward to acquire new eBPF-managed IPs.

## Proposed Steps

### Phase 1: Preparation & Flannel Removal
To install Cilium, we must explicitly tell K3s to stop managing the default Flannel overlay network.
1. Modify the K3s systemd service configuration (`/etc/systemd/system/k3s.service`) to include the `--flannel-backend=none` and `--disable-network-policy` flags.
2. Reload systemd and restart K3s.
3. Clean up the old Flannel interfaces and `iptables` rules on the host to ensure a clean slate for eBPF.

### Phase 2: Install Cilium CLI & Helm Chart
1. Install the `cilium-cli` tool on the host machine to manage and inspect the eBPF datapath.
2. Install Cilium into the `kube-system` namespace using the official Helm chart or CLI, explicitly configuring it to replace the `kube-proxy` component with strict eBPF routing (`--routing-mode native`).

### Phase 3: Network Regeneration & Multus Verification
1. Restart all pods in the `open5gs` and `open5gs-upf` namespaces.
2. Verify that the pods receive new IP addresses originating from the Cilium IPAM (IP Address Management) pool rather than the old Flannel pool.
3. Verify that **Multus** successfully re-attaches the `net1` (N4) and `net2` (N6) MACVLAN interfaces alongside the new Cilium-managed `eth0` (N3) interface. The K3s Multus symlinks we created earlier should ensure this transition is smooth.

### Phase 4: Validating eBPF Datapath Performance
1. Ensure the 20 UE data tunnels (`uesimtun0`-`19`) are successfully re-established over the new Cilium network.
2. Re-run exactly the same **Test 1: Standard Deployment UDP Blast** (2 Gbps via `iperf3`) over the new Cilium N3 interface.
3. Use the Cilium CLI (`cilium hubble`) to inspect the eBPF datapath.
4. Compare the peak CPU usage against the original `214m` spike. We expect to see a massive reduction in CPU overhead because eBPF drastically shortens the packet processing pipeline inside the Linux kernel.
