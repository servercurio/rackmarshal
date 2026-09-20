<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# Design document conventions

Cross-cutting conventions for the per-repository design documents that follow
[0001](0001-project-repositories.md). This is not a design document: it collects the proposals from
[0002](0002-api-schema.md), [0003](0003-sdk.md), and [0004](0004-common.md) that other
repositories depend on, so documents 0005–0015 stay consistent. Every item is a **Draft proposal** until
those documents are accepted. 0001's Resolved decisions always win; a document that deviates from a
convention says so under Alternatives considered and links the convention it breaks.

## Numbering and document shape

| #    | Repository             | #    | Repository         |
|------|------------------------|------|--------------------|
| 0002 | `api-schema`           | 0009 | `inventory`        |
| 0003 | `sdk`                  | 0010 | `cli`              |
| 0004 | `common`               | 0011 | `provisioner`      |
| 0005 | `infrastructure`       | 0012 | `agent`            |
| 0006 | `identity`             | 0013 | `agent-plugin-sdk` |
| 0007 | `sso`                  | 0014 | `agent-plugins`    |
| 0008 | `gateway`              | 0015 | `plugin-starter`   |
| 0016 | *web UI architecture*  | 0018 | `console`          |
| 0017 | `portal`               | 0019 | *brand identity*   |
| 0020 | *desired-state kinds*  |      |                    |
| 0021 | *plugin extensibility* |      |                    |

0016, and 0019 through 0021, describe no single repository, so they are named for their subject rather than for
a module, as 0001 is.

- File `NNNN-<name>.md`, title `# NNNN — <name>`, header and sections from
  [`TEMPLATE.md`](TEMPLATE.md). Proposal subsections, in order, as they apply: Responsibilities;
  Interfaces; Dependencies; Data & storage; Security; Environment awareness; Logging & telemetry;
  Configuration; Build, release & versioning; Testing.
- Link 0001 by heading anchor (`0001-project-repositories.md#environment-identity`) and siblings by file
  name. Label proposals; put unknowns in Open questions; cite every external claim in References and
  mark anything unverified. Wrap at about 105 characters; `—` em dashes; no HTML.

## Go modules and layout

