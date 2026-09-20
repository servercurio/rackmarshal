<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0021 — Plugin extensibility

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-20
- **Summary:** Plugins become a paired extension: an agent half that enforces a kind on an endpoint and an
  required provisioner bundle carrying its schemas and policy, and an optional provisioner service that
  interprets results and proposes follow-up work. One `Plugin` document and one version pin all of it.
  Apply results travel back as bounded, schema-validated
  payloads instead of digests alone, and each half may ship Rego that the host evaluates, scoped to the
  kinds the plugin was granted and able only to deny.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

The plugin model in [0013](0013-rackmarshal-agent-plugin-sdk.md), [0014](0014-rackmarshal-agent-plugins.md),
and [0015](0015-rackmarshal-plugin-starter.md) is entirely agent-side: `hashicorp/go-plugin` binaries that
`rackmarshal-agent` launches on the endpoint. `rackmarshal-provisioner` never runs plugin code. Its only
relationship to a plugin is supply chain — verifying a release at import and pinning digests into bundles
([0011](0011-rackmarshal-provisioner.md)).

That is enough for a plugin whose whole job is to converge a kind on a host. It is not enough for four
things the design has since needed, three of which the existing documents already circle without naming:

- A plugin has no way to run anything **beside the provisioner**, so a kind that must be reached from the
  control plane rather than from the endpoint has nowhere to live. 0011 rejected out-of-process drivers
  over go-plugin because they "bring gRPC into a service against the API style convention" — a rejection
  about in-process transport, which never considered a separate process with its own lifecycle.
- A plugin has no **provisioner-side half** to validate its kind at admission, interpret what its agent
  half reported, or act on it. 0011 asks "who publishes their schemas" and 0013 asks "how do their schemas
  reach the agent and 0011"; both are this gap seen from one end.
- An agent plugin **cannot return a structured result**. Reports carry "a digest of observed state (never
  file content)" (0012) and `enforcement_reports` stores "digests of observed state, never content"
  (0011). `ApplyResourceResponse` is declared in 0013's contract and its fields are never specified.
- Neither half can **supply its own policy**. The provisioner layers platform Rego under tenant `Policy`
  documents (0011) and the agent layers an embedded baseline under local `policy.d` and the bundle's
  `host` policies (0012). There is no plugin layer in either stack.

**Goals**

- One plugin, two optional halves, one version, one verification chain.
- Every plugin usable at admission, because every plugin ships its schemas and policy to the control
  plane whether or not it runs anything there.
- A bounded, schema-validated result payload from a plugin's agent half back to the control plane.
- Plugin-supplied Rego on both sides, scoped so a plugin can constrain only its own kinds.
- A provisioner-side process model that works on every deployment target 0005 supports.
- No new trust root, and no path by which a plugin gains authority it was not granted.

**Non-goals**

- Changing how agent plugins are launched, sandboxed, or verified on the host — 0012 and 0013 stand.
- A plugin marketplace, discovery, or dependency resolution between plugins.
- Plugin-authored schemas replacing `rackmarshal-api-schema` as the source of truth for built-in kinds
  ([0020](0020-desired-state-kinds.md)).
- Letting a plugin apply state directly. A provisioner service proposes; the platform decides.

## Proposal

### Responsibilities

- **`Plugin` document** — supersedes `AgentPlugin`, naming every artifact at one version with one publisher.
- **Provisioner bundle** — required of every plugin: the schemas and Rego the control plane needs to
  validate and police the plugin's kinds without executing any of its code.
- **Provisioner plugin host** — verifies, launches, and supervises the optional provisioner service as a
  separate process, and routes interpretation and proposal calls to it.
- **Result channel** — carries a bounded, schema-validated payload from the agent half to the control plane.
- **Policy layer** — compiles and evaluates plugin-supplied Rego on both sides, scoped and denial-only.

### Interfaces

#### The `Plugin` document

`AgentPlugin` becomes `Plugin`, with everything a plugin ships under one `spec` at one `version`:

