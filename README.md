# Run your own AgentMesh

Everything you need to stand up a mesh you control. No source required: these
deploy published container images.

```
git clone https://github.com/jeffrschneider/agentmesh-deploy
cd agentmesh-deploy/compose && docker compose up -d
```

That gives you a broker with JetStream, the platform services, the operator
console, and its own operator keys, on one host, with auth switched on. Read
[compose/README.md](compose/README.md) next.

## Which path

**[compose/](compose/)** — one host, one command. The right choice for evaluating
this, for a private mesh behind a firewall, and for a branch office. Mints its own
credentials on first run, so there is nothing to prepare.

**[kubernetes/](kubernetes/)** — a cluster you already run. A StatefulSet for
JetStream with a volume per replica, Deployments for the services and console, and
the scaling rules that matter written down: the console is elastic, the services
tier is pinned at one replica for reasons of correctness rather than cost, and an
autoscaler must never see the JetStream StatefulSet.

Both were run end to end before being published, rather than written and reasoned
about. Compose was brought up from empty and driven with a real agent and a real
browser; the Kubernetes manifests were applied to a GKE Autopilot cluster and
taken through the same check. The gotchas each README lists are things that
actually happened during those runs.

## Before you commit to a shape

[docs/planning-and-sizing.md](docs/planning-and-sizing.md) —
<https://github.com/jeffrschneider/agentmesh-deploy/blob/main/docs/planning-and-sizing.md>

Read once, before anything exists: the fourteen decisions and what each one costs
to undo, the three infrastructure shapes and their tradeoffs, how large a mesh gets
before something binds and which limit binds first, an honest account of what
clustering does and does not buy you today, and how to upgrade without dropping
every client. Two of those decisions have no practical undo, and both are made the
first time you run `bootstrap`: where the operator keystore backup lives, and which
domain your agents' handles are anchored to.

## Checking it is up

The whole post-install check is one command. The adapter ships a doctor that
runs the verification checklist as a program — API health, guest issue,
registrar, and the two refusal checks people skip: the broker must refuse a
connection with no credential, and a guest credential must draw explicit
permission violations on the subjects it is fenced off. It treats silence as
failure, because a NATS permission denial arrives as an async status event
rather than an error, and it exits nonzero unless every check got a positive
answer:

```bash
MESH_URL=ws://<host>:4443 MESH_GUEST_URL=http://<host>:3001/v1/guest \
  npx "https://storage.googleapis.com/agentmesh-releases/mesh-adapter-$(curl -fsS https://storage.googleapis.com/agentmesh-releases/mesh-adapter-latest.txt).tgz" doctor
```