- Module path `github.com/rackmarshal/<name>` (`/vN` suffix from v2, see
  [major version suffixes](https://go.dev/ref/mod#major-version-suffixes)); Go 1.27, as in the starters.
  Repositories carry no `rackmarshal-` prefix, because the organization already supplies it and
  `rackmarshal/rackmarshal-gateway` says it twice. The prefix survives wherever a name leaves its
  repository and lands somewhere shared — binaries, OS packages, systemd units, install paths, Helm
  charts, configuration prefixes, headers — where `gateway` alone would be ambiguous. The external
  `servercurio/go-*-starter` baselines keep their own names; they are not Rackmarshal repositories.
- Libraries export from `pkg/`, with versioned API packages at `pkg/<area>/<version>` named like
  `inventoryv1alpha1`. Executables keep `cmd/<binary>/` and `internal/`, and binaries take the repo name.

## API contract and style

- **Types are the contract.** `api-schema` holds the Go types for service APIs, for OPA inputs,
  outputs and policy state, and for desired-state manifests. Those types are authoritative: the OpenAPI 3.0
  documents and the reference documentation are generated from them, never written by hand, and CI fails on
  drift. There are no standalone JSON Schema files. [0002](0002-api-schema.md) sets the
  direction; [0020](0020-desired-state-kinds.md) specifies the manifest kinds.
- **REST + JSON, internal and external.** Services call each other over the same contract with mutual
  TLS. There is no service-to-service gRPC. gRPC appears only between a host process and its own
  plugins — `agent` and its plugin halves, and `provisioner` and its optional
  plugin services ([0021](0021-plugin-extensibility.md)) — over the go-plugin protobuf contract in
  `agent-plugin-sdk`, and always on a local transport that binds no port. A plugin channel is
  not a service-to-service call and never leaves the host or pod; two plugins never connect to each
  other.
- **Paths** — `/<service>/<version>/<plural-resource>[/{id}]`, kebab-case segments, e.g.
  `/inventory/v1alpha1/endpoints/{endpointId}`. `gateway` routes on the first segment.
- **Audience** — every operation declares `x-rackmarshal-audience` with one or more of `operator`, `agent`,
  `internal`. The gateway exposes `operator` operations on the operator ingress and `agent` operations on
  the agent ingress, and never routes `internal` ones.
- **Other extensions** — `x-rackmarshal-sensitive: true` on secret properties (never logged, redacted by
  the SDK); `x-rackmarshal-idempotent: true` on POST operations that are safe to retry.
- **JSON** — lowerCamelCase properties and query parameters; RFC 3339 UTC timestamps; opaque string IDs;
  no `format: uuid`, `date`, `email`, or `binary`, which generate `oapi-codegen/runtime` types. Lists
  take `?limit=&cursor=` and return `items` and `nextCursor`; no offset paging.
- **Headers** — `Authorization: Bearer <token>` for user and API tokens; W3C `traceparent` and
  `tracestate`; `X-Request-Id` echoed on every response. Health probes stay at `/livez`, `/readyz`, and
  `/healthz`, as in `go-echo-starter`, outside versioned paths.
- **Tooling** — vacuum (lint with the Rackmarshal ruleset), oasdiff (breaking changes), oapi-codegen v2.8.0
  (models in `api-schema`, client in `sdk`), run as `go run <module>@<version>` so tools
  never enter `go.mod`. Generated code is committed; CI regenerates and fails on drift.

## API versioning, deprecation, and errors

- **Stages** — `v1alpha1` → `v1beta1` → `v1`, matching 0001's desired-state `apiVersion`. Alpha may
  break between releases; beta breaks only by adding a new beta version beside the old one; a stable
  version never breaks, so breaking changes ship as `v2` side by side. oasdiff compares each pull
  request with the last release and fails on a breaking change to a beta or stable document.
- **Deprecation** — `deprecated: true` in the contract plus `Deprecation`
  ([RFC 9745](https://www.rfc-editor.org/rfc/rfc9745)) and `Sunset`
  ([RFC 8594](https://www.rfc-editor.org/rfc/rfc8594)) response headers.
- **Errors** — every non-2xx response is `application/problem+json`
  ([RFC 9457](https://www.rfc-editor.org/rfc/rfc9457)) with Rackmarshal members `code` (stable
  lower_snake_case, e.g. `endpoint_not_found`), `traceId`, and, for validation failures, `errors[]` of
  `pointer` and `detail`. `type` is `<problem-base-url>/<code>`; the base URL is an open question in
  0002. Problem bodies never carry secrets, stack traces, or another tenant's data.

## Security and identity

- **SPIFFE IDs** ([SPIFFE ID](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md)), one per
  certificate. No other path types without a design document:
  - `spiffe://<environment-id>/service/<repository>` — e.g. `/service/inventory`
  - `spiffe://<environment-id>/agent/<agent-id>`
  - `spiffe://<environment-id>/control-node/<node-name>` — `infrastructure` control nodes
- **ID syntax** — `<environment-id>` and `<agent-id>` are 128 random bits as 26 characters of lowercase,
  unpadded base32 ([RFC 4648](https://www.rfc-editor.org/rfc/rfc4648)), valid in a SPIFFE trust domain;
  `<node-name>` is a lowercase DNS label.
- **Shared helpers** — SPIFFE parsing, mutual-TLS `tls.Config` builders, OCSP/CRL checking, and CSR
  enrollment and renewal live in `sdk` (`pkg/spiffe`, `pkg/tlsconfig`, `pkg/revocation`,
  `pkg/enroll`); no repository re-implements them. `go-spiffe` is not used — its `go.mod` requires gRPC.
- **TLS** — TLS 1.3 only where both ends are Rackmarshal components (services, agent ingress, control node);
  the operator and third-party ingress keeps the starter's hardened TLS 1.2+ configuration.
- **Keys and secrets** — leaf keys are ECDSA P-256, generated where used, and never leave that host.
  Tokens and keys are never logged or placed in URLs, and are read from files (`...File` keys).

## Plugins

[0021](0021-plugin-extensibility.md) settles the shape; these are the parts other repositories depend on.

- **Every plugin ships a provisioner bundle** — its JSON schemas, its Rego, and its result schema, signed
  and digest-pinned like any other release asset. A plugin that ships no bundle is not importable, because
  the control plane would otherwise sign a directive containing a kind it can neither validate nor police.
- **A provisioner-side executable is optional.** The bundle is data; the service that interprets results
  and proposes follow-up work is a separate, optional artifact in the same `Plugin` document at the same
  version.
- **Plugin policy may only deny, and only its own kinds.** The host filters policy input to the kinds the
  plugin was granted before evaluating; a policy is never trusted to scope itself. Installing a plugin can
  therefore never widen what the platform or a tenant allows.
- **Both ends validate both directions.** The agent and the provisioner each schema-validate what they
  send and what they receive, against the schema the pinned plugin version publishes. Neither relies on
  the other having checked.
- **Plugin payloads are bounded at every hop** and are tenant data: never logged, never in a metric label,
  and only their size and digest in a span.

## Configuration and environment variables

- Loading follows the starters: defaults → YAML file → `<PREFIX>_*` variables → flags. YAML keys are
  lowerCamelCase; variables are upper snake case under the prefix (`RACKMARSHAL_INVENTORY_SERVER_HTTPS_PORT`).
- Each executable's prefix is `RACKMARSHAL_` plus its repository name without `rackmarshal-`, upper-cased, hyphens
  as underscores: `RACKMARSHAL_IDENTITY`, `RACKMARSHAL_SSO`, `RACKMARSHAL_GATEWAY`, `RACKMARSHAL_INVENTORY`, `RACKMARSHAL_CLI`,
  `RACKMARSHAL_PROVISIONER`, `RACKMARSHAL_AGENT`. An agent plugin uses `RACKMARSHAL_PLUGIN_<NAME>`.
- Libraries define no prefix. Their config structs implement the starters' `FromEnv(prefix string)` and
  `Validate() error` and mount under fixed child keys: `logging` → `<PREFIX>_LOG_*` and
  `<PREFIX>_ACCESS_LOG_*`; `telemetry` → `<PREFIX>_TELEMETRY_*`; `environment` →
  `<PREFIX>_ENVIRONMENT_*`; the `sdk` client → `<PREFIX>_GATEWAY_*`.

## Environment

- Keys under `environment` / `<PREFIX>_ENVIRONMENT_`: `name` / `_NAME` (lowercase DNS label, e.g.
  `qa-east`); `tier` / `_TIER` (`production`, `staging`, `test`, `development`); `id` / `_ID`;
  `caBundle` / `_CA_BUNDLE` (path to the root CA bundle); `overrides` / `_OVERRIDES` (comma-separated
  last-resort feature names).
- `name` and `tier` are required everywhere. `id` and `caBundle` are required wherever a component makes
  or accepts mutual-TLS connections, and `id` must match the trust domain of the bundle's roots.
  `agent` records all four from enrollment; plugins receive them from the agent in `Init` and
  carry no environment configuration of their own.
- Tier logic goes through `common`'s `environment` package: `Hardened()` is true for `production`
  and `staging`; last-resort features call `AllowLastResort("<feature>")`, which refuses in `production`
  unless the kebab-case feature name is in `overrides`, and logs every override at `warn`.

## Running multiple replicas

Every service runs as N replicas, N >= 1, and no replica holds a role the others do not. Nothing elects
a primary and no configuration names an instance. A service that cannot satisfy this has a design
defect, not a deployment note.

- **Per-request state is per-replica.** Caches, rate-limit buckets, and connection pools live in the
  process. A service states the bound on divergence — normally a TTL — and sizes limits knowing an
  operator multiplies them by the replica count.
- **Shared state lives in PostgreSQL, and the database enforces the invariant.** Prefer a constraint
  that makes the wrong state unrepresentable over a lock that makes it unreachable. A partial unique
  index permitting one `current` signing key beats a mutex around rotation, because the index also
  binds the replica that forgot to take the mutex.
- **Scheduled work is claimed, not assumed.** A loop that fires on every replica runs N times. Which
  primitive depends on whether a missed run is detectable:

| Work | Primitive | Why |
|------|-----------|-----|
| Idempotent and skippable — retention sweeps, cache refresh | `pg_try_advisory_lock`, skip the tick when not acquired | No lease table and no failover gap; the next tick catches up |
| Must happen once per interval, and its absence is itself a signal — audit anchoring | An interval-keyed claim row with `INSERT … ON CONFLICT DO NOTHING` | The row records that the interval was handled, so a missing row is the alarm |
| Per-item queues — reconciliation | `SELECT … FOR UPDATE SKIP LOCKED` with an owner and a lease expiry | A crashed worker's lease lapses without a reaper |

Serial chains — anything where record *n* commits to record *n-1* — take `pg_advisory_xact_lock` for the
append and read the predecessor inside the same transaction. A sequence is not a substitute: a
rolled-back transaction burns its number and leaves a gap, and in a hash chain a gap is
indistinguishable from a deletion.

Each design document states its position under **Scaling** in Data & storage, including when the
answer is that nothing is shared.

## Logging and telemetry

- Executables log and export telemetry only through `common`. Other shared libraries return errors
  and accept injected transports instead of logging.
- Every executable writes each log event to two sinks from one `zerolog.Logger`, each with its own
  level: a **console sink** in logfmt on stdout, for people, and an **OTLP sink** that ships to a
  collector or any OTLP-compatible backend, for machines. `<PREFIX>_LOG_CONSOLE_FORMAT=json` restores
  JSON lines for a deployment that still scrapes stdout. A log call never blocks on the OTLP sink:
  its queue is bounded and overflow is dropped and counted.
- Events carry `time` (RFC 3339 UTC), `level`, `message`, `error`; `trace_id`, `span_id`, `trace_flags`
  ([trace context in logs](https://opentelemetry.io/docs/specs/otel/compatibility/logging_trace_context/));
  and on every event `service.namespace`, `service.name`, `service.version`, `service.instance.id`,
  `deployment.environment.name`, `rackmarshal.environment.tier`, `rackmarshal.environment.id`. The same
  fields reach both sinks; only the encoding differs.
- **`service.namespace` is always `rackmarshal`; `service.name` is the bare component** — `gateway`,
  `identity`, `provisioner`. This is the same split the repository names take, in the form
  [the service conventions](https://opentelemetry.io/docs/specs/semconv/resource/#service) define for it:
  the product identifies the group, the component identifies the member. A query for one Rackmarshal
  service and a query for all of them are both one label match, and neither depends on parsing a
  prefix out of a name.
- Other fields use the OpenTelemetry semantic-convention name when one exists (`http.request.method`,
  `http.response.status_code`, `http.route`, `url.path`, `client.address`); Rackmarshal concepts use dotted,
  snake_case names under `rackmarshal.` (`rackmarshal.tenant.id`, `rackmarshal.agent.id`).
- Telemetry resources carry the same `service.*`, `deployment.environment.name`, and
  `rackmarshal.environment.*` attributes; custom metrics are named `rackmarshal.<component>.<name>`. Propagation is
  W3C Trace Context only, with no baggage. Spans and logs never contain `x-rackmarshal-sensitive` data.

## Deployment artifacts

Rackmarshal deploys to Kubernetes, Docker/Podman hosts, and supported operating systems
([0001](0001-project-repositories.md#rackmarshals-own-infrastructure)), so every service repository ships:

- **OCI image** — multi-architecture (`linux/amd64`, `linux/arm64`), non-root, referenced by digest, and
  signed; used by the Kubernetes, Podman, and Docker targets. A service that needs cgo (`identity`,
  for PKCS#11) builds each architecture on a native runner instead of cross-compiling, on the oldest
  glibc in the support matrix (Enterprise Linux 9, glibc 2.34).
- **Helm chart** — in `charts/rackmarshal-<repository>/`, as in `go-echo-starter`, including an
  enrollment init container that uses the same image and the pod's projected service account token. Every
  rendered object carries the [recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/):
  `app.kubernetes.io/part-of: rackmarshal` for the application, `app.kubernetes.io/name` and
  `app.kubernetes.io/component` for the component (`gateway`, `identity`, …), plus `instance`, `version`,
  and `managed-by`. The product name belongs in `part-of`, not folded into every object's name.
- **Linux packages** — signed deb and rpm packages with a hardened systemd unit, for Enterprise Linux and
  Debian/Ubuntu LTS on amd64 and arm64.
- **Windows package** — a signed [NSIS](https://nsis.sourcerackmarshal.io) installer (`.exe`,
  Authenticode-signed) that installs the service as a Windows service on Windows Server. NSIS is
  zlib/libpng licensed and builds on Linux runners.

Quadlet units and Compose files are rendered by `infrastructure` roles, not kept in service
repositories. Configuration, health probes, and enrollment behave the same on every target; only the
credential for first enrollment differs (a single-use token file, or a projected service account token).

## License headers

Per [0001](0001-project-repositories.md#license-headers-and-license-files):

- Every tracked file starts with `SPDX-License-Identifier: Apache-2.0` in its comment syntax, and
  `LICENSE` sits at the repository root. `.licenserc.yaml` is the single policy file, and
  `LICENSE_EYE_VERSION` in `Taskfile.yaml` is the only place the license-eye version is pinned.
- Comment styles that `license-eye header fix` does not infer are pinned in `.licenserc.yaml`: `go.mod`
  uses `//`, and `CODEOWNERS` and `.helmignore` use `#`.
- Every file under `charts/*/templates/` starts with `{{- /* SPDX-License-Identifier: Apache-2.0 */ -}}`,
  added by hand, so a disabled template renders nothing; a `#` header outside `{{- if }}` leaves a
  comment-only manifest that fails `helm install`. license-eye accepts any comment style there, so
  `.licenserc.yaml` checks templates in a separate block and `task lint:license` also verifies each
  template's first line.
- `paths-ignore` lists only files that cannot hold a comment: `LICENSE`, `**/go.sum`, `**/*.json`,
  `**/.gitkeep`, and embedded data such as `**/version/version.txt`.
- Generators write the header themselves (for example `openapi-gen` for YAML output); generated JSON is
  ignored.
- CI's `800-call-license-headers.yaml`, called from the 200 and 300 flows, installs Task and runs
  `task lint:license`, the same task developers run; `task lint` includes it and `task license:fix`
  adds missing headers.

## Dependencies, build, and release

- Every new direct dependency is justified in its document with version and what it pulls in. Libraries
  keep a checked-in module allowlist; CI fails when
  `go list -deps -f '{{with .Module}}{{.Path}}{{end}}' ./pkg/...` reports a module not on it.
- Test-only and tooling modules that would enlarge consumers' module graphs go in a nested module (e.g.
  `conformance/go.mod`) or run through `go run <module>@<version>`.
- Pinned choices: zerolog; the OpenTelemetry API and SDK with the Rackmarshal OTLP/HTTP exporter; OPA; Tengo;
  `hashicorp/go-plugin`; `santhosh-tekuri/jsonschema/v6` for desired-state validation (proposed).
- Taskfile, golangci-lint, `-race` tests, semantic-release, and signed CycloneDX SBOMs as in the
  starters; CI workflows keep the numeric prefixes.
- Tags are `vX.Y.Z` from Conventional Commits. Modules stay `v0.x` (the starters' `.releaserc.json` maps
  a breaking change to a minor release) until the owner declares 1.0, when that rule becomes major. A
  module's version is independent of the API versions it contains.