```yaml
apiVersion: rackmarshal.servercurio.com/v1alpha1
kind: Plugin
metadata: { name: bigip }
spec:
  publisher: acme                       # PluginPublisher, unchanged (0011)
  version: 0.4.0
  baseURL: https://github.com/acme/rackmarshal-plugin-bigip/releases/download/v0.4.0
  agent:                                # optional: absent for control-plane-only kinds
    sha256: { linux/amd64: "…", linux/arm64: "…" }
    grant: { capabilities: [resource:acme.example.com/v1alpha1/VirtualServer] }
  provisioner:
    bundle:                             # REQUIRED — schemas and policy, no process
      sha256: "…"
    service:                            # optional — the running half
      image: ghcr.io/acme/rackmarshal-plugin-bigip@sha256:…   # kubernetes, podman, docker
      sha256: { linux/amd64: "…" }                      # package and windows targets
      grant: { capabilities: [validate, interpret, propose] }
```

One document and one `version` is the whole point. Two documents — an `AgentPlugin` and a sibling
`ProvisionerPlugin` — would let the halves drift to different versions while each remains individually
valid, and the failure would surface as a result payload the provisioner half cannot parse, at apply
time, on one endpoint. Pinning everything to one release makes that unrepresentable.

The shape carries the requirement rather than a field asserting it: `spec.provisioner.bundle` is
mandatory, so a `Plugin` without one does not validate. What varies is whether a plugin also ships a
running half:

| Ships | Meaning |
|-------|---------|
| `agent` + `provisioner.bundle` | The common case. The provisioner validates and polices the kind without running plugin code |
| `agent` + `provisioner.bundle` + `provisioner.service` | Adds result interpretation and proposals |
| `provisioner.bundle` + `provisioner.service` | Control-plane kinds with nothing to run on an endpoint |

#### The provisioner bundle

**Every plugin ships one, even when it has no provisioner-side process.** The bundle is passive data —
signed, digest-pinned, and verified at import like any other asset — and it is what lets the control
plane reason about a kind it did not define:

```
bundle/
├── manifest.yaml            # the same manifest the agent half embeds
├── schemas/
│   └── acme.example.com/v1alpha1/VirtualServer.json
│       # one per kind in the agent half's resource: capabilities, plus the result schema
└── policy/
    ├── admission.rego       # package rackmarshal.plugin.bigip.admission
    └── host.rego            # package rackmarshal.plugin.bigip.host
```

The alternative is that the provisioner passes a spec it cannot read straight through to a bundle it
signs. That breaks the property 0011 is built on — "fail-closed policy at write time, before dispatch,
and (via the bundle) on the host" — in the one case where it matters most, because a plugin kind is
exactly the kind nobody on the platform wrote. A malformed or malicious spec would then be caught on
each endpoint, after dispatch, once per host, instead of once at admission. Requiring the bundle keeps
admission uniform: **every kind is schema-validated and policy-checked before anything is signed, whether
the platform defined it or a third party did.**

Two consistency checks run at import, because a bundle that does not cover its own plugin is worse than
none:

- Every kind named in an agent half's `resource:` capability has a schema in the bundle. A capability
  without a schema fails import with `schema_missing`.
- Every schema in the bundle corresponds to a declared capability. A schema without a capability fails
  with `schema_unclaimed`, so a bundle cannot smuggle a definition for a kind the plugin was never
  granted.

The bundle also carries the result schema that both ends validate against (see The result round trip), so
a plugin with no running provisioner half still gets its results checked at the control plane.

Requiring this costs a plugin author almost nothing — the schemas and Rego already have to exist for the
agent half to be useful — and it means the expensive half of this proposal, the plugin host below, is
needed only by plugins that genuinely interpret or propose.

#### Provisioner plugin host

A provisioner-side half is **a separate process with its own lifecycle**, never code loaded into the
service. It speaks the protobuf contract from `rackmarshal-agent-plugin-sdk`, extended with the services
below, over mutual TLS on a loopback or Unix-socket transport.

| Target | Process model | Transport |
|--------|---------------|-----------|
| `kubernetes` | Sidecar container in the provisioner pod, one per replica | Unix socket on a shared `emptyDir` |
| `podman`, `docker` | Sibling container in the same pod or network namespace | Unix socket on a shared volume |
| `package` | `rackmarshal-provisioner-plugin-<name>.service`, socket-activated | Unix socket, root-owned directory |
| `windows` | A service under the SCM | Named pipe with a restrictive DACL |

Every row is a local transport. A provisioner-side half binds no port and is not reachable from outside
the host or pod, which is what keeps adding a plugin from adding an attack surface.