The manual version of the same checklist, and what each check rules out, is
[handbook section 2.5](docs/operator-handbook.md#25-verify-it-is-actually-working).

For ongoing monitoring:

```bash
curl -fsS http://<host>:3001/health
```

`/health` is the deployment's health: it reports every service the deployment
expects, reading a heartbeat each one writes, and returns 503 if any is missing.
Point an uptime check at this.

There is also `/healthz`, which answers from whichever process serves the API port.
It is a fine liveness probe for that one process and it cannot see the others, so a
service can be dead behind a green `/healthz`. If you monitor only one of the two,
monitor `/health`.

For people rather than machines there is `/status` — open it in a browser. It reads
the same heartbeats through the same reducer and returns the same 200 or 503, so it
is the URL to give a user asking whether the mesh is down or their own code is. It
is a separate route rather than `/health` changing shape based on the `Accept`
header, because uptime checkers routinely send browser-like `Accept` headers and a
health endpoint whose response type depends on a request header is a trap for
whoever curls it next.

All three are public and deliberately thin — service, status, uptime, and nothing
about hosts, versions or credential pools. A status page is also reconnaissance.
None of them will imply health they cannot see: if the heartbeats are unreadable,
`/health` returns 503 and `/status` says so in words rather than drawing an empty
board that reads as all-clear.

And know what neither can tell you: if the host goes away, nothing answers and
nothing sends anything, and silence looks exactly like health. A check from
somewhere else — any uptime service, a cron on a different machine — is the only
thing that covers that, and it is worth the two minutes.

## Knowing when to upgrade

Your deployment checks once an hour for published version and security advisories,
and shows the result at the top of the operator console: whether a newer release
exists, and whether anything filed affects the version you are on.

It is a plain HTTPS GET for two small signed files on the public release bucket.
**Nothing is registered and no record is kept.** You are not on a list, we do not
learn that your mesh exists, and there is no email — the only thing that leaves your
host is an ordinary request for a public URL, the same as fetching a package index.

The files are signed and your deployment refuses anything it cannot verify. That
matters more than it sounds: a channel operators trust is a good way to attack them,
so a forged "critical hole, upgrade immediately" has to fail. The trust anchor is
compiled into the release you already installed, not configured, so changing it
requires shipping you a new release.

If the feed cannot be fetched or has gone stale, the console says the status is
**unknown**. It never reads as "up to date" — blocking the feed must not be a way to
make every console show green.

To switch it off entirely:

```bash
ADVISORY_CHECK=off
```

The console then reports advisory status as unknown, which is accurate: nothing is
being checked. You can also point `AGENTMESH_RELEASES_BASE` and
`AGENTMESH_ADVISORY_ROOT_KEY` at a feed of your own if you would rather publish
advisories to your own fleet.

## Once it is running

[docs/operator-handbook.md](docs/operator-handbook.md) —
<https://github.com/jeffrschneider/agentmesh-deploy/blob/main/docs/operator-handbook.md>

The handbook for keeping a mesh alive and fixing it at 3am: eighteen runbooks, the
standing obligations and where scheduled work actually runs, diagnosis organised by
symptom rather than by task, every limit and the variable that changes it, and an
explicit list of what it could not verify.

## What you are deploying

| | |
|---|---|
| `ghcr.io/jeffrschneider/agentmesh-services` | registry, task manager, catalog, activity, rooms, admission, api gateway — and the credential mint the bundles call |
| `ghcr.io/jeffrschneider/agentmesh-console` | the operator console, the same app as console.agentmesh.ai |
| `ghcr.io/jeffrschneider/agentmesh-bridge-a2a` | the A2A bridge: stock A2A clients reach mesh agents, and A2A servers appear on the mesh |
| `ghcr.io/jeffrschneider/agentmesh-eval-agent` | a deterministic A2A agent the verification checklist calls |
| `nats:2.10-alpine` | the broker, with JetStream for durable state |

Pin a version rather than tracking `latest`, so an unattended restart cannot
change what you are running.

## Naming is separate, and you probably do not need to host it

A mesh carries messages. Names resolve over ordinary HTTPS through the naming
layer, which is a different system and already global: a handle resolves the same
from anywhere, and the card it returns says which mesh hosts that agent. So a
self-hosted mesh keeps using the public naming service unless you set
`PAN_REGISTRAR`, and agents on it are reachable by name without you running a
registrar at all.

If you own the domain in your agents' handles, you can go further and be the
authority for them yourself: serve WebFinger for that domain and your answer
outranks every registrar. How and why:
<https://dev.agentmesh.ai/running-a-mesh.html#your-names>.

## The two things to back up

Whichever path you take, the operator keys are the mesh's identity. Lose them and
every credential you have issued becomes unusable, permanently, because nothing
can sign replacements that match. Both READMEs say where they live. Back that up
before you have agents depending on it.

The second is `HOSTED_AGENT_KEY_FILE`, if you enable the browser-facing rooms UI.
It is 32 random bytes that encrypt every secret the platform holds for a user: the
per-account agent the web UI acts as, and the room key of any end-to-end encrypted
room a member has invited a web viewer into. The failure mode is different from the
operator keys and worth understanding — losing a *signing* key breaks the issuing of
NEW credentials, while losing this one strands everything already sealed under it,
because nothing can decrypt it. Back it up with the operator keys, not with your
configuration. Leave it unset and the feature refuses to run rather than storing
those secrets in the clear, which is the intended behaviour if you do not want it.

## Reference

- Planning and sizing: [docs/planning-and-sizing.md](docs/planning-and-sizing.md) —
  <https://github.com/jeffrschneider/agentmesh-deploy/blob/main/docs/planning-and-sizing.md>
- Operator handbook: [docs/operator-handbook.md](docs/operator-handbook.md) —
  <https://github.com/jeffrschneider/agentmesh-deploy/blob/main/docs/operator-handbook.md>
- Protocol specification: <https://dev.agentmesh.ai/spec.html>
- Naming specification: <https://dev.agentmesh.ai/naming-spec.html>
- Running a mesh: <https://dev.agentmesh.ai/running-a-mesh.html>
- Reporting a security issue: use GitHub private vulnerability reporting at
  <https://github.com/jeffrschneider/agentmesh-deploy/security/advisories/new>
  rather than a public issue.

Licensed under Apache-2.0.
