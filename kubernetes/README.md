# A mesh on Kubernetes

The credentials come from outside the cluster. Generate the operator chain on a
workstation with `nsc`, mint the user credentials with the platform's own mint
(the services image, run locally), then load only the derived credentials as
Secrets. The operator and account signing keys never enter Kubernetes, because
whatever holds the root of trust has to be something you can lose the cluster
without losing.

User credentials are deliberately NOT minted with `nsc add user`: with no
permission flags that is an unrestricted credential (an empty permissions block
inherits the account's defaults), and the guest pool goes to strangers. The
mint below uses the same least-privilege templates the hosted platform mints
from, and refuses to sign a pool credential that is not narrow.

```
mkdir -p creds/pool
nsc -H ./.nsc add operator -n mymesh --sys
nsc -H ./.nsc add account -n agents
nsc -H ./.nsc edit account -n agents \
  --js-mem-storage -1 --js-disk-storage -1 --js-streams -1 --js-consumer -1
nsc -H ./.nsc generate config --mem-resolver --config-file accounts.conf --force

# Hand the account signing seed to the mint. It stays in this directory, on
# this workstation — nothing below loads it into the cluster.
ACCT=$(nsc -H ./.nsc describe account -n agents --field sub | tr -d '"')
cp "$(find ./.nsc -name "$ACCT.nk")" creds/mint-signing.nk

# services, node-1, bridge, and a pool of 3, minted from the templates.
docker run --rm -e SANDBOX_POOL_SIZE=3 -v "$PWD/creds":/data/creds \
  ghcr.io/jeffrschneider/agentmesh-services:<version> mint-bootstrap
```

`<version>` is the version `mesh.yaml` pins. The mint is idempotent per file:
run it again after raising the pool size and it mints only the missing ones.

Then:

```
kubectl create namespace agentmesh
kubectl -n agentmesh create secret generic mesh-config    --from-file=accounts.conf=./accounts.conf
kubectl -n agentmesh create secret generic services-creds --from-file=services.creds=./creds/services.creds
kubectl -n agentmesh create secret generic sandbox-pool   --from-file=./creds/pool/
kubectl -n agentmesh create secret generic bridge-creds   --from-file=bridge.creds=./creds/bridge.creds
kubectl -n agentmesh create secret generic bridge-api-keys --from-literal=api-keys="$(openssl rand -hex 24)=validation"
kubectl -n agentmesh apply -f mesh.yaml
kubectl -n agentmesh logs deploy/services | grep -A6 "OPERATOR CONSOLE LOGIN"
```

Note what was NOT loaded: `creds/mint-signing.nk` stays on the workstation.
The consequence is deliberate and worth knowing — an in-cluster mesh cannot
sign new credentials, so the console's agent-key flow (`/v1/bootstrap`) and
guest-pool rotation do not run here; minting more credentials means running
the mint on the workstation again and updating the Secrets. That is the
root-of-trust trade this page opens with, chosen in favour of the key.

The last two are the A2A bridge's, and both are marked optional in the manifest
so that a missing one leaves a diagnosable pod rather than a stuck one. Without
`bridge-creds` the bridge cannot reach the mesh; without `bridge-api-keys` it
reaches the mesh and refuses every inbound A2A call with 401, which is its
shipped default and says so in its own log. Read the key back out when you need
it:

```
kubectl -n agentmesh get secret bridge-api-keys -o jsonpath='{.data.api-keys}' | base64 -d
```

To look at it without an ingress:

```
kubectl -n agentmesh port-forward svc/console 8080:8080 &
kubectl -n agentmesh port-forward svc/services 3001:3001 &
kubectl -n agentmesh port-forward svc/nats-client 4443:4443 &
kubectl -n agentmesh port-forward svc/bridge 8090:8090 &
```

## The A2A bridge and the eval agent

Two more Deployments at the bottom of the manifest, both optional and neither
depended on by anything else: delete them and the mesh is unaffected.

**All four AgentMesh images are built by one release workflow and published
together on ghcr at the version this manifest pins.** To build one yourself
instead, the build context is the AgentMesh repository **root** — `docker build
-f eval-agent/Dockerfile -t <your-registry>/agentmesh-eval-agent:<version> .`
and the same shape for `bridge-a2a/Dockerfile` — push to a registry the cluster
can pull from, and change the `image:` lines.

**A package's first publish lands private, and a private package is
indistinguishable from a missing one.** A GitHub container registry package
stays private until someone makes it public once, by hand, in that package's
settings; until then an anonymous pull fails with a denied error and the pod
sits in `ImagePullBackOff` looking exactly like a tag that was never published.
Whoever cuts a release that adds a NEW image flips that package to public
afterwards. If you deliberately keep a package private, the cluster needs an
`imagePullSecret` on the pod spec, which this manifest does not set.

Three things about this pair that are specific to Kubernetes:

**`TRUSTED_PROXIES` behind an ingress must be the ingress pod CIDR, never
`loopback`.** The bridge believes `X-Forwarded-For` only from addresses on that
list, and the peer it sees is the ingress controller's *pod*, which is never
127.0.0.1 from inside the bridge's container. Leave it empty or set it to
`loopback` and the header is ignored for every request, so every caller on the
internet is identified as the ingress pod: one mesh identity and one shared rate
bucket for all of them. Nothing logs that this happened; it looks exactly like a
working bridge with one very busy client.

**Attachment happens once, at startup, and nothing retries it.** Kubernetes has
no `depends_on`, so a bridge scheduled before the eval agent or before the
services tier logs `failed to attach` and then runs indefinitely without the
eval agent on the mesh, passing its own readiness probe the whole time. The fix
is `kubectl -n agentmesh rollout restart deploy/bridge`, and the symptom is the
eval agent missing from discovery while both pods read as Ready.

**The bridge is pinned at one replica.** Each replica is its own mesh node and
runs `ATTACH` independently, so two replicas register two copies of the eval
agent under two different ids, and discovery returns two agents where there is
one service. The eval agent itself scales freely; note only that its rate limiter
is per-pod, so N replicas serve N times the cap.

And two that are not specific to Kubernetes but will bite here first, because
this manifest already sets two variables to `""` and makes that look like the
house style:

**An empty string is a value, not an absence.** The bridge reads `MESH_URL`,
`PORT` and `PUBLIC_BASE_URL` with `??`, so `value: ""` on any of those three
replaces the code default rather than leaving it in place. `PORT: ""` becomes
`Number("") = 0`, and the bridge binds whatever port the kernel hands out while
the Service and the readiness probe both point at 8090 — a pod that never goes
ready, for a reason nothing logs. The manifest gives all three real values;
`ALLOW_ANONYMOUS` and `TRUSTED_PROXIES` are the ones that may safely be empty,
because every variable other than those three is read with a truthy test.

**`tsx` is a runtime dependency of the bridge image.** The bridge is not
compiled — it runs `node --import tsx src/main.ts`, because it imports the SDK
by relative source path — yet `tsx` is declared in `devDependencies`. If you
adapt `bridge-a2a/Dockerfile`, an `npm ci --omit=dev` on its own gives you an
image that builds green and then exits on its first line with `Cannot find
package 'tsx'`, which in a cluster reads as an unexplained `CrashLoopBackOff`.

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

**That run predates the `bridge` and `eval-agent` Deployments and does not cover
them.** Both images now exist and have been run as containers — the eval agent
answers a real A2A call with the exact value the verification step expects, and
the bridge binds its port and reports `ready:false` from `/healthz` before its
mesh connection is up, which is what proves `tsx` and the SDK source resolved
inside the image — and the release workflow repeats both checks on every build.
The bridge's attach path has separately been shown to accept the eval agent's
card and forward a real call over HTTP. What has never happened is either object
applied to a cluster, or the bridge's mesh leg carrying a request. Treat the A2A
objects as unverified on Kubernetes.
