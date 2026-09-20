<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0002 — api-schema

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-18
- **Summary:** `api-schema` holds the Go types every other repository shares: the service API
  models, the OPA policy inputs, outputs and state, and the desired-state manifests. Those types are the
  contract. The OpenAPI 3.0 documents and the reference documentation are generated from them and never
  written by hand, and `sdk` generates its client from the types directly rather than from a
  document. The manifest kinds themselves are specified in [0020](0020-desired-state-kinds.md).

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

[0001](0001-project-repositories.md#repository-inventory) makes `api-schema` the home of "the
inter-service and client schema" and requires the wire contract to live there once, with clients using
`sdk` rather than re-deriving types
([Naming & conventions](0001-project-repositories.md#naming--conventions)). It is first in the
[build order](0001-project-repositories.md#sequencing--phases), so its choices constrain every other
repository.

This document originally specified that as contract-first: hand-written OpenAPI 3.1 documents, hand-written
JSON Schema files for desired-state kinds, and Go models generated from the documents. That is reversed
here. The repository holds Go types, and everything else is generated from them.

The reason is the failure the old arrangement had already produced. A kind was described in three places —
a hand-written schema, a hand-written Go type, and prose — with nothing forcing agreement, and the portal's
directive wizard ended up generating YAML inferred from a single example ([0017](0017-portal.md)).
One artefact has to win, and the one that compiles is the only one that cannot quietly disagree with itself.

**Goals**

- One module holding every shared Go type: service API models, OPA structures, desired-state manifests.
- Types that compile are the contract, so no second hand-written artefact can contradict them.
- Documents and reference material generated from the types and drift-checked in CI.
- One dependency for every consumer: the SDK, the services, the gateway, the provisioner, and the agent.

**Non-goals**

- Hand-written OpenAPI documents or JSON Schema files. Both are generated; neither is edited.
- The agent plugin contract — gRPC over `hashicorp/go-plugin`, owned by
  [0013](0013-agent-plugin-sdk.md).
- Client behavior such as retries, authentication, and TLS — [0003](0003-sdk.md).
- Token formats, RBAC, and the enrollment token encoding — [0006](0006-identity.md).
- Gateway routing, rate limits, and principal propagation — [0008](0008-gateway.md).
- Rego policy source. This repository types the inputs and outputs; the policies live in
  [0011](0011-provisioner.md) and are authored per tenant.
- Runtime, tenant-supplied JSON Schemas for inventory classes, which are a different mechanism entirely —
  [0009](0009-inventory.md).

## Proposal

### Responsibilities

- Go types for every service API request and response, plus the shared components every service reuses.
- Go types for OPA: the policy input per phase, the decision and violation shapes, and policy state.
- Go types for the desired-state manifest kinds specified in [0020](0020-desired-state-kinds.md).
- Generation of the OpenAPI 3.0 component schemas and the reference documentation from those types.
- The vacuum ruleset, the oasdiff compatibility policy, examples, and the drift checks every repository runs.

### Types first, documents generated

Proposed: **the Go types are the contract, and documents are build outputs.** Rationale:

- **One artefact wins, and it is the one that compiles.** A hand-written schema and a hand-written type
  can disagree; a generated schema cannot disagree with the type it came from.
- **The starters already work this way.** `go-echo-starter` generates OpenAPI from route metadata and
  drift-checks it in CI (`800-call-openapi-drift.yaml`). Under contract-first that was an obstacle to work
  around; here it is the mechanism.
- **One description of a manifest, not two.** Dropping the standalone JSON Schema files removes the second
  description of every desired-state kind. The Go type is the only one left.
- **Parallelism survives.** The types live here rather than in any service, so `sdk`, the
  gateway, and the first services still start together — from a Go package instead of a YAML document.

**OpenAPI 3.0, not 3.1.** The generated documents are OpenAPI 3.0, which is what the starter's generator
emits. 3.1 was originally chosen so its Schema Object would be JSON Schema 2020-12 and API bodies could
`$ref` the desired-state schema files. With those files gone there is nothing to `$ref` and nothing to
reconcile: a manifest and an API body that carries one are described by the same Go type, so they cannot
diverge whatever dialect the generated document uses.

### Repository layout

```
api-schema/
├── pkg/
│   ├── api/
│   │   ├── common/v1/                  # Problem, list envelope, pagination, shared parameters
│   │   ├── identity/v1alpha1/
│   │   ├── inventory/v1alpha1/
│   │   └── provisioner/v1alpha1/
│   ├── opa/v1alpha1/                   # policy input, decision, violation, policy state
│   └── desiredstate/v1alpha1/          # manifest kinds (0020)
├── gen/                                # generated, committed, drift-checked
│   ├── openapi/common/v1/components.yaml
│   └── reference/                      # generated reference documentation
├── examples/                           # valid and invalid samples per operation and kind
├── rules/rackmarshal.vacuum.yaml       # Spectral-compatible ruleset
├── conformance/                        # nested Go module: validation and round-trip tests
└── Taskfile.yaml
```

Nothing under `gen/` is edited. `task generate` rewrites it and `task check:drift` fails the build if the
committed output differs from what the types produce.

Each service generates its own document, because paths and operations live with the routes that declare
them. This repository generates the shared components those documents reference, so a service document is
its paths plus a reference to components it does not restate.

### OPA types

The policies are Rego and live with the provisioner; what crosses the boundary is typed here, so the
provisioner, the agent, and a policy author all agree on the shape.

| Type           | Carries                                                                        |
|----------------|--------------------------------------------------------------------------------|
| `Phase`        | `admission`, `dispatch`, or `host`                                              |
| `Input`        | Environment, tenant, principal, the document under evaluation, endpoint facts   |
| `Decision`     | The outcome plus the violations that produced it                                |
| `Violation`    | `code` (stable lower_snake_case), `message`, and a JSON pointer where relevant  |
| `PolicyRef`    | Name, phase, and the revision evaluated, for the audit record                   |
| `EvalMetadata` | Duration, the rules that fired, and whether the evaluation hit its deadline     |

The phases are 0011's: `admission` when a document is written, `dispatch` when a bundle is built, and
`host` on the agent against the rendered bundle. A `host` policy may only add denials
([0012](0012-agent.md)), so its `Decision` is merged as a union of violations rather than
replacing an earlier one.

`Violation.code` is the same stable identifier the problem responses use, so a policy denial surfaces to a
caller as `policy_denied` with the rule that denied it rather than as a generic failure.

### Paths, operations, and extensions

Paths follow `/<service>/<version>/<plural-resource>[/{id}]` in kebab-case, and `operationId` is a
lowerCamelCase verb-noun unique within its document. Three Rackmarshal extensions carry metadata other
repositories act on, and because documents are generated they originate as annotations on the route
declarations rather than as YAML:

| Extension                  | Applies to      | Values                                   | Used by                         |
|----------------------------|-----------------|------------------------------------------|---------------------------------|
| `x-rackmarshal-audience`   | operation       | array of `operator`, `agent`, `internal` | gateway routing, SDK docs, lint |
| `x-rackmarshal-sensitive`  | schema property | `true`                                   | SDK redaction, logging rules    |
| `x-rackmarshal-idempotent` | POST operation  | `true`                                   | SDK retry policy                |

`x-rackmarshal-sensitive` is a struct tag on the field it marks, so the property and its marking cannot
drift apart. The other two are route annotations.

`common/v1` defines two security schemes: `bearerAuth` (`type: http`, `scheme: bearer`) and `mutualTLS`.
`operator` operations require `bearerAuth`; `agent` and `internal` operations require `mutualTLS`. The
exceptions are agent enrollment, which 0001 makes the single route without a client certificate
([Agent enrollment](0001-project-repositories.md#agent-enrollment)), and service enrollment; both declare
`security: []`. The gateway-to-service hop is always mutual TLS and is not modeled per operation.

### Errors

Every non-2xx response is `application/problem+json`
([RFC 9457](https://www.rfc-editor.org/rfc/rfc9457)) with Rackmarshal members `code`, `traceId`, and, for
validation failures, `errors[]` of `pointer` and `detail`. `Problem` is a Go type in `pkg/api/common/v1`,
so every service returns the same shape by construction. Problem bodies never carry secrets, stack traces,
or another tenant's data.

### Versioning and deprecation

One Go package per API version (`inventory/v1alpha1`), with versions side by side so a breaking change ships
as a new package rather than an edit to an existing one. Stages are `v1alpha1` → `v1beta1` → `v1`, matching
the desired-state stages 0001 sets. `oasdiff` compares each generated document with the last release and
fails on a breaking change to a beta or stable version. Deprecation uses `deprecated: true` in the generated
document plus `Deprecation` ([RFC 9745](https://www.rfc-editor.org/rfc/rfc9745)) and `Sunset`
([RFC 8594](https://www.rfc-editor.org/rfc/rfc8594)) response headers.

Adding an optional field with a default is not breaking. Changing a default, narrowing an enum, or making an
optional field required is.

### Dependencies

- **Rackmarshal repositories** — none upstream. Consumers: `sdk` (types and generated client),
  every service (types and generated documents), `gateway` (audience metadata),
  `provisioner` and `agent` (OPA and desired-state types).
- **Root module** — the Go standard library only. This is the constraint that matters most, because every
  other repository imports it.
- **`conformance` module** — [kin-openapi](https://github.com/getkin/kin-openapi) v0.149.0 to validate
  examples against the generated documents. It requires `go-openapi/jsonpointer`, `gorilla/mux`,
  `oasdiff/yaml`, `oasdiff/yaml3`, and `jsonschema/v6`, which is why it stays in a nested module.
- **Tools** (not in `go.mod`) — the OpenAPI generator, [oasdiff](https://github.com/oasdiff/oasdiff) v1.32.0,
  and [vacuum](https://github.com/daveshanley/vacuum) v0.30.6, all run through `go run <module>@<version>`.

`oapi-codegen` was the generator under contract-first, turning documents into Go models. With the direction
reversed it has no job here. Whether `sdk` still needs it is 0003's question, not this one.

### Data & storage

None. Types live in Git; the module holds no runtime state.

### Security

- **Security is declared where the route is.** Lint fails on any operation whose generated document lacks an
  explicit `security`. An empty `security: []` is allowed only on an allowlisted set: enrollment and health.
- **Audiences bound exposure.** The gateway builds its route tables from `x-rackmarshal-audience`, so an
  operation is never reachable on an ingress it was not declared for ([0008](0008-gateway.md)).
- **Secrets are marked at the field.** `x-rackmarshal-sensitive` is a struct tag, so a property cannot be
  added without the marking travelling with it. The SDK redacts them and `common` excludes them.
- **Review.** `CODEOWNERS` requires the identity and gateway owners on changes to security schemes,
  `security`, or `x-rackmarshal-audience`.
- **Supply chain.** Generators are pinned by version, and releases publish the starters' signed SBOMs.

### Environment awareness

The types are environment-neutral: no environment names in paths, and `servers` lists only `/`. Environment
binding — tokens carrying the environment ID, SPIFFE trust domains
([Environment identity](0001-project-repositories.md#environment-identity)) — is enforced by
`identity` and `gateway`. Services serving a generated document keep the OpenAPI UI
off in `production` and `staging`, per 0001's
[hardened defaults](0001-project-repositories.md#environment-awareness).

### Logging & telemetry

None at runtime; this module has no runtime. The generator and drift checks log to CI output only.

### Build, release & versioning

- **Tasks** — `generate` (documents and reference material from the types), `check:drift` (regenerate and
  diff), `lint` (vacuum), `breaking` (oasdiff), and `test` for the root and nested modules.
- **CI** — the 200-series pull request workflow runs lint, breaking, drift, and tests; the 300-series repeats
  them on main.
- **Module** — `github.com/rackmarshal/api-schema`, `v0.x` from Conventional Commits, with the
  Go package version independent of the API versions it contains.

### Testing

- **Round trip** — every example decodes into the Go types, re-encodes, and still validates against the
  generated document.
- **Generated artefact drift** — documents, component schemas, and reference documentation are regenerated
  in CI and the build fails on any diff.
- **Examples** — valid samples must pass and invalid samples must fail with the expected pointer and code.
- **Dependency budget** — a test fails if the root `go.mod` gains any requirement.

## Alternatives considered

- **Contract-first OpenAPI 3.1** — the position this document originally took: hand-written documents,
  hand-written JSON Schema files, Go models generated from them. Reversed because it left three descriptions
  of one kind with nothing forcing agreement, which is how the portal's wizard came to generate inferred
  YAML. The parallelism it was protecting is preserved by keeping the types out of the services.
- **Keeping the JSON Schema files alongside generated documents** — would let API bodies `$ref` a manifest
  schema. Rejected as the second description all over again, and unnecessary once one Go type describes both.
- **OpenAPI 3.1 by replacing the starter's generator** — keeps the richer dialect at the cost of replacing
  `internal/openapi` in an external starter repository before any of this can proceed. Not chosen; 3.0 is
  sufficient once the schema files are gone.
- **A separate repository for the types** — considered when the SDK's ordering problem surfaced. Unnecessary:
  `api-schema` is that repository, correctly defined.

## Open questions

- **Which generator** emits OpenAPI 3.0 from Go types and route declarations, and does this repository emit
  only the shared components while each service emits its own paths?
- **How route annotations are expressed** in Go so `x-rackmarshal-audience` and `x-rackmarshal-idempotent`
  reach the generated document — struct tags, a registration call, or a comment convention?
- **Does `sdk` still need a generator at all** if it builds its client from these types
  directly ([0003](0003-sdk.md))?
- **Policy state** — `EvalMetadata` and `PolicyRef` are proposed from what 0011 and 0012 already record.
  What else does a policy author or the audit trail need typed?
- **Reference documentation format** — godoc, generated Markdown, or both, and does it live here or beside
  the design documents?

## References

- [0001 — Project Repositories](0001-project-repositories.md) — inventory, desired-state format, build order.
- [0003 — sdk](0003-sdk.md) — the client built from these types.
- [0011 — provisioner](0011-provisioner.md) — OPA phases, policies, and admission.
- [0012 — agent](0012-agent.md) — host-phase policy and what the agent refuses.
- [0020 — Desired-state kinds](0020-desired-state-kinds.md) — the manifest kinds these types carry.
- [OpenAPI Specification 3.0.3](https://spec.openapis.org/oas/v3.0.3.html) — the generated document version.
- [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) — problem details.
- [oasdiff](https://github.com/oasdiff/oasdiff) — breaking-change detection.
- [vacuum](https://github.com/daveshanley/vacuum) — linting, built on libopenapi.
- [go-echo-starter](https://github.com/servercurio/go-echo-starter) — `internal/openapi`, which generates a
  document from route metadata and drift-checks it in CI.
