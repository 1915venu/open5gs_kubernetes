#!/bin/bash
# ============================================================
# Registration Latency Measurement
# Measures actual per-UE registration time with ms precision
# Compares baseline (idle) vs loaded (background UE churn)
#
# Usage: sudo ./measure_reg_latency.sh [background_ues] [measurement_count]
# Example: sudo ./measure_reg_latency.sh 100 10
# ============================================================

export PATH=/home/venu/.local/go/bin:$PATH
PACKETRUSHER="/home/venu/PacketRusher/packetrusher"
BASE_CONFIG="/home/venu/PacketRusher/config/config.yml"

BG_UES="${1:-0}"
MEASURE_COUNT="${2:-10}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/home/venu/reg_latency_${TIMESTAMP}_bg${BG_UES}"
mkdir -p "$OUTPUT_DIR"

echo "================================================================"
echo "  Registration Latency Measurement"
echo "  Background UEs:    $BG_UES"
echo "  Measurements:      $MEASURE_COUNT"
echo "  Output:            $OUTPUT_DIR"
echo "================================================================"

# Helper: generate a config file with specific gNB port and MSIN
generate_config() {
    local OUT_FILE="$1"
    local GNB_PORT="$2"
    local MSIN="$3"
    cat > "$OUT_FILE" <<EOF
gnodeb:
  controlif:
    ip: "10.0.0.49"
    port: ${GNB_PORT}
  dataif:
    ip: "10.0.0.49"
    port: 2152
  plmnlist:
    mcc: "999"
    mnc: "70"
    tac: "000001"
    gnbid: "000002"
  slicesupportlist:
    sst: "01"
    sd: "ffffff"
ue:
  hplmn:
    mcc: "999"
    mnc: "70"
  msin: "${MSIN}"
  routingindicator: "0000"
  protectionScheme: 0
  homeNetworkPublicKey: "5a8d38864820197c3394b92613b20b91633cbd897119273bf8e4a6f4eec0a650"
  homeNetworkPublicKeyID: 1
  key: "465B5CE8B199B49FAA5F0A2EE238A6BC"
  opc: "E8ED289DEBA952E4283B54E88E6183CA"
  amf: "8000"
  sqn: "00000000"
  dnn: "internet"
  snssai:
    sst: "01"
    sd: "ffffff"
  integrity:
    nia0: false
    nia1: true
    nia2: true
    nia3: false
  ciphering:
    nea0: true
    nea1: true
    nea2: true
    nea3: false
amfif:
  - ip: "10.0.0.151"
    port: 38412
logs:
  level: 4
EOF
}

# CSV for results
RESULTS="$OUTPUT_DIR/latency_results.csv"
echo "measurement,background_ues,start_epoch_ms,end_epoch_ms,latency_ms,status" > "$RESULTS"

# ---------------------------------------------------------------
# Step 1: Start background load (if requested)
# ---------------------------------------------------------------
BG_PID=""
if [ "$BG_UES" -gt 0 ]; then
    echo ""
    echo "[1/3] Starting $BG_UES background UEs in registration loop..."

    BG_CONFIG="$OUTPUT_DIR/bg_config.yml"
    generate_config "$BG_CONFIG" 9600 "0000000200"

    $PACKETRUSHER --config "$BG_CONFIG" multi-ue \
        -n "$BG_UES" \
        --tr 50 \
        --td 2000 \
        --loop \
        --tbrr 200 \
        > "$OUTPUT_DIR/background.log" 2>&1 &
    BG_PID=$!

    echo "  Background PID: $BG_PID"
    echo "  Waiting 10s for load to stabilize..."
    sleep 10

    if ! kill -0 $BG_PID 2>/dev/null; then
        echo "  WARNING: Background load died!"
        tail -10 "$OUTPUT_DIR/background.log"
    else
        BG_REGS=$(grep -c "Receive Registration Accept" "$OUTPUT_DIR/background.log" 2>/dev/null || echo 0)
        echo "  Background active ($BG_REGS registrations so far)"
    fi
