#!/bin/sh
# First-run bootstrap for a self-hosted mesh: mint the operator -> account ->
# user chain and write a server config.
#
# Runs inside nats-box, which ships nsc, so the bundle needs no tooling on the
# host and nothing from the AgentMesh repository. `agentmesh init` does the same
# thing on a workstation; this exists because that CLI is not published, and a
# deployment recipe should not depend on a tool the reader cannot get.
#
# Idempotent: if the config is already there, this exits without touching
# anything. Deleting the volume is what starts over, and starting over means new
# keys and therefore new credentials for every agent.
#
# The consequence of that short-circuit, for anything ADDED to this script
# later: an existing deployment never runs the new lines. `bridge.creds` below
# is the current example — a mesh bootstrapped before it was added has no such
# file, and the bridge container will crash-loop on the missing path until the
# credential is minted by hand. The README's "Upgrading an existing deployment"
# section has the one command that does it.
set -eu

DATA=/data
NAME="${MESH_NAME:-agentmesh}"
WS_PORT="${MESH_WS_PORT:-4443}"
ACCT=agents
POOL_SIZE="${SANDBOX_POOL_SIZE:-5}"

if [ -f "$DATA/nats.conf" ]; then
  echo "[bootstrap] $DATA/nats.conf exists; nothing to do"
  exit 0
fi

echo "[bootstrap] minting a new operator. These keys ARE this mesh's identity."
mkdir -p "$DATA/creds/pool" "$DATA/.nsc"
N="nsc -H $DATA/.nsc"

$N add operator -n "$NAME" --sys >/dev/null
$N add account -n "$ACCT" >/dev/null
# Unlimited JetStream for the account: the server's own limits are the real cap.
$N edit account -n "$ACCT" \
  --js-mem-storage -1 --js-disk-storage -1 --js-streams -1 --js-consumer -1 >/dev/null

# The services' own credential.
$N add user -a "$ACCT" -n services >/dev/null
$N generate creds -a "$ACCT" -n services > "$DATA/creds/services.creds"

# One credential for a first agent, so there is something to connect with.
$N add user -a "$ACCT" -n node-1 >/dev/null
$N generate creds -a "$ACCT" -n node-1 > "$DATA/creds/node-1.creds"

# The A2A bridge's own credential. The bridge is a mesh NODE, not an agent: it
# holds one credential and vouches for every external A2A party it bridges, in
# both directions. Its own credential rather than the services' one, so that
# what the bridge did is distinguishable from what the platform did, and so that
# revoking the bridge does not take the mesh down with it.
$N add user -a "$ACCT" -n bridge >/dev/null
$N generate creds -a "$ACCT" -n bridge > "$DATA/creds/bridge.creds"

# Sandbox pool: the api service hands these out to guests. Without a pool it
# still runs and reports zero available, which is a working mesh with guest
# access switched off.
i=1
while [ "$i" -le "$POOL_SIZE" ]; do
  $N add user -a "$ACCT" -n "guest-$i" >/dev/null
  $N generate creds -a "$ACCT" -n "guest-$i" > "$DATA/creds/pool/guest-$i.creds"
  i=$((i + 1))
done
echo "[bootstrap] sandbox pool: $POOL_SIZE credentials"

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

# The services run as an unprivileged user in their own container and have to be
# able to read these. Dev-bundle permissions; a real deployment should hand them
# in as secrets instead.
chmod -R a+rX "$DATA/creds" "$DATA/accounts.conf" "$DATA/nats.conf"

echo "[bootstrap] done. Operator keys are in the mesh-data volume under .nsc"
echo "[bootstrap] BACK THAT UP: losing it means you cannot mint credentials again."
