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
the scaling rules that matter written down: the services tier is elastic, the
JetStream tier is not, and an autoscaler must never see both.

Both were run end to end before being published, rather than written and reasoned
about. Compose was brought up from empty and driven with a real agent and a real
browser; the Kubernetes manifests were applied to a GKE Autopilot cluster and
taken through the same check. The gotchas each README lists are things that
actually happened during those runs.

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

## The one thing to back up

Whichever path you take, the operator keys are the mesh's identity. Lose them and
every credential you have issued becomes unusable, permanently, because nothing
can sign replacements that match. Both READMEs say where they live. Back that up
before you have agents depending on it.

## Reference

- Protocol specification: <https://dev.agentmesh.ai/spec.html>
- Naming specification: <https://dev.agentmesh.ai/naming-spec.html>
- Running a mesh: <https://dev.agentmesh.ai/running-a-mesh.html>
- Reporting a security issue: use GitHub private vulnerability reporting at
  <https://github.com/jeffrschneider/agentmesh-deploy/security/advisories/new>
  rather than a public issue.

Licensed under Apache-2.0.
