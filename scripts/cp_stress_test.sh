#!/bin/bash
# ============================================================
# Control Plane Stress Test: Registration Latency Under Load
# Runs PacketRusher multi-UE registration flood while capturing
# per-NF cgroup metrics at sub-second intervals
#
# Usage: sudo ./cp_stress_test.sh [num_ues] [time_between_reg_ms] [test_label]
# Example: sudo ./cp_stress_test.sh 50 100 "50ue_no_limit"
# ============================================================

export PATH=/home/venu/.local/go/bin:$PATH
PACKETRUSHER="/home/venu/PacketRusher/packetrusher"
PR_CONFIG="/home/venu/PacketRusher/config/config.yml"

NUM_UES="${1:-10}"
REG_INTERVAL_MS="${2:-500}"
TEST_LABEL="${3:-test}"

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/home/venu/cp_stress_test_${TIMESTAMP}_${TEST_LABEL}"
mkdir -p "$OUTPUT_DIR"

# Control plane NF pods to monitor
CP_NFS=("amf" "ausf" "udm" "udr" "smf" "mongodb")

echo "================================================================"
echo "  Control Plane Stress Test"
echo "  UEs:                $NUM_UES"
echo "  Registration gap:   ${REG_INTERVAL_MS}ms"
echo "  Label:              $TEST_LABEL"
echo "  Output:             $OUTPUT_DIR"
echo "================================================================"

# ---------------------------------------------------------------
# Step 1: Resolve all CP NF container PIDs and cgroup paths
# ---------------------------------------------------------------
echo ""
echo "[1/5] Resolving container PIDs and cgroup paths..."

declare -A NF_PIDS
declare -A NF_CGROUPS
declare -A NF_PODS

