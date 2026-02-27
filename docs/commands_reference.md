# 5G Testbed: Complete Commands Reference

All commands used for deploying, configuring, testing, and debugging the Open5GS + UERANSIM 5G core on K3s with Multus CNI and Cilium eBPF.

---

## 1. K3s Cluster Management

```bash
# Check cluster status
kubectl cluster-info
kubectl get nodes -o wide

# Restart K3s (fixes CNI deadlocks, stale routes)
sudo systemctl restart k3s
sudo systemctl status k3s

# View K3s service config (contains CNI flags)
cat /etc/systemd/system/k3s.service

# K3s logs (debugging API server hangs)
sudo journalctl -u k3s --no-pager -n 100

# Check all system pods
kubectl get pods -n kube-system
```

---

## 2. Open5GS Core Deployment

```bash
# List all 5G core pods
kubectl get pods -n open5gs -o wide
kubectl get pods -n open5gs-upf -o wide

# Check services (ClusterIP, NodePort)
kubectl get svc -n open5gs
kubectl get svc -n open5gs-upf

# Restart a specific NF
kubectl rollout restart deploy/open5gs-amf -n open5gs

# Restart ALL control plane NFs
kubectl rollout restart deploy -n open5gs

# Scale a deployment (e.g., scale down then up to force fresh pod)
kubectl scale deploy open5gs-mongodb --replicas=0 -n open5gs
kubectl scale deploy open5gs-mongodb --replicas=1 -n open5gs

# View NF logs
kubectl logs -n open5gs deploy/open5gs-amf --tail=50
kubectl logs -n open5gs deploy/open5gs-smf --tail=50
kubectl logs -n open5gs-upf deploy/open5gs-upf --tail=50

# View NF config (ConfigMap)
kubectl get cm -n open5gs
kubectl get cm open5gs-smf-config -n open5gs -o yaml

# Edit a ConfigMap live
kubectl edit cm open5gs-smf-config -n open5gs

# Check PFCP association (SMF ↔ UPF link)
kubectl logs -n open5gs deploy/open5gs-smf | grep -i "pfcp\|association\|upf"
kubectl logs -n open5gs-upf deploy/open5gs-upf | grep -i "pfcp\|heartbeat"

# Check NRF registrations
kubectl logs -n open5gs deploy/open5gs-nrf | grep -i "registered\|profile"
```

---

## 3. UERANSIM (gNB + UE)

```bash
# Check gNB and UE pods
kubectl get pods -n open5gs | grep ueransim

# View gNB logs (SCTP/NGAP connection to AMF)
kubectl logs -n open5gs deploy/ueransim-gnb | tail -30

# View UE logs (registration + PDU session)
kubectl logs -n open5gs deploy/ueransim-gnb-ues | tail -50
kubectl logs -n open5gs deploy/ueransim-gnb-ues | grep -E "successful|PDU|uesimtun"

# Check if PDU sessions created (uesimtun interfaces)
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ip addr | grep uesimtun

# Update gNB IP in the UE deployment (after gNB restarts)
GNB_IP=$(kubectl get pod -n open5gs -l app.kubernetes.io/component=gnb -o jsonpath='{.items[0].status.podIP}')
kubectl set env deploy/ueransim-gnb-ues GNB_IP=$GNB_IP -n open5gs

# Restart UEs to re-register
kubectl rollout restart deploy/ueransim-gnb-ues -n open5gs

# Ping through 5G data plane
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -I uesimtun0 -c 5 8.8.8.8
```

---

## 4. MongoDB (Subscriber Management)

```bash
# Access MongoDB shell
kubectl exec -it -n open5gs deploy/open5gs-mongodb -- mongosh open5gs

# Inside mongosh — list all subscribers
db.subscribers.find().pretty()
db.subscribers.countDocuments()

# Check a specific subscriber by IMSI
db.subscribers.find({imsi: "999700000000001"}).pretty()

# Delete all subscribers (re-provision fresh)
db.subscribers.deleteMany({})

# Run subscriber provisioning script
kubectl exec -n open5gs deploy/open5gs-populate -- /bin/bash /tmp/add_ues_fixed.sh
```

---

## 5. Multus CNI

```bash
# Install Multus (thick plugin)
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

# Check Multus pods
kubectl get pods -n kube-system | grep multus

# Create host dummy interface (MACVLAN parent)
sudo ip link add dummy-n3n4 type dummy
sudo ip link set dummy-n3n4 up

# Apply Network Attachment Definitions
kubectl apply -f upf-nads.yaml

# Check NADs
kubectl get net-attach-def -n open5gs-upf

# Verify Multus interfaces inside UPF pod
kubectl exec -n open5gs-upf deploy/open5gs-upf -- ip addr show
# Should show: eth0 (Cilium), net1 (MACVLAN N4), net2 (MACVLAN N6), ogstun
```

