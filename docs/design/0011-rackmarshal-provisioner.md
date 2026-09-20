<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0011 — rackmarshal-provisioner

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `rackmarshal-provisioner` is Rackmarshal's single desired-state authority. It stores versioned YAML
  documents, validates them with JSON Schema and embedded OPA, renders them with sandboxed Tengo, and
  reconciles every endpoint from a PostgreSQL work queue. Agents pull signed per-endpoint bundles, and
  agentless devices are enforced by in-process drivers.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 makes `rackmarshal-provisioner` the **single** desired-state authority with two enforcement paths
([Desired-state model](0001-project-repositories.md#desired-state-model--one-authority-two-enforcement-paths)).
It fixes the format as custom YAML with `apiVersion` and `kind`, OPA embedded as a Go library and checked
at write time and before dispatch, and Tengo with allowlisted pure modules, an allocation cap, and a
timeout ([Desired-state format](0001-project-repositories.md#desired-state-format)). Agents reach it only
through `rackmarshal-gateway`'s mutual-TLS agent ingress. Both paths converge against `rackmarshal-inventory`.

**Goals**

- One authoritative store of desired state per tenant, with history and optimistic concurrency.
- Deterministic rendering: the same documents and facts always produce the same bundle digest.
- Fail-closed policy at write time, before dispatch, and (via the bundle) on the host.
- Horizontally scalable reconciliation with no scheduler outside PostgreSQL.
- Agentless enforcement whose credentials never leave the provisioner's trust boundary.

**Non-goals**

- On-host enforcement, plugins, and host inventory collection — [0012](0012-rackmarshal-agent.md).
- The endpoint catalog and reported inventory — [0009](0009-rackmarshal-inventory.md).
- Token formats, roles, and tenancy records — [0006](0006-rackmarshal-identity.md); routing and principal
  propagation — [0008](0008-rackmarshal-gateway.md).
- Deploying Rackmarshal itself — [0005](0005-rackmarshal-infrastructure.md).

## Proposal

### Responsibilities

- **Document store** — CRUD, validation, revisions, and audit for desired-state documents.
- **Targeting** — resolve label selectors against `rackmarshal-inventory` into per-endpoint desired state.
- **Rendering and policy** — Tengo `render` scripts, JSON Schema validation, OPA `admission` and
  `dispatch` policies.
- **Dispatch** — signed directive bundles for agent endpoints; plan, apply, and verify for agentless ones.
- **Drift** — compare desired state with agent reports, observed device state, and inventory facts.

### Interfaces

#### Document model

Kinds in `rackmarshal.servercurio.com/v1alpha1`. [0020](0020-desired-state-kinds.md) specifies every field,
and the Go types carrying them live in [0002](0002-rackmarshal-api-schema.md), which generates the OpenAPI
components and reference material from those types rather than from hand-written schema files:

| Kind               | Purpose                                                                         |
|--------------------|---------------------------------------------------------------------------------|
| `DirectiveSet`     | A named set of resources, a target selector, a mode (`enforce` or `audit`)      |
| `Policy`           | A Rego module with a phase: `admission`, `dispatch`, or `host`                  |
| `Script`           | Tengo source with a phase (`render` or `host`), declared inputs, and limits     |
| `DeviceConnection` | Driver, address, pinned TLS or SSH identity, and a credential reference         |
| `Plugin`           | A plugin's artifacts at one version: agent half, required bundle, optional service |
| Resource kinds     | `File`, `Package`, `Service`, … for hosts; driver-defined kinds for devices     |

Every resource inside a `DirectiveSet` is itself an `apiVersion`/`kind` document, so one validator
covers both levels:

```yaml
apiVersion: rackmarshal.servercurio.com/v1alpha1
kind: DirectiveSet
metadata: { name: web-baseline, labels: { team: web } }
spec:
  mode: enforce
  target: { selector: { matchLabels: { role: web } } }
  resources:
    - apiVersion: rackmarshal.servercurio.com/v1alpha1
      kind: File
      metadata: { name: nginx-conf }
      spec:
        path: /etc/nginx/nginx.conf
        mode: "0644"
        content: { scriptRef: nginx-conf-render, inputs: { workers: 4 } }
      dependsOn: [nginx]
```

- **Decoding** — `go.yaml.in/yaml/v3` into `yaml.Node`; reject alias nodes (`AliasNode`), documents over
  1 MiB, and unknown top-level fields; convert to JSON; validate with `santhosh-tekuri/jsonschema/v6`.
- **Conflicts** — two sets that target one endpoint with the same `kind` and `metadata.name` are a
  conflict reported at plan time, never resolved by last writer wins.
- **Enforcement path** — each endpoint's path (`agent` or `agentless`) comes from `rackmarshal-inventory`.
  Admission rejects host kinds targeted at agentless endpoints and device kinds at agent endpoints.
- **Conversion** — the provisioner stores documents as written and converts between `apiVersion`s in
  Go when a newer version exists (0002 assigns conversion here).

#### HTTP API (generated to `gen/openapi/provisioner/v1alpha1/openapi.yaml`)

| Method and path                                                  | Audience   | Notes                              |
|------------------------------------------------------------------|------------|------------------------------------|
| `GET, POST /provisioner/v1alpha1/directive-sets`                 | `operator` | list, create                       |
| `GET, PUT, DELETE /provisioner/v1alpha1/directive-sets/{id}`     | `operator` | `PUT` requires `If-Match`          |
| `… /provisioner/v1alpha1/policies`, `/scripts`, `/device-connections` | `operator` | same shape as directive sets  |
| `POST /provisioner/v1alpha1/plans`                               | `operator` | dry run: affected endpoints, diff  |
| `GET /provisioner/v1alpha1/endpoints/{endpointId}/desired-state` | `operator` | rendered, secrets redacted         |
| `GET /provisioner/v1alpha1/endpoints/{endpointId}/status`        | `operator` | generation, drift, conditions      |
| `POST /provisioner/v1alpha1/reconciliations`                     | `operator` | enqueue; `x-rackmarshal-idempotent`      |
| `GET /provisioner/v1alpha1/directive-bundles/current`            | `agent`    | long poll, see below               |
| `POST /provisioner/v1alpha1/enforcement-reports`                 | `agent`    | `x-rackmarshal-idempotent` by `reportId` |

Writes return an `ETag` of the document generation and accept `If-Match`
([RFC 9110](https://www.rfc-editor.org/rfc/rfc9110#name-conditional-requests)). Validation and policy
failures are `422` problems with `errors[]` pointers and codes such as `policy_denied`.

#### Directive bundles and how agents get them

Agents pull; the provisioner never connects to hosts. `GET …/directive-bundles/current` has no agent ID
in the path — the provisioner takes it from the verified SPIFFE ID the gateway forwards (0008), so one
agent cannot request another's bundle. The agent sends `If-None-Match: "<digest>"` and
`?waitSeconds=0..60`. The response is `304` or `200` with the bundle and an `ETag` of its digest.

The bundle is a [DSSE](https://github.com/secure-systems-lab/dsse/blob/master/envelope.md) envelope
(payload type `application/vnd.rackmarshal.directive-bundle.v1alpha1+json`) plus the signer's certificate
chain. It is signed with the provisioner's own service key, whose certificate carries
`spiffe://<environment-id>/service/rackmarshal-provisioner`. The payload holds `environmentId`, `tenantId`,
`endpointId`, `agentId`, a per-endpoint monotonic `generation`, `issuedAt`, `notAfter` (default 7
days), `mode`, rendered resources, `host`-phase policies and scripts, and plugin pins (name, version,
SHA-256, and publisher identity) taken only from verified plugin imports (below). 0001 relies on this
signature for plugin pins.

Two environment-wide fields ride along for core plugins ([0012](0012-rackmarshal-agent.md)): `coreKeyId`,
naming the embedded core public key agents treat as current, and `coreRevocations`, a list of core key
IDs and plugin digests. `coreRevocations` is signed by the other embedded core key and copied into the
payload verbatim, so a compromised provisioner can neither rackmarshal a revocation nor drop one an agent has
already recorded. `coreKeyId` carries only the provisioner's signature, but an agent accepts it solely
when it names a key the agent already embeds and never moves it backwards, so the worst a compromised
provisioner achieves is retiring the current key early — a denial of service that fails closed, not a
route to an attacker's key.
OPA on the host catches a stale or out-of-policy directive,
and the signature lets the agent reject one forged by a compromised gateway. DSSE needs only
standard-library ECDSA and an estimated (unmeasured) 50 lines of code, so it adds no module.

#### Plugin release verification

Plugin signatures are verified here at import, and again on each host by the core `sigstore` validator
plugin before install ([0001](0001-project-repositories.md#agent-plugin-ecosystem)). A host installs a
non-core plugin only when its digest matches a pin in a bundle this service signs and the validator
accepts its signature for the pin's publisher identity
([0012](0012-rackmarshal-agent.md#sigstore-verifier-measurements) records why the agent binary links no
verifier).

- **Import** — creating or updating a `Plugin` ([0014](0014-rackmarshal-agent-plugins.md)) downloads
  `plugins-index.json`, the plugin manifest, and each listed asset's `.sigstore.json` bundle, and
  verifies them with [sigstore-go](https://github.com/sigstore/sigstore-go) `pkg/verify` against the
  referenced `PluginPublisher`: the keyless issuer and structured identity (repository, workflow, and
  ref) or its public key, a transparency-log entry, and an SCT for keyless certificates. Each asset
  digest must equal both its index entry and the `Plugin` pin.
- **Bundle** — every `Plugin` carries a provisioner bundle, and a document without one fails import
  ([0021](0021-plugin-extensibility.md)). The bundle is verified like any other asset and then checked
  against the plugin it belongs to: a `resource:` capability with no matching schema fails
  `schema_missing`, and a schema with no matching capability fails `schema_unclaimed`, so a bundle can
  neither leave a declared kind unvalidated nor smuggle a definition for a kind the plugin was never
  granted. Its schemas and compiled policy land in `plugin_bundles`.
- **Record** — verified digests, signer identity, Rekor log index, and integrated time go into
  `plugin_verifications`, one row per artifact, and the audit log. Only verified digests can appear as
  plugin pins in a bundle; anything else fails admission with `plugin_not_verified`.
- **Pins** — each bundle pin carries the plugin name, version, per-platform SHA-256, and the publisher
  identity verified at import: the keyless issuer, repository, workflow, and refs, or the public key.
  The host validator checks the same identity before install ([0012](0012-rackmarshal-agent.md)).
- **Core plugins** — `sigstore` and `sysfacts` ship in agent packages and are trusted through the
  core-plugin key embedded in the agent (0012); a pin for a newer core release also needs its core-signed
  envelope on the host ([0014](0014-rackmarshal-agent-plugins.md)).
- **Trusted root** — proposed: refresh `trusted_root.json` through Sigstore's TUF repository
  (sigstore-go `pkg/tuf`), with a packaged fallback for air-gapped environments.
- **Withdrawal** — removing a `Plugin` version or its `PluginPublisher` drops its pins from the
  next bundle generation, so agents stop launching it once they accept that generation.

#### Reconciliation loop

Level-triggered and idempotent, modeled on Kubernetes controllers
([API conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md)):

1. **Enqueue** an endpoint when a targeting document changes, its inventory labels or facts change, an
   agent reports drift or failure, or the resync interval (default 15 minutes) elapses.
2. **Lease** — workers claim rows with `SELECT … FOR UPDATE SKIP LOCKED`
   ([PostgreSQL](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)) and set
   `lease_expires_at`, so replicas share the queue and a crashed worker's lease lapses.
3. **Resolve** matching `DirectiveSet`s and the endpoint's facts from `rackmarshal-inventory`.
4. **Render** `render`-phase scripts, validate every resource against its schema, and evaluate
   `dispatch` policies. Any error, timeout, or `deny` stops the endpoint with a condition.
5. **Dispatch** — for an agent, store a new signed bundle only if the digest changed. For agentless
   devices, run the driver's `Observe` → `Plan` → `Apply` → `Observe`.
6. **Record** status and requeue failures with exponential backoff (cap 30 minutes).

Inventory changes arrive by polling a change cursor from [0009](0009-rackmarshal-inventory.md) (to be agreed);
until it exists, the resync interval covers them.

#### Policy (OPA)

- **Library** — `github.com/open-policy-agent/opa/v1/rego` v1.20.2. Modules compile once per tenant
  revision with `PrepareForEval`; each evaluation gets a context deadline (default 500 ms), which
  `rego` turns into a topdown cancel.
- **Contract** — packages `rackmarshal.admission`, `rackmarshal.dispatch`, and `rackmarshal.host`; each defines
  `deny contains {"code": …, "message": …}`. Input is `document`, `principal`, `tenant`, `environment`
  (`id`, `name`, `tier`), `endpoint` (`id`, `labels`, `facts`), and `now`. Errors, timeouts, and
  non-set results deny.
- **Layers** — platform policies embedded in the binary are evaluated first and cannot be disabled by
  tenants; plugin policies from each verified provisioner bundle follow
  ([0021](0021-plugin-extensibility.md)); tenant `Policy` documents last. All three must allow.
- **Plugin scoping** — a plugin's policy is evaluated only against resources whose kind is in the
  `resource:` capabilities that plugin was granted, and the service filters `input` before evaluation
  rather than trusting the policy to scope itself. A plugin policy may only define `deny`, so installing
  a plugin can never widen what the platform or a tenant allows. Plugin modules compile once per plugin
  version alongside the tenant's and are cached with the rest of that version's verified artifacts.
- **Builtins** — `rego.Capabilities` removes `http.send`, `net.lookup_ip_addr`, `opa.runtime`,
  `rand.intn`, `uuid.rfc4122`, and `time.now_ns` (time comes from `input.now`), so a policy using them
  fails to compile. `rego.StrictBuiltinErrors(true)`; print statements only in `development`.

```rego
package rackmarshal.admission

deny contains {"code": "command_denied", "message": msg} if {
	input.environment.tier == "production"
	some r in input.document.spec.resources
	r.kind == "Command"
	msg := sprintf("Command %q is not allowed in production", [r.metadata.name])
}
```

#### Scripts (Tengo)

- **Library** — `github.com/d5/tengo/v2` at pseudo-version `v2.17.1-0.20260429084800-8daf696551f2`.
  The newest tag, `v3.0.0`, still declares module `github.com/d5/tengo/v2`, so Go refuses it; v2.17.0
  (2024-02-29) lacks later fixes such as regex alternation (#460) and `int == float` (#477).
- **Sandbox** — `SetImports(stdlib.GetModuleMap("text", "math", "json", "base64", "hex", "enum"))`;
  `EnableFileImport(false)`; no `os`, `fmt` (prints), `times`, or `rand` (non-deterministic).
  `SetMaxAllocs(100000)`, `SetMaxConstObjects(10000)`, source up to 64 KiB, output up to 1 MiB, and
  `RunContext` with a 2 s deadline by default. Compiled scripts are cached and `Clone`d per run.
- **Host functions** — a `rackmarshal` module with `facts()` (immutable endpoint facts), `input()`, and
  `fail(message)`. Results must be JSON-encodable and are schema-validated like any other resource.

#### Plugin host

Optional, and behind a build tag: a plugin's required bundle is validated and evaluated with the
jsonschema, OPA, and sigstore-go this service already links, so the default build policies every plugin
kind while linking no gRPC at all. Only a plugin that ships a provisioner service needs the host, which
brings 0013's go-plugin and gRPC stack with it ([0021](0021-plugin-extensibility.md)).

A provisioner service runs as a separate process, never in this address space: a sidecar container on
`kubernetes`, a `rackmarshal-provisioner-plugin-<name>.service` unit on `package`, an SCM service on
`windows`, each on a local socket or named pipe that binds no port. It receives a capability grant
(`validate`, `interpret`, `propose`) the same way an agent half does, holds no database credentials, and
has no network grant by default.

`InterpretResult` runs after a report is accepted and validated, and its conditions merge into
`endpoint_status`. `Propose` output is desired state like any other: it is written as a
`document_revisions` entry attributed to the plugin and must pass admission, the plugin's own policy, and
the tenant's before it can be dispatched. A plugin proposes; it never applies.

Each replica runs its own plugin processes, and work reaches one only through the replica already holding
that row's lease, so plugins add no coordination beyond
[the reconciliation queue](CONVENTIONS.md#running-multiple-replicas).

#### Agentless drivers

```go
type Driver interface {
	Kinds() []string // resource kinds this driver enforces
	Observe(ctx context.Context, c Connection, rs []Resource) ([]Observed, error)
	Plan(ctx context.Context, desired []Resource, observed []Observed) (Plan, error)
	Apply(ctx context.Context, c Connection, p Plan) (Result, error)
}
```

- **Built in, compiled in** — `http` (REST and JSON device and cloud APIs on `net/http`), `ssh` (CLI
  over `golang.org/x/crypto/ssh`), and `netconf` ([RFC 6241](https://www.rfc-editor.org/rfc/rfc6241) over
  SSH on `encoding/xml`). A new built-in driver needs its own design note with its dependency cost; a
  third party extends the service through a plugin instead ([0021](0021-plugin-extensibility.md)).
- **Safety** — one lease per device, a per-connection concurrency cap, and per-call timeouts.
  `DirectiveSet.spec.mode: audit` runs `Observe` and `Plan` only.
- **Observed state** is written back to `rackmarshal-inventory` through its `internal` API (0009), so both
  enforcement paths converge against one catalog.

### Dependencies

- **Rackmarshal** — `rackmarshal-api-schema` (models, schemas, embedded document), `rackmarshal-sdk` (`pkg/tlsconfig`,
  `pkg/revocation`, `pkg/enroll` for the service certificate, and the inventory client), `rackmarshal-common`
  (`logging`, `environment`, `telemetry`).
- **Starter** — Echo v5, pgx v5, bun, goose, as in `go-echo-starter`. Replace the starter's direct
  `gopkg.in/yaml.v3` with `go.yaml.in/yaml/v3` v3.0.5, which the starter already lists as indirect and
  OPA links anyway, so there is one YAML library.
- **New, measured** on 2026-09-15 with throwaway `linux/amd64` modules (`CGO_ENABLED=0`, stripped),
  counting modules in `go list -deps`:

| Module                                | Version        | Linked modules | Binary   | Notes                             |
|---------------------------------------|----------------|----------------|----------|-----------------------------------|
| `open-policy-agent/opa/v1/rego`       | v1.20.2        | 26             | 22.0 MiB | 127 in `go list -m all`           |
| `d5/tengo/v2`                         | pseudo-version | 1              | 3.4 MiB  | no requirements                   |
| `santhosh-tekuri/jsonschema/v6`       | v6.0.3         | +1 (`x/text`)  | —        | already chosen in 0002            |
| All three                             | —              | 29             | 23.5 MiB | no gRPC                           |
| `sigstore/sigstore-go` (`pkg/verify`) | v1.3.0         | 71             | —        | 367 in `go list -m all`; see 0012 |

**OPA is heavy — flagged.** Its 26 modules include `lestrrat-go/jwx/v3` and five more `lestrrat-go`
modules (for `io.jwt` builtins), `sirupsen/logrus`, `rcrowley/go-metrics`, `vektah/gqlparser/v2` (GraphQL
builtins), `google.golang.org/protobuf`, and `sigs.k8s.io/yaml`. The `opa_no_oci` build tag did not
change the count. 0001 settles on the OPA library, so the lighter Wasm route is only listed under
Alternatives.

**sigstore-go is heavy — flagged, and confined here.** Its verifier compiles in 71 modules, including
23 `go-openapi` modules, OpenTelemetry, and gRPC (through Rekor v2 types, without serving or calling any
gRPC API); [0012](0012-rackmarshal-agent.md#sigstore-verifier-measurements) records the measurement and import
chains. It is accepted in this service and in the core `sigstore` validator plugin
([0014](0014-rackmarshal-agent-plugins.md)), so the agent binary and other plugins never link it. The combined
set with
OPA, Tengo, and jsonschema is not measured yet; the module allowlist records it.

### Data & storage

PostgreSQL through the starter's pgx, bun, and goose. Every table has `tenant_id` first in its primary
key.

| Table                  | Contents                                                                                   |
|------------------------|--------------------------------------------------------------------------------------------|
| `documents`            | `id`, `api_version`, `kind`, `name`, `generation`, `spec` (jsonb), `labels`, `sha256`      |
| `document_revisions`   | append-only copies of every accepted generation, with author and request ID                |
| `endpoint_targets`     | materialized selector matches: endpoint → documents                                        |
| `directive_bundles`    | `endpoint_id`, `generation`, `digest`, `envelope` (bytea), `not_after`; last 10 kept       |
| `reconcile_queue`      | `endpoint_id`, `reason`, `due_at`, `lease_owner`, `lease_expires_at`, `attempts`           |
| `endpoint_status`      | path, `applied_generation`, drift (`in_sync`, `drifted`, `failed`, `unknown`), conditions  |
| `enforcement_reports`  | monthly partitions, 30-day retention; digests of observed state, plus bounded `result_json` |
| `plugin_verifications` | `plugin_id`, `artifact`, `platform`, `sha256`, signer identity, Rekor log index, integrated time |
| `plugin_bundles`       | per plugin version: verified schemas and compiled policy, keyed by bundle digest            |
| `audit_events`         | append-only: principal, action, document, policy decision                                  |

#### Scaling

N replicas, nothing elected. Reconciliation was designed for this from the start — workers claim
`reconcile_queue` rows with `SELECT … FOR UPDATE SKIP LOCKED` and a lease that lapses on its own if the
worker dies (see Reconciliation above), which is the per-item queue primitive in
[CONVENTIONS](CONVENTIONS.md#running-multiple-replicas). Two consequences that were implicit are worth
stating:

- **`directive_bundles` pruning** ("last 10 kept") happens inline on the write that adds the eleventh,
  inside the transaction that already holds that endpoint's lease. It is not a background job, so it
  needs no separate claim.
- **`enforcement_reports` partition creation** is scheduled work and would otherwise race: N replicas
  would each try to create next month's partition, and all but one would fail on the duplicate
  relation. It takes `pg_try_advisory_lock` and skips the tick when another replica holds it, running
  far enough ahead of the month boundary that a skipped tick is harmless.

**Plugin results.** `enforcement_reports` carries a bounded `result_json` beside the observed digest
([0021](0021-plugin-extensibility.md)). The rule that replaces "never content" is *never file content;
bounded plugin results, validated against the schema in the plugin's bundle* — the control it was always
providing, without foreclosing a structured result. The payload is validated on receipt, before
`InterpretResult` sees it, and an invalid one is stored as a resource-level failure rather than
rejecting the report. Results are tenant data and are handled as 0009 handles facts: never logged, never
in a metric label, only size and digest in a span.

Credentials for devices are **never** stored here or in bundles: `credentialRef` names a secret that a
`SecretProvider` resolves at apply time. The first provider reads files mounted by
`rackmarshal-infrastructure`.

A `credentialRef` is resolved within the writing tenant only: the provider reads
`<secrets.directory>/<tenantId>/<name>`, rejects any `name` containing a path separator or `..`, and
refuses a reference from a different tenant even when the file exists. Without that scoping a tenant
could name another tenant's device credential and receive it at apply time. The same process evaluates
tenant-authored Rego and Tengo, so credentials are resolved in the driver at apply time and never
placed in a policy input, a script value, or a rendered resource.

### Security

- **Multi-tenancy** — the tenant comes from the verified principal, as 0002 proposes. Every repository
  method requires a tenant ID, and PostgreSQL
  [row-level security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html) with
  `SET LOCAL rackmarshal.tenant_id` per transaction is defense in depth.
- **RBAC hooks** — the gateway authorizes each operation (0008). The provisioner additionally checks
  permissions such as `provisioner.policies.write` from the forwarded principal (format per 0006), and
  passes `principal` to `admission` policies for finer rules. Writing `Policy` and `Script` documents is
  a separate permission from writing `DirectiveSet`s.
- **Untrusted input** — size limits, alias rejection, strict schemas, OPA capability filtering, and the
  Tengo sandbox above; fuzzing covers YAML decoding and DSSE parsing.
- **Signing** — the bundle key is the renewing service key from `pkg/enroll`; it never leaves the
  process. Agents verify the chain and SPIFFE ID ([0012](0012-rackmarshal-agent.md)).
- **Plugin releases** — Sigstore verification runs at import in this service, and again on hosts in the
  core validator against the identity in each pin (0012). `PluginPublisher` documents are audited like
  policies, and writing them is a separate permission from `Plugin`.
- **Devices** — TLS verification is mandatory and SSH host keys are pinned in `DeviceConnection`.
  Skipping either is the last-resort feature `insecure-device-transport`.

### Environment awareness

Requires `name`, `tier`, `id`, and `caBundle` (it serves and makes mutual-TLS connections). Bundles carry
`environmentId`, and agents reject any other. `DeviceConnection`s are per environment and never copied
between them.

| Setting                        | `production` / `staging`           | `test` / `development`     |
|--------------------------------|------------------------------------|----------------------------|
| Script and policy limit ceilings | fixed at defaults                | may be raised              |
| Rego print statements          | off                                | `development` only         |
| `insecure-device-transport`    | refused in `production` unless overridden | allowed, logged     |
| OpenAPI UI                     | off                                | on                         |

### Logging & telemetry

Through `rackmarshal-common`. Fields `rackmarshal.tenant.id`, `rackmarshal.endpoint.id`, `rackmarshal.document.id`,
`rackmarshal.bundle.generation`, and `rackmarshal.policy.decision`; specs and rendered content are logged only as
digests. Metrics: `rackmarshal.provisioner.reconcile.duration`, `rackmarshal.provisioner.queue.depth`,
`rackmarshal.provisioner.policy.duration`, `rackmarshal.provisioner.script.duration`, and
`rackmarshal.provisioner.endpoints.drifted`.

### Configuration

Prefix `RACKMARSHAL_PROVISIONER_`, plus the starter's `server` and `database` blocks and the library blocks
from [CONVENTIONS.md](CONVENTIONS.md).

| YAML                         | Variable                                         | Default                      |
|------------------------------|--------------------------------------------------|------------------------------|
| `reconcile.workers`          | `RACKMARSHAL_PROVISIONER_RECONCILE_WORKERS`            | `8`                          |
| `reconcile.resyncInterval`   | `RACKMARSHAL_PROVISIONER_RECONCILE_RESYNC_INTERVAL`    | `15m`                        |
| `plugins.enabled`            | `RACKMARSHAL_PROVISIONER_PLUGINS_ENABLED`              | `true`                       |
| `plugins.socketDir`          | `RACKMARSHAL_PROVISIONER_PLUGINS_SOCKET_DIR`           | `/run/rackmarshal-provisioner/plugins` |
| `plugins.startTimeout`       | `RACKMARSHAL_PROVISIONER_PLUGINS_START_TIMEOUT`        | `30s`                        |
| `plugins.callTimeout`        | `RACKMARSHAL_PROVISIONER_PLUGINS_CALL_TIMEOUT`         | `10s`                        |
| `plugins.result.maxBytes`    | `RACKMARSHAL_PROVISIONER_PLUGINS_RESULT_MAX_BYTES`     | `16384`                      |
| `reconcile.leaseDuration`    | `RACKMARSHAL_PROVISIONER_RECONCILE_LEASE_DURATION`     | `60s`                        |
| `policy.evalTimeout`         | `RACKMARSHAL_PROVISIONER_POLICY_EVAL_TIMEOUT`          | `500ms`                      |
| `script.maxAllocs`           | `RACKMARSHAL_PROVISIONER_SCRIPT_MAX_ALLOCS`            | `100000`                     |
| `script.timeout`             | `RACKMARSHAL_PROVISIONER_SCRIPT_TIMEOUT`               | `2s`                         |
| `bundle.validity`            | `RACKMARSHAL_PROVISIONER_BUNDLE_VALIDITY`              | `168h`                       |
| `bundle.maxWait`             | `RACKMARSHAL_PROVISIONER_BUNDLE_MAX_WAIT`              | `60s`                        |
| `inventory.url`              | `RACKMARSHAL_PROVISIONER_INVENTORY_URL`                | required                     |
| `secrets.directory`          | `RACKMARSHAL_PROVISIONER_SECRETS_DIRECTORY`            | required if devices are used |
| `plugins.trustedRootFile`    | `RACKMARSHAL_PROVISIONER_PLUGINS_TRUSTED_ROOT_FILE`    | packaged fallback            |
| `plugins.tufRefreshInterval` | `RACKMARSHAL_PROVISIONER_PLUGINS_TUF_REFRESH_INTERVAL` | `24h`                        |

### Build, release & versioning

Bootstrap from `go-echo-starter`, replacing its logging with `rackmarshal-common` and its route-metadata
OpenAPI with the embedded contract from 0002. Binary `rackmarshal-provisioner`, shipped as the
[CONVENTIONS.md](CONVENTIONS.md#deployment-artifacts) deployment artifacts: the starter's Dockerfile and
Helm chart (with the enrollment init container), signed deb and rpm packages, and a Windows installer.
Database migrations are forward-only goose files; bundles are versioned by payload type so agents can
support the current and previous `apiVersion`.

### Testing

- **Policy** — Rego unit tests for embedded platform policies with `opa test`, run as
  `go run github.com/open-policy-agent/opa@v1.20.2 test`.
- **Sandbox** — importing `os`, file imports, allocation exhaustion, infinite loops, and oversized output
  must all fail.
- **Determinism** — rendering the same fixture twice yields the same digest.
- **Reconciliation** — integration tests on a disposable PostgreSQL: lease expiry, two workers, backoff,
  and selector changes.
- **Drivers** — `httptest` and an in-process `x/crypto/ssh` server. Contract tests against the OpenAPI
  document, fuzzing, `-race`, and the module allowlist.
- **Plugin verification** — a wrong identity, wrong digest, missing log entry, or unknown trusted root
  fails import, and no bundle may carry an unverified pin or a pin without its publisher identity.

## Alternatives considered

- **OPA compiled to Wasm and run on [wazero](https://github.com/tetratelabs/wazero)** — v1.12.0 links
  2 modules (`wazero`, `x/sys`) instead of 26, but Rackmarshal would own the OPA Wasm ABI and non-Wasm builtins
  ([OPA Wasm](https://www.openpolicyagent.org/docs/wasm)), and the official Go SDK
  [`golang-opa-wasm`](https://github.com/open-policy-agent/golang-opa-wasm) is archived. It also departs
  from 0001's "OPA as a Go library" decision.
- **Push to agents** (provisioner connects out or holds streams) — needs a route to hosts and long-lived
  connections through the gateway; pull with long polling fits the agent ingress.
- **Unsigned bundles relying on mutual TLS** — a compromised gateway could rackmarshal directives that OPA
  might still allow.
- **On-host verification only** — without an import check, an unverifiable release could be pinned and
  would fail on every host instead of at admission; see
  [0012](0012-rackmarshal-agent.md#sigstore-verifier-measurements).
- **Out-of-process drivers over go-plugin, in this process** — isolates faults, but would bring gRPC into
  the service's own address space. [0021](0021-plugin-extensibility.md) instead runs a plugin service as a
  separate process on a local socket, which keeps the isolation; the
  [API style convention](CONVENTIONS.md#api-contract-and-style) was widened to cover a host and its
  plugins rather than read around.
- **A job queue library such as River** — more features, but a dependency for what `SKIP LOCKED` does.
- **CUE or Jsonnet instead of Tengo** — ruled out by 0001.
- **Tengo v2.17.0 tag** — a clean tag, but missing fixes; kept as the fallback.

## Open questions

- **Inventory change feed** — cursor polling (proposed), or does 0009 call the provisioner?
- **Principal propagation** — the header or token the gateway forwards, and the permission names (0006,
  0008).
- **Secret providers** beyond mounted files — Vault, cloud secret managers?
- **Plugin build tag** — is the tagged plugin host on or off in released artifacts, given that every
  plugin is policed from its bundle either way ([0021](0021-plugin-extensibility.md))?
- **Proposal loops** — a plugin whose `Propose` output produces a report that produces another proposal.
  A generation cap and a depth limit are the obvious controls; which, and what value?
- **Bundle validity** — is 7 days right for offline agents, and should it be per tenant?
- **Tengo maintenance** — pin upstream pseudo-versions, or fork under `servercurio`?
- **Approvals** — do `production` changes need a second approver before dispatch?
- **Air-gapped trusted root** — who approves updates to the packaged `trusted_root.json` fallback, and
  how often?

## References

- [0001 — Project Repositories](0001-project-repositories.md), [CONVENTIONS.md](CONVENTIONS.md),
  [0002](0002-rackmarshal-api-schema.md), [0003](0003-rackmarshal-sdk.md), [0004](0004-rackmarshal-common.md).
- [OPA Go integration](https://www.openpolicyagent.org/docs/integration) and
  [`v1/rego`](https://pkg.go.dev/github.com/open-policy-agent/opa/v1/rego) — `PrepareForEval`,
  `Capabilities`, `StrictBuiltinErrors`, `EnablePrintStatements`; source read at v1.20.2.
- [OPA releases](https://github.com/open-policy-agent/opa/releases) — v1.20.2, 2026-09-03.
- [Tengo](https://github.com/d5/tengo) and [`tengo/v2`](https://pkg.go.dev/github.com/d5/tengo/v2) —
  `SetMaxAllocs`, `RunContext`, `EnableFileImport`, `stdlib.GetModuleMap`;
  [v3.0.0 `go.mod`](https://github.com/d5/tengo/blob/v3.0.0/go.mod) declares `/v2`.
- [santhosh-tekuri/jsonschema](https://github.com/santhosh-tekuri/jsonschema).
- [`go.yaml.in/yaml/v3`](https://pkg.go.dev/go.yaml.in/yaml/v3) — `Node` and `AliasNode`.
- [DSSE envelope](https://github.com/secure-systems-lab/dsse/blob/master/envelope.md) and
  [protocol](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md).
- [sigstore-go](https://github.com/sigstore/sigstore-go) —
  [`verify`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/verify) and
  [`tuf`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf) packages; measured in 0012.
- [0021 — Plugin extensibility](0021-plugin-extensibility.md) — the `Plugin` document, the required
  provisioner bundle, the plugin host, and the result round trip.
- [PostgreSQL `FOR UPDATE SKIP LOCKED`](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)
  and [row security policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html).
- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) — conditional requests;
  [RFC 6241](https://www.rfc-editor.org/rfc/rfc6241) — NETCONF.
- [Kubernetes API conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md).
- [wazero](https://github.com/tetratelabs/wazero), [OPA Wasm](https://www.openpolicyagent.org/docs/wasm),
  [golang-opa-wasm](https://github.com/open-policy-agent/golang-opa-wasm) (archived).
- [River](https://github.com/riverqueue/river) — PostgreSQL job queue named in alternatives.
- [go-echo-starter](https://github.com/servercurio/go-echo-starter) — Echo v5, pgx, bun, goose; `go.mod`.
