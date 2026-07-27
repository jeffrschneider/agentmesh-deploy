# A mesh on one host, with Docker Compose

```
docker compose up -d
```

That is the whole thing. No `.env` to prepare, nothing to clone, no credentials
to generate by hand. On first run it mints its own operator keys, an account with
JetStream, a credential for the services, one for a first agent, one for the A2A
bridge, and a small pool of sandbox credentials.

One caveat before you run it: the version this bundle pins, `0.2.1`, has not
been released yet, so that command currently fails to pull. [The four
images](#the-four-images) says why, and what to do until it has.

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

Six containers. `bootstrap` runs once and exits; it is the only thing that
touches keys. `nats` is the broker with JetStream. `services` is the platform:
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

**What has not happened yet is the push.** `agentmesh-services` and
`agentmesh-console` are on ghcr at `0.2.0`; the eval agent and the bridge have
never been pushed at all. All four publish at `0.2.1` when a release is cut, and
until that release runs `docker compose up -d` fails to pull at the pinned
version. That is the pin behaving correctly, not a broken bundle.

`0.2.1` rather than `0.2.0` on purpose. The workflow builds all four images from
current `main` at whatever version it is handed, so publishing the two new images
at `0.2.0` would rebuild and re-push `agentmesh-services:0.2.0` and
`agentmesh-console:0.2.0` as well, silently replacing already-published images
with substantially different content. One version would then name two different
builds. A new patch version costs nothing and avoids it.

To run the bundle before that release you have to build the two missing images
yourself, which needs the AgentMesh source — so if you do not have it, waiting
for the release is the path. The build context is the repository **root** in both
cases, never the component directory, because the bridge imports the SDK's source
by relative path and so needs `sdk-typescript/` in the same context:

```
docker build -f eval-agent/Dockerfile \
  -t ghcr.io/jeffrschneider/agentmesh-eval-agent:0.2.1 .
docker build -f bridge-a2a/Dockerfile \
  -t ghcr.io/jeffrschneider/agentmesh-bridge-a2a:0.2.1 .
```

**A package's first publish lands private, and the failure looks identical to
never having published it.** A GitHub container registry package is private
until someone makes it public once, by hand, in that package's settings. An
anonymous `docker pull` of a private package fails with a denied error, which an
operator cannot tell apart from an image that does not exist. Whoever cuts the
first `0.2.1` release has to flip both new packages to public afterwards; it
bites exactly once per package and never again.

The alternative to all of this is to delete the `bridge` and `eval-agent`
services from `docker-compose.yml`. That costs A2A interop and one step of the
verification checklist, and nothing else: no other service depends on either.

## The A2A bridge

`bridge` is a mesh **node**, not an agent: it holds one credential
(`bridge.creds`, minted by the bootstrap) and vouches for the external A2A
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

`bootstrap.sh` exits immediately when `nats.conf` already exists, so a mesh
brought up before a given version never runs anything added to that script
afterwards. The A2A bridge's credential is the current instance: a mesh
bootstrapped before it was added has no `bridge.creds`, and the bridge container
crash-loops on the missing path. Mint it once, by hand, then start the new
services:

```
docker compose run --rm --entrypoint sh bootstrap -c \
  'nsc -H /data/.nsc add user -a agents -n bridge && \
   nsc -H /data/.nsc generate creds -a agents -n bridge > /data/creds/bridge.creds && \
   chmod a+r /data/creds/bridge.creds'
docker compose up -d eval-agent bridge
```

This is not a reason to delete the volume. Deleting it mints a new operator and
invalidates every credential the mesh has ever issued.

## Connecting an agent

The bootstrap minted `node-1.creds` for exactly this. Copy it out of the volume:

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

For more agents, mint more credentials:

```
docker compose run --rm --entrypoint sh bootstrap -c \
  'nsc -H /data/.nsc add user -a agents -n node-2 && \
   nsc -H /data/.nsc generate creds -a agents -n node-2 > /data/creds/node-2.creds'
```

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