for NF in "${CP_NFS[@]}"; do
    POD=$(kubectl get pods -n open5gs --no-headers 2>/dev/null | grep "$NF" | grep Running | head -1 | awk '{print $1}')
    if [ -z "$POD" ]; then
        echo "  WARNING: No running pod for $NF, skipping"
        continue
    fi

    POD_UID=$(kubectl get pod -n open5gs "$POD" -o jsonpath='{.metadata.uid}')
    CONTAINER_ID=$(kubectl get pod -n open5gs "$POD" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
    POD_UID_ESCAPED=$(echo "$POD_UID" | sed 's/-/_/g')

    # Get PID
    PID=$(crictl inspect --output go-template --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null)
    if [ -z "$PID" ]; then
        PID=$(crictl inspect "$CONTAINER_ID" 2>/dev/null | grep '"pid"' | head -1 | grep -o '[0-9]*')
    fi

    # Get cgroup path
    CGROUP="/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${POD_UID_ESCAPED}.slice/cri-containerd-${CONTAINER_ID}.scope"
    if [ ! -d "$CGROUP" ]; then
        CGROUP="/sys/fs/cgroup/kubepods.slice/kubepods-pod${POD_UID_ESCAPED}.slice/cri-containerd-${CONTAINER_ID}.scope"
    fi
    if [ ! -d "$CGROUP" ]; then
        CGROUP=$(find /sys/fs/cgroup -name "cri-containerd-${CONTAINER_ID}.scope" -type d 2>/dev/null | head -1)
    fi

    if [ -n "$PID" ] && [ -d "$CGROUP" ]; then
        NF_PIDS[$NF]=$PID
        NF_CGROUPS[$NF]=$CGROUP
        NF_PODS[$NF]=$POD
        echo "  ✓ $NF: PID=$PID, Pod=$POD"
    else
        echo "  ✗ $NF: Failed to resolve (PID=$PID, CGROUP=$CGROUP)"
    fi
done

echo "  Resolved ${#NF_PIDS[@]} NFs"

# ---------------------------------------------------------------
# Step 2: Start metrics collection for all NFs (background)
# ---------------------------------------------------------------
echo ""
echo "[2/5] Starting sub-second metrics collection..."

METRICS_PIDS=()
METRICS_INTERVAL_MS=200

for NF in "${!NF_PIDS[@]}"; do
    CSV_FILE="$OUTPUT_DIR/metrics_${NF}.csv"
    PID=${NF_PIDS[$NF]}
    CGROUP=${NF_CGROUPS[$NF]}

    echo "timestamp_epoch_ms,timestamp_human,nf,cpu_usage_usec,cpu_delta_usec,cpu_percent,mem_bytes,net_rx_bytes,net_rx_delta,net_tx_bytes,net_tx_delta" > "$CSV_FILE"

    # Launch background metrics collector
    (
        PREV_CPU=0; PREV_RX=0; PREV_TX=0; PREV_TS=0
        INTERVAL_SEC=$(echo "scale=3; $METRICS_INTERVAL_MS / 1000" | bc)

        while true; do
            TS_MS=$(date +%s%3N)
            TS_HUMAN=$(date +%H:%M:%S.%3N)

            CPU_USEC=$(grep "^usage_usec" "${CGROUP}/cpu.stat" 2>/dev/null | awk '{print $2}')
            [ -z "$CPU_USEC" ] && CPU_USEC=0
            MEM_BYTES=$(cat "${CGROUP}/memory.current" 2>/dev/null)
            [ -z "$MEM_BYTES" ] && MEM_BYTES=0

            NET_RX=0; NET_TX=0
            if [ -f "/proc/$PID/net/dev" ]; then
                NET_DATA=$(grep eth0 "/proc/$PID/net/dev" 2>/dev/null)
                if [ -n "$NET_DATA" ]; then
                    NET_RX=$(echo "$NET_DATA" | awk '{print $2}')
                    NET_TX=$(echo "$NET_DATA" | awk '{print $10}')
                fi
            fi

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
            else
                CPU_DELTA=0; CPU_PCT="0.000"; RX_DELTA=0; TX_DELTA=0
            fi

            echo "${TS_MS},${TS_HUMAN},${NF},${CPU_USEC},${CPU_DELTA},${CPU_PCT},${MEM_BYTES},${NET_RX},${RX_DELTA},${NET_TX},${TX_DELTA}" >> "$CSV_FILE"

            PREV_CPU=$CPU_USEC; PREV_RX=$NET_RX; PREV_TX=$NET_TX; PREV_TS=$TS_MS
            sleep "$INTERVAL_SEC"
        done
    ) &
    METRICS_PIDS+=($!)
    echo "  Started collector for $NF (PID: ${METRICS_PIDS[-1]})"
done

echo "  ${#METRICS_PIDS[@]} collectors running"

# ---------------------------------------------------------------
# Step 3: Baseline capture (5 seconds)
# ---------------------------------------------------------------
echo ""
echo "[3/5] Capturing baseline (5 seconds)..."
sleep 5

# ---------------------------------------------------------------
# Step 4: Launch PacketRusher registration flood
# ---------------------------------------------------------------
echo ""
echo "[4/5] Launching PacketRusher: $NUM_UES UEs, ${REG_INTERVAL_MS}ms interval..."

PCAP_FILE="$OUTPUT_DIR/registration.pcap"
PR_LOG="$OUTPUT_DIR/packetrusher.log"

# Calculate expected duration: num_ues * interval + buffer
EXPECTED_DURATION=$(( (NUM_UES * REG_INTERVAL_MS / 1000) + 15 ))

# Start tcpdump to capture NGAP signaling
tcpdump -i any sctp -w "$PCAP_FILE" > /dev/null 2>&1 &
TCPDUMP_PID=$!

# Run PacketRusher
$PACKETRUSHER --config "$PR_CONFIG" multi-ue \
    -n "$NUM_UES" \
    --tr "$REG_INTERVAL_MS" \
    --td 30000 \
    > "$PR_LOG" 2>&1 &
PR_PID=$!

echo "  PacketRusher PID: $PR_PID"
echo "  Expected duration: ~${EXPECTED_DURATION}s"

# Wait for all UEs to deregister (monitor log), then kill PacketRusher
WAIT_COUNT=0
MAX_WAIT=$((EXPECTED_DURATION + 60))
while kill -0 $PR_PID 2>/dev/null; do
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))

    # Check how many UEs have completed
    TERMINATED=$(grep -c "UE Terminated" "$PR_LOG" 2>/dev/null || echo 0)
    REGISTERED=$(grep -c "Receive Registration Accept" "$PR_LOG" 2>/dev/null || echo 0)

    if [ "$TERMINATED" -ge "$NUM_UES" ] 2>/dev/null; then
        echo "  All $NUM_UES UEs deregistered. Stopping PacketRusher."
        sleep 2
        kill $PR_PID 2>/dev/null
        sleep 1
        kill -9 $PR_PID 2>/dev/null
        break
    fi

    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "  TIMEOUT: Killing PacketRusher after ${MAX_WAIT}s (Registered: $REGISTERED, Terminated: $TERMINATED)"
        kill $PR_PID 2>/dev/null
        sleep 2
        kill -9 $PR_PID 2>/dev/null
        break
    fi

    if [ $((WAIT_COUNT % 10)) -eq 0 ]; then
        echo "  Progress: ${WAIT_COUNT}s | Registered: $REGISTERED/$NUM_UES | Terminated: $TERMINATED/$NUM_UES"
    fi
done

wait $PR_PID 2>/dev/null
echo "  PacketRusher finished"

# ---------------------------------------------------------------
# Step 5: Recovery capture (10 seconds) and cleanup
# ---------------------------------------------------------------
echo ""
echo "[5/5] Capturing recovery (10 seconds)..."
sleep 10

# Stop all metrics collectors
for MPID in "${METRICS_PIDS[@]}"; do
    kill $MPID 2>/dev/null
done