**This requires amending an explicit convention.** CONVENTIONS states "there is no service-to-service
gRPC; gRPC appears only between `rackmarshal-agent` and plugins." The principle behind that rule is that
*services* speak one REST + JSON contract, and *a host speaks to its plugins* over the plugin protobuf
contract. This proposal widens the carve-out from "`rackmarshal-agent` and plugins" to "a host process and
its plugins" and changes nothing about service-to-service traffic. That is a deliberate amendment to be
made in CONVENTIONS, not a reading of the existing text, and it is listed under Alternatives with the two
options that would have avoided it.

New services, in the same protobuf package and versioned with it:

```proto
service ProvisionerPluginService {
  rpc GetManifest(GetManifestRequest) returns (GetManifestResponse);
  rpc Init(InitRequest) returns (InitResponse);
  rpc ValidateDocument(ValidateDocumentRequest) returns (ValidateDocumentResponse); // admission
  rpc InterpretResult(InterpretResultRequest) returns (InterpretResultResponse);
  rpc Propose(ProposeRequest) returns (ProposeResponse);
}
message InterpretResultRequest {
  Resource resource = 1; string endpoint_id = 2; string report_id = 3;
  bytes result_json = 4;             // what the agent half returned, verbatim
}
message InterpretResultResponse {
  string summary = 1;                // one line, shown in the console
  repeated Condition conditions = 2; // typed status, merged into endpoint_status
  repeated Resource proposed = 3;    // follow-up desired state, never applied directly
}
```

