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

Both are public and deliberately thin — service, status, uptime, and nothing about
hosts, versions or credential pools. A status page is also reconnaissance.

And know what neither can tell you: if the host goes away, nothing answers and
nothing sends anything, and silence looks exactly like health. A check from
somewhere else — any uptime service, a cron on a different machine — is the only
thing that covers that, and it is worth the two minutes.

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
| `ghcr.io/jeffrschneider/agentmesh-services` | registry, task manager, catalog, activity, rooms, admission, api gateway |
| `ghcr.io/jeffrschneider/agentmesh-console` | the operator console, the same app as console.agentmesh.ai |
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
