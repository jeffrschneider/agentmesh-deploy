# A mesh on one host, with Docker Compose

```
docker compose up -d
```

That is the whole thing. No `.env` to prepare, nothing to clone, no credentials
to generate by hand. On first run it mints its own operator keys and an account
with JetStream, then mints the credentials — one for the services, one for a
first agent, one for the A2A bridge, and a small pool of sandbox credentials —
from the platform's own least-privilege templates. The guest pool in particular
is minted narrow and asserted narrow before signing: a sandbox credential
cannot read other agents' mail, touch JetStream, or reach the bucket where
session tokens live.

Then:

```
docker compose logs services | grep -A6 "OPERATOR CONSOLE LOGIN"
```

That prints the console login, once. Open <http://localhost:8080> and sign in.

| | |
|---|---|
| console | <http://localhost:8080> |
| api | <http://localhost:3001> |
| mesh | `nats://localhost:4222`, `ws://localhost:4443` |
| A2A bridge | <http://localhost:8090> |
| A2A eval agent | <http://localhost:8091> |

## What you get

Seven containers. `bootstrap` runs once and exits: operator and account keys,
and the server config. `mint` runs once and exits: every user credential,
minted from the platform's permission templates and signed by the account key
bootstrap exported — it is idempotent per file, so re-running it mints
whatever is missing and touches nothing that exists. `nats` is the broker with
JetStream. `services` is the platform:
registry, task manager, catalog, activity, rooms, admission and the api gateway,
all in one process. `console` is the operator console, the same application as
console.agentmesh.ai, served as static files. `eval-agent` is a stateless A2A
agent that answers with a value you can predict, and `bridge` is the A2A bridge
that puts it on the mesh and lets stock A2A clients call mesh agents.

Auth is on. The services connect with a real credential, and an agent without one
is refused. That is worth saying because it is the opposite of most quickstarts.

## The four images

Four of the six containers run AgentMesh images: `agentmesh-services`,
`agentmesh-console`, `agentmesh-eval-agent` and `agentmesh-bridge-a2a`. (The
other two are stock upstream images, `nats` and `nats-box`.) All four have
Dockerfiles in the AgentMesh repository and are built, smoke-tested and pushed
together by one release workflow, under one version. Nothing here needs building
by hand as a matter of course.

All four are published on ghcr at the pinned version, publicly, so
`docker compose up -d` pulls them anonymously.

If you rebuild any of them from source, the build context is the repository
**root**, never the component directory, because the bridge imports the SDK's
source by relative path and so needs `sdk-typescript/` in the same context:

```
docker build -f eval-agent/Dockerfile \
  -t ghcr.io/jeffrschneider/agentmesh-eval-agent:0.2.2 .
docker build -f bridge-a2a/Dockerfile \
  -t ghcr.io/jeffrschneider/agentmesh-bridge-a2a:0.2.2 .
```

For whoever cuts a release that adds a NEW image: **a package's first publish
lands private, and the failure looks identical to never having published it.**
An anonymous pull of a private ghcr package fails with a denied error, so flip
the new package to public once, by hand, in its package settings. It bites
exactly once per package and never again.

A smaller bundle is also fine: delete the `bridge` and `eval-agent` services
from `docker-compose.yml`. That costs A2A interop and one step of the
verification checklist, and nothing else: no other service depends on either.

## The A2A bridge

`bridge` is a mesh **node**, not an agent: it holds one credential
(`bridge.creds`, minted by the mint service) and vouches for the external A2A
parties it bridges, both directions. Outbound, `ATTACH` puts the eval agent on
the mesh as an ordinary discoverable agent. Inbound, a stock A2A client reaches
mesh agents through `http://localhost:8090/agents/<id>/rpc`.

**It refuses every inbound call until you give it a key.** With no `API_KEYS`
and anonymous access off — the shipped default — it starts, warns that it is
closed, and answers 401 to everything. That is on purpose: a caller it admits
gets a node-vouched mesh identity, so an open bridge is a thing an operator
turns on knowingly. Set one key and restart:

```
echo "BRIDGE_API_KEYS=$(openssl rand -hex 24)=validation" >> .env
docker compose up -d bridge
```

`BRIDGE_ALLOW_ANONYMOUS=1` is the other way, and opens the bridge to anyone who
can reach port 8090. Both are documented in `.env.example`, along with
`BRIDGE_TRUSTED_PROXIES`, which you must set if you put a reverse proxy in
front — without it every caller shares the proxy's identity and rate budget.

Two things about the bridge are easy to trip over if you change anything around
it. **`tsx` is a runtime dependency, not a build-time one.** The bridge is not
compiled: it runs `node --import tsx src/main.ts`, because it imports the SDK by
relative source path rather than as a published package. `tsx` is declared in
`devDependencies` regardless, so an `npm ci --omit=dev` in a Dockerfile you adapt
produces an image that builds green and then dies on its first line with `Cannot
find package 'tsx'`. And **an empty string is a value, not an absence.** The
bridge reads `MESH_URL`, `PORT` and `PUBLIC_BASE_URL` with `??`, so setting any
of those three to `""` replaces the code default rather than falling back to it:
`PORT=""` becomes `Number("") = 0`, and the bridge binds whatever port the kernel
hands out while 8090 is published to nothing. This bundle sets all three to real
values, and writes `PUBLIC_BASE_URL` as `${PUBLIC_BRIDGE_URL:-…}` whose `:-`
covers an empty `.env` entry too, so it is safe as shipped and one edit away from
not being. Every other bridge variable is read with a truthy test, which is why
`BRIDGE_API_KEYS` and `BRIDGE_TRUSTED_PROXIES` can be left blank.

Attachment is attempted once, at bridge startup, and a failure is logged and not
retried. `depends_on` orders the first bring-up correctly; if you restart the
eval agent on its own, restart the bridge after it or the mesh keeps an entry
pointing at an agent that has moved on.

## Upgrading an existing deployment

A missing credential is no longer a hand command: `bootstrap` re-runs on every
`up` and exports the signing material even on an existing mesh, and `mint`
mints whatever credential is missing. So the ordinary upgrade is:

```
docker compose pull
docker compose up -d
```

**One thing an ordinary upgrade cannot do for you: the credentials an older
bundle minted are unrestricted, and they stay valid until you revoke them.**
Every credential minted by a pre-mint-service bootstrap — the guest pool
included — carries no permission block and no expiry, so replacing the files
is not enough; the old JWTs keep working from anywhere they were copied.
Re-mint narrow and revoke the old generation in one sitting:

```
docker compose run --rm --entrypoint sh bootstrap -c '
  N="nsc -H /data/.nsc"
  for u in services node-1 bridge; do
    $N revocations add-user -a agents -n "$u" 2>/dev/null || true
  done
  i=1; while [ $i -le 5 ]; do   # raise 5 to your pool size
    $N revocations add-user -a agents -n "guest-$i" 2>/dev/null || true
    i=$((i+1))
  done
  $N generate config --mem-resolver --config-file /data/accounts.conf --force
  rm -f /data/creds/pool/*.creds /data/creds/node-1.creds \
        /data/creds/bridge.creds /data/creds/services.creds
  sh /bootstrap.sh'
docker compose up -d mint
docker compose restart nats
docker compose up -d
```

Revocation is by user key at the account, so the freshly minted credentials —
new keys — are untouched; the broker reloads the account with the revocation
list when it restarts on the regenerated config. Any `node-1.creds` you copied
out to an agent host must be replaced with the new file, and any credential
minted by hand under a name not listed above needs its own `revocations
add-user` line.

Deleting the volume is still not the way. That mints a new operator and
invalidates every credential the mesh has ever issued.

## Connecting an agent

The mint made `node-1.creds` for exactly this. Copy it out of the volume:

```
docker run --rm -v agentmesh_mesh-data:/d alpine cat /d/creds/node-1.creds > node-1.creds
```

Then point an adapter at the local mesh:

```
MESH_URL=ws://localhost:4443 MESH_CREDS_FILE=./node-1.creds \
  npx https://storage.googleapis.com/agentmesh-releases/mesh-adapter-0.32.0.tgz \
  start --inbox --name my-agent
```

It will register, appear in the console, and be reachable by its key. Naming is
separate: handles still resolve through the public naming service unless you set
`PAN_REGISTRAR`, because the directory is a different system from the message bus
and does not need to be self-hosted to be used.

For more agents, use the console rather than `nsc`: create the agent under
"Your agents", copy the agent key it shows, and run `agentmesh bootstrap
<agent-key>` on the agent's host. That path mints a per-agent credential from
the platform's narrow template — scoped to that agent's own inbox and mailbox
— and it works self-hosted because the mint installed the signing key the
services need to answer it. (A hand-run `nsc add user` with no permission
flags mints an UNRESTRICTED credential; that is the mistake this bundle
stopped making, so do not reintroduce it one credential at a time.)

## The three volumes, in order of how much you would miss them

`mesh-data` holds the operator keys. **Back this up.** Losing it does not just
lose the mesh, it makes every credential you have issued unusable, permanently,
because there is no way to sign new ones that match. Deleting the volume and
starting again gives you a different mesh that happens to have the same name.

`mesh-jetstream` holds streams and KV: the registry, tasks, rooms. Losing it
loses the mesh's memory but not its identity, and agents can re-register.

`mesh-usage` holds per-agent message counters and the console login hash.
Rebuildable; losing it costs history and means the login is generated again.

## Before anyone outside your network uses this

There is no TLS here, and that is not a detail you can defer. The browser console
opens a WebSocket to the mesh, and an https page is not permitted to open a plain
`ws://` connection, so the moment you serve the console over TLS the mesh has to
be `wss://` too. Put a reverse proxy in front of both, then set the addresses the
browser should use:

```
PUBLIC_API_URL=https://api.example.com
PUBLIC_NATS_WS_URL=wss://mesh.example.com
```

Those are resolved by the browser, not inside the compose network, which is why
they are hostnames and not service names. `nats` and `services` mean nothing to
a browser.

Two more things a real deployment should change. The credentials are readable by
the containers that need them through a shared volume, which is convenient and
not how secrets should be handled beyond one host; hand them in as secrets
instead. And accounts live in the config file (a memory resolver), so adding one
means editing and restarting. Fine for a private mesh, wrong for anything adding
tenants continuously, which wants a directory resolver.

## Scaling, briefly

Not much, on one host, and less than you might assume. **Do not run a second
`services` container.** No subscription in the services tier uses a NATS queue
group, so NATS delivers every message to every subscriber: two instances would
both do the work and both reply to a single request. On top of that, the activity
service keeps usage counters in a local SQLite file and the console login hash is
a separate local file, so both diverge per instance. One is the only supported
count.

`console` is different. It is static files with no state and no subscriptions, so
it scales freely.

Beyond one host, this composition is the same shape as the Kubernetes deployment:
a broker you can cluster, a services tier pinned at one, and a console you can
scale. What clustering the broker does and does not buy, and how to size any of
it, is in [`../docs/planning-and-sizing.md`](../docs/planning-and-sizing.md).

## Verified

This bundle was brought up from empty on 2026-07-24 and checked end to end: the
bootstrap minted its chain, the services connected authenticated, a real
mesh-adapter joined and registered, and the console was signed into in a browser
and showed the agent, with no requests to any public AgentMesh endpoint.

**That run predates the `bridge` and `eval-agent` services and does not cover
them**, so the composition as it stands has not been brought up whole. Both
images now exist and have been built and run as containers: the eval agent
answers a real A2A call with the exact value the verification step expects, and
the bridge starts, binds 8090 and reports `ready:false` from `/healthz` before
its mesh connection is up — which is what proves `tsx` and the SDK source
resolved inside the image. The release workflow runs both of those checks on
every build. What has still not been done: the two of them together, in
containers, on a mesh, with the bridge holding a credential and its mesh leg
carrying the request. Treat that last leg as unverified until someone repeats
the run above with all six containers.