**Ownership under N replicas.** Each replica runs its own plugin instances, and work reaches a plugin only
through the replica that already holds the row's lease
([CONVENTIONS — Running multiple replicas](CONVENTIONS.md#running-multiple-replicas)). Nothing is shared
between one replica's plugin and another's, so the reconciliation lease continues to be the only thing
serializing work on an endpoint, and plugins add no coordination problem of their own.

#### The result round trip

**The two halves never connect to each other.** There is no plugin-to-plugin channel, and a plugin half
never opens or accepts a network connection as part of this design. Each half talks only to its own host,
over a local socket, and the halves reach each other the way everything else in Rackmarshal does — as a
payload carried over the existing REST + JSON path through the gateway:

```
plugin half ──gRPC over local socket──► rackmarshal-agent
                                             │  outbox, then POST /provisioner/v1alpha1/enforcement-reports
                                             ▼  mutual TLS through rackmarshal-gateway (0008)
                                     rackmarshal-provisioner
                                             │  gRPC over local socket
                                             ▼
                                        plugin half
```

The halves share a *payload format*, not a connection. Every property the edge already enforces — agent
certificate verification, revocation re-checked per request, audience routing, rate limits, body size caps
(0008) — applies unchanged, because the result rides the request that already existed. A plugin gains no
route it did not have, and an operator has no new listener to firewall.

Today `Resource.spec_json` carries arbitrary per-kind JSON outward, and nothing structured comes back.
The return path is added symmetrically, and bounded at every hop:

```proto
message ApplyResourceResponse {
  Status status = 1;                 // applied | unchanged | failed
  bytes observed_digest = 2;         // unchanged from today
  bytes result_json = 3;             // NEW: plugin-defined, schema-validated, bounded
}
```

| Hop | Limit | Enforced by |
|-----|-------|-------------|
| Plugin half to agent | 16 KiB per resource | `serve`, which refuses a larger response |
| Agent to outbox | 256 KiB per report | The agent, which truncates and sets a `result_truncated` condition |
| Outbox budget | Counts against `outbox.maxBytes` | Existing 50 MiB cap and drop counter (0012) |
| Agent to provisioner | The agent ingress body limit, 8 MiB | `rackmarshal-gateway`, unchanged (0008) |
| Stored | 30-day partitions | `enforcement_reports`, unchanged retention |
| Provisioner to plugin half | `plugins.result.maxBytes` | The plugin host, before the call |

**Both ends validate both directions.** Every plugin payload is schema-validated twice: once by the party
about to transmit it, and again by the party about to act on it. Neither end relies on the other having
checked. This extends a discipline the design already has rather than inventing one — the agent
"schema-validates and OPA-checks specs before sending them" to plugins and "validates facts before
reporting them" (0013) — and applies it to the new return path in the same shape.

| Checkpoint | Party | Payload | On failure |
|------------|-------|---------|------------|
| Before dispatch | Provisioner | `spec_json` it renders into a bundle | `422` at write time, `policy_denied` or `schema_invalid`; nothing is signed |
| On bundle accept | Agent | `spec_json` it received | Reject the bundle, keep the previous generation (0012) |
| Before report | Agent | `result_json` its plugin returned | Resource-level `result_invalid`; the rest of the report still ships |
| On report accept | Provisioner | `result_json` it received | Store the failure, do not call `InterpretResult` |

The asymmetry in the last two rows is deliberate. A bad *spec* is a control-plane error and fails the
whole bundle, because dispatching a partially valid desired state is worse than dispatching none. A bad
*result* is one plugin misbehaving on one resource, and must not cost an endpoint its whole enforcement
record — so it degrades to a resource-level failure carrying `result_invalid`.

The schema each check uses is the one the plugin publishes with the version that is pinned, so both ends
validate against the same definition by construction: the pin covers the schema exactly as it covers the
binary and the policy.

**This amends 0011's "never content" rule, and the amendment is narrower than it sounds.** That rule
exists to keep file bodies out of the provisioner's database — a privacy and size control, written when
the only thing a plugin might have returned was the content it just wrote. A bounded, schema-validated,
plugin-defined result is not file content. The rule becomes: *never file content; bounded plugin results,
validated against the plugin's published schema.* Results are tenant data and inherit the handling 0009
already sets for facts — never logged, never in a metric label, and only their size and digest in a span.

`Propose` output is desired state like any other. It is written as a `DirectiveSet` revision attributed
to the plugin, and it passes admission, the tenant's policies, and the plugin's own policy before it can
be dispatched. A plugin that proposes something its own policy denies is refused, which is the intended
outcome rather than a corner case.

#### Plugin-supplied policy

Every plugin ships Rego, because the provisioner bundle is mandatory and `policy/` is part of it. It is
carried where each side's trust already comes from: the agent half's copy travels in the manifest that
`GetManifest` returns, "trusted only as far as the verified publisher" (0013), and the control plane's
comes from the bundle, verified at import through the same sigstore-go chain that already writes
`plugin_verifications` (0011). One trust root, two delivery paths, no new verification code — and no
executable involved in either.

```yaml
# manifest.yaml, additions
policies:
  - phase: admission                  # admission | dispatch | host
    package: rackmarshal.plugin.bigip.admission
    file: policy/admission.rego
  - phase: host
    package: rackmarshal.plugin.bigip.host
    file: policy/host.rego
```

Four rules make this safe, and the first is the one that matters:

1. **Scoped by the existing grant, by the evaluator.** A plugin's policy is evaluated only against
   resources whose kind appears in the `resource:<group>/<version>/<Kind>` capabilities the plugin was
   granted (0013). The host filters `input` before evaluation; the policy is not trusted to restrain
   itself. Without this, a plugin's Rego could deny `File` and `Package` resources it has nothing to do
   with, or deny another plugin's kinds — a supply-chain foothold wearing a policy's clothes.
2. **Denial only.** A plugin policy defines `deny` and nothing else, exactly as local `policy.d` on the
   agent "may only add denials" (0012). It can never permit what a layer above denied, so adding a plugin
   cannot widen what a tenant or the platform allows.
3. **Same sandbox.** The capability filter, `StrictBuiltinErrors`, the 500 ms deadline, and deny-on-error
   from 0011 apply unchanged. Plugin Rego adds no module to either binary, only compile time, and it is
   compiled once per plugin version and cached beside the plugin's other verified artifacts.
4. **Pinned with the plugin.** Policy is part of what the plugin digest covers, so it changes only when
   the pin changes. 0011's guarantee that "the same documents and facts always produce the same bundle
   digest" therefore still holds with plugin policy in the evaluation set.

The resulting stacks, with the new layer in bold:

| Phase | Provisioner | Agent |
|-------|-------------|-------|
| `admission` | platform, **plugin**, tenant | — |
| `dispatch` | platform, **plugin**, tenant | — |
| `host` | — | agent baseline, local `policy.d`, **plugin**, bundle `host` |

### Dependencies

- **Rackmarshal** — `rackmarshal-agent-plugin-sdk` gains the provisioner-side services and the `serve`
  helpers for them; `rackmarshal-api-schema` gains the `Plugin` kind; `rackmarshal-provisioner` gains the
  plugin host.
- **Third-party** — the mandatory path adds **nothing**. Validating a bundle's schemas and evaluating its
  Rego uses the jsonschema and OPA v1.20.2 that `rackmarshal-provisioner` already links (0011), and
  verifying the bundle uses the sigstore-go it already links for imports. This is the strongest argument
  for splitting the bundle from the service: the part every plugin must ship costs no new dependency.
  The optional plugin host does carry a cost — 0013's gRPC and go-plugin stack, measured at 14 linked
  modules — and because it is now needed only by plugins that interpret or propose, putting it behind a
  build tag is practical rather than theoretical. See Open questions.
- **Plugin authors** — `rackmarshal-plugin-starter` (0015) grows a provisioner-half example and a second
  fake host, so the local harness exercises the bundle, the optional service, and their pinning together.

### Data & storage

| Table | Change |
|-------|--------|
| `plugin_verifications` | Gains an `artifact` column; one row per verified artifact, bundle included |
| `plugin_bundles` | Verified schemas and compiled policy per plugin version, keyed by digest |
| `enforcement_reports` | Gains `result_json`, bounded, inside the existing monthly partitions |
| `endpoint_status` | Conditions may now originate from `InterpretResult` |
| `document_revisions` | Gains plugin-attributed revisions from `Propose` |

Compiled plugin policy is held in memory beside the tenant's compiled modules, keyed by plugin version,
and is rebuilt on a pin change like any other bundle input.

### Security

- **No new trust root.** Both halves are verified against the same `PluginPublisher` identity, at import,
  by the code that already does it. An artifact that fails verification is not installed, and a plugin
  missing a verified bundle fails import rather than running with an unpoliced kind.
- **No new authority.** A provisioner service receives a capability grant the same way an agent half does —
  the intersection of its manifest and the operator's policy, never more than the manifest declares
  (0013). `validate`, `interpret`, and `propose` are separate capabilities, so a plugin that only needs to
  read results cannot propose state.
- **Proposals are not applications.** `Propose` output is subject to admission, tenant policy, and the
  plugin's own policy. A plugin cannot reach an endpoint except through the same pipeline an operator uses.
- **Blast radius of a hostile plugin policy** is bounded to denying its own kinds, by construction
  (rule 1 above) rather than by review.
- **Result payloads are tenant data**, handled as 0009 handles facts: never logged, never in metric
  labels, size and digest only in traces.
- **Process isolation.** A provisioner service runs as its own user with no database credentials and no
  network grant by default, reachable only over the socket the host created. A plugin that ships only a
  bundle introduces no process at all, which is why the bundle is the mandatory part and the service is not.
- **No plugin-to-plugin path.** The halves never connect; results travel as a payload over the existing
  agent ingress. A compromised agent half can therefore send the control plane nothing but bytes that
  the gateway already authenticated, rate-limited, and size-capped.
- **Neither end trusts the other's validation.** Both the agent and the provisioner validate what they
  send and what they receive, so a compromised or simply buggy peer cannot place an unvalidated payload in
  front of plugin code on the other side. A single validating party would make whichever end was
  compromised the one deciding what the other end parses.

### Environment awareness

| Default | `production` | `staging` | `test` | `development` |
|---------|--------------|-----------|--------|---------------|
| Unverified plugin half | refused | refused | refused | refused |
| `Plugin` with no provisioner bundle | refused | refused | refused | refused |
| Declared kind with no schema in the bundle | refused | refused | refused | refused |
| Plugin policy compile error | deny | deny | deny | deny |
| Plugin `print` in Rego | off | off | off | on |
| Local unsigned plugin half | refused | refused | allowed | allowed |

Verification has no last-resort override in any tier, matching 0011: an unverifiable plugin is the case
the chain exists to stop.

### Logging & telemetry

Plugin calls carry `rackmarshal.plugin.name`, `rackmarshal.plugin.version`, and `rackmarshal.plugin.side`.
Metrics: `rackmarshal.plugin.calls` (by side, rpc, and outcome), `rackmarshal.plugin.policy.denials` (by
plugin and phase), `rackmarshal.plugin.result.bytes`, and `rackmarshal.plugin.result.truncated`. Spans wrap
each host-to-plugin call, so a proposal is traceable back to the report that produced it.

### Configuration

| YAML | Variable | Default |
|------|----------|---------|
| `plugins.provisioner.enabled` | `RACKMARSHAL_PROVISIONER_PLUGINS_ENABLED` | `true` |
| `plugins.provisioner.socketDir` | `RACKMARSHAL_PROVISIONER_PLUGINS_SOCKET_DIR` | `/run/rackmarshal-provisioner/plugins` |
| `plugins.provisioner.startTimeout` | `RACKMARSHAL_PROVISIONER_PLUGINS_START_TIMEOUT` | `30s` |
| `plugins.provisioner.callTimeout` | `RACKMARSHAL_PROVISIONER_PLUGINS_CALL_TIMEOUT` | `10s` |
| `plugins.result.maxBytes` | `RACKMARSHAL_PROVISIONER_PLUGINS_RESULT_MAX_BYTES` | `16384` |
| `plugins.policy.enabled` | `RACKMARSHAL_PROVISIONER_PLUGINS_POLICY_ENABLED` | `true` |

### Build, release & versioning

One release train per plugin, as 0014 already sets for the first-party set: every artifact built from one
commit, released under one tag, signed by one publisher identity, and recorded in one `plugins-index.json`.
The provisioner bundle is a release asset like the binaries, signed the same way. A release without one is
not a valid plugin release, which CI enforces in `rackmarshal-plugin-starter` (0015) so a third party finds
out at build time rather than at import.

### Testing

- **Bundle completeness** — a `Plugin` with no provisioner bundle fails import; a declared `resource:`
  capability with no matching schema fails `schema_missing`; a schema with no matching capability fails
  `schema_unclaimed`; version-skewed artifacts cannot be pinned from one `Plugin` document.
- **Admission without a service** — a plugin shipping only a bundle still has its kinds schema-validated
  and its policy evaluated at admission, with no plugin process running anywhere.
- **Scoping** — a plugin policy that denies a kind outside its grant has no effect; a table across the
  built-in kinds and a second plugin's kinds asserts it, and this is the test that must not be skipped.
- **Denial only** — a plugin policy defining `allow` cannot widen platform or tenant denials.
- **Result bounds** — oversized, malformed, and non-conforming results become resource-level failures and
  never reject a report; truncation sets its condition and its metric.
- **Bidirectional validation** — all four checkpoints reject a payload that violates the pinned schema,
  asserted by making each party the liar in turn: a provisioner that dispatches an invalid spec is caught
  by the agent, and an agent that reports an invalid result is caught by the provisioner.
- **Proposals** — `Propose` output passes through admission and is denied by the tenant's policy when the
  tenant denies it, and by the plugin's own policy when the plugin does.
- **Process model** — the plugin host recovers from a crashed half, and a half that never starts fails the
  plugin rather than the service; a half that attempts to bind a network port is refused by its sandbox.
- **Determinism** — the same documents, facts, and plugin pins produce the same bundle digest with plugin
  policy in the evaluation set.

## Alternatives considered

- **Keep `AgentPlugin` and add a sibling `ProvisionerPlugin`** — no churn on an existing kind, but the two
  halves could then be pinned at different versions while each document stays individually valid, and the
  failure would appear at apply time as an unparseable result. One document makes the skew
  unrepresentable, which is worth the rename.
- **Agent plugins with no provisioner bundle**, as they are today — no work for plugin authors, but the
  provisioner would sign a bundle containing a spec it cannot validate and a kind it cannot police, so a
  bad spec surfaces per endpoint after dispatch instead of once at admission. That is precisely the
  fail-closed-at-write-time property 0011 is built on, and plugin kinds are where it matters most.
- **A provisioner service in-process over go-plugin** — what 0011 rejected. It brings gRPC into the service
  and puts third-party code in the address space that holds the database credentials. A separate process
  keeps the isolation and costs a socket.
- **REST + JSON between the provisioner and its plugins**, to avoid amending the convention — consistent
  with service-to-service traffic, but a plugin author would then implement two wire protocols for one
  plugin, and the contract for the two halves would diverge over time. Widening the existing plugin
  carve-out keeps one `.proto` for both halves.
- **WASM plugins on wazero** for the provisioner half — one sandbox, no process management, and 0011
  already weighed wazero for OPA. Rejected for now because the agent half is a native binary with OS
  privileges, and a plugin whose two halves have different execution models is harder to write, test, and
  reason about than one that does not.
- **Results into `rackmarshal-inventory` as facts** — the existing `Fact.value_json` path already reaches
  the provisioner and needs no new field. It is the wrong shape: facts are endpoint state on a 5-minute
  cadence, not the outcome of one apply, and they carry no `reportId` to correlate against.
- **Unscoped plugin policy with review as the control** — simpler, and what a trusted-plugin model would
  do. Rejected because the verification chain establishes *who* published a plugin, never what its Rego
  intends, and a denial of `File` would look exactly like a legitimate rule.
- **Plugin policy that may allow as well as deny** — would let a plugin ship its own exceptions, and would
  let installing a plugin widen what a tenant permits. Denial-only keeps the platform and the tenant
  strictly above the plugin.

## Open questions

- **Module budget** — the plugin host would move 0013's gRPC and go-plugin stack (14 linked modules) into
  `rackmarshal-provisioner`, which already links OPA's 26. With the bundle mandatory and the service
  optional, a build tag now looks right rather than merely tempting: the default build would validate and
  police every plugin kind while linking no gRPC at all. Confirm, and decide whether the tagged build is
  the default in released artifacts.
- **Where a plugin's schemas live** — this document assumes the plugin publishes them and the provisioner
  half validates against them, which answers 0011's "who publishes their schemas" and 0013's "how do their
  schemas reach the agent and 0011". Does 0020's "no standalone JSON Schema files" rule extend to
  plugin-defined kinds, whose Go types cannot live in `rackmarshal-api-schema`?
- **`AgentPlugin` migration** — rename with an alias for one release, or a breaking change while every
  kind is still `v1alpha1`?
- **Sidecar lifecycle on Kubernetes** — a native sidecar (an init container with `restartPolicy: Always`)
  ties the plugin's lifetime to the pod's; is that the right coupling for a plugin that fails repeatedly?
- **Proposal loops** — a plugin whose `Propose` output triggers a report that triggers another proposal.
  A generation cap and a proposal-depth limit are the obvious controls; which, and what value?
- **Result schema evolution** — when a plugin's result schema changes between versions, the provisioner
  service may read a result an agent half wrote before the upgrade. Does the `Plugin` document need a
  compatibility range rather than a single version?
- **Per-tenant plugin enablement** — may a tenant refuse a plugin an operator installed, and does that
  belong in `Policy` or in a tenant setting?

## References

- [0001 — Project Repositories](0001-project-repositories.md#agent-plugin-ecosystem) — the plugin
  ecosystem and its verification requirements.
- [0011 — rackmarshal-provisioner](0011-rackmarshal-provisioner.md) — policy layers and the OPA contract,
  the `Driver` interface and its "built in, compiled in" rule, plugin import verification and
  `plugin_verifications`, `enforcement_reports` and the "never content" rule, and the rejection of
  out-of-process drivers over go-plugin.
- [0012 — rackmarshal-agent](0012-rackmarshal-agent.md) — the agent policy stack and its denial-only local
  layer, the plugin host and core trust, report contents, and the outbox budget.
- [0013 — rackmarshal-agent-plugin-sdk](0013-rackmarshal-agent-plugin-sdk.md) — the wire contract,
  `Resource.spec_json`, the capability model and grant intersection, and the open questions on third-party
  kinds and host callbacks.
- [0014 — rackmarshal-agent-plugins](0014-rackmarshal-agent-plugins.md) — the one-release-train model,
  `AgentPlugin` and `PluginPublisher`, signing, and SBOMs.
- [0015 — rackmarshal-plugin-starter](0015-rackmarshal-plugin-starter.md) — the third-party template and
  its local harness.
- [0020 — Desired-state kinds](0020-desired-state-kinds.md) — the document envelope, the resource envelope,
  and the rule that Go types are the only description of a kind.
- [CONVENTIONS.md](CONVENTIONS.md) — the REST + JSON rule and its plugin carve-out, and the replica rules
  the plugin host relies on.
- [hashicorp/go-plugin](https://github.com/hashicorp/go-plugin) — the plugin transport and `SecureConfig`.
- [OPA `v1/rego`](https://pkg.go.dev/github.com/open-policy-agent/opa/v1/rego) — capabilities, strict
  builtin errors, and evaluation deadlines.
- [sigstore-go `pkg/verify`](https://github.com/sigstore/sigstore-go) — the verification chain every
  plugin artifact shares.