# Stop tcpdump
kill -INT $TCPDUMP_PID 2>/dev/null
sleep 1

# ---------------------------------------------------------------
# Generate summary
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Generating Summary..."
echo "================================================================"

SUMMARY_FILE="$OUTPUT_DIR/summary.txt"

{
    echo "Control Plane Stress Test Summary"
    echo "================================="
    echo "Timestamp:   $TIMESTAMP"
    echo "Label:       $TEST_LABEL"
    echo "UEs:         $NUM_UES"
    echo "Reg Interval: ${REG_INTERVAL_MS}ms"
    echo ""

    for NF in "${!NF_PIDS[@]}"; do
        CSV="$OUTPUT_DIR/metrics_${NF}.csv"
        if [ -f "$CSV" ]; then
            SAMPLES=$(awk -F',' 'NR>1 {count++} END{print count+0}' "$CSV")
            AVG_CPU=$(awk -F',' 'NR>1 {sum+=$6; n++} END{if(n>0) printf "%.3f", sum/n; else print 0}' "$CSV")
            MAX_CPU=$(awk -F',' 'NR>1 {if($6+0 > max) max=$6+0} END{printf "%.3f", max}' "$CSV")
            AVG_MEM=$(awk -F',' 'NR>1 {sum+=$7; n++} END{if(n>0) printf "%.1f", sum/n/1048576; else print 0}' "$CSV")

            echo "--- $NF (${NF_PODS[$NF]}) ---"
            echo "  Samples:  $SAMPLES"
            echo "  Avg CPU:  ${AVG_CPU}%"
            echo "  Peak CPU: ${MAX_CPU}%"
            echo "  Avg Mem:  ${AVG_MEM} MiB"
            echo ""
        fi
    done

    # Extract registration stats from PacketRusher log
    echo "--- Registration Stats ---"
    REG_COUNT=$(grep -c "Receive Registration Accept" "$PR_LOG" 2>/dev/null || echo 0)
    AUTH_COUNT=$(grep -c "Receive Authentication Request" "$PR_LOG" 2>/dev/null || echo 0)
    PDU_COUNT=$(grep -c "PDU Session Establishment Accept" "$PR_LOG" 2>/dev/null || echo 0)
    DEREG_COUNT=$(grep -c "UE Terminated" "$PR_LOG" 2>/dev/null || echo 0)
    FAIL_COUNT=$(grep -c "Registration Reject\|SCTP dial failed\|fatal" "$PR_LOG" 2>/dev/null || echo 0)

    echo "  Registrations Accepted: $REG_COUNT / $NUM_UES"
    echo "  Authentications: $AUTH_COUNT"
    echo "  PDU Sessions: $PDU_COUNT"
    echo "  Deregistrations: $DEREG_COUNT"
    echo "  Failures: $FAIL_COUNT"

} | tee "$SUMMARY_FILE"

# Extract per-UE registration timestamps from PacketRusher log
echo ""
echo "--- Registration Timing (from logs) ---"
REG_TIMING="$OUTPUT_DIR/registration_timing.csv"
echo "ue_msin,reg_request_time,reg_accept_time,latency_ms" > "$REG_TIMING"

# Parse registration request and accept timestamps
grep "TESTING REGISTRATION USING IMSI" "$PR_LOG" | while read LINE; do
    MSIN=$(echo "$LINE" | grep -o 'IMSI [0-9]*' | awk '{print $2}')
    REQ_TIME=$(echo "$LINE" | grep -o '[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' | head -1)

    # Find corresponding Registration Accept
    ACCEPT_LINE=$(grep -A50 "IMSI $MSIN" "$PR_LOG" | grep "Receive Registration Accept" | head -1)
    if [ -n "$ACCEPT_LINE" ]; then
        ACCEPT_TIME=$(echo "$ACCEPT_LINE" | grep -o '[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' | head -1)

        # Calculate latency (seconds resolution from logs, need PCAP for ms)
        REQ_EPOCH=$(date -d "2026-03-01 $REQ_TIME" +%s 2>/dev/null || echo 0)
        ACCEPT_EPOCH=$(date -d "2026-03-01 $ACCEPT_TIME" +%s 2>/dev/null || echo 0)
        LATENCY_S=$((ACCEPT_EPOCH - REQ_EPOCH))
        LATENCY_MS=$((LATENCY_S * 1000))

        echo "$MSIN,$REQ_TIME,$ACCEPT_TIME,$LATENCY_MS" >> "$REG_TIMING"
    fi
done

echo ""
echo "================================================================"
echo "  Test Complete!"
echo "  Output:   $OUTPUT_DIR"
echo "  Summary:  $SUMMARY_FILE"
echo "  Timing:   $REG_TIMING"
echo "  PCAP:     $PCAP_FILE"
echo "  PR Log:   $PR_LOG"
echo "  Metrics:  $OUTPUT_DIR/metrics_*.csv"
echo "================================================================"
