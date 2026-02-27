#!/bin/bash
# ============================================================
# High-Frequency Container Metrics Logger (cgroup v2 direct)
# Polls Linux cgroup filesystem at sub-second intervals
# Exports CPU, Memory, Network, Disk I/O to CSV with ms timestamps
#
# Usage: sudo ./cadvisor_metrics.sh <namespace> <pod_substring> <duration_sec> [interval_ms]
# Example: sudo ./cadvisor_metrics.sh open5gs-upf upf 60 200
# ============================================================

NS="${1:-open5gs-upf}"
POD_MATCH="${2:-upf}"
DURATION="${3:-60}"
INTERVAL_MS="${4:-200}"

OUTPUT_DIR="/home/venu/cadvisor_metrics_$(date +%Y%m%d_%H%M%S)"
CSV_FILE="$OUTPUT_DIR/metrics.csv"

mkdir -p "$OUTPUT_DIR"
chown venu:venu "$OUTPUT_DIR"

# Resolve pod and container ID (kubectl works as any user)
POD_NAME=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep "$POD_MATCH" | grep Running | head -1 | awk '{print $1}')
if [ -z "$POD_NAME" ]; then
    echo "ERROR: No running pod matching '$POD_MATCH' in namespace '$NS'"
    exit 1
fi

