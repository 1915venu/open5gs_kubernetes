#!/bin/bash
# ============================================================
# Bulk Subscriber Provisioning for Open5GS MongoDB
# Inserts N subscribers with sequential IMSIs for PacketRusher
#
# Usage: ./provision_subscribers.sh [count] [start_msin]
# Example: ./provision_subscribers.sh 500 100
#   Creates IMSIs: 999700000000100 to 999700000000599
# ============================================================

COUNT="${1:-500}"
START_MSIN="${2:-100}"

# Open5GS subscriber credentials (same as existing UERANSIM)
KEY="465B5CE8B199B49FAA5F0A2EE238A6BC"
OPC="E8ED289DEBA952E4283B54E88E6183CA"
AMF_VALUE="8000"
MCC="999"
MNC="70"

# MongoDB pod
MONGO_POD=$(kubectl get pods -n open5gs --no-headers | grep mongodb | grep Running | awk '{print $1}')
if [ -z "$MONGO_POD" ]; then
    echo "ERROR: MongoDB pod not found"
    exit 1
fi

echo "=================================================="
echo "  Bulk Subscriber Provisioning"
echo "  Count:      $COUNT"
echo "  IMSI range: ${MCC}${MNC}$(printf '%010d' $START_MSIN) to ${MCC}${MNC}$(printf '%010d' $((START_MSIN + COUNT - 1)))"
echo "  Key:        $KEY"
echo "  OPC:        $OPC"
echo "  MongoDB:    $MONGO_POD"
echo "=================================================="

# Check existing count
EXISTING=$(kubectl exec -n open5gs "$MONGO_POD" -- mongosh open5gs --quiet --eval "db.subscribers.countDocuments()" 2>/dev/null)
echo "Existing subscribers: $EXISTING"
echo ""

# Build bulk insert JavaScript
JS_SCRIPT="var bulk = db.subscribers.initializeUnorderedBulkOp();"

for i in $(seq 0 $((COUNT - 1))); do
    MSIN=$(printf '%010d' $((START_MSIN + i)))
    IMSI="${MCC}${MNC}${MSIN}"

    JS_SCRIPT+="
bulk.insert({
  imsi: '${IMSI}',
  msisdn: [],
  schema_version: 1,
  security: {
    k: '${KEY}',
    op: null,
    opc: '${OPC}',
    amf: '${AMF_VALUE}',
    sqn: NumberLong(0)
  },
  ambr: {
    downlink: { value: 1000000000, unit: 0 },
    uplink: { value: 1000000000, unit: 0 }
  },
  slice: [{
    sst: 1,
    sd: 'ffffff',
    default_indicator: true,
    session: [{
      name: 'internet',
      type: 3,
      qos: {
        index: 9,
        arp: {
          priority_level: 8,
          pre_emption_capability: 1,
          pre_emption_vulnerability: 2
        }
      },
      ambr: {
        downlink: { value: 1000000000, unit: 0 },
        uplink: { value: 1000000000, unit: 0 }
      },
      pcc_rule: []
    }]
  }]
});"
done

JS_SCRIPT+="
var result = bulk.execute();
print('Inserted: ' + result.nInserted);
print('Errors: ' + result.getWriteErrorCount());
"

echo "[*] Inserting $COUNT subscribers..."

# Write JS to temp file and execute
TEMP_JS="/tmp/provision_subscribers.js"
echo "$JS_SCRIPT" > "$TEMP_JS"

kubectl cp "$TEMP_JS" "open5gs/${MONGO_POD}:/tmp/provision_subscribers.js"
kubectl exec -n open5gs "$MONGO_POD" -- mongosh open5gs --quiet --file /tmp/provision_subscribers.js 2>&1

# Verify
NEW_COUNT=$(kubectl exec -n open5gs "$MONGO_POD" -- mongosh open5gs --quiet --eval "db.subscribers.countDocuments()" 2>/dev/null)
echo ""
echo "=================================================="
echo "  Provisioning Complete!"
echo "  Previous count: $EXISTING"
echo "  New count:      $NEW_COUNT"
echo "  Added:          $((NEW_COUNT - EXISTING))"
echo "=================================================="
