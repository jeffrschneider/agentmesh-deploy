# A mesh on Kubernetes

The credentials come from outside the cluster. Generate the operator chain on a
workstation with `nsc`, then load only the derived credentials as Secrets. The
operator signing key never enters Kubernetes, because whatever holds the root of
trust has to be something you can lose the cluster without losing.

```
nsc -H ./.nsc add operator -n mymesh --sys
nsc -H ./.nsc add account -n agents
nsc -H ./.nsc edit account -n agents \
  --js-mem-storage -1 --js-disk-storage -1 --js-streams -1 --js-consumer -1
nsc -H ./.nsc add user -a agents -n services
nsc -H ./.nsc generate creds -a agents -n services > creds/services.creds
nsc -H ./.nsc add user -a agents -n node-1
nsc -H ./.nsc generate creds -a agents -n node-1 > creds/node-1.creds
for i in 1 2 3; do
  nsc -H ./.nsc add user -a agents -n guest-$i
  nsc -H ./.nsc generate creds -a agents -n guest-$i > creds/pool/guest-$i.creds
done
nsc -H ./.nsc generate config --mem-resolver --config-file accounts.conf --force
```

Then:

```
kubectl create namespace agentmesh
kubectl -n agentmesh create secret generic mesh-config    --from-file=accounts.conf=./accounts.conf
kubectl -n agentmesh create secret generic services-creds --from-file=services.creds=./creds/services.creds
kubectl -n agentmesh create secret generic sandbox-pool   --from-file=./creds/pool/
kubectl -n agentmesh apply -f mesh.yaml
kubectl -n agentmesh logs deploy/services | grep -A6 "OPERATOR CONSOLE LOGIN"
```

To look at it without an ingress:

```
kubectl -n agentmesh port-forward svc/console 8080:8080 &
kubectl -n agentmesh port-forward svc/services 3001:3001 &
kubectl -n agentmesh port-forward svc/nats-client 4443:4443 &
```

## Three objects, three scaling rules, and only one of them is elastic

**The console is elastic.** Static files, no state, no subscriptions. Two replicas
here is right and an autoscaler belongs on this Deployment. It is the only place
one does.

**The services are pinned at one replica, and that is a correctness requirement.**
Three separate properties of the current build make a second instance wrong rather
than merely slow. No subscription in the services tier uses a NATS queue group, so
NATS delivers every message to every subscriber and two instances would both do
the work and both reply to a single request. The activity service keeps usage
counters in a SQLite file on its PVC, so two replicas keep two divergent sets, and
fair-use enforcement reads those counters. The console login hash is a separate
local file, so a second instance either has no login or a different one. Leave
`replicas: 1` and do not point an HPA at it.
[`../docs/planning-and-sizing.md`](../docs/planning-and-sizing.md) section 4.3 has
the detail, and section 5.3 covers what that means for a rolling upgrade.

**NATS is ballast.** JetStream is Raft-replicated, so three replicas means quorum
is two, and the replica count is a decision rather than a dial. Never point an
autoscaler at the StatefulSet. Scaling in is a runbook: check no stream is at
minimum replicas, reassign, remove the peer, let the group settle, and only then
reduce the StatefulSet. Shrinking it casually leaves orphaned PVCs and can drop
you below quorum.

Be clear about what three replicas buys, because it is less than it looks.
**Every stream and KV bucket the platform creates is single-replica today**, so
the registry, accounts, tasks, rooms, offline mail and the rest each live on one
of the three servers with no copy on the other two. Connections fail over; data
does not. That is a known gap, and section 4.2 of the planning document states it
in full.

## Five things that will bite, all of which did

These are in the manifest with comments, but they are worth stating plainly
because each one produced a stack that looked broken for a reason that was not
obvious.

**The headless Service needs `publishNotReadyAddresses: true`.** By default it
publishes DNS only for ready pods. The NATS pods cannot become ready until they
have clustered, and cannot cluster until they can resolve each other. Without
this they spin on `no such host` until the liveness probe kills them, forever.

**Liveness must not probe `/healthz`.** While the cluster is forming and
JetStream is recovering, `/healthz` reports unhealthy, so a liveness probe on it
kills the pod mid-formation and the cluster never converges. Liveness uses
`/varz`, which answers as soon as the server is listening. `/healthz` belongs on
readiness, where being unhealthy correctly withholds traffic.

**`include` in a NATS config resolves relative to the config file.** An absolute
path becomes `/etc/nats/etc/...` and fails. Both `nats.conf` and `accounts.conf`
therefore have to land in one directory, which is what the projected volume is
for: a ConfigMap and a Secret presented as a single directory. Note that a
projected source uses `name`, not `secretName`.

**A fresh PersistentVolume mounts root-owned.** That masks the ownership the
image set up, and the non-root user gets EACCES on its first write. `fsGroup:
1000` on the pod fixes it. This is invisible in Docker Compose, where the volume
inherits the image's directory ownership, so it is a genuinely Kubernetes-only
failure.

## Before production

No TLS here. The browser console opens a WebSocket to the mesh, and an https page
may not open a plain `ws://` connection, so the moment the console is served over
TLS the mesh must be `wss://` too. Terminate both at an ingress with
cert-manager, and set the console's `API_URL` and `NATS_WS_URL` to the hostnames
a browser can reach — not in-cluster service names, which mean nothing to a
browser.

If you use nginx-ingress, raise `proxy-read-timeout` and `proxy-send-timeout`.
The default 60 seconds silently kills idle agent connections, they reconnect, and
it looks like flapping infrastructure rather than a timeout.

Accounts live in the config (a memory resolver), so adding one means editing the
Secret and restarting. Fine for a private mesh; wrong for anything adding tenants
continuously, which wants a directory or URL resolver.

## Tearing it down

Deleting the cluster does NOT reclaim the disks. The PersistentVolumes outlive it
as orphaned Compute Engine disks, still billing, and nothing warns you. Delete
the namespace first, which deletes the PVCs and lets the reclaim policy do its
job:

```
kubectl delete namespace agentmesh    # BEFORE deleting the cluster
```

If the cluster is already gone, find and remove them by hand:

```
gcloud compute disks list --filter="name~^pvc-" \n  --format="value(name,zone,sizeGb,users.len(),description)"
```

The description names the PVC and namespace each disk came from, and a users
count of zero means nothing is attached. Four disks totalling 31GB were left
behind by the verification run below, which is how this section came to exist.

## Verified

Applied to a GKE Autopilot cluster on 2026-07-24 and taken end to end: the NATS
StatefulSet formed a three-replica cluster with its own PVCs, the services
connected authenticated and loaded the sandbox pool, a real mesh-adapter 0.32.0
joined over a port-forward and registered, and the operator console was signed
into in a browser and showed the agent, with no requests to any public AgentMesh
endpoint. The four failures above are all things that happened during that run
rather than things anticipated on paper. The cluster was deleted afterwards.
