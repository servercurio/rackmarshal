<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0020 — Desired-state kinds

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-18
- **Summary:** One catalogue specifying every desired-state kind field by field. It is the design input
  the Go structures are first written from; once those structures exist they are the single source, and
  the OpenAPI 3.0 component schemas and the reference documentation are generated from them. There are
  no standalone JSON Schema files. This reverses the contract-first direction
  [0002](0002-rackmarshal-api-schema.md) proposed, and amends it.

> An initial draft. The kinds themselves were proposed in [0011](0011-rackmarshal-provisioner.md); this
> document specifies them. Conventions other repositories depend on are summarized in
> [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

The desired-state kinds were named in 0011 — `DirectiveSet`, `Policy`, `Script`, `DeviceConnection`, and
the resource kinds beneath them — with one line of description each and a single worked example. Their
schemas were given a home in 0002 at `schemas/<group>/<version>/<kind>.schema.json`. Between the two,
nothing ever specified a field.

That gap has already produced a defect. The portal's directive wizard ([0017](0017-rackmarshal-portal.md))
generates a `DirectiveSet`, and it was written by inferring the shape from 0011's one example. The YAML
it produces is plausible rather than verified, because there was nothing to verify it against.

**Goals**

- Specify every kind and every field in one place, precisely enough to write the Go structures from.
- Record the invariants a type cannot carry — conflicts, ordering, tenancy, phase restrictions.
- Fix the generation direction so that no two artefacts describing a kind can disagree.

**Non-goals**

- API operations, paths, and responses — [0002](0002-rackmarshal-api-schema.md).
- How the provisioner renders, validates, and dispatches documents — [0011](0011-rackmarshal-provisioner.md).
- Plugin-defined resource kinds, whose schemas travel in the plugin's required provisioner bundle —
  [0021](0021-plugin-extensibility.md); the wire contract that carries them is
  [0013](0013-rackmarshal-agent-plugin-sdk.md).
- Inventory's endpoint and class schemas, which are a different tree — [0009](0009-rackmarshal-inventory.md).

## Proposal

### Where the truth lives

Two phases, and the distinction matters more than anything else in this document.

**Bootstrap.** This catalogue is the specification. The Go types in `rackmarshal-api-schema` under
`pkg/desiredstate/v1alpha1` are written from it, by hand, once. That repository holds the shared types
for service APIs, OPA, and these manifests ([0002](0002-rackmarshal-api-schema.md)).

**Steady state.** The Go types are the single source of truth. Everything else is generated:

| Artefact                                | Generated from | Drift check                    |
|-----------------------------------------|----------------|--------------------------------|
| OpenAPI 3.0 component schemas for kinds | Go types       | regenerate in CI, fail on diff |
| Reference documentation for each kind   | Go types       | regenerate in CI, fail on diff |
| This document's field tables            | Go types       | regenerate in CI, fail on diff |

There are no standalone JSON Schema files. A kind is described by its Go type and nothing else, which
is the whole point: a second description is a second thing to disagree with.

The last row is the one that keeps this document honest. Once the types exist, the field tables below
are regenerated from them rather than maintained by hand, so the catalogue cannot drift from the code
the way the schemas and the wizard already drifted from each other. What stays hand-written here is
everything a struct tag cannot carry: the rationale, and the invariants in
[Invariants](#invariants-a-type-cannot-carry).

**What this costs.** 0002 originally chose contract-first so that `rackmarshal-sdk`, the gateway, and
the first services could start in parallel from a hand-written document. Under this direction the types
must exist first instead — and they can, because they live in `rackmarshal-api-schema` rather than in
any service, and every consumer imports that one module. The parallelism survives; its starting point
moves from a YAML document to a Go package.

### The document envelope

Every desired-state document carries the same four top-level fields.

| Field        | Type                | Required | Notes                                                  |
|--------------|---------------------|----------|--------------------------------------------------------|
| `apiVersion` | string              | yes      | `rackmarshal.servercurio.com/v1alpha1`                  |
| `kind`       | string              | yes      | One of the kinds below                                  |
| `metadata`   | `ObjectMeta`        | yes      |                                                         |
| `spec`       | kind-specific       | yes      | Shape determined by `kind`                              |

`ObjectMeta`:

| Field         | Type                | Required | Notes                                                  |
|---------------|---------------------|----------|--------------------------------------------------------|
| `name`        | string              | yes      | Lowercase DNS label, 1–63 characters                    |
| `labels`      | map[string]string   | no       | Selector keys; both key and value are DNS labels        |
| `annotations` | map[string]string   | no       | Not selectable; carried through unmodified              |

Documents are decoded with alias nodes rejected, unknown top-level fields rejected, and a 1 MiB limit,
as 0011 specifies at admission. The same rules apply wherever a document is accepted, including the
portal's upload path.

### DirectiveSet

A named set of resources, the endpoints they apply to, and whether they are enforced or only observed.

| Field            | Type            | Required | Default   | Notes                                     |
|------------------|-----------------|----------|-----------|-------------------------------------------|
| `spec.mode`      | enum            | no       | `enforce` | `enforce` or `audit`                       |
| `spec.target`    | `Target`        | yes      |           | Which endpoints the set applies to         |
| `spec.resources` | `[]Resource`    | no       | `[]`      | Empty is valid and applies nothing         |

`Target`:

| Field                       | Type              | Required | Notes                                    |
|-----------------------------|-------------------|----------|------------------------------------------|
| `selector.matchLabels`      | map[string]string | no       | All pairs must match                      |
| `selector.matchExpressions` | `[]Expression`    | no       | `key`, `operator`, `values`               |
| `endpoints`                 | []string          | no       | Explicit endpoint names, in addition      |

At least one of `matchLabels`, `matchExpressions`, or `endpoints` must be present; a `Target` matching
everything is written explicitly as `matchExpressions: [{key: name, operator: Exists}]` rather than by
omission, so a set never applies estate-wide by accident.

`mode: audit` runs `Observe` and `Plan` and never `Apply` (0011), which makes it the safe way to
introduce a set to endpoints already carrying state.

### The resource envelope

Every entry in `spec.resources` is itself an `apiVersion`/`kind` document, so one validator handles both
levels.

| Field            | Type          | Required | Notes                                                  |
|------------------|---------------|----------|--------------------------------------------------------|
| `apiVersion`     | string        | yes      | Same group and version as the enclosing set             |
| `kind`           | string        | yes      | A host resource kind, or a driver-defined device kind   |
| `metadata.name`  | string        | yes      | Unique within the set, per kind                         |
| `spec`           | kind-specific | yes      |                                                         |
| `dependsOn`      | []string      | no       | `metadata.name` of resources in the same set            |

`dependsOn` names must resolve within the same `DirectiveSet`; a reference to a resource in another set
is rejected at admission rather than resolved across sets. Cycles are rejected.

### Host resource kinds

**`File`**

| Field         | Type       | Required | Default | Notes                                          |
|---------------|------------|----------|---------|------------------------------------------------|
| `path`        | string     | yes      |         | Absolute path on the host                       |
| `mode`        | string     | no       | `"0644"`| Octal, quoted, so YAML does not read it as int  |
| `owner`       | string     | no       | `root`  |                                                 |
| `group`       | string     | no       | `root`  |                                                 |
| `content`     | `Content`  | no       |         | Exactly one of `content` or `state: absent`     |
| `state`       | enum       | no       | `present` | `present` or `absent`                         |

`Content` is one of `inline` (string), `scriptRef` (a `Script` name plus `inputs`), or `source` (a URL
the agent fetches through its egress proxy).

**`Package`**

| Field      | Type   | Required | Default   | Notes                                          |
|------------|--------|----------|-----------|------------------------------------------------|
| `name`     | string | yes      |           | Package name as the host's manager knows it     |
| `version`  | string | no       | unpinned  | Exact version; unpinned means any installed     |
| `state`    | enum   | no       | `present` | `present`, `absent`, or `latest`                |
| `manager`  | enum   | no       | detected  | `apt`, `dnf`, `zypper`; detected from facts     |

`state: latest` is refused in `production` unless the environment carries the matching override, because
it makes the applied state depend on when the run happened rather than on the document.

**`Service`**

| Field      | Type    | Required | Default   | Notes                                         |
|------------|---------|----------|-----------|-----------------------------------------------|
| `name`     | string  | yes      |           | Unit or service name                           |
| `state`    | enum    | no       | `started` | `started`, `stopped`                           |
| `enabled`  | bool    | no       | `true`    | Start at boot                                  |
| `reloadOn` | []string| no       |           | `metadata.name` of resources that trigger reload |

`reloadOn` is the ordering primitive that matters in practice: a `File` that changes triggers a reload of
the `Service` naming it, without the file needing to know what consumes it.

### Policy

A Rego module evaluated at one phase.

| Field         | Type   | Required | Notes                                                       |
|---------------|--------|----------|-------------------------------------------------------------|
| `spec.phase`  | enum   | yes      | `admission`, `dispatch`, or `host`                           |
| `spec.module` | string | yes      | Rego source; package name must match the phase               |
| `spec.strict` | bool   | no       | Fail the evaluation on an undefined rule rather than allowing |

Phases are not interchangeable. `admission` runs in the provisioner when a document is written,
`dispatch` when a bundle is built, and `host` on the agent against the rendered bundle. A `host` policy
may only add denials (0012); it cannot permit something an earlier phase denied.

### Script

Tengo source with declared inputs and limits.

| Field           | Type              | Required | Default | Notes                                        |
|-----------------|-------------------|----------|---------|----------------------------------------------|
| `spec.phase`    | enum              | yes      |         | `render` or `host`                            |
| `spec.source`   | string            | yes      |         | Tengo source                                  |
| `spec.inputs`   | map[string]schema | no       | `{}`    | Declared inputs with types and defaults       |
| `spec.maxAllocs`| int               | no       | 5000000 | Allocation cap for the run                    |
| `spec.timeout`  | duration          | no       | `2s`    | Wall-clock limit                              |

A `render` script runs in the provisioner and produces content; a `host` script runs on the agent. Both
run under the sandbox 0001 fixes: allowlisted pure standard-library modules, no `os`, no file access.

### DeviceConnection

How the provisioner reaches an agentless endpoint.

| Field                 | Type     | Required | Notes                                              |
|-----------------------|----------|----------|----------------------------------------------------|
| `spec.driver`         | string   | yes      | Driver name; determines the resource kinds allowed  |
| `spec.address`        | string   | yes      | Host and port                                       |
| `spec.tls.pin`        | string   | no       | SHA-256 of the expected certificate                 |
| `spec.ssh.hostKey`    | string   | no       | Pinned host key                                     |
| `spec.credentialRef`  | string   | yes      | Name of a secret, resolved within the writing tenant |

TLS verification is mandatory and SSH host keys are pinned (0011). `credentialRef` resolves under
`<secrets.directory>/<tenantId>/<name>`, rejects path separators and `..`, and never resolves across
tenants — the credential itself never enters a document, a policy input, a script value, or a rendered
resource.

### Invariants a type cannot carry

These are the rules that make a syntactically valid document still wrong. They live here because no
struct tag expresses them, and they are what the generated schemas cannot check alone.

- **Conflict.** Two `DirectiveSet`s targeting one endpoint with the same resource `kind` and
  `metadata.name` are a conflict, reported at plan time and never resolved by last writer wins (0011).
- **Path separation.** Host resource kinds are refused on agentless endpoints, and device kinds on agent
  endpoints; admission decides from the endpoint's path in `rackmarshal-inventory` (0011).
- **Tenancy.** Every reference a document makes — `credentialRef`, `scriptRef`, `dependsOn` — resolves
  within the writing tenant only.
- **Ordering.** `dependsOn` and `reloadOn` name resources in the same set; cycles and dangling names are
  rejected at admission, not at apply.
- **Generation monotonicity.** A bundle carrying these documents is accepted by an agent only if its
  `generation` advances, within the bound 0012 sets (`bundle.maxGenerationJump`).

### Versioning

Kinds follow the same stages as APIs: `v1alpha1` → `v1beta1` → `v1`, with side-by-side versions and
conversion in the provisioner (0011). Adding an optional field with a default is not breaking; changing a
default, narrowing an enum, or making an optional field required is. `oasdiff` covers the generated
OpenAPI components, and the generated JSON Schema files are compared the same way.

### Testing

- **Round trip** — every example decodes into the Go structures, re-encodes, and still validates.
- **Generated artefact drift** — schemas, OpenAPI components, reference docs, and this document's field
  tables are regenerated in CI and the build fails on any diff.
- **Invariant tests** — one failing example per rule in [Invariants](#invariants-a-type-cannot-carry),
  asserting the expected error code and JSON pointer rather than just a failure.
- **Wizard conformance** — the document the portal's guided flow produces validates against the generated
  schema, which is the check that was missing when it was written.

## Alternatives considered

- **Keeping contract-first, with the catalogue as prose** — the position 0002 took and this document
  reverses. It keeps `rackmarshal-sdk` startable on day one, but leaves three artefacts describing one
  kind — hand-written schema, hand-written Go type, and prose — with nothing forcing agreement. That is
  how the wizard came to generate inferred YAML.
- **A machine-readable block per kind in this document**, extracted by a generator. Considered because it
  would make the catalogue itself the build input. Rejected once the direction was settled: after
  bootstrap the Go structures are the source, so a parseable Markdown block would be a second source
  competing with them.
- **Generating the Go types from JSON Schema** rather than the reverse. Viable, and it keeps a schema
  authoritative, but the generators produce types shaped by the schema rather than by Go, and the
  invariants above still have to live somewhere else.
- **Keeping standalone JSON Schema files alongside the generated OpenAPI components.** Rejected: it
  reinstates the second description this document exists to remove, and nothing needs it once one Go
  type describes both a manifest and the API body that carries it.

## Open questions

- **Bootstrap mechanics** — who writes the first Go structures from this catalogue, and is that reviewed
  against it field by field, or only against the examples?
- **Reference documentation format** — godoc, a generated Markdown reference, or both? If Markdown, does
  it live in `rackmarshal-api-schema` or here beside this document?
- **Field-table regeneration** — this document's tables are to be regenerated from the structures. Which
  tool does that, and does it rewrite the file in place or emit a fragment this document includes?
- **`matchExpressions` operators** — `In`, `NotIn`, `Exists`, `DoesNotExist` mirrors Kubernetes. Is that
  the full set, and is a regex operator wanted for label values?
- **Driver-defined device kinds** — 0011 leaves their schema publication open, and 0013 asks the same for
  plugin kinds. Both land in the same place: what does a third party publish so this catalogue's rules
  apply to their kinds too?

## References

- [0001](0001-project-repositories.md) — the desired-state format decision and Tengo sandbox bounds.
- [0002](0002-rackmarshal-api-schema.md) — contract formats, generation, and the drift checks; amended by
  this document's generation direction.
- [0011](0011-rackmarshal-provisioner.md) — the kinds, admission, rendering, conflicts, and device drivers.
- [0012](0012-rackmarshal-agent.md) — host-phase policy, bundle generation bounds, and what the agent refuses.
- [0017](0017-rackmarshal-portal.md) — the guided flow that produces a `DirectiveSet`.
- [OpenAPI Specification 3.0.3](https://spec.openapis.org/oas/v3.0.3.html) — the generated document
  version.