---

## 6. Cilium eBPF

```bash
# Disable Flannel in K3s (edit service file)
sudo vi /etc/systemd/system/k3s.service
# Add: --flannel-backend=none --disable-network-policy
sudo systemctl daemon-reload
sudo systemctl restart k3s

# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

# Install Cilium via Helm
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.18.5 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=6443

# Verify Cilium status
cilium status
cilium version
kubectl get pods -n kube-system -l k8s-app=cilium

# Verify eBPF routing is active
ip route | grep cilium_host
# Should show: 10.0.0.0/24 via 10.0.0.49 dev cilium_host

# Clean old Flannel artifacts (if needed)
sudo ip link delete flannel.1
sudo ip link delete cni0
```

---

## 7. Metrics Server

```bash
# Check metrics-server pod
kubectl get pods -n kube-system -l k8s-app=metrics-server

# View metrics-server logs (debugging crashes)
kubectl logs -n kube-system deploy/metrics-server

# Quick resource usage check
kubectl top pod -n open5gs
kubectl top pod -n open5gs-upf
kubectl top nodes
```

---

## 8. UPF Stress Testing

```bash
# HTTP/wget flood (20 UEs, no extra tools needed)
./upf_flood.sh 60

# iperf3 UDP flood (20 UEs × 100Mbps = 2 Gbps)
./upf_flood_iperf3.sh 60

# Install iperf3 inside UE pod (if not present)
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- apt-get update
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- apt-get install -y iperf3

# Deploy standalone iperf3 server in UPF namespace
kubectl run iperf3-server --image=networkstatic/iperf3 -n open5gs-upf -- -s
kubectl expose deployment iperf3-app -n open5gs-upf --port=5201 --type=NodePort

# Manual single-UE iperf3 test
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- \
  iperf3 -c <HOST_IP> -p <NODE_PORT> -u -b 100M -t 10 -B <uesimtun0_IP>
```

---

## 9. Sub-Second Metrics (cAdvisor/cgroup)

```bash
# High-frequency UPF metrics (200ms intervals, 60 seconds)
sudo ./cadvisor_metrics.sh open5gs-upf upf 60 200

# Monitor AMF instead
sudo ./cadvisor_metrics.sh open5gs amf 60 200

# Ultra-fast 100ms intervals
sudo ./cadvisor_metrics.sh open5gs-upf upf 30 100

# Combined: start logger + flood simultaneously
sudo ./cadvisor_metrics.sh open5gs-upf upf 70 200 > /tmp/logger.txt 2>&1 &
sleep 5
./upf_flood_iperf3.sh 45

# Manual cgroup reads (what the script does internally)
# CPU (microseconds):
sudo cat /sys/fs/cgroup/kubepods.slice/.../cpu.stat | grep usage_usec
# Memory (bytes):
sudo cat /sys/fs/cgroup/kubepods.slice/.../memory.current
# Network (bytes) — using container PID:
sudo cat /proc/<CONTAINER_PID>/net/dev | grep eth0
# Disk I/O (bytes):
sudo cat /sys/fs/cgroup/kubepods.slice/.../io.stat

# Find a container's cgroup path
CONTAINER_ID=$(kubectl get pod -n open5gs-upf <POD> -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
sudo find /sys/fs/cgroup -name "cri-containerd-${CONTAINER_ID}.scope" -type d

# Find a container's PID (for /proc reads)
sudo crictl inspect --output go-template --template '{{.info.pid}}' $CONTAINER_ID
```

---

## 10. Debugging & Troubleshooting

```bash
# Pod stuck in ContainerCreating (CNI deadlock)
kubectl describe pod <POD_NAME> -n <NAMESPACE>
# Fix: sudo systemctl restart k3s

# Pod in CrashLoopBackOff
kubectl logs -n <NS> <POD> --previous   # logs from crashed container
kubectl describe pod <POD> -n <NS>       # events/errors

# Check network connectivity between pods
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -c 1 <TARGET_IP>

# View pod environment variables
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- env | sort

# Get container ID and runtime details
kubectl get pod <POD> -n <NS> -o jsonpath='{.status.containerStatuses[0]}'

# Host-level network debugging
ip route                  # routing table (look for cilium_host)
ip link show              # all interfaces
sudo iptables -L -t nat   # NAT rules
ss -tlnp                  # listening ports

# DNS resolution inside pods
kubectl exec -n open5gs deploy/open5gs-amf -- nslookup open5gs-nrf

# Force delete a stuck pod
kubectl delete pod <POD> -n <NS> --grace-period=0 --force
```
