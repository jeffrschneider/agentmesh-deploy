#!/bin/sh
# First-run bootstrap for a self-hosted mesh: mint the operator -> account
# chain and write a server config. USER credentials are no longer minted here
# — the `mint` service (the services image's `mint-bootstrap` entrypoint)
# mints them from the platform's own least-privilege templates, signed by the
# account key this script leaves on the volume. This script's job ends at the
# account boundary on purpose: `nsc add user` with no permission flags mints
# an UNRESTRICTED credential (an empty permissions block inherits the
# account's defaults), which is exactly the mistake this split removes.
#
# Runs inside nats-box, which ships nsc, so the bundle needs no tooling on the
# host and nothing from the AgentMesh repository.
#
# Idempotent: if the config is already there, only the mint hand-off below
# runs — it is the one part an EXISTING deployment needs on upgrade, because
# a mesh bootstrapped before the mint split has no exported signing key and
# the mint container cannot sign without it. Deleting the volume is what
# starts over, and starting over means new keys and therefore new credentials
# for every agent.
set -eu

DATA=/data
NAME="${MESH_NAME:-agentmesh}"
WS_PORT="${MESH_WS_PORT:-4443}"
ACCT=agents

N="nsc -H $DATA/.nsc"

# ── the mint hand-off ───────────────────────────────────────────────────────
# Export the account's signing seed and public key where the `mint` container
# and the services can reach them: the seed signs user JWTs (the mint, the
# /v1/bootstrap door, pool rotation), the public key is the issuer the
# services advertise. Same volume, same trust boundary as the keystore the
# seed already lives in; a real deployment hands these in as secrets instead,
# exactly like the credentials themselves (see the chmod note below).
#
# Runs on EVERY boot, not only the first — this is the "new lines never run"
# hazard the old header warned about, handled for the one addition that
# upgrades need.
export_mint_material() {
  [ -d "$DATA/.nsc" ] || return 0
  ACCT_PUB=$($N describe account -n "$ACCT" --field sub 2>/dev/null | tr -d '"') || return 0
  [ -n "$ACCT_PUB" ] || return 0
  mkdir -p "$DATA/creds"
  if [ ! -f "$DATA/creds/mint-signing.nk" ]; then
    SEED_FILE=$(find "$DATA/.nsc" -name "$ACCT_PUB.nk" | head -n 1)
    if [ -n "$SEED_FILE" ]; then
      cp "$SEED_FILE" "$DATA/creds/mint-signing.nk"
      echo "[bootstrap] account signing key exported for the mint container"
    else
      echo "[bootstrap] WARNING: account key $ACCT_PUB not in the keystore — the mint container cannot sign"
    fi
  fi
  printf '%s' "$ACCT_PUB" > "$DATA/creds/mint-issuer.txt"
  chmod a+rX "$DATA/creds" 2>/dev/null || true
  chmod a+r "$DATA/creds/mint-signing.nk" "$DATA/creds/mint-issuer.txt" 2>/dev/null || true
}

if [ -f "$DATA/nats.conf" ]; then
  echo "[bootstrap] $DATA/nats.conf exists; checking the mint hand-off only"
  export_mint_material
  exit 0
fi

echo "[bootstrap] minting a new operator. These keys ARE this mesh's identity."
mkdir -p "$DATA/creds" "$DATA/.nsc"

$N add operator -n "$NAME" --sys >/dev/null
$N add account -n "$ACCT" >/dev/null
# Unlimited JetStream for the account: the server's own limits are the real cap.
$N edit account -n "$ACCT" \
  --js-mem-storage -1 --js-disk-storage -1 --js-streams -1 --js-consumer -1 >/dev/null

# Operator + account JWTs for the server, memory resolver: accounts live in the
# config file, so adding one later means editing this and restarting. Fine for a
# single host; a mesh that adds accounts continuously wants a directory resolver.
$N generate config --mem-resolver --config-file "$DATA/accounts.conf" --force >/dev/null

cat > "$DATA/nats.conf" <<EOF
# Generated on first run by deploy/compose/bootstrap.sh. Do not hand-edit:
# delete the volume to regenerate, which also invalidates every credential.
server_name: $NAME

# Set explicitly, not inherited. It is a contract: the API advertises exactly
# this figure to clients as max_message_bytes and refuses request bodies larger
# than it, so a broker that disagreed would either reject what the API accepted
# or accept what the API promised to refuse. And a default is not a decision:
# the server's own default happens to be the same 1 MiB today, and writing it
# down is what stops a version bump from moving it.
max_payload: 1048576

jetstream {
  store_dir: "/jetstream"
  max_mem: 1G
  max_file: 10G
}

websocket {
  port: $WS_PORT
  no_tls: true   # The browser console connects here. See the README on TLS.
}

include "accounts.conf"
EOF

export_mint_material

# The services run as an unprivileged user in their own container and have to be
# able to read these. Dev-bundle permissions; a real deployment should hand them
# in as secrets instead.
chmod -R a+rX "$DATA/creds" "$DATA/accounts.conf" "$DATA/nats.conf"

echo "[bootstrap] done. User credentials are minted next, by the mint service."
echo "[bootstrap] Operator keys are in the mesh-data volume under .nsc"
echo "[bootstrap] BACK THAT UP: losing it means you cannot mint credentials again."
