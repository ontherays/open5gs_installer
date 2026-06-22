#!/bin/bash
# =============================================================================
#  add-subscribers.sh - provision SIM/UE profiles in the Open5GS MongoDB.
#
#  This replaces the old hand-maintained db.subscribers.insertMany([...]) blob.
#  Instead of editing BSON by hand, you give it a starting IMSI and a count and
#  it generates the consecutive profiles for you, all sharing the Ki/OPc/AMF and
#  slice defaults from open5gs.env.
#
#  Usage:
#    ./add-subscribers.sh seed                 # add SUB_COUNT IMSIs from SUB_IMSI_BASE
#    ./add-subscribers.sh range <base> <count> # add <count> IMSIs from <base>
#    ./add-subscribers.sh add <imsi>           # add a single IMSI
#    ./add-subscribers.sh list                 # list provisioned IMSIs
#    ./add-subscribers.sh remove <imsi>        # delete one IMSI
#    ./add-subscribers.sh reset                # delete ALL subscribers (asks first)
#
#  Adds are idempotent: an IMSI that already exists is left untouched, so you can
#  re-run safely. Subscribers take effect immediately - no daemon restart needed.
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

command -v mongosh >/dev/null 2>&1 || die "mongosh not found - install MongoDB first (./install.sh)."

DB_URI="mongodb://localhost/open5gs"

# Insert `count` consecutive subscribers starting at `base`, skipping any IMSI
# that already exists. All the per-subscriber values come from open5gs.env.
seed_range() {
  local base="$1" count="$2"
  [[ "$base"  =~ ^[0-9]+$ ]] || die "IMSI base must be numeric: $base"
  [[ "$count" =~ ^[0-9]+$ ]] || die "count must be numeric: $count"
  info "Provisioning $count subscriber(s) from IMSI $base (slice sst=$SST, dnn=$DNN)"

  mongosh --quiet "$DB_URI" <<JS
const base  = "$base";
const count = $count;
const sst   = $SST;
const dnn   = "$DNN";
const type  = $SUB_PDU_TYPE;          // 1=IPv4 2=IPv6 3=IPv4v6
const k     = "$SIM_K";
const opc   = "$SIM_OPC";
const amf   = "$SIM_AMF";

// 1 Gbps up/down expressed in the {value, unit} form Open5GS expects (unit 3 = Gbps).
const gbps1 = { value: 1, unit: 3 };

let added = 0, skipped = 0;
for (let i = 0; i < count; i++) {
  // BigInt keeps long IMSIs exact; padStart restores any leading zeros.
  const imsi = (BigInt(base) + BigInt(i)).toString().padStart(base.length, "0");

  // The IMSI lives in the filter, so it is omitted from the document below and
  // added automatically on insert. \$setOnInsert means existing rows are kept.
  const profile = {
    schema_version: 1,
    msisdn: [], imeisv: [], mme_host: [], mme_realm: [], purge_flag: [],
    subscribed_rau_tau_timer: 12,
    network_access_mode: 0,
    subscriber_status: 0,
    operator_determined_barring: 0,
    access_restriction_data: 32,
    ambr: { downlink: gbps1, uplink: gbps1 },
    slice: [{
      sst: sst,
      default_indicator: true,
      session: [{
        name: dnn,
        type: type,
        qos: { index: 9, arp: { priority_level: 8,
                                pre_emption_capability: 1,
                                pre_emption_vulnerability: 1 } },
        ambr: { downlink: gbps1, uplink: gbps1 },
        pcc_rule: []
      }]
    }],
    security: { k: k, amf: amf, op: null, opc: opc },
    __v: 0
  };

  const res = db.subscribers.updateOne(
    { imsi: imsi },
    { \$setOnInsert: profile },
    { upsert: true }
  );
  if (res.upsertedCount > 0) { added++; } else { skipped++; }
}
print(\`done: \${added} added, \${skipped} already present.\`);
JS
}

cmd="${1:-seed}"
case "$cmd" in
  seed)
    seed_range "$SUB_IMSI_BASE" "$SUB_COUNT"
    ;;
  range)
    [ $# -eq 3 ] || die "usage: $0 range <base-imsi> <count>"
    seed_range "$2" "$3"
    ;;
  add)
    [ $# -eq 2 ] || die "usage: $0 add <imsi>"
    seed_range "$2" 1
    ;;
  list)
    mongosh --quiet "$DB_URI" --eval \
      'db.subscribers.find({}, {imsi:1, _id:0}).sort({imsi:1}).forEach(d => print(d.imsi))'
    ;;
  remove)
    [ $# -eq 2 ] || die "usage: $0 remove <imsi>"
    mongosh --quiet "$DB_URI" --eval "print('removed ' + db.subscribers.deleteOne({imsi:'$2'}).deletedCount + ' subscriber(s)')"
    ;;
  reset)
    read -rp "Delete ALL subscribers from the database? [y/N] " ans
    [ "${ans:-N}" = "y" ] || { info "aborted."; exit 0; }
    mongosh --quiet "$DB_URI" --eval "print('deleted ' + db.subscribers.deleteMany({}).deletedCount + ' subscriber(s)')"
    ;;
  *)
    die "unknown command '$cmd' (try: seed | range | add | list | remove | reset)"
    ;;
esac
