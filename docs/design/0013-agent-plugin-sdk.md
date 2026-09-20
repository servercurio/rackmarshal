<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0013 — agent-plugin-sdk

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `agent-plugin-sdk` defines the versioned gRPC contract between `agent` and
  its plugins over `hashicorp/go-plugin`. The agent gets launch helpers that pin each binary's SHA-256,
  use automatic mutual TLS, and start plugins with a clean environment. Plugins get a `serve` package
  that enforces the environment check and capability grants, plus a test harness. The contract includes
  a `VerifierService` that only a core-signed plugin may provide. The only third-party code is the
  go-plugin and gRPC stack, measured at 14 linked modules.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

In 0001, plugins are separate processes that `agent` launches over gRPC with
`hashicorp/go-plugin`. `provisioner` verifies plugin release signatures at import, the core
`sigstore` validator plugin verifies them again on the host before install, and before every launch the
agent pins the binary's SHA-256, taken from its signed directive bundle or a core plugin's signed
statement, through `SecureConfig`. The agent passes its environment ID, and a plugin refuses an agent
from another environment
([Agent plugin ecosystem](0001-project-repositories.md#agent-plugin-ecosystem),
[Environment identity](0001-project-repositories.md#environment-identity)). This repository is "the
stable contract plugins build against", and [CONVENTIONS.md](CONVENTIONS.md) makes it the only home of
Rackmarshal's gRPC contract.

**Goals**

- A versioned wire contract, so the agent and plugins release independently.
- One implementation of the go-plugin setup: hash pinning, mutual TLS, a clean environment, and
  protocol negotiation.
- The environment check and capability gates enforced once, for every plugin.
- A verifier contract and network grants that keep Sigstore verification out of the agent binary and
  the executor off the network.
- A small footprint and a harness authors can run without a real agent.

**Non-goals**

- Signature and core-signature verification policy, installation, OS sandboxing, and restarts —
  [0012](0012-agent.md); the validator implementation — [0014](0014-agent-plugins.md).
- Desired-state kind schemas — [0002](0002-api-schema.md).
- First-party plugins ([0014](0014-agent-plugins.md)) and the author template
  ([0015](0015-plugin-starter.md)).
- Agentless device drivers, which `provisioner` enforces remotely
  ([Desired-state model](0001-project-repositories.md#desired-state-model--one-authority-two-enforcement-paths)).

## Proposal

### Responsibilities

- **Contract** — protobuf definitions, generated Go code, handshake values, and protocol versions.
- **Manifest** — plugin names, capabilities, the `core` flag, and declared privileges and network
  grants, with validation.
- **Host and plugin sides** — `host` launches and calls plugins; `serve` is the plugin boilerplate
  with its interceptors.
- **Trace context and testing** — W3C propagation, the harnesses, and a conformance suite.

### Interfaces

#### Package layout

```
agent-plugin-sdk/
├── proto/rackmarshal/agent/plugin/v1alpha1/   # plugin.proto, facts.proto, resource.proto, verifier.proto
├── buf.yaml, buf.gen.yaml
├── pkg/
│   ├── plugin/v1alpha1/                 # package pluginv1alpha1 (generated, committed)
│   ├── handshake/                       # Config, SupportedProtocols
│   ├── manifest/                        # Manifest, Capability, Privileges, NetworkGrant, Policy
│   ├── bundle/                          # build, read, and verify a provisioner bundle (0021)
│   ├── serve/                           # Main, Options, FactsCollector, ResourceHandler, Granted
│   ├── host/                            # Launch, Config, Plugin, ErrEnvironmentMismatch
│   ├── tracecontext/                    # Carrier, UnaryClient, UnaryServer
│   └── plugintest/                      # InProcess, Launch, Conformance
└── Taskfile.yaml
```

#### Wire contract

Proposed: one protobuf package per protocol version, with services split by capability, using buf's
`STANDARD` naming (`<Rpc>Request`/`<Rpc>Response`, services suffixed `Service`).

```proto
syntax = "proto3";
package rackmarshal.agent.plugin.v1alpha1;
option go_package = "github.com/rackmarshal/agent-plugin-sdk/pkg/plugin/v1alpha1;pluginv1alpha1";

service PluginService {
  rpc GetManifest(GetManifestRequest) returns (GetManifestResponse); // allowed before Init
  rpc Init(InitRequest) returns (InitResponse);                      // environment check, grants
  rpc Check(CheckRequest) returns (CheckResponse);                   // liveness
}
service FactsService { rpc CollectFacts(CollectFactsRequest) returns (CollectFactsResponse); }
service ResourceService {
  rpc ValidateResource(ValidateResourceRequest) returns (ValidateResourceResponse);
  rpc PlanResource(PlanResourceRequest) returns (PlanResourceResponse);    // read-only diff
  rpc ApplyResource(ApplyResourceRequest) returns (ApplyResourceResponse); // idempotent
}
message Environment { string name = 1; string tier = 2; string id = 3; }
message InitRequest { Environment environment = 1; string agent_id = 2; Grant grant = 3; }
message Grant { repeated string capabilities = 1; Privileges privileges = 2; string mode = 3; }
message Resource { string api_version = 1; string kind = 2; string name = 3; bytes spec_json = 4; }
message Fact { string name = 1; bytes value_json = 2; } // name: <plugin>.<snake_case>

message ApplyResourceResponse {
  Status status = 1;                 // applied | unchanged | failed
  bytes observed_digest = 2;
  bytes result_json = 3;             // plugin-defined, validated against the bundle's result schema
}
```

`result_json` is the return half of `spec_json`, added by [0021](0021-plugin-extensibility.md). `serve`
refuses a response larger than 16 KiB, and the agent validates the payload against the result schema in
the plugin's provisioner bundle before it reaches the outbox. `PlanResourceResponse` carries the same
field for a dry run. A result that is oversized, unparseable, or non-conforming fails that one resource
with `result_invalid`; it never fails the report.

- **JSON payloads** — specs and fact values keep their 0002 JSON Schema form, with no protobuf copies
  of kinds. The agent schema-validates and OPA-checks specs before sending them (0001), and validates
  facts before reporting them.
- **Errors** — gRPC status codes with `google.rpc.ErrorInfo`: `reason` is a stable lower_snake_case
  code, as in CONVENTIONS' problem `code`, and `domain` is the plugin name. `errdetails` comes from
  `genproto/googleapis/rpc`, which gRPC already links.
- **Size** — gRPC's default 4 MiB receive limit. The agent passes content inline; plugins fetch nothing.
  The one exception is the validator's `RefreshTrust`, under its network grant.

#### Provisioner-side services

A plugin may ship an optional provisioner service alongside its required bundle (0021). It speaks the
same protobuf package, versioned with it, and `provisioner` launches it as a separate process
over a local socket:

```proto
service ProvisionerPluginService {
  rpc GetManifest(GetManifestRequest) returns (GetManifestResponse);
  rpc Init(InitRequest) returns (InitResponse);
  rpc ValidateDocument(ValidateDocumentRequest) returns (ValidateDocumentResponse);
  rpc InterpretResult(InterpretResultRequest) returns (InterpretResultResponse);
  rpc Propose(ProposeRequest) returns (ProposeResponse);
}
message InterpretResultRequest {
  Resource resource = 1; string endpoint_id = 2; string report_id = 3; bytes result_json = 4;
}
message InterpretResultResponse {
  string summary = 1; repeated Condition conditions = 2; repeated Resource proposed = 3;
}
```

The two halves of a plugin never connect to each other. A result reaches `InterpretResult` only as a
payload the agent posted through `gateway` and the provisioner validated on receipt, so a
plugin gains no route it did not have and opens no listener.

#### Verifier service

Proposed in `verifier.proto`, served only by the core `sigstore` plugin
([0014](0014-agent-plugins.md)) under the `verifier:sigstore` capability:

```proto
service VerifierService {
  rpc RefreshTrust(RefreshTrustRequest) returns (RefreshTrustResponse);       // mode "refresh" only
  rpc VerifyArtifact(VerifyArtifactRequest) returns (VerifyArtifactResponse); // "verify" mode, offline
}
message TrustMetadata { map<string, bytes> files = 1; }  // TUF metadata files by name
message TrustVersions { uint64 root = 1; uint64 timestamp = 2; uint64 snapshot = 3; uint64 targets = 4; }
message RefreshTrustRequest { TrustVersions accepted = 1; }
message RefreshTrustResponse { TrustMetadata metadata = 1; }
message PublisherIdentity {
  string issuer = 1; string repository = 2; string workflow = 3; repeated string refs = 4;
  bytes public_key_pem = 5; // set instead of the keyless fields for key-based publishers
}
message VerifyArtifactRequest {
  string sha256 = 1;        // digest the agent computed; binaries stay out of the 4 MiB message
  bytes bundle_json = 2;    // the asset's .sigstore.json
  PublisherIdentity publisher = 3;
  TrustMetadata trust = 4;
  TrustVersions accepted = 5; // rollback floor from the agent's state
}
message VerifyArtifactResponse {
  string verified_identity = 1; int64 log_index = 2; google.protobuf.Timestamp integrated_time = 3;
  TrustVersions accepted = 4;
}
```

- **Refresh** — fetches TUF metadata newer than `accepted` from the granted repository and returns it
  unverified; the caller stores it as untrusted input (0012).
- **Verify** — re-verifies `trust` from the root embedded in the validator, per the
  [TUF specification](https://theupdateframework.github.io/specification/latest/) (expiry, versions not
  below `accepted`), then verifies `bundle_json` for `sha256` against `publisher`: certificate identity,
  transparency-log entry, and an SCT for keyless certificates. Any failure is `PERMISSION_DENIED` with a
  reason such as `identity_mismatch`, `tlog_entry_missing`, or `trust_metadata_expired`.
- **Wrong mode** — `serve` rejects `RefreshTrust` in `verify` mode and `VerifyArtifact` in `refresh`
  mode with `PERMISSION_DENIED` (`mode_not_granted`).

#### Handshake and protocol versions

| Protocol | Protobuf package              | Stage | Status        |
|----------|-------------------------------|-------|---------------|
| `1`      | `rackmarshal.agent.plugin.v1alpha1` | alpha | first release |

- **Cookie** — `RACKMARSHAL_AGENT_PLUGIN` with a fixed random value. go-plugin calls the cookie "not a
  security measure, just a UX feature" (`server.go`). A binary run by hand prints help and exits.
- **Negotiation** — `host` offers the agent's protocols in `VersionedPlugins`. go-plugin passes them in
  `PLUGIN_PROTOCOL_VERSIONS`, and `serve` answers with one they share.
- **Compatibility** — additive fields and RPCs stay in the package. A host that calls a missing RPC
  gets `UNIMPLEMENTED` and treats the feature as absent. Any wire- or generated-code-breaking change
  creates a new package and protocol number, alpha included (see Alternatives).
- **Window** — the agent supports protocols N and N-1 and warns on N-1. SDK releases serve every
  protocol they implement.

#### Capability model

Each plugin embeds a `manifest.yaml`. `GetManifest` returns it, and each release publishes it
([0014](0014-agent-plugins.md)):

```yaml
name: packages                  # lowercase DNS label; binary rackmarshal-plugin-packages
version: 0.4.0
core: false                     # true is honored only with a verified core signature (0012)
protocolVersions: [1]
capabilities: [resource:rackmarshal.servercurio.com/v1alpha1/Package]
privileges:
  runAsRoot: true
  execPaths: [/usr/bin/apt-get, /usr/bin/dpkg-query, /usr/bin/dnf, /usr/bin/rpm]
  network:                      # package managers download from mirrors; operators narrow hosts
    - { host: "*", port: 80 }
    - { host: "*", port: 443 }
platforms: [linux/amd64, linux/arm64]
policies:                       # 0021; the same files ship in the provisioner bundle
  - { phase: host, package: rackmarshal.plugin.packages.host, file: policy/host.rego }
```

| Capability                          | Service           | Meaning                                                |
|-------------------------------------|-------------------|--------------------------------------------------------|
| `facts`                             | `FactsService`    | read-only inventory facts                              |
| `resource:<group>/<version>/<Kind>` | `ResourceService` | validate, plan, and apply one kind                     |
| `verifier:sigstore`                 | `VerifierService` | Sigstore verification for install decisions; core only |
| `validate`                          | `ProvisionerPluginService` | Validate a document at admission        |
| `interpret`                         | `ProvisionerPluginService` | Read an agent half's `result_json`      |
| `propose`                           | `ProvisionerPluginService` | Return follow-up desired state          |

The last three are granted to a provisioner service the same way the others are granted to an agent half:
the intersection of the manifest and the operator's policy, never more than the manifest declares. They
are separate capabilities so a plugin that only reads results cannot propose state.

1. **Declare** — after verifying and launching the plugin (0012), the agent reads its manifest. The
   manifest is trusted only as far as the verified publisher.
2. **Grant** — the grant is the intersection of the manifest and the operator's policy for the
   plugin, never more than the manifest declares.
3. **Core** — `core: true` and `verifier:*` capabilities are honored only for a binary whose core
   statement the agent verified (0012). `host` sets `Config.Core` only on that path; a manifest that
   claims `core` without it is refused (`core_signature_required`), and a non-core plugin is never
   granted a `verifier:*` capability.
4. **Gate** — `Init` carries the grant. `serve` rejects RPCs outside it with `PERMISSION_DENIED`
   (`capability_not_granted`), and `serve.Granted(ctx)` exposes the privilege grant to handlers.
5. **Enforce** — in-plugin checks are defense in depth. The boundary is the OS sandbox the agent builds
   from the grant (dedicated user, no network, path limits) through go-plugin's `RunnerFunc` (0012).

#### Network grants

`privileges.network` is a list of `{host, port}` destinations, with optional `mode`; absent or empty
means no network. The validator's manifest:

```yaml
name: sigstore
core: true
capabilities: [verifier:sigstore]
privileges:
  runAsRoot: false
  network:
    - { host: tuf-repo-cdn.sigstore.dev, port: 443, mode: refresh }
```

- **Defaults** — a manifest only requests; the agent grants. No plugin receives a network grant by
  default except the core validator in `refresh` mode, where the agent may substitute a configured TUF
  mirror for the declared host (0012). Every other grant must be listed in the agent's root-owned
  `plugins.grants` configuration, which narrows the manifest's request and never widens it, so a
  manifest asking for `{host: "*"}` reaches nothing until an operator names the hosts.
- **Modes** — the grant's `mode` selects entries: the validator runs as `refresh` (from `serve`) or
  `verify` (from the executor, never with network).
- **Enforcement** — the agent, not the OS, is the egress path: it runs a loopback proxy scoped to the
  grant and passes it in `Init` and through `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, so the same rules
  hold on Linux, Windows, and macOS (0012). `serve.Granted(ctx)` exposes the allowlist so a plugin's
  own clients refuse other destinations first. Neither check contains hostile code, which is why the
  grant is only given to signed plugins the operator approved.

#### Environment check

1. **Startup** — `serve.Main` starts without environment configuration of its own; the agent supplies
   name, tier, and ID in `Init`.
2. **Gate** — until `Init` succeeds, every RPC except `GetManifest` and `Check` returns
   `FAILED_PRECONDITION` (`not_initialized`). `Init` is accepted once.
3. **Record** — `Init` records the environment for logging and for `serve.Environment(ctx)`. A plugin
   that is separately configured with an environment (optional, and unusual) compares and returns
   `PERMISSION_DENIED` (`environment_mismatch`), logging both IDs and exiting with code 78; `host`
   returns `ErrEnvironmentMismatch` so the agent does not restart it in a loop.
4. **One source** — the agent's values come from enrollment and are authoritative. `host.Launch`
   refuses `Env` entries that set `<PREFIX>_ENVIRONMENT_*`, so the two paths cannot disagree. The
   agent already controls the plugin binary, its arguments, and its environment, so a plugin-side copy
   would add no boundary.

#### Plugin side (`serve`)

```go
type ResourceHandler interface {
    Validate(ctx context.Context, r serve.Resource) error
    Plan(ctx context.Context, r serve.Resource) (serve.Plan, error)                  // no host changes
    Apply(ctx context.Context, r serve.Resource, p serve.Plan) (serve.Result, error) // idempotent
}

func main() {
    os.Exit(serve.Main(serve.Options{
        Manifest:  manifestYAML,     // //go:embed manifest.yaml
        Version:   version.Number(),
        Configure: loadConfig,       // defaults → file → RACKMARSHAL_PLUGIN_<NAME>_* → *environment.Config
        Logger:    initLogging,      // receives the original stderr (see Logging & telemetry)
        Facts:     example.Facts{},  // FactsCollector: CollectFacts(ctx) ([]serve.Fact, error)
        Resources: map[string]serve.ResourceHandler{"plugins.example.com/v1alpha1/Marker": marker},
    }))
}
```

`serve.Main` checks for the magic cookie and a handler for every declared capability, and keeps the
original stderr for logging. It installs interceptors for panic recovery (`INTERNAL`, `plugin_panic`,
no stack in the reply), the `Init`, capability, and mode gates, trace extraction, and message size, then
calls `plugin.Serve` with gRPC only. `Options.Verifier` registers `VerifierService`.

#### Host side (`host`)

```go
p, err := host.Launch(ctx, host.Config{
    Name:   "packages",
    Path:   "/var/lib/rackmarshal-agent/plugins/packages/rackmarshal-plugin-packages",
    SHA256: digest,                             // from the verified install record (0012)
    Env:    map[string]string{"RACKMARSHAL_PLUGIN_PACKAGES_LOG_LEVEL": "info"},
    Stderr: logSink,                            // receives the plugin's JSON log lines
    ClientInterceptors: []grpc.UnaryClientInterceptor{tracecontext.UnaryClient(inject)},
})
if err != nil { return err }
defer p.Close()
m, err := p.Manifest(ctx)
err = p.Init(ctx, host.InitRequest{Environment: env, AgentID: agentID, Grant: policy.Grant(m)})
plan, err := p.Resources().PlanResource(ctx, &pluginv1alpha1.PlanResourceRequest{Resource: r})
```

`p.Verifier()` returns a `VerifierService` client only when `Config.Core` is true and the manifest
declares `core: true` and `verifier:sigstore`; otherwise it returns `ErrNotCoreVerifier`.

| go-plugin setting  | `host.Launch` value               | Reason                                         |
|--------------------|-----------------------------------|------------------------------------------------|
| `AllowedProtocols` | gRPC only                         | no `net/rpc` gob decoding                      |
| `SecureConfig`     | caller's SHA-256, required        | 0001; constant-time compare (`client.go`)      |
| `AutoMTLS`         | `true`                            | other local processes cannot use the socket    |
| `SkipHostEnv`      | `true`                            | agent credentials and proxies not inherited    |
| `UnixSocketConfig` | agent-owned `0700` directory      | socket unreachable by other users              |
| `Logger`           | `hclog.NewNullLogger()`           | the SDK does not log; lines go to `Stderr`     |
| `RunnerFunc`       | optional, from the caller         | sandboxing belongs to 0012                     |

`host` requires an absolute path to a regular file. On Unix, the file and its parent directories must
not be writable by group or others.

#### Trace context

`tracecontext.Carrier` implements `Get`, `Set`, and `Keys` over gRPC metadata for `traceparent` and
`tracestate` only (no baggage). The interceptors take inject and extract functions, such as closures
over `otel.GetTextMapPropagator()`, so the SDK never imports OpenTelemetry. The agent records a client
span per plugin RPC. The plugin extracts the remote context, so `common`'s `TraceHook` stamps
`trace_id` on its logs without the plugin exporting spans.

### Dependencies

- **Root module** — `hashicorp/go-plugin` v1.8.0 (latest), `google.golang.org/grpc` v1.83.2,
  `google.golang.org/protobuf` v1.36.12, and `common` (`environment` only).
- **Measured 2026-09-15** — throwaway gRPC plugin and host programs (`Serve`, `NewClient` with
  `SecureConfig`, `AutoMTLS`, `SkipHostEnv`) each link the same **14 modules** on linux and windows:
  `go-plugin`, `go-hclog`, `yamux`, `oklog/run`, `fatih/color`, `mattn/go-colorable`,
  `mattn/go-isatty`, `golang/protobuf`, `grpc`, `protobuf`, `genproto/googleapis/rpc`, `x/net`,
  `x/sys`, and `x/text`. `go list -m all` reports 43 for the probe module. `jhump/protoreflect` is
  required but not linked. Both binaries were 12 MiB stripped (18 MiB unstripped); 0012's tables use
  the same measurement.
- **gRPC floor** — go-plugin v1.8.0 requires gRPC v1.61.0 and protobuf v1.36.6. The SDK requires
  current versions, so minimal version selection gives every plugin current security fixes.
- **Not in the SDK** — `sigstore-go` v1.3.0: its verifier links 71 modules, including gRPC,
  OpenTelemetry, and `go-openapi`, and `go list -m all` reports 367
  ([0012](0012-agent.md#sigstore-verifier-measurements)). The SDK defines `VerifierService` but
  links no verifier; verification runs in `provisioner` ([0011](0011-provisioner.md)) and in
  the core `sigstore` plugin (79 linked modules, [0014](0014-agent-plugins.md)), not in the agent
  binary. `google.protobuf.Timestamp` comes from `protobuf`, already linked.
- **Tools** (not in `go.mod`) — buf v1.73.0, `protoc-gen-go` v1.36.12, and `protoc-gen-go-grpc` v1.6.2.
  All three were verified to run through `go run <module>@<version>`. `task tools` installs them into
  `.tools/bin` for `buf.gen.yaml`'s `local:` plugins.
- **Licenses** — go-plugin and yamux are MPL-2.0: binary distributors must tell recipients where the
  source is available (MPL FAQ). The rest are Apache-2.0, BSD-3-Clause, or MIT.

### Data & storage

None; only in-memory grant and environment state per plugin process.

### Security

- **Launch chain** — for core plugins, a core statement verified against the agent's embedded keys
  (0012); for other plugins, publisher signature verification at import (0011), a provisioner-signed
  pin, on-host verification by the core validator, and a digest-checked install (0012). Then, for both,
  the SHA-256 in `SecureConfig` on every launch, mutual TLS on the socket, the environment check, and
  capability gates.
- **Verifier trust** — the agent uses `VerifierService` only from a core-signed plugin; `core: true`
  and `verifier:*` in any other manifest are refused, so a non-core plugin can never provide the
  verifier behind install decisions.
- **`SecureConfig` gap** — go-plugin hashes `Path`, then executes `Path`, so a writer could swap the
  file in between. 0012's root-owned store (`plugins/<name>/`, `0555`, with the digest in a `.sha256`
  sidecar re-checked against the bundle pin at launch) and the writable-path refusal close that window
  in practice.
- **Clean environment** — plugins never receive the agent's variables, certificate, key, or token, and
  have no path to `gateway`.
- **Untrusted replies** — the agent validates and size-caps facts and verifier replies, and never shows
  plugin error details to operators verbatim.
- **Least privilege** — manifests default to no root, exec, writes, or network. Network grants are host
  and port allowlists, granted by default only to the core validator's `refresh` mode. Fuzzing covers
  manifest, capability, network grant, and fact-name parsing.

### Environment awareness

Plugins require name, tier, and ID at startup and refuse agents from another environment (0001). Tier
behavior goes through `common`'s `Hardened()` and `AllowLastResort`. `host.Launch` has no insecure
mode, and only `plugintest` uses `development` fixtures.

### Logging & telemetry

- **Stderr, not stdout** — go-plugin uses stdout for its handshake line, and `plugin.Serve` then
  redirects `os.Stdout` and `os.Stderr` to `SyncStdout` and `SyncStderr` streams (`server.go`). `serve`
  gives the original stderr to `common`'s logger. go-plugin reads it line by line into
  `host.Config.Stderr`, splitting lines longer than its 64 KiB buffer.
- **Re-emitted by the agent** — the agent parses each JSON line, adds `rackmarshal.plugin.name` and
  `rackmarshal.plugin.version`, rate-limits, and writes to its stdout. Non-JSON lines, such as panics, become
  `warn` events.
- **Fields and telemetry** — `service.name` is `rackmarshal-plugin-<name>`. Plugins export no telemetry in
  `v1alpha1`; the agent records `rackmarshal.agent.plugin.rpc.duration` (0012).

### Configuration

A plugin's prefix is `RACKMARSHAL_PLUGIN_<NAME>`: the name upper-cased, hyphens as underscores. The SDK's
config mounts under the child key `rpc`. The environment is not configurable here: the agent supplies
name, tier, and ID in `Init`, and `host.Launch` refuses any `<PREFIX>_ENVIRONMENT_*` variable.

| YAML                                 | Variable                                    | Default             |
|--------------------------------------|---------------------------------------------|---------------------|
| `rpc.maxMessageBytes`                | `RACKMARSHAL_PLUGIN_<NAME>_RPC_MAX_MESSAGE_BYTES` | `4194304`           |
| `rpc.initTimeout`                    | `RACKMARSHAL_PLUGIN_<NAME>_RPC_INIT_TIMEOUT`      | `30s`, then exit    |

### Build, release & versioning

- **Bootstrap** from `go-library-starter`, removing its runtime packages as
  [0002](0002-api-schema.md) does.
- **Tasks** — `tools`, `generate`, `check:drift`, `test`, `deps:check`, `proto:lint` (`buf lint`,
  `STANDARD`), and `proto:breaking` (`buf breaking` against the last tag with `FILE`, buf's default and
  strictest category, on every package).
- **CI** — the starters' 200, 300, and 100 workflows plus these checks.
- **Versioning** — `v0.x` per CONVENTIONS, independent of protocol numbers. `SupportedProtocols` and
  each release note list the protocols served. Dropping one is breaking and waits for the N-1 window.

### Testing

- **`plugintest.InProcess`** — go-plugin's `TestPluginGRPCConn`, using only the standard `testing`
  package.
- **`plugintest.Launch`** — a fake agent: it pins the binary's hash, enables mutual TLS and a clean
  environment, sends a `development` environment, and forwards stderr to `t.Log`.
- **`plugintest.Conformance`** — a valid manifest with handlers; refusal before `Init`, on environment
  mismatch (with exit), for ungranted capabilities, and for RPCs outside the granted mode; panics as
  `INTERNAL`; JSON log lines; and no changes from `Plan` after `Apply` for author-supplied samples.
- **SDK tests** — negotiation (host `{1,2}` against plugin `{1}`), a checksum mismatch, the
  writable-path refusal, `core: true` or `verifier:sigstore` without `Config.Core` refused, network grant
  validation, fuzzers, `-race`, and the allowlist.

## Alternatives considered

- **go-plugin `net/rpc`** — gob encoding with no schema; 0001 chose gRPC.
- **`protoc`** — a C++ binary that `go run` cannot install, with no lint or breaking checks.
- **Buf Schema Registry remote plugins** — need network access and an account to generate.
- **In-process WebAssembly plugins** — strong sandboxing, but contradicts 0001's separate processes.
- **Plugin configuration sent in `Init`** — the environment would then come from the agent being
  checked.
- **Certificate-backed environment proof** — the agent's X.509-SVID signs a nonce from the plugin. It
  is stronger, but the parent process already controls the binary and its environment, so the main
  risk is misconfiguration, which an ID comparison catches. Revisit if plugins hold environment secrets.
- **Signature verification in `host`** — `sigstore-go` would add 71 linked modules for every plugin
  author and the agent; verification runs at import (0011) and in the core validator's own process
  instead.
- **Streaming artifact bytes to `VerifyArtifact`** — lets the validator hash independently, but binaries
  exceed the 4 MiB message limit; the executor that computes the digest is already trusted.
- **A boolean `network` privilege** — cannot express the validator's single-destination grant.
- **Logs over a `GRPCBroker` callback** — structured, but crash output is lost and a second connection
  is needed.
- **`otelgrpc` interceptors** — would import OpenTelemetry into the SDK.
- **Deviations from [CONVENTIONS.md](CONVENTIONS.md)**:
  - Plugins log to stderr, not stdout (*Logging and telemetry*).
  - Alpha protobuf packages never break in place (*API versioning*).
  - go-plugin's auto mutual TLS uses ephemeral ECDSA P-521 certificates (`mtls.go`), not P-256
    (*Security and identity*). They are not Rackmarshal certificates and carry no SPIFFE ID.
  - `id` is required without Rackmarshal mutual TLS (*Environment*).

## Open questions

- **Log writer** — 0004's `logging.Initialize` needs an option to write to stderr.
- **Plugin spans** — no export (proposed), forwarding through the agent, or direct export with a network
  grant?
- **Third-party kinds** — which groups can they use? How their schemas reach the agent and
  [0011](0011-provisioner.md) is settled: the required provisioner bundle carries them
  ([0021](0021-plugin-extensibility.md)). The group-naming half is still open.
- **Long operations** — unary `ApplyResource` with a deadline (proposed), or streamed progress?
- **Scope** — `GRPCBroker` host callbacks (secrets, content), and host-attached device drivers?
- **Hardening** — execute from a verified file descriptor to close the `SecureConfig` gap? Windows ACL
  checks?
- **Network grant syntax** — are `"*"` hosts acceptable for package mirrors, and are CIDR ranges or URL
  path prefixes needed? OS-level enforcement is open in 0012.

## References

- [0001](0001-project-repositories.md), [CONVENTIONS.md](CONVENTIONS.md),
  [0002](0002-api-schema.md), [0003](0003-sdk.md), [0004](0004-common.md),
  [0012](0012-agent.md), [0014](0014-agent-plugins.md).
- [0021 — Plugin extensibility](0021-plugin-extensibility.md) — the provisioner bundle, the optional
  provisioner service, the result round trip, and plugin-supplied policy.
- [`hashicorp/go-plugin` v1.8.0](https://github.com/hashicorp/go-plugin/tree/v1.8.0) (MPL-2.0):
  - `client.go` — `SecureConfig`, `SkipHostEnv`, `AutoMTLS`, `RunnerFunc`, `logStderr`, 64 KiB buffer;
  - `server.go` — cookie comment, `PLUGIN_PROTOCOL_VERSIONS`, stdio redirection, Windows TCP listener;
  - `mtls.go`, `testing.go`, and [`go.mod`](https://github.com/hashicorp/go-plugin/blob/v1.8.0/go.mod);
  - [package docs](https://pkg.go.dev/github.com/hashicorp/go-plugin).
- [grpc-go](https://github.com/grpc/grpc-go) — `server.go` 4 MiB default;
  [`errdetails`](https://pkg.go.dev/google.golang.org/genproto/googleapis/rpc/errdetails).
- [Buf lint rules](https://buf.build/docs/lint/rules/) and
  [breaking rules](https://buf.build/docs/breaking/rules/) — `FILE`, `PACKAGE`, `WIRE_JSON`, `WIRE`.
- [protobuf-go](https://github.com/protocolbuffers/protobuf-go);
  [`protoc-gen-go-grpc`](https://pkg.go.dev/google.golang.org/grpc/cmd/protoc-gen-go-grpc).
- [sigstore-go](https://github.com/sigstore/sigstore-go) — measured verifier footprint;
  [`tuf`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf) — default TUF repository
  `https://tuf-repo-cdn.sigstore.dev`.
- [The Update Framework specification](https://theupdateframework.github.io/specification/latest/) —
  client workflow, rollback and freeze attack checks.
- [MPL 2.0 FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/);
  [W3C Trace Context](https://www.w3.org/TR/trace-context/).
