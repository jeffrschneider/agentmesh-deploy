# Planning and sizing an AgentMesh deployment

For the person deciding what to build, before any of it exists. It assumes you
have read one of the two bundle READMEs and have not yet run anything you would
mind losing.

This is the document you read once. Its companion,
[`operator-handbook.md`](operator-handbook.md)
(<https://github.com/jeffrschneider/agentmesh-deploy/blob/main/docs/operator-handbook.md>),
is the one you read repeatedly, at 3am, with a running mesh and a problem:
runbooks, standing obligations, diagnosis organised by symptom, every limit and
the variable that sets it, and an explicit list of what it could not verify.
Nothing here restates a runbook. Where a decision has a procedure attached, this
document names the procedure and stops.

Every placeholder used here is defined once, in the handbook's
[Placeholders](operator-handbook.md#placeholders) table, along with the four URLs
that are genuinely public and stay literal. Fill them in there.

The same caveat about sources applies. The services and console are published as
container images built from a private source repository, so where this document
attributes a number to a specific module it does so as attribution, not as a
pointer you can open. The claim has a source; you cannot read it. What you *can*
read is either in this repository, at <https://dev.agentmesh.ai>, or in the NATS
documentation, and the text says which.

---

## Table of contents

- [1. Decisions before you start](#1-decisions-before-you-start): the forks, ordered by what they cost to undo
- [2. Infrastructure shapes](#2-infrastructure-shapes): one node, one region, and the one we have not tried
- [3. Sizing, and what binds first](#3-sizing-and-what-binds-first): the numbers, the arithmetic, and the file each one lives in
- [4. High availability, honestly](#4-high-availability-honestly): what clustering buys today, and the two hard limits it does not fix
- [5. Rolling upgrades](#5-rolling-upgrades): lame duck mode, the hard restart, and the image swap
- [6. Verifying the install works](#6-verifying-the-install-works): where the checks are, and the trap in the conformance defaults

---

## 1. Decisions before you start

Fourteen decisions change what you build. They are not equally reversible, and
the two least reversible ones are easy to make by accident, because both of them
happen at the moment you first run `bootstrap`.

### 1.1 Which of these you cannot take back

**No undo at all: custody of the operator keys.** The keys minted at bootstrap
*are* the mesh's identity. Every account JWT and every credential you ever issue
chains to them. Lose them and nothing can sign a replacement that matches: every
credential ever issued becomes permanently unusable, and the only path forward is
standing up a different mesh that happens to have the same name and reissuing
every agent. There is no recovery, no support channel, and no vendor holding a
copy. Decide where the backup lives before you run anything, not after. Detail in
[1.3](#13-the-five-that-deserve-more-than-a-row).

**Effectively no undo: the domain your handles are anchored to.** Whether you run
a registrar is a cheap decision, and `PAN_REGISTRAR` is one variable. *Which
domain your agents' handles carry* is not cheap, because a handle is a public
address other people's nodes resolve and pin. Once a handle is bound to a key and
pinned elsewhere, it cannot be re-homed casually: the refusal is deliberate, and
confirming a legitimate rebinding is a runbook with a reversal window
([R17](operator-handbook.md#r17-confirm-a-refused-handle-rebinding)). Changing
the anchor domain later is not a configuration change, it is asking everyone who
has your agents' addresses to accept new ones. Pick the domain you will still own
in five years.

**Expensive: the account resolver, and user accounts.** Both are high-cost
changes for the same underlying reason, which is that they are not settings.
Moving from a memory resolver to a directory resolver is a broker
reconfiguration and a restart. Adding human sign-in means mail, and mail today
means building the services yourself
([1.3](#13-the-five-that-deserve-more-than-a-row)).

**Moderate: the deployment shape, and the broker's node count.** Changing shape
is cheaper than it looks, because the mesh's identity is portable: the keystore
and the account JWTs move between Compose, Kubernetes and a VM, and agents keep
working. What you rewrite is your own runbooks, not the mesh. Changing the
broker's replica count is a migration rather than an edit, for the reasons in
[section 2.2](#22-clustered-within-one-region).

**Cheap: nearly everything else.** The guest sandbox is an empty directory away
from off. Postgres for history can be added any time, with no backfill. Whether
the console is internet-facing is a choice between a certificate and an SSH
tunnel. The image version is a tag. Artifact storage is portable for new
artifacts, though the bytes already written do not follow.

### 1.2 The decisions, in one table

| Decision | What it decides | Cost to change later |
|---|---|---|
| **Deployment shape**: Compose, Kubernetes, or a VM with a process manager | Where the pieces run, how you restart them, how secrets arrive | Moderate. The mesh's identity is portable: the keystore and the account JWTs move between shapes, so agents keep working. You rewrite your own runbooks, not the mesh. |
| **Broker node count**: one server, or a clustered set | Whether losing one machine takes the transport down with it | Moderate, and it is a migration rather than an edit. Scaling in has an ordering you have to follow. [Section 2.2](#22-clustered-within-one-region). |
| **A real domain with TLS** | Whether anyone outside your network can use it at all. Not optional, see [1.3](#13-the-five-that-deserve-more-than-a-row) | Low to do, but everything downstream embeds it: sign-in links, the console's WebSocket URL, CORS. Changing the domain later means reissuing links and re-pointing clients. |
| **User accounts, and therefore mail** | Whether humans sign in, own agents, and hold quota, or whether the mesh is sandbox-only | High, and today it is a code change rather than a configuration one. See [1.3](#13-the-five-that-deserve-more-than-a-row). |
| **Artifact storage**: `nats`, `fs`, or an object store | Where room artifact bytes physically live | Low for new artifacts, but there is no migration: bytes already written to one backend are not visible through another. Switch early or accept a cut-over. |
| **Names**: run a registrar, point at one, or skip handles | Whether agents are addressable by `<HANDLE>` or only by raw key | Low. `PAN_REGISTRAR` is one variable. But the anchor domain is not, and a handle already bound to a key and pinned by other nodes cannot be re-homed casually ([R17](operator-handbook.md#r17-confirm-a-refused-handle-rebinding)). |
| **A public guest sandbox** | Whether strangers can `POST /v1/guest` and get a throwaway credential | Low: an empty pool directory turns it off, and the endpoint answers 503 rather than breaking. But arming it means owning the pool's expiry and rotation forever ([R13](operator-handbook.md#r13-re-mint-the-guest-pool-when-rotation-is-refusing)). |
| **Postgres** | The registrar requires it. The history recorder wants it and works without it | Low for the recorder: set `METRICS_DB_URL` any time and charts start recording from then on. There is no backfill. |
| **Is the console internet-facing** | Whether you need TLS and a public hostname for it, or only an SSH tunnel | Low. Loopback is exempt from the TLS refusal, so `ssh -L 3000:localhost:3000 <host>` is a complete answer and needs no certificate. |
| **Where the operator keystore backup lives** | Whether the mesh survives losing its host | **No undo.** See [1.3](#13-the-five-that-deserve-more-than-a-row). |
| **The account resolver**: memory, or directory/URL | Whether adding an account or revoking a credential needs a broker restart | High. Both bundles here use a memory resolver: accounts are literal JWT text in the config file. Moving to a directory resolver later is a broker reconfiguration and a restart, and it is the only way to satisfy the spec's requirement that revocation not restart the mesh ([SPEC §4.8](https://dev.agentmesh.ai/spec.html)). |
| **Pinned service identities**: the `*_SEED` files | Whether a client can hard-check that a reply claiming to be from the registry actually is | Low to add, mildly disruptive to change. Without them each service generates a fresh keypair on **every restart** and clients can only pin-and-warn. Adding one later is fine; rotating one makes every client that pinned the old key log a mismatch. Install them on day one. |
| **Replica count for the services** | Nothing, today. One is the only supported value | Not a dial. Three separate properties of the current build make a second instance wrong rather than slow, and one of them makes it actively incorrect. [Section 4.3](#43-the-second-limit-the-services-tier-cannot-go-past-one-replica). |
| **Which image version you pin** | What you are running after an unattended restart | Low, and this is the point of pinning. `0.2.0` is the only published version at the time of writing. |

### 1.3 The five that deserve more than a row

**TLS is not optional, and the reason is mechanical.** The operator console is a
browser page that opens a WebSocket straight to the broker. An `https:` page is
not permitted to open a plain `ws://` connection, so the moment the console is
served over TLS the broker's WebSocket must be `wss://` too: you cannot do one
half. Independently, the console refuses to load over plain HTTP anywhere but
loopback, because it holds an operator session in `sessionStorage` and that
session can disable accounts, release handles and reach a fleet host. The console
image accepts `ALLOW_INSECURE_HTTP=1` to override that refusal and then carries a
standing warning; treat it as a thing you set on a network you fully control and
nowhere else. And sign-in links are built from `API_BASE_URL`, so a mesh with user
accounts and no domain mails out links nobody can use. Both bundles here ship
without TLS deliberately, and both READMEs say so; terminating it is the first
thing you add. Symptoms of getting this wrong are in
[5.4](operator-handbook.md#54-a-screen-has-gone-blank).

**User accounts drag in mail, and mail is where this bundle is least portable.**
The services' email module defines an `EmailService` interface with exactly three
methods (`sendMagicLink`, `sendInvitation`, `sendAgentKey`) and ships exactly two
implementations: an adapter for one hosted mail API, and a console fallback that
prints to the log and is a development tool. The fallback prints nothing at all
unless `MESH_DEV_MODE=1`, because a sign-in link on stdout is a credential. There
is no provider abstraction beyond that interface. Two consequences to be honest
about:

- Another provider means implementing those three methods and rebuilding the
  image. Nothing selects a provider at runtime; the API key being present or
  absent is the entire decision.
- **Set the sending address.** `MESH_MAIL_FROM` is the address mail comes from.
  A provider will not send from a domain the account has not verified, so leaving
  this at its default, which is the AgentMesh deployment's own address, gets your
  sends rejected rather than delivered. A bare address is wrapped with `MESH_NAME`
  (`noreply@example.com` becomes `Example Mesh <noreply@example.com>`), or pass
  the full display form yourself. Set `MESH_CONSOLE_URL` too: it is the console
  address embedded in outbound mail and it also defaults to ours.

So the honest reading today: **accounts need a provider whose API shape fits the
one adapter that exists, and a verified sending domain.** If you do not want
either, a sandbox-and-agents mesh needs no mail at all. That is a real and
complete deployment: agents connect with credentials you mint, register, discover
each other, run tasks, and share rooms, none of which touches email. Deciding you
want human sign-in is deciding to build the services yourself. The handbook's
examples name one provider because it is the one adapter that exists; read that as
an example, not as a choice you are being offered. The handbook also records that
a full self-hosted mail round trip has never been verified end to end
([section 8](operator-handbook.md#8-where-this-handbook-is-uncertain)), which is
worth knowing before you plan a launch around it.

**Artifact storage genuinely is portable, and the default needs nothing.**
`ROOMS_DRIVE_BACKEND` takes three values, and all three are real code paths:
`nats` (the default) keeps artifact bytes in a JetStream object store, so an
operator with no cloud at all has a working path and nothing extra to run; `fs`
writes one file per object under `ROOMS_DRIVE_FS_DIR` (default
`<INSTALL_ROOT>/rooms-drive`), which suits a host with a persistent disk; `gcs`
writes to a bucket named by `ROOMS_GCS_BUCKET` and authenticates with ambient
application credentials. An unrecognised value warns and falls back to `nats`
rather than failing. Adding S3 or Azure is one class and one branch in that
module, but it is not there today, so treat "any object store" as false and
"these three" as true. Members address artifacts by opaque refs and read and
write through the rooms service, so nothing about the protocol, the SDK or the
adapter changes when you switch, but the bytes do not follow. One sizing note
that belongs here rather than in section 3: with the default backend, artifacts
consume the same JetStream disk as everything else, so the per-operator drive
quota and the disk ceiling are the same budget.

**Where the keystore backup lives is the one decision with no undo.** The
operator keys minted at bootstrap *are* your mesh's identity. Every account JWT
and every credential you ever issue chains to them. Lose them and nothing can
sign a replacement that matches: every credential ever issued becomes permanently
unusable, and there is no recovery path other than standing up a different mesh
that happens to have the same name and reissuing every agent. In Compose they are
in the `mesh-data` volume under `.nsc`; in Kubernetes they are on the workstation
you minted them on and should never enter the cluster; on a VM they are
`<CREDS_DIR>/nsc/`. Decide **now** where the backup goes, whether that is a
secret manager, an encrypted archive somewhere else, or a printed copy in a safe,
so long as it is not the host itself. Decide who else can reach it, because a
backup only one person can restore is a single point of failure with a pulse.
Then restore it once into a scratch directory and confirm it lists your accounts,
because a backup that has never been restored is a hope
([R11](operator-handbook.md#r11-restore-the-nsc-keystore)). Two things to write
down alongside it: never commit the keystore, and never invoke `nsc` with only
`-H` on a store you care about, because it has previously renamed a store and
left both copies unusable. Pass `--data-dir` and `--keystore-dir` explicitly.

**Choosing a cloud is mostly a non-decision, which is worth knowing early.**
Nothing in the mesh requires a particular provider or a managed service. What a
host has to give you is short:

- A persistent disk for JetStream that survives a restart, sized from
  [section 3](#3-sizing-and-what-binds-first).
- Somewhere to terminate TLS in front of two things: HTTPS for `<API_BASE>` and
  `<CONSOLE_URL>`, and `wss://` for `<MESH_WS>`. One reverse proxy or one ingress
  covers both.
- Outbound HTTPS, if you use a hosted mail provider or resolve handles through a
  registrar you do not run.
- A way to get secrets onto the host as files or as injected environment values.
  Nothing in the services talks to a secret manager directly; that is your
  platform's job, not the mesh's
  ([2.1](operator-handbook.md#21-what-must-exist-before-anything-runs)).

Everything beyond that is optional: Postgres only for history charts and for a
registrar you host yourself, object storage only if you move artifacts off the
default backend. `<CLOUD_PROJECT>` appears in the handbook's placeholders because
some readers will have one, not because the mesh asks for one. The two shapes in
this repository were each verified once on real infrastructure, Compose on a
single host and the manifests on a managed Kubernetes cluster, and both READMEs
name the provider used. Read those as the environments that happened to be
available, not as requirements.

---

## 2. Infrastructure shapes

Three, and we have operational experience of one of them.

### 2.1 A single node

One broker, one services process, one console, one host. This is
[`compose/`](../compose/) and it is also what the reference instance runs, as a
VM with a process manager rather than as containers. The handbook covers bringing
it up both ways
([2.2](operator-handbook.md#22-bring-up-a-mesh-with-compose),
[2.4](operator-handbook.md#24-bring-up-a-broker-by-hand)).

What you get is a complete mesh. Nothing about the protocol is degraded: agents
register, discover each other, run tasks, share rooms, hold sealed rooms, and
receive offline mail exactly as they would on a larger deployment. Single-node is
not a reduced feature set, it is a single failure domain.

What you accept is that the host is the failure domain, for all of it. A restart
of the broker drops every client connection
([R4](operator-handbook.md#r4-restart-the-broker)), and the handbook is right to
call that a small outage rather than a config refresh. JetStream state is
unbacked in both bundles, with no snapshot schedule and nothing in cron, so if
the disk holding it is lost then the registry, the tasks, the rooms and the
offline mail are lost with it; agents can re-register, but the mesh's memory does
not come back on its own
([section 8](operator-handbook.md#8-where-this-handbook-is-uncertain)). If
JetStream state matters to you, arranging backups is work you have to do, and it
is worth deciding that now rather than after the first incident.

For a starting size, the Kubernetes manifest in this repository is the only place
the resource shapes are written down, and they are the same processes:
[`kubernetes/mesh.yaml`](../kubernetes/mesh.yaml) requests 250m CPU and 1Gi of
memory for the broker with a 1 CPU / 2Gi limit, 200m and 512Mi for the services
with a 1 CPU / 1Gi limit, and 50m and 128Mi for the console. Those are requests
chosen to schedule, not measurements of a loaded mesh, so treat them as a floor.
Disk is the number that actually matters, and it comes from
[section 3](#3-sizing-and-what-binds-first).

Right for evaluating, for a private mesh behind a firewall, for a branch office,
and for a production deployment whose availability requirement is honestly stated
as "we can be down while someone fixes it".

### 2.2 Clustered within one region

Several brokers in one cluster, with JetStream replicated between them by Raft.
[`kubernetes/mesh.yaml`](../kubernetes/mesh.yaml) is this shape: a three-replica
NATS StatefulSet, a persistent volume per replica, and the services and console
as Deployments alongside. It was applied to a managed Kubernetes cluster and taken
end to end once, and the failure modes in
[`kubernetes/README.md`](../kubernetes/README.md) are things that happened during
that run rather than things anticipated on paper. It is not what we operate day to
day.

Three properties of that manifest are decisions rather than defaults, and each
one has a reason:

**Three replicas, and an odd number.** JetStream replication is Raft, so quorum
is two of three. Two replicas has no quorum advantage over one and a worse
failure story. This is why the replica count is a decision and not a dial, and
why an autoscaler must never point at the StatefulSet: a scaler that removes a
peer without reassigning its stream replicas first will eventually eat data.
Scaling in has an order (confirm no stream is at minimum replicas, reassign,
remove the peer, let the group settle, and only then reduce the StatefulSet), and
[`kubernetes/README.md`](../kubernetes/README.md) is where that lives.

**Pods spread across hosts.** Three replicas on two machines lose quorum the
moment one machine drains, which defeats the point of having three. The manifest
enforces the spread with a `topologySpreadConstraint` on
`kubernetes.io/hostname` and `whenUnsatisfiable: DoNotSchedule`, so a cluster that
cannot honour the spread refuses to schedule rather than quietly clustering onto
two nodes.

**Restart one pod at a time.** With quorum at two, restarting two pods together
takes the cluster below quorum.
[R4](operator-handbook.md#r4-restart-the-broker) has the procedure, and
[section 5](#5-rolling-upgrades) covers doing it without dropping every client.

What clustering buys you today is that a broker node can be lost, or drained, or
restarted, without the transport going away: client connections fail over to a
surviving server. **What it does not buy you today is data redundancy or a
redundant services tier**, and both of those are hard current limits rather than
tuning gaps. Read [section 4](#4-high-availability-honestly) before you choose
this shape for an availability requirement, because the thing most people expect
clustering to give them is the thing it does not currently give them.

Two costs worth planning for. Each replica gets its own persistent volume, so
disk is multiplied by the replica count even though application data is not
replicated ([section 4.2](#42-the-first-limit-every-stream-and-kv-bucket-is-single-replica)),
and the manifest asks for 10Gi apiece. And deleting the cluster does not reclaim
those volumes: they outlive it as orphaned disks, still billing, with nothing
warning you. Delete the namespace first.

### 2.3 More than one region

We run a single node ourselves and have not tested a cross-region deployment.
Nothing in this repository configures one, and no procedure here has been
exercised across regions.

What we can tell you is the name of the mechanism, so that you are searching for
the right thing. NATS connects separate clusters to each other with **gateway**
connections, and a set of clusters joined that way is a **supercluster**;
gateways propagate interest between clusters rather than extending a single Raft
group across them, which is the reason a supercluster is not simply a stretched
cluster. Cross-region durability of JetStream data is a separate concern again,
handled by stream mirrors and sources rather than by raising a replica count. The
NATS documentation at <https://docs.nats.io> is the authority for all three, and
it is the right source to read rather than anything we could write here.

Two things we will not do. We will not give you a manifest or a set of flags for
a shape we have never run, because a deployment recipe that has not been executed
is a guess with syntax highlighting. And we will not imply that
[section 4](#4-high-availability-honestly)'s limits get better with distance:
application streams and KV buckets are single-replica today, so spreading brokers
across regions does not make the data survive losing one.

One distinction to keep clear, because the words collide. Two separate AgentMesh
instances that talk to each other is **peering**, a protocol-level concept
specified at <https://dev.agentmesh.ai/spec.html>, where agents visit a host mesh
and the meshes remain separate systems with separate identities. That is a
different thing from one mesh whose brokers happen to sit in several regions.
Neither is a substitute for the other, and the conformance suite tests peering
separately ([section 6](#6-verifying-the-install-works)).

---

## 3. Sizing, and what binds first

Five numbers decide how large a mesh can get before something refuses. They all
exist and they are all verifiable, but they live in five different files, which is
the reason for collecting them here. One of them additionally has to be mirrored
into a second file by hand, and those two copies have drifted apart in a real
deployment before, invisibly, until someone did the arithmetic.

| Bound | Value as shipped | Where it is set |
|---|---|---|
| Per-envelope size on the wire | 1 MiB | `max_payload` in the broker config. **Not set by either bundle in this repository**, so both inherit the NATS server default, which is also 1 MiB. |
| Inbound sender text, per agent | 64 KiB of characters | A hardcoded constant in the TypeScript SDK. Not an environment variable. Per-agent override only. |
| Offline mailbox retention | 7 days, or 25 MiB per agent, whichever comes first | `INBOX_BUFFER_MAX_AGE_MS` and `INBOX_BUFFER_MAX_BYTES` in the services environment. |
| Offline mailbox count | 500 mailboxes | `INBOX_BUFFER_MAX_MAILBOXES` in the services environment. |
| JetStream disk ceiling | 10G in Compose, 8G per replica in Kubernetes | `jetstream { max_file }` in the broker config, mirrored into the services as `JS_MAX_FILE_BYTES`. |

### 3.1 The per-envelope ceiling, and the two different limits people confuse

**1 MiB is the transport bound.** NATS refuses a message larger than
`max_payload`, and the refusal is at the broker, so it is not something an agent
can talk its way past. The API gateway advertises the same figure to clients as
`max_message_bytes`, and the platform's HTTP body cap matches it, so the number
is consistent across the three places a client meets it. Anything genuinely
larger than that is supposed to become an artifact: the bytes go to the object
store and the envelope carries a `ref`
([SPEC §18.9](https://dev.agentmesh.ai/spec.html)).

Worth knowing, because it affects whether you can rely on it: **neither bundle in
this repository sets `max_payload` at all.** The Compose bootstrap writes a
`nats.conf` with `server_name`, a `jetstream` block, a `websocket` block and an
include, and the Kubernetes ConfigMap writes the same plus `port`, `http` and a
`cluster` block. Neither mentions payload size. The effective value is 1 MiB
because that is the NATS default, which means the behaviour is right and the
provenance is not: a vendor default is not a decision, and it moves if the vendor
moves it. If the number matters to your design, set it explicitly in your own
broker config rather than inheriting it.

**64 KiB is something else, and it is not a mesh limit.** The TypeScript SDK caps
the sender-supplied text it will hand to an agent's handler at 64 KiB, and refuses
anything larger before the handler runs: on a path that has a reply subject the
sender gets a signed non-retryable `CONTEXT_TOO_LARGE` error, and on an event
path, which has no reply subject, the recipient's security-warning callback fires
and the message is dropped. Four properties matter when you plan around it:

- It is **inbound only**. Nothing caps what your agent sends.
- It counts **characters, not bytes**. 64 KiB of characters in four-byte UTF-8 is
  roughly 256 KiB on the wire, still comfortably under `max_payload`, but the two
  limits are in different units and neither name says so.
- It is a **hardcoded constant**, not an environment variable. The only override
  is per-agent, in the agent's own connect options, where `0` disables it.
- **The Rust SDK has no equivalent.** A Rust agent is bounded only by the
  broker's `max_payload`. If you are planning a fleet with agents in both
  languages, they do not have the same inbound behaviour.

The reference node adapter carries the same 64 KiB figure independently, and
treats it slightly differently in one place: an oversized room message is
truncated rather than refused.

### 3.2 Offline mail, per agent

When an agent is not connected, messages addressed to it are captured into a
per-agent JetStream stream and drained when it returns. Each mailbox is bounded
two ways and both are enforced by JetStream rather than by application code:
`max_age` of 7 days, and `max_bytes` of 25 MiB, with a discard-oldest policy. So
the promise is "7 days or 25 MiB, whichever runs out first", and past either one
the oldest mail is dropped silently to make room. Both are settable per
deployment through `INBOX_BUFFER_MAX_AGE_MS` and `INBOX_BUFFER_MAX_BYTES`, and
the whole mechanism has a kill switch in `INBOX_BUFFER_DISABLED`.

Two notes for capacity planning rather than for operations. 25 MiB is a
*ceiling*, not a reservation: a mailbox with three messages in it occupies three
messages worth of disk, so the nominal figure is a worst case and a real
deployment sits far below it. And the drop is discard-oldest across the whole
mailbox, so a flood of low-value mail to an offline agent evicts the mail that
mattered. Watch backlog per mailbox rather than total disk if that failure mode
concerns you; the handbook's obligations surface reports it
([section 3](operator-handbook.md#3-what-you-owe-it)).

### 3.3 The count cap against the disk ceiling, which is the arithmetic worth doing

The mailbox count cap is 500, and it is a cap on the **number of streams**, not on
messages or agents: each mailbox is one JetStream stream, and streams cost file
handles and metadata whether or not they hold anything. Two properties of the cap
are worth knowing before you rely on it. It **fails open**: the check counts
existing streams, and if JetStream cannot be queried the count comes back unknown
and the cap is simply not applied. And the count is **process-local**, so it is
not a cluster-wide guarantee.

Now the arithmetic, because the answer to "which limit binds first" depends
entirely on the disk ceiling you configure, and the two bundles here configure
different ones:

| JetStream `max_file` | Mailboxes that fit at 25 MiB nominal | Which cap binds first |
|---|---|---|
| 8G, which is what [`kubernetes/mesh.yaml`](../kubernetes/mesh.yaml) sets per replica | 327 | Disk, about 35% before the count cap |
| 10G, which is what [`compose/bootstrap.sh`](../compose/bootstrap.sh) writes | 409 | Disk, about 18% before the count cap |
| 20G | 819 | The count cap, but only just: 500 mailboxes at nominal is 12.2 GiB, or 61% of the ceiling |

So on **every configuration checked into this repository, disk binds before the
mailbox count does**, which is what the handbook's limits table says
([section 7](operator-handbook.md#7-limits-and-where-they-are-set)). Raise
`max_file` above roughly 12.25 GiB and the relationship inverts and the count cap
binds instead. Neither answer is universally true, which is exactly why the two
numbers need to be read together rather than quoted separately. Remember also
that 25 MiB is a ceiling per mailbox and not a reservation, so 500 real mailboxes
will normally occupy a small fraction of that 12.2 GiB, and the table is a
worst-case boundary rather than a forecast.

Three things to get right when you set this:

**The account limit wins when it is set.** The broker enforces the account's
`max_storage` if it has one, and only falls back to the server's
`jetstream.max_file` otherwise
([section 6](operator-handbook.md#6-what-is-enforced-where)). Both bundles here
mint the account with JetStream unlimited (`--js-disk-storage -1`), deliberately,
so that the server's own config is the single ceiling. If you set an account limit
instead, that becomes the number that matters and the server config stops being
the answer.

**Keep `JS_MAX_FILE_BYTES` in step with the broker by hand.** The services
process cannot read `nats.conf`, so the ceiling has to be mirrored into its
environment for the obligations screen to measure usage against the right number.
There is no mechanism keeping the two in sync, and they have already drifted once
in a real deployment: the environment said 10 GiB while the broker said 20G, so
the screen would have called disk capacity critical at half the real ceiling. If
you change one, change the other in the same commit.

**On a cluster, the per-server ceiling is what binds, not the total.** The
Kubernetes manifest gives each of three replicas a 10Gi volume and sets
`max_file: 8G`, so the aggregate looks like 24 GiB. It is not a shared 24 GiB.
Application streams are single-replica ([section 4.2](#42-the-first-limit-every-stream-and-kv-bucket-is-single-replica)),
so each one lives on one server and is bounded by that server's 8G, and uneven
placement can fill one server while the others are idle.

### 3.4 What is not capped, and what is capped elsewhere

Both bundles mint the account with unlimited JetStream streams, consumers and
disk, so there is no per-account storage quota in the way by default: the server
config is the only ceiling. There is no consumer-count limit anywhere in the
platform.

Everything else with a number on it is in the handbook's limits table, and that
is the right place for it because those are dials you turn while running rather
than sizes you plan around: agents per account, fair-use messages and bytes per
day, durable rooms and drive bytes per operator, artifact size, room record
size, room idle expiry, the sandbox TTLs and per-IP caps, the reaper intervals,
presence limits, and every rate limit with the variable that changes it. Read
[section 7](operator-handbook.md#7-limits-and-where-they-are-set) once before you
size anything, because two of those defaults consume the disk budget above:
`ROOMS_DRIVE_BYTES_PER_OPERATOR` at 100 MB and the room record cap at 8 MB per
room both land in JetStream when `ROOMS_DRIVE_BACKEND` is left at `nats`.

---

## 4. High availability, honestly

This is the section most likely to mislead, so it is written to be read against
the manifest rather than instead of it.

### 4.1 What the shipped cluster actually gives you

[`kubernetes/mesh.yaml`](../kubernetes/mesh.yaml) runs three NATS servers with
JetStream clustering, Raft quorum at two of three, pods spread across hosts, a
volume per replica, and probes that let a cluster form rather than killing pods
mid-formation. All of that is real, and the handbook has the correct restart
procedure for it: one pod at a time, wait for it to rejoin, never an autoscaler
([R4](operator-handbook.md#r4-restart-the-broker)).

What that buys is **connection availability**. Lose a node, drain a node, restart
a node, and clients reconnect to a surviving server; the transport does not go
away.

That is a smaller claim than "highly available", and the next two subsections are
why.

### 4.2 The first limit: every stream and KV bucket is single-replica

**Every JetStream stream and KV bucket the platform creates is created with one
replica, today, on every deployment shape including the three-node cluster.**

The mechanism, so you can check it rather than take it on faith. The services
share one helper for creating KV buckets, and that helper defaults its replica
count to 1. Nineteen distinct buckets are created through it, from twenty call
sites across twelve modules, and **not one of them passes a replica count**, so
the default is what every bucket gets. The only two places the services tier
mentions a replica count at all are that helper's own option type and its `?? 1`.
Separately, the two JetStream streams the platform creates set `num_replicas: 1`
literally in their configuration: the per-agent offline mailbox, and the per-room
record. There is also a second, thinner bucket-creation path that passes no
options whatsoever, which lands on the same value, so the helper is not even a
single chokepoint you could change in one place.

The consequence, stated plainly: **on a three-node cluster, connections fail over
but application data does not.** The registry, the catalog, accounts and sessions
and auth tokens, tasks, admission rosters and guard state, room descriptors, held
senders, roster proposals, the obligations snapshot, the scheduler's leases,
operator sessions, every agent's offline mail, and every room's transcript each
live on exactly one of the three servers, with no copy on the other two. Lose the
server holding a bucket and that data is unreachable until it returns. Lose its
disk and the data is gone, the same as on a single node. **Clustering today buys
connection failover, not data redundancy.**

Two further details that matter for planning rather than for blame. Raising the
default in a future build would not repair an existing deployment: the NATS client
looks a bucket up before creating it and silently ignores the configuration you
pass when it already exists, so replica count on live buckets is a migration
rather than an edit. And the mailbox stream's self-healing path repairs only two
specific fields, so it will not correct a replica count either.

This is a known gap and it is being worked on. We are not going to attach a date
to it here, because a date in a document like this one becomes a promise, and the
honest planning input is the current state rather than the intention. Plan against
what the build does today.

What to do with that in the meantime. If your requirement is "survive losing one
machine without losing state", the shipped configuration does not meet it, and
clustering will not make it meet it. What does help is backing JetStream up
yourself, since neither bundle does
([section 8](operator-handbook.md#8-where-this-handbook-is-uncertain)), keeping
the keystore backup current so identity survives independently of state
([1.3](#13-the-five-that-deserve-more-than-a-row)), and being clear with whoever
depends on the mesh about which of the two properties you actually have.

### 4.3 The second limit: the services tier cannot go past one replica

**One services replica is the only supported count.** The handbook's decisions
table used to frame this as a throughput note with a caveat about counters. That
undersold it: it is a hard limit, and it has three independent causes, of which
the third is the serious one.

**Local SQLite counters.** The activity service keeps per-agent usage counters in
a SQLite file on local disk, at `USAGE_DB_PATH`. Two instances keep two divergent
sets of counters, and neither is right. That is not only cosmetic: whether an agent
is over fair use is a judgement a human makes from those counters
([section 3](operator-handbook.md#3-what-you-owe-it)), so divergent counters mean
the operator is making a real decision from a number that is wrong by an unknown
amount.

**A local console login.** The operator console's login hash is a separate JSON
file at `MESH_OPERATOR_AUTH_FILE`. It is not in the SQLite database and not in
JetStream, though both bundles here land it in the same per-instance volume as
the counters, which is why they get described together. A second instance either
has no login configured, and therefore answers 503 on every operator route, or
has a different one, depending on how the volume is mounted.

**No subscription uses a queue group.** This is the one that makes a second
instance incorrect rather than merely inconsistent. Every NATS subscription in
the services tier is created with a subject and nothing else: the task manager's
update subject, the admission service's inbox, the activity service's two usage
subjects, the heartbeat monitor, the catalog's subjects, and the shared
request-reply helper that every service uses. The helper's own type signature
accepts only a subject, so there is no place to pass a queue group even by
accident. Without one, NATS delivers every message to **every** subscriber, so two
services instances both receive each request and **both answer it**. The client
gets duplicate replies to a single request, both instances do the work, and any
side effect happens twice.

So `replicas: 1` on the services Deployment is a requirement, not a starting
point, and an autoscaler pointed at that Deployment is a correctness bug rather
than a cost decision. The manifest ships `replicas: 1`, which is right.

Two things this does **not** apply to. The console is genuinely elastic: it is a
static file server with no state and no subscriptions, and the manifest runs two
replicas of it correctly. And scheduled work is already safe against multiple
instances, by a different mechanism: jobs take a lease in a JetStream KV bucket
and the losers skip, so the scheduler was designed for a replicated tier even
though the subscriptions were not
([section 3](operator-handbook.md#3-what-you-owe-it)).

The availability consequence is worth being explicit about, because it is easy to
miss. With one services replica, anything that needs a platform service to answer
stops while that replica is down: discovery, task creation and updates, room
operations, admission, the HTTP API, the operator surface, and the guest sandbox.
Traffic that is purely between two agents keeps flowing, because the broker
carries it and no service sits in that path. So a services restart is a
control-plane outage rather than a total one, which is a useful thing to know
when you are writing down what your mesh promises.

### 4.4 What high availability looks like today, in one paragraph

Broker availability is real and available to you now, at the cost of running a
cluster and following the restart order. Data redundancy is not, because every
stream and bucket is single-replica. A redundant services tier is not, because of
the three causes above. If you need better than that today, the honest levers are
a fast and rehearsed rebuild, JetStream backups you arrange yourself, a pinned
image version so a rebuild is deterministic
([R5](operator-handbook.md#r5-deploy-services-agents-bridge-and-console),
[R6](operator-handbook.md#r6-roll-back-services-or-the-console)), and a verified
keystore backup so the mesh's identity is never the thing you are missing
([R11](operator-handbook.md#r11-restore-the-nsc-keystore)). Those four are worth
more in practice than a third broker replica, given what the third replica does
and does not currently protect.

---

## 5. Rolling upgrades

Two mechanisms, and only one of them avoids an outage. Which one you get depends
on a shape decision from [section 2](#2-infrastructure-shapes), so it belongs in
planning rather than in a runbook.

### 5.1 Lame duck mode, which is the primitive for upgrading a cluster

A NATS server can be told to retire gracefully instead of stopping. The sequence,
per the NATS documentation at
<https://docs.nats.io/running-a-nats-service/nats_admin/lame_duck_mode>, is that
the server stops accepting new connections, waits out a grace period, and then
closes its existing client connections gradually over a configurable duration
before shutting down. Clients whose libraries support it also receive a
notification that the server is entering lame duck mode, which lets an
application prepare for the brief gap between being evicted and reconnecting
somewhere else. The point of the gradual eviction is that a thousand clients do
not all reconnect in the same millisecond.

The pieces, all verifiable in the NATS documentation:

- The signal is `nats-server --signal ldm`, which corresponds to `SIGUSR2`. Where
  more than one server runs on the host, the signal takes a target in the form
  `ldm=<pid>` or `ldm=/path/to/pidfile`.
- `lame_duck_grace_period` is how long the server waits after entering lame duck
  before it starts closing connections. It defaults to `10s`.
- `lame_duck_duration` is the period over which connections are then closed, after
  which the server exits. It defaults to `2m` and cannot be set below 30 seconds.
- The pidfile form of the signal needs a pidfile to exist. `pid_file` in the
  server configuration, or `-P` / `--pid` on the command line, is what writes one.

Lame duck is only useful when there is somewhere for the clients to go. On a
single node there is no surviving server to hand them to, so signalling it makes
the outage orderly and slightly longer rather than avoiding it. Its value is
entirely in the clustered shape.

**One thing to check before you rely on it here.** The Kubernetes manifest already
attempts this: the NATS container has a `preStop` hook that runs
`nats-server --signal ldm=/var/run/nats/nats.pid`, an `emptyDir` mounted at
`/var/run/nats` for the pidfile to live in, and `terminationGracePeriodSeconds:
75` to leave room for the handoff. Two gaps are visible in the same file. The
`nats.conf` in the ConfigMap sets no `pid_file`, and the container's arguments
pass no `-P`, so nothing ever writes the pidfile the hook names. And the default
`lame_duck_duration` of two minutes does not fit inside a 75 second grace period,
so even with the signal delivered Kubernetes would terminate the pod partway
through the handoff. Closing both means writing the pidfile and setting a
`lame_duck_duration` that fits the grace period you allow. Neither change has been
made or tested in this repository, so treat the hook as intent rather than as a
working feature, and verify it yourself on your own cluster before an upgrade
depends on it.

### 5.2 The hard restart, which is what the single-node shapes do

There is no graceful path on a single node, and the reference deployment does not
pretend otherwise. `docker compose restart nats`, or
`systemctl restart nats`, drops every client connection
([R4](operator-handbook.md#r4-restart-the-broker)). The handbook is right to call
this a small outage rather than a config refresh, and to say so next to the
command.

Three specifics that shape how bad it is. The services process reconnects on its
own and its reconnect attempts are unlimited, so the platform comes back without
intervention. Agents come back if their client reconnects, which the SDKs and the
reference adapter do. And **the reference systemd unit has no `ExecReload`**, so
`systemctl reload` does not work and restart is the only mechanism there; the
handbook notes that this is inference from the unit rather than documentation, and
that if you write your own unit you decide it
([section 8](operator-handbook.md#8-where-this-handbook-is-uncertain)).

Related, and worth knowing before you plan a maintenance window: no script in
either bundle ships broker configuration to a running broker. In Compose the
config is generated once and then yours; in Kubernetes it is a ConfigMap and a
Secret you edit. So every broker config change, including the account-JWT step of
a revocation, is a manual edit followed by a restart
([R12](operator-handbook.md#r12-revoke-a-credential-and-why-that-is-not-rotation)).

### 5.3 Upgrading the services and the console

With published images a deploy is a tag change, and a rollback is putting the old
tag back ([R5](operator-handbook.md#r5-deploy-services-agents-bridge-and-console),
[R6](operator-handbook.md#r6-roll-back-services-or-the-console)). The two images
are released together under one version deliberately, because they talk to each
other and independent version numbers would only create pairs nobody has tested.
Change both.

The planning consequence is that **the services tier has no zero-downtime path
today**, and it follows directly from
[section 4.3](#43-the-second-limit-the-services-tier-cannot-go-past-one-replica):
one replica means the swap is a gap, and you cannot close the gap by briefly
running two, because two would both answer every request.

On Kubernetes there is a specific interaction to plan for rather than discover.
The services Deployment declares no update strategy, so it takes the default
rolling update, which for a single replica permits one surplus pod. The new pod is
therefore created while the old one is still running, and the services state
volume is a `ReadWriteOnce` PersistentVolumeClaim, which only one node may mount
at a time. If the new pod schedules onto a different node, it cannot attach the
volume and the rollout stalls with the old pod still serving. Setting that
Deployment's strategy to `Recreate` trades the stall for a short, predictable gap,
which is the honest shape of the thing anyway given the replica limit. This
follows from reading the manifest rather than from a run that hit it, so verify it
on your own cluster.

If you are upgrading everything, the order that minimises noise is brokers first,
one at a time with lame duck if you are clustered, then the services and console
together, then agents and adapters
([R7](operator-handbook.md#r7-release-and-roll-the-adapter)). The services
reconnect to a restarted broker on their own, so the reverse order also works; it
just produces a stretch of reconnect noise in the logs that looks like a fault.

---

## 6. Verifying the install works

Do not invent your own acceptance test. Two already exist, and the second one has
a trap in it that is worth knowing about while you are still planning, because it
determines whether your CI tells you the truth.

**The manual checklist is in the handbook**, at
[2.5](operator-handbook.md#25-verify-it-is-actually-working): eight steps in
order, each ruling out one layer, from the health endpoint through to a real agent
answering. Run it in that order rather than sampling it. The two steps people skip
are steps 6 and 7, because they test for a **refusal** rather than a success:
whether the broker rejects a connection with no credential, and whether a guest
credential is actually denied the subjects that matter. Those two are the only
checks on the list that can catch a broker running with authentication switched
off, or a credential minted with the run of the account, and every other check
passes cheerfully in both of those states. Plan to run them.

**The conformance suites are public and separate from this bundle.** They live
with the protocol, at <https://github.com/jeffrschneider/agentmesh-protocol>,
under `conformance/core` and `conformance/peering`. Core exercises the protocol
against your mesh; peering exercises the two-mesh behaviour described in
[2.3](#23-more-than-one-region). Run them with
[R15](operator-handbook.md#r15-prove-the-deployment-is-behaving), which has the
exact invocation, the list of skips that are legitimate rather than failures, and
two prerequisites that are easy to trip over: `npm install` inside
`conformance/peering` is required even to run the core suite, and plain
`node run.mjs` exits 0 even when tests fail, so anything scheduled must pass
`--ci`.

**The trap, and it is the reason this is in a planning document.** Every endpoint
the suites need has a default, and **the defaults point at the reference
instance**, because that is what the suite develops against. Forget one export and
the run does not fail. It tests someone else's mesh, comes back green, and tells
you nothing. The symptom is a board that stays green while your own deployment is
down, which is worse than no board at all, because it is trusted. Newer runners
print a banner naming the endpoints under test; read the banner before you read
any result, and if it names a host that is not yours, fix your exports rather than
trusting the board. If you are wiring this into CI, assert on the endpoints you
expect rather than assuming the exports took.

One last planning decision that belongs here: **nothing in either bundle runs
either of these on a schedule.** "The mesh is behaving" is only as true as the
last time someone ran the suite, and the same goes for "the keystore backup
restores". Both have scripted answers and neither has a scheduler, so if either
matters to you, deciding who owns it and where it runs is part of standing the
mesh up rather than something to sort out later
([section 3](operator-handbook.md#3-what-you-owe-it)).
