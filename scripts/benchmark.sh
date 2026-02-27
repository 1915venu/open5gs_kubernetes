#!/bin/bash
# ============================================================
# Open5GS K3s Benchmark Script
# Captures CPU/RAM of all Open5GS pods over time
# Usage: ./benchmark.sh [duration_seconds] [interval_seconds]
# Example: ./benchmark.sh 300 5   (5 min, every 5 sec)
# ============================================================

export KUBECONFIG=~/.kube/config

DURATION="${1:-120}"        # default 2 minutes
INTERVAL="${2:-5}"          # default every 5 seconds
OUTPUT_DIR="$HOME/k3s_benchmark_$(date +%Y%m%d_%H%M%S)"
CSV_FILE="$OUTPUT_DIR/pod_metrics.csv"
NODE_CSV="$OUTPUT_DIR/node_metrics.csv"
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"

mkdir -p "$OUTPUT_DIR"

echo "=================================================="
echo "  Open5GS K3s Benchmark"
echo "  Duration: ${DURATION}s | Interval: ${INTERVAL}s"
echo "  Output: $OUTPUT_DIR"
echo "=================================================="

# Header for pod CSV
echo "timestamp,pod,cpu_millicores,memory_mib" > "$CSV_FILE"
echo "timestamp,node,cpu_percent,memory_percent,cpu_millicores,memory_mib" > "$NODE_CSV"

# Capture initial snapshot
echo "" >> "$SUMMARY_FILE"
echo "=== INITIAL STATE ($(date)) ===" >> "$SUMMARY_FILE"
kubectl top pods -n open5gs >> "$SUMMARY_FILE" 2>/dev/null
echo "" >> "$SUMMARY_FILE"
kubectl top node >> "$SUMMARY_FILE" 2>/dev/null

ELAPSED=0
echo ""
echo "Recording... Press Ctrl+C to stop early."
echo ""

while [ $ELAPSED -lt $DURATION ]; do
    TIMESTAMP=$(date +%s)
    
    # Pod-level metrics
    kubectl top pods -n open5gs --no-headers 2>/dev/null | while read POD CPU MEM; do
        # Strip 'm' from CPU and 'Mi' from memory
        CPU_VAL=$(echo "$CPU" | sed 's/m//')
        MEM_VAL=$(echo "$MEM" | sed 's/Mi//')
        echo "$TIMESTAMP,$POD,$CPU_VAL,$MEM_VAL" >> "$CSV_FILE"
    done
    
    # Node-level metrics
    kubectl top node --no-headers 2>/dev/null | while read NODE CPU_PCT CPU MEMORY_PCT MEM; do
        CPU_VAL=$(echo "$CPU" | sed 's/m//')
        MEM_VAL=$(echo "$MEM" | sed 's/Mi//')
        echo "$TIMESTAMP,$NODE,${CPU_PCT},$MEMORY_PCT,$CPU_VAL,$MEM_VAL" >> "$NODE_CSV"
    done
    
    # Progress indicator
    TOTAL_CPU=$(kubectl top pods -n open5gs --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); sum+=$2} END {print sum}')
    TOTAL_MEM=$(kubectl top pods -n open5gs --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$3); sum+=$3} END {print sum}')
    printf "\r[%3ds/%3ds] CPU: %sm  RAM: %sMi    " "$ELAPSED" "$DURATION" "$TOTAL_CPU" "$TOTAL_MEM"
    
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo ""

# Capture final snapshot
echo "=== FINAL STATE ($(date)) ===" >> "$SUMMARY_FILE"
kubectl top pods -n open5gs >> "$SUMMARY_FILE" 2>/dev/null
echo "" >> "$SUMMARY_FILE"
kubectl top node >> "$SUMMARY_FILE" 2>/dev/null

# Generate summary statistics
echo "" >> "$SUMMARY_FILE"
echo "=== STATISTICS ===" >> "$SUMMARY_FILE"

echo "" >> "$SUMMARY_FILE"
echo "Per-Pod Averages:" >> "$SUMMARY_FILE"
awk -F',' 'NR>1 {
    cpu[$2]+=$3; mem[$2]+=$4; count[$2]++
} END {
    for (pod in cpu) {
        printf "  %-45s CPU_avg: %6.1fm  RAM_avg: %6.1fMi\n", pod, cpu[pod]/count[pod], mem[pod]/count[pod]
    }
}' "$CSV_FILE" >> "$SUMMARY_FILE"

echo "" >> "$SUMMARY_FILE"
echo "Total Cluster Averages:" >> "$SUMMARY_FILE"
awk -F',' 'NR>1 {
    cpu[$1]+=$3; mem[$1]+=$4
} END {
    total_cpu=0; total_mem=0; n=0
    for (ts in cpu) { total_cpu+=cpu[ts]; total_mem+=mem[ts]; n++ }
    printf "  Avg Total CPU: %.1fm\n  Avg Total RAM: %.1fMi\n  Samples: %d\n", total_cpu/n, total_mem/n, n
}' "$CSV_FILE" >> "$SUMMARY_FILE"

echo "=================================================="
echo "  Benchmark Complete!"
echo "  Results: $OUTPUT_DIR"
echo "  CSV:     $CSV_FILE"
echo "  Summary: $SUMMARY_FILE"
echo "=================================================="
cat "$SUMMARY_FILE"