else
    echo ""
    echo "[1/3] No background load (baseline measurement)"
fi

# ---------------------------------------------------------------
# Step 2: Measure individual registrations
# ---------------------------------------------------------------
echo ""
echo "[2/3] Measuring $MEASURE_COUNT individual registrations..."
echo ""
printf "  %-4s %12s  %s\n" "#" "Latency" "Status"
printf "  %-4s %12s  %s\n" "----" "------------" "------"

TOTAL_LATENCY=0
SUCCESS_COUNT=0
MAX_LATENCY=0
MIN_LATENCY=999999

for i in $(seq 1 $MEASURE_COUNT); do
    MSIN=$(printf '%010d' $((99 + i)))
    GNB_PORT=$((9700 + i))

    MEAS_CONFIG="$OUTPUT_DIR/meas_${i}.yml"
    generate_config "$MEAS_CONFIG" "$GNB_PORT" "$MSIN"

    MEAS_LOG="$OUTPUT_DIR/meas_${i}.log"

    START_MS=$(date +%s%3N)

    # Start PacketRusher in background
    $PACKETRUSHER --config "$MEAS_CONFIG" multi-ue \
        -n 1 \
        --td 1000 \
        > "$MEAS_LOG" 2>&1 &
    PR_PID=$!

    # Poll log for Registration Accept (check every 50ms, max 15s)
    STATUS="TIMEOUT"
    LATENCY=15000
    for tick in $(seq 1 300); do
        if grep -q "Receive Registration Accept" "$MEAS_LOG" 2>/dev/null; then
            END_MS=$(date +%s%3N)
            LATENCY=$((END_MS - START_MS))
            STATUS="OK"
            break
        fi
        if ! kill -0 $PR_PID 2>/dev/null; then
            END_MS=$(date +%s%3N)
            LATENCY=$((END_MS - START_MS))
            STATUS="FAIL"
            break
        fi
        sleep 0.05
    done

    # Kill PacketRusher
    kill $PR_PID 2>/dev/null
    sleep 0.5
    kill -9 $PR_PID 2>/dev/null
    wait $PR_PID 2>/dev/null

    if [ "$STATUS" = "OK" ]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        TOTAL_LATENCY=$((TOTAL_LATENCY + LATENCY))
        [ $LATENCY -gt $MAX_LATENCY ] && MAX_LATENCY=$LATENCY
        [ $LATENCY -lt $MIN_LATENCY ] && MIN_LATENCY=$LATENCY
    fi

    printf "  %-4d %8d ms  %s\n" "$i" "$LATENCY" "$STATUS"
    echo "$i,$BG_UES,$START_MS,$((START_MS + LATENCY)),$LATENCY,$STATUS" >> "$RESULTS"

    # Wait for SCTP socket cleanup
    sleep 2
done

# ---------------------------------------------------------------
# Step 3: Cleanup and summary
# ---------------------------------------------------------------
echo ""
echo "[3/3] Cleanup..."

if [ -n "$BG_PID" ]; then
    kill $BG_PID 2>/dev/null
    sleep 2
    kill -9 $BG_PID 2>/dev/null
    BG_REGS=$(grep -c "Receive Registration Accept" "$OUTPUT_DIR/background.log" 2>/dev/null || echo 0)
    echo "  Background stopped ($BG_REGS total registrations)"
fi

if [ $SUCCESS_COUNT -gt 0 ]; then
    AVG_LATENCY=$((TOTAL_LATENCY / SUCCESS_COUNT))
else
    AVG_LATENCY=0; MIN_LATENCY=0
fi

echo ""
echo "================================================================"
echo "  Results: bg=$BG_UES"
echo "  Successful:  $SUCCESS_COUNT / $MEASURE_COUNT"
echo "  Min Latency: ${MIN_LATENCY}ms"
echo "  Avg Latency: ${AVG_LATENCY}ms"  
echo "  Max Latency: ${MAX_LATENCY}ms"
echo "  CSV:         $RESULTS"
echo "================================================================"