POD_UID=$(kubectl get pod -n "$NS" "$POD_NAME" -o jsonpath='{.metadata.uid}')
CONTAINER_ID=$(kubectl get pod -n "$NS" "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
POD_UID_ESCAPED=$(echo "$POD_UID" | sed 's/-/_/g')

# Get the container's PID on the host for direct /proc reads (fast network counters)
CONTAINER_PID=$(crictl inspect --output go-template --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null)
if [ -z "$CONTAINER_PID" ]; then
    CONTAINER_PID=$(crictl inspect "$CONTAINER_ID" 2>/dev/null | grep '"pid"' | head -1 | grep -o '[0-9]*')
fi

# Construct cgroup v2 path
CGROUP_PATH="/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${POD_UID_ESCAPED}.slice/cri-containerd-${CONTAINER_ID}.scope"

if [ ! -d "$CGROUP_PATH" ]; then
    CGROUP_PATH="/sys/fs/cgroup/kubepods.slice/kubepods-pod${POD_UID_ESCAPED}.slice/cri-containerd-${CONTAINER_ID}.scope"
fi
if [ ! -d "$CGROUP_PATH" ]; then
    CGROUP_PATH=$(find /sys/fs/cgroup -name "cri-containerd-${CONTAINER_ID}.scope" -type d 2>/dev/null | head -1)
fi
if [ ! -d "$CGROUP_PATH" ]; then
    echo "ERROR: Cannot find cgroup path for container ${CONTAINER_ID:0:12}"
    exit 1
fi

INTERVAL_SEC=$(echo "scale=3; $INTERVAL_MS / 1000" | bc)
TOTAL_SAMPLES=$((DURATION * 1000 / INTERVAL_MS))

echo "=================================================="
echo "  High-Frequency Container Metrics Logger"
echo "  Pod:        $POD_NAME ($NS)"
echo "  Container:  ${CONTAINER_ID:0:12}..."
echo "  PID:        $CONTAINER_PID"
echo "  Cgroup:     $CGROUP_PATH"
echo "  Duration:   ${DURATION}s @ ${INTERVAL_MS}ms intervals"
echo "  Expected:   $TOTAL_SAMPLES samples"
echo "  Output:     $CSV_FILE"
echo "=================================================="

# CSV header
echo "timestamp_epoch_ms,timestamp_human,cpu_usage_usec,cpu_delta_usec,cpu_percent,mem_bytes,mem_rss_bytes,mem_cache_bytes,net_rx_bytes,net_rx_delta_bytes,net_tx_bytes,net_tx_delta_bytes,disk_read_bytes,disk_read_delta_bytes,disk_write_bytes,disk_write_delta_bytes" > "$CSV_FILE"

# Previous values
PREV_CPU=0; PREV_RX=0; PREV_TX=0; PREV_DREAD=0; PREV_DWRITE=0; PREV_TS=0
SAMPLE=0

echo "[*] Logging started..."
echo ""

while [ $SAMPLE -lt $TOTAL_SAMPLES ]; do
    TS_MS=$(date +%s%3N)
    TS_HUMAN=$(date +%H:%M:%S.%3N)

    # CPU (microseconds) — direct cgroup read, <0.1ms
    CPU_USEC=$(grep "^usage_usec" "${CGROUP_PATH}/cpu.stat" 2>/dev/null | awk '{print $2}')
    [ -z "$CPU_USEC" ] && CPU_USEC=0

    # Memory — direct cgroup read, <0.1ms
    MEM_BYTES=$(cat "${CGROUP_PATH}/memory.current" 2>/dev/null)
    MEM_RSS=$(grep "^anon " "${CGROUP_PATH}/memory.stat" 2>/dev/null | awk '{print $2}')
    MEM_CACHE=$(grep "^file " "${CGROUP_PATH}/memory.stat" 2>/dev/null | awk '{print $2}')
    [ -z "$MEM_BYTES" ] && MEM_BYTES=0
    [ -z "$MEM_RSS" ] && MEM_RSS=0
    [ -z "$MEM_CACHE" ] && MEM_CACHE=0

    # Network — direct /proc/<PID>/net/dev read from host, <0.1ms (no kubectl exec!)
    if [ -n "$CONTAINER_PID" ] && [ -f "/proc/$CONTAINER_PID/net/dev" ]; then
        NET_DATA=$(grep eth0 "/proc/$CONTAINER_PID/net/dev" 2>/dev/null)
        if [ -n "$NET_DATA" ]; then
            NET_RX=$(echo "$NET_DATA" | awk '{print $2}')
            NET_TX=$(echo "$NET_DATA" | awk '{print $10}')
        else
            NET_RX=0; NET_TX=0
        fi
    else
        NET_RX=0; NET_TX=0
    fi

    # Disk I/O
    DISK_READ=0; DISK_WRITE=0
    if [ -f "${CGROUP_PATH}/io.stat" ]; then
        DISK_READ=$(awk '{for(i=1;i<=NF;i++) if($i ~ /rbytes=/) {split($i,a,"="); s+=a[2]}} END{print s+0}' "${CGROUP_PATH}/io.stat" 2>/dev/null)
        DISK_WRITE=$(awk '{for(i=1;i<=NF;i++) if($i ~ /wbytes=/) {split($i,a,"="); s+=a[2]}} END{print s+0}' "${CGROUP_PATH}/io.stat" 2>/dev/null)
    fi

    # Deltas
    if [ $PREV_TS -gt 0 ]; then
        CPU_DELTA=$((CPU_USEC - PREV_CPU))
        TIME_DELTA_MS=$((TS_MS - PREV_TS))
        TIME_DELTA_USEC=$((TIME_DELTA_MS * 1000))
        if [ $TIME_DELTA_USEC -gt 0 ]; then
            CPU_PCT=$(awk "BEGIN{printf \"%.3f\", ($CPU_DELTA / $TIME_DELTA_USEC) * 100}")
        else
            CPU_PCT="0.000"
        fi
        RX_DELTA=$((NET_RX - PREV_RX))
        TX_DELTA=$((NET_TX - PREV_TX))
        DREAD_DELTA=$((DISK_READ - PREV_DREAD))
        DWRITE_DELTA=$((DISK_WRITE - PREV_DWRITE))
    else
        CPU_DELTA=0; CPU_PCT="0.000"; RX_DELTA=0; TX_DELTA=0; DREAD_DELTA=0; DWRITE_DELTA=0
    fi

    # Write row
    echo "${TS_MS},${TS_HUMAN},${CPU_USEC},${CPU_DELTA},${CPU_PCT},${MEM_BYTES},${MEM_RSS},${MEM_CACHE},${NET_RX},${RX_DELTA},${NET_TX},${TX_DELTA},${DISK_READ},${DREAD_DELTA},${DISK_WRITE},${DWRITE_DELTA}" >> "$CSV_FILE"

    PREV_CPU=$CPU_USEC; PREV_RX=$NET_RX; PREV_TX=$NET_TX
    PREV_DREAD=$DISK_READ; PREV_DWRITE=$DISK_WRITE; PREV_TS=$TS_MS

    # Progress (every 5th)
    if [ $((SAMPLE % 5)) -eq 0 ]; then
        ELAPSED_S=$(awk "BEGIN{printf \"%.1f\", $SAMPLE * $INTERVAL_MS / 1000}")
        MEM_MI=$(awk "BEGIN{printf \"%.1f\", $MEM_BYTES / 1048576}")
        printf "\r  [%6ss/%ss] CPU=%-10s MEM=%-8sMi  RX_Δ=%-12s TX_Δ=%-12s" \
            "$ELAPSED_S" "$DURATION" "${CPU_PCT}%" "$MEM_MI" "${RX_DELTA}B" "${TX_DELTA}B"
    fi

    SAMPLE=$((SAMPLE + 1))
    sleep "$INTERVAL_SEC"
done

echo ""
echo ""

# Summary
TOTAL_ROWS=$(($(wc -l < "$CSV_FILE") - 1))
AVG_CPU=$(awk -F',' 'NR>2 {sum+=$5; n++} END{if(n>0) printf "%.3f", sum/n; else print 0}' "$CSV_FILE")
MAX_CPU=$(awk -F',' 'NR>2 {if($5+0 > max) max=$5+0} END{printf "%.3f", max}' "$CSV_FILE")
TOTAL_RX=$(awk -F',' 'NR>2 {sum+=$10} END{printf "%.0f", sum}' "$CSV_FILE")
TOTAL_TX=$(awk -F',' 'NR>2 {sum+=$12} END{printf "%.0f", sum}' "$CSV_FILE")

chown venu:venu "$CSV_FILE"

echo "=================================================="
echo "  Logging Complete!"
echo "  Total Samples: $TOTAL_ROWS"
echo "  Interval:      ${INTERVAL_MS}ms"
echo "  Duration:      ${DURATION}s"
echo "  Avg CPU:       ${AVG_CPU}%"
echo "  Peak CPU:      ${MAX_CPU}%"
echo "  Total Net RX:  ${TOTAL_RX} bytes"
echo "  Total Net TX:  ${TOTAL_TX} bytes"
echo "  CSV File:      $CSV_FILE"
echo "=================================================="
echo ""
echo "Quick Python plot:"
echo "  import pandas as pd; import matplotlib.pyplot as plt"
echo "  df = pd.read_csv('$CSV_FILE')"
echo "  fig, axes = plt.subplots(2, 2, figsize=(14,8))"
echo "  df['cpu_percent'].plot(ax=axes[0,0], title='CPU %')"
echo "  (df['mem_bytes']/1e6).plot(ax=axes[0,1], title='Memory (MB)')"
echo "  df['net_rx_delta_bytes'].plot(ax=axes[1,0], title='Network RX Δ (bytes/sample)')"
echo "  df['net_tx_delta_bytes'].plot(ax=axes[1,1], title='Network TX Δ (bytes/sample)')"
echo "  plt.tight_layout(); plt.savefig('${OUTPUT_DIR}/plot.png', dpi=150); plt.show()"
