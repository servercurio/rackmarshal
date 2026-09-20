<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0012 — rackmarshal-agent

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `rackmarshal-agent` is one binary run as two processes: an unprivileged network daemon that
  enrolls, renews, pulls signed directive bundles, and reports, and a privileged executor with no network
  access that verifies bundles, re-checks OPA, runs Tengo, enforces resources, and launches verified
  plugins. Keys are TPM-backed where possible. Core plugins are trusted through Rackmarshal keys embedded in
  the agent; other plugins need a provisioner-signed pin and on-host verification by the core `sigstore`
  validator plugin, so the agent binary itself links no Sigstore verifier.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 defines the agent's enrollment ([Agent enrollment](0001-project-repositories.md#agent-enrollment)),
its on-host OPA re-check and Tengo sandbox
([Desired-state format](0001-project-repositories.md#desired-state-format)), its plugin model
([Agent plugin ecosystem](0001-project-repositories.md#agent-plugin-ecosystem)), and that it records its
environment from enrollment ([Environment awareness](0001-project-repositories.md#environment-awareness)).
It reaches Rackmarshal only through the gateway's agent ingress via `rackmarshal-sdk`.

**Goals**

- Nothing that terminates TLS or speaks to the network runs as root: the root executor parses only what
  the unprivileged daemon has written to the spool, and treats it as untrusted until verified.
- Idempotent, converge-then-verify enforcement that keeps working while offline.
- Every plugin launch verified: core plugins by a DSSE statement signed with an embedded Rackmarshal key;
  other plugins by a SHA-256 pin from a provisioner-signed bundle and, before install, by the core
  `sigstore` validator against the pinned publisher identity.
- Sigstore verification on the host without network access in the executor or a verifier in the agent
  binary.
- A measured dependency set, with the heaviest pieces confined and questioned.

**Non-goals**

- The plugin gRPC contract — [0013](0013-rackmarshal-agent-plugin-sdk.md); first-party and core plugins, and
  core signing — [0014](0014-rackmarshal-agent-plugins.md).
- Desired-state authoring, targeting, bundle signing, and plugin import verification —
  [0011](0011-rackmarshal-provisioner.md).
- Inventory schemas and storage — [0009](0009-rackmarshal-inventory.md); CA and token format —
  [0006](0006-rackmarshal-identity.md).

## Proposal

### Responsibilities

| Process                | Runs as                            | Does                                                                                               |
|------------------------|------------------------------------|----------------------------------------------------------------------------------------------------|
| `rackmarshal-agent serve`    | `rackmarshal-agent` user (+ `tss` group) | enrollment, key use, renewal, bundle pull, CRL fetch, TUF refresh through the validator, reporting |
| `rackmarshal-agent executor` | root, no network                   | bundle and plugin verification, OPA, Tengo, enforcement, plugins, privileged inventory             |

The processes share only a spool directory. `serve` writes bundles, CRLs, and TUF metadata to
`spool/inbox` (group `rackmarshal-agent`, `0770`); the executor treats them as untrusted, and writes reports
and inventory to `spool/outbox`. Other commands: `enroll`, `status`, `version`, and
`plugin verify <path>`.

### Interfaces

#### Enrollment

`rackmarshal-agent enroll --token-file <path>` (or the token on stdin, never as an argument, so it cannot leak
through the process list), built on `rackmarshal-sdk` `pkg/enroll` ([0003](0003-rackmarshal-sdk.md)):

1. `enroll.ParseToken` reads the environment ID and CA certificate hash offline.
2. **Key** — `keystore.auto` picks, in order: TPM 2.0 on Linux (`/dev/tpmrm0` via `go-tpm`, an ECC P-256
   signing key under the storage root key, stored as TPM-wrapped blobs), the Windows Platform Crypto
   Provider (`certtostore`), then `enroll.FileKeyStore` (`0600`, owned by `rackmarshal-agent`). The chosen
   backend is reported in inventory as `keyProtection` so policies can require hardware keys.
3. `enroll.Enroll` checks that the gateway's chain matches the token's CA hash and that its SPIFFE ID is
   `spiffe://<environment-id>/service/rackmarshal-gateway`. Only then does it send the CSR.
4. The certificate carries `spiffe://<environment-id>/agent/<agent-id>`. `Result` is written atomically
   to `identity/` with the environment `id`, `name`, `tier`, and `caBundle`.

`serve` refuses to start without an enrolled identity. If configuration also sets `environment.*`, the
values must match the recorded ones, which catches a host pointed at the wrong deployment. `enroll.Renewer`
renews at two-thirds of the lifetime with a **new key**, keeps the old key until the new certificate is
installed, and retries through the final third. An expired or revoked certificate stops `serve` until
the host is re-enrolled.

#### Directive pull and host evaluation

- **Pull** — `serve` long-polls `GET /provisioner/v1alpha1/directive-bundles/current` with
  `If-None-Match` and `waitSeconds=55`, with jittered backoff on errors (0011). It also fetches the
  environment CRL (path per 0006) so the offline executor can check the signer. The CRL is signed by the
  environment CA, so the gateway cannot rackmarshal one; it could withhold a fresh one, which is why a CRL
  older than its `nextUpdate` stops new bundles from being accepted, and why `revocation.crlUrl` may name
  a source that does not pass through the gateway.
- **Verify** (executor, fail closed): the DSSE signature; a signer chain to the environment roots
  evaluated at `issuedAt`; a signer SPIFFE ID of `spiffe://<environment-id>/service/rackmarshal-provisioner`,
  not revoked by a CRL whose `nextUpdate` has not passed; `environmentId` and `agentId` equal to the
  recorded values; `generation` greater than the last accepted one but not more than
  `bundle.maxGenerationJump` (default 1000) beyond it, so a forged bundle cannot set it near the type's
  maximum and wedge the host against every later legitimate generation; and `now < notAfter`. A
  generation from a signer the CRL has since revoked is discarded rather than recorded as the floor. The
  bundle's `coreKeyId` and revocation list are recorded with the same monotonicity: a bundle may move the
  current core key forward or add revocations, never move back or drop them, so a replayed older bundle
  cannot restore a retired or revoked key.
- **Validate** each resource against its JSON Schema — embedded from `rackmarshal-api-schema` for built-in
  kinds, and from the plugin's provisioner bundle for a plugin kind
  ([0021](0021-plugin-extensibility.md)). The provisioner validated the same specs before signing; the
  agent validates them again on accept, because neither end relies on the other having checked. A
  failure rejects the bundle and keeps the previous generation.
- **Policy** — OPA evaluates, in order, the embedded agent baseline (for example, deny kinds disabled in
  local config), root-owned local policies in `/etc/rackmarshal-agent/policy.d/*.rego` that may only add
  denials, each verified plugin's `host` policies scoped to the kinds that plugin was granted
  (0021), and the bundle's `host` policies. Same contract, capability filter, and 500 ms deadline as
  0011; an error or any `deny` rejects the whole bundle.
- **Scripts** — `host`-phase Tengo with the same allowlist and limits as 0011. The `rackmarshal` module exposes
  read-only host `facts()`; scripts compute values and never act.

#### Enforcement model

- **Handlers** — built-in kinds `File`, `Directory`, `Service` (systemd, Windows SCM, launchd), and
  `Package` (the OS package manager). Everything else is provided by plugins. Each handler implements
  `Observe`, `Diff`, `Apply`, and `Verify`.
- **Idempotence** — `Apply` runs only when `Diff` is non-empty; `Verify` re-observes and must be empty.
  Files are written to a temp file, `fsync`ed, and renamed.
- **Ordering** — resources run in `dependsOn` order; a failure skips its dependents and continues the
  others.
- **Cadence** — on every new bundle, and every `enforce.interval` (default 30 minutes) to correct drift.
  `mode: audit` observes and diffs only.
- **Reports** — per resource: status, a digest of observed state (never file content), timings, a
  `reportId`, and a plugin's bounded `result_json` when it returned one
  ([0021](0021-plugin-extensibility.md)), posted to
  `POST /provisioner/v1alpha1/enforcement-reports`. The agent validates a result against the schema in
  that plugin's bundle before queueing it, caps a report's results at 256 KiB, and sets
  `result_truncated` rather than dropping the report. Results count against `outbox.maxBytes` like
  anything else in the spool.

#### Inventory

Collectors use `gopsutil` (host, CPU, memory, disks, interfaces), `/etc/os-release`, and the package
database. Privileged facts such as DMI serials come from the executor through the outbox. Full reports
every 6 hours and changed-digest deltas every 5 minutes go to `rackmarshal-inventory` (operation per 0009).

#### Plugin host

- **Store** — `/var/lib/rackmarshal-agent/plugins/<name>/rackmarshal-plugin-<name>`, with its digest beside it in
  `rackmarshal-plugin-<name>.sha256`; the directory and both files are root-owned and `0555`. go-plugin's
  `SecureConfig.Check` hashes `cmd.Path` and then execs that path
  ([client.go L662](https://github.com/hashicorp/go-plugin/blob/v1.8.0/client.go#L662),
  [L735](https://github.com/hashicorp/go-plugin/blob/v1.8.0/client.go#L735)), so a writable store would
  leave a swap window between the two. Nothing but root can write this store, and every launch
  re-reads the sidecar digest and re-checks it against the accepted bundle pin before the hash.
- **Core plugins** — `sigstore` (`rackmarshal-plugin-sigstore`, the Sigstore validator) and `sysfacts` are
  built in [0014](0014-rackmarshal-agent-plugins.md) and ship in every agent package under
  `/usr/lib/rackmarshal-agent/plugins/<name>/`, each beside its `<asset>.core.dsse.json` envelope, root-owned
  and read-only. They are enabled by default. Root-owned local config may disable them
  (`plugins.core.disabled`), but cannot replace them: a binary runs as a core plugin only if its core
  statement verifies. With `sigstore` disabled, no non-core plugin can be installed (fail closed).
- **Core trust** — the agent embeds the Rackmarshal core-plugin public keys with `//go:embed`
  ([`embed`](https://pkg.go.dev/embed)): ECDSA P-256, as a list holding the current and next key for
  rotation. The private key stays in an HSM or cloud KMS and is used only by the `rackmarshal-agent-plugins`
  release workflow (0014). Before install and before every launch, the process launching a core plugin
  verifies its [DSSE](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md) envelope with
  the standard-library ECDSA code that already verifies bundles:
  - payload type exactly `application/vnd.rackmarshal.core-plugin.v1+json`, signed by an embedded key;
  - payload `{name, version, platform, sha256, protocolVersions, environmentIds}` whose `name` is the
    plugin being installed or launched, `platform` is the host's, `sha256` is the file's digest,
    `protocolVersions` overlaps the agent's, and `environmentIds` either lists the environment the host
    is enrolled in or is the explicit wildcard `["*"]` for a general release. A statement scoped to
    named environments cannot be replayed into another one.

  Binding the digest to name and platform stops a signed `sysfacts` from being installed as `sigstore`.
  The verified `sha256` is then pinned through `SecureConfig`. A newer core-signed build may be accepted
  without an agent release when the accepted bundle pins it; it installs into the store beside its
  envelope, and every launch re-verifies the envelope.
- **Install of other plugins** (executor, fail closed) — a downloaded plugin is moved into the store only
  when both checks pass:
  1. **Pin** — its SHA-256 equals a pin in the accepted, signature-verified bundle. `rackmarshal-provisioner`
     verified that release against the publisher's Sigstore signature at import (0011), and the pin
     carries the publisher identity it used.
  2. **Validator** — the executor verifies the core `sigstore` plugin's envelope, launches it in
     `verify` mode with no network, and calls `VerifyArtifact` (0013) with the digest, the asset's
     `.sigstore.json`, the pin's publisher identity, and the TUF metadata from `spool/inbox/tuf/`. The
     validator re-verifies the TUF chain from the root embedded in it, derives `trusted_root.json`, and
     checks the certificate identity, the transparency-log entry, and, for keyless certificates, the
     SCT. The returned identity must equal the pin's; it is recorded in `state/` with the log index and
     integrated time.

  The verifier used for install decisions is always the core-signed `sigstore` plugin; a non-core plugin
  that declares a verifier capability is never called for them.
- **Trust refresh** — every `plugins.sigstore.tufRefreshInterval`, `serve` verifies the validator's core
  envelope and launches it in `refresh` mode as the `rackmarshal-plugin` user. Its only network grant is the
  TUF repository: `https://tuf-repo-cdn.sigstore.dev`, sigstore-go's
  [`DefaultMirror`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf) and the published
  [sigstore/root-signing](https://github.com/sigstore/root-signing) repository, or
  `plugins.sigstore.tufMirror`. `RefreshTrust` returns the metadata, and `serve` writes it to
  `spool/inbox/tuf/`, so the plugin user needs no spool access. The grant is enforced in the validator's
  fetcher (HTTPS to the granted host and port, no redirects elsewhere); `IPAddressAllow=` takes only
  addresses and prefixes, not host names
  ([systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)).
- **Trust verification** — the executor treats that metadata as untrusted. `verify` mode checks the
  signatures, versions, and expiry of root, timestamp, snapshot, and targets against a fixed start time,
  rejecting rollback and freeze attacks as the
  [TUF specification](https://theupdateframework.github.io/specification/latest/) requires (§5.3–5.6),
  and returns the accepted versions, which the executor stores in `state/trust/` as the floor for the
  next call.
- **Re-validation** — proposed: when the verified `trusted_root.json` changes, the executor re-verifies
  every installed non-core plugin from its stored `.sigstore.json` and blocks further launches of any
  digest that fails, reported as a condition (see Open questions).
- **Before every launch** (executor): a non-core digest must still be pinned by the currently accepted
  bundle, and a core plugin's envelope must still verify. Then go-plugin launches with
  `SecureConfig{Checksum: pin, Hash: sha256.New()}`, `AllowedProtocols: [ProtocolGRPC]`, `AutoMTLS: true`,
  and `SkipHostEnv: true`.
- **Environment** — the agent is the only source: name, tier, and ID reach the plugin in the `Init`
  RPC (0013), never as `RACKMARSHAL_PLUGIN_<NAME>_ENVIRONMENT_*` variables, which `host.Launch` refuses. A
  plugin needs no environment configuration of its own to start.
- **Privileges** — plugins run as the `rackmarshal-plugin` user by default (`SysProcAttr.Credential`). Root is
  granted only when local, root-owned config lists the plugin under `plugins.privileged`; a bundle cannot
  grant it. The validator never runs as root.
- **Limits** — on Linux, each plugin starts in its own child cgroup (`SysProcAttr.UseCgroupFD`) under
  the executor's delegated subtree, with `memory.max`, `cpu.max`, and `pids.max`. On Windows, a Job
  Object (`CreateJobObject`, `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`). On macOS, `setrlimit` only.
- **Network grants, enforced by the agent** — the agent is the egress path; it relies on no OS network
  feature, so the rules are identical on Linux, Windows, and macOS. For each plugin process with a
  network grant (`packages`, and the validator's `refresh` mode), the agent starts a proxy bound to
  loopback on an ephemeral port, authorized by a per-process token, that accepts only the `{host,
  port}` pairs in that grant and refuses every other destination, redirect, and CONNECT target. It
  passes the proxy to the plugin two ways:
  - the SDK's client uses it through `Init` (0013), and
  - `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are set in the plugin's environment, so tools the
    plugin execs follow it too: apt supports `http_proxy` for system-wide configuration
    ([apt-transport-http](https://manpages.ubuntu.com/manpages/noble/en/man1/apt-transport-http.1.html)),
    dnf honors the curl variables when its own `proxy` option is unset
    ([dnf.conf](https://dnf.readthedocs.io/en/latest/conf_ref.html)), and Go clients follow
    [`http.ProxyFromEnvironment`](https://pkg.go.dev/net/http#ProxyFromEnvironment).

  Refused requests are logged with the plugin name and destination. This is agent policy, not a
  sandbox: a hostile plugin can open its own socket and bypass the proxy. The trust basis stays the
  signed plugin and the capability grant the operator approved; the proxy stops an honest plugin from
  reaching an ungranted destination and makes every attempt visible.
- **OS controls, shipped and optional** — the agent can also express each grant as native OS policy, so
  a bypass attempt fails in the kernel rather than only in the log. `osControls.mode` selects `off`
  (default), `check`, or `apply`; nothing touches host firewall state unless an operator sets `apply`.
  The definitions are derived from the accepted bundle, so they follow grant changes without
  hand-maintained templates:
  - **Executor lockdown** — `IPAddressDeny=any` with `IPAddressAllow=localhost` in a drop-in under
    `<unit>.d/`, which systemd merges after the unit file
    ([systemd.unit](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)); a block
    rule on the executor binary on Windows; the pf equivalent on macOS. Only the loopback proxy stays
    reachable.
  - **Per-plugin grant rules** — one rule set per plugin holding a network grant, including the
    validator's TUF egress: transient-unit properties on Linux
    ([systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)),
    `New-NetFirewallRule -Program` with `-RemoteAddress` and `-RemotePort` on Windows
    ([New-NetFirewallRule](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule)),
    and on macOS a pf anchor keyed on the plugin's user, since pf matches `user <user>` against the
    socket's owner ([pf.conf](https://keith.github.io/xcode-man-pages/pf.conf.5.html)).
  - **Regeneration** — on every accepted bundle whose grants differ, `apply` mode rewrites and reloads
    the definitions before the affected plugin launches, and refuses to launch it if that fails, so a
    grant is never left enforced only in the proxy when the operator asked for OS policy.
  - **Verification** — `rackmarshal-agent os-controls check` (also what `check` mode runs) compares live OS
    state with the generated definitions and reports drift without changing anything, for CI and the
    control node (0005).

  These controls harden the proxy; they do not replace it. systemd's IP filtering silently does nothing
  without eBPF cgroup support, which `check` reports as drift rather than assuming enforcement.
- **Supervision** — restart with exponential backoff; quarantine after 5 crashes in 10 minutes, reported
  as a condition.

### Dependencies

- **Rackmarshal** — `rackmarshal-sdk`, `rackmarshal-api-schema`, `rackmarshal-common`, `rackmarshal-agent-plugin-sdk`.
- **Starter** — cobra and `ants` from `go-cli-starter`. Its database packages (pgx, bun, goose) are
  removed: the agent keeps files, not a database.
- **New, measured** on 2026-09-15 in throwaway `linux/amd64` modules (`CGO_ENABLED=0`, stripped), counting
  modules in `go list -deps`:

| Module                                                                               | Version        | Linked | Binary   | Notes                                            |
|--------------------------------------------------------------------------------------|----------------|--------|----------|--------------------------------------------------|
| `hashicorp/go-plugin`                                                                | v1.8.0         | 14     | 12 MiB   | gRPC, genproto, hclog, yamux, `fatih/color`      |
| `open-policy-agent/opa/v1/rego`                                                      | v1.20.2        | 26     | 22.0 MiB | jwx, logrus, gqlparser; see 0011                 |
| `sigstore/sigstore-go` (not linked)                                                  | v1.3.0         | 71     | 17.5 MiB | measured below; runs in the core validator       |
| `d5/tengo/v2`                                                                        | pseudo-version | 1      | 3.4 MiB  | see 0011                                         |
| `google/go-tpm`                                                                      | v0.9.8         | 2      | 2.6 MiB  | + `x/sys`                                        |
| `shirou/gopsutil/v4`                                                                 | v4.26.8        | 4      | 3.3 MiB  | `go-ole` and `wmi` on Windows, `purego` on macOS |
| `google/certtostore` (Windows)                                                       | v1.0.7         | 6      | —        | `go-ole`, `google/deck`, `StackExchange/wmi`     |
| **Proposed agent set** — above, without certtostore and sigstore-go, with jsonschema | —              | **44** | 29.4 MiB | 165 in `go list -m all`                          |
| For comparison, with sigstore-go                                                     | —              | 102    | 33.3 MiB | 428 in `go list -m all`; 104 linked on Windows   |

The core validator's 79 modules live in the separate `rackmarshal-plugin-sigstore` binary, not in the agent's
44 (below).

#### Sigstore verifier measurements

Measured again on 2026-09-15 with Go 1.27.1: throwaway `linux/amd64` programs (`CGO_ENABLED=0`,
`-trimpath`) that import only the listed packages, counting the modules
[`go version -m`](https://pkg.go.dev/cmd/go#hdr-Print_Go_version) reports as compiled into the binary.

| Import set                                                     | Version  | Modules in the binary | `go list -m all` |
|----------------------------------------------------------------|----------|-----------------------|------------------|
| `sigstore-go/pkg/verify`                                       | v1.3.0   | 71                    | 367              |
| `pkg/verify`, `pkg/bundle`, `pkg/root`, and `pkg/tuf`          | v1.3.0   | 71                    | 367              |
| `sigstore-go/pkg/bundle`                                       | v1.3.0   | 71                    | 367              |
| `sigstore-go/pkg/root`                                         | v1.3.0   | 18                    | 209              |
| `sigstore/protobuf-specs` bundle types (`gen/pb-go/bundle/v1`) | v0.5.2   | 3                     | 128              |
| `sigstore/sigstore/pkg/signature`                              | v1.10.10 | 11                    | 69               |
| `transparency-dev/merkle/proof`                                | v0.0.2   | 1                     | 2                |
| `google/certificate-transparency-go/x509`                      | v1.3.3   | 2                     | 147              |

The 71 are sigstore-go and 70 others, from about 26 upstream projects: 23 `go-openapi` modules (its
`swag` package ships as many small modules), 7 `golang.org/x`, 6 `sigstore`, 4 gRPC, protobuf, and
genproto, and 4 OpenTelemetry. The import chains show that most come from service clients rather than
verification cryptography:

- `pkg/verify` → `pkg/tlog` → the generated Rekor v1 OpenAPI client → `go-openapi/runtime` →
  OpenTelemetry;
- `pkg/verify` → `rekor-tiles/v2` protobuf types → gRPC;
- `pkg/verify` → `sigstore/sigstore/pkg/signature` → `go-containerregistry` (image-name parsing);
- `pkg/verify` → `certificate-transparency-go/ctutil` → `loglist3` → `k8s.io/klog/v2`;
- `pkg/verify` → `pkg/root` → `pkg/tuf` → `go-tuf/v2`, even when the trusted root is loaded from a file.

The core validator plugin was measured the same day with Go 1.27.1 (`linux/amd64`, `CGO_ENABLED=0`,
`-trimpath -ldflags "-s -w"`), counting the modules `go version -m` lists as compiled in:

| Binary                                                        | Versions       | Modules in the binary | `go list -m all` | Stripped |
|---------------------------------------------------------------|----------------|-----------------------|------------------|----------|
| `hashicorp/go-plugin` alone                                   | v1.8.0         | 14                    | 43               | 12 MiB   |
| Validator: go-plugin + sigstore-go `pkg/verify` and `pkg/tuf` | v1.8.0, v1.3.0 | 79                    | 372              | 17 MiB   |

The validator links 65 modules beyond go-plugin. It shares `grpc`, `protobuf`, `golang/protobuf`,
`genproto/googleapis/rpc`, `x/net`, `x/sys`, `x/text`, `go-hclog`, `yamux`, `fatih/color`,
`go-colorable`, `go-isatty`, and `oklog/run` with go-plugin.

**Decision: no verifier in the agent binary.** A Rackmarshal-built verifier on the small building blocks above
would link about 4–6 modules (an estimate; that combination is not built), but it would re-implement
security-critical checks: the Fulcio certificate chain and identity, SCTs, and transparency-log
inclusion proofs and checkpoints. Instead, `rackmarshal-provisioner` verifies publisher signatures with
sigstore-go when a plugin release is imported ([0011](0011-rackmarshal-provisioner.md)), and the core
`sigstore` validator plugin ([0014](0014-rackmarshal-agent-plugins.md)) verifies them again on the host with
sigstore-go in its own unprivileged process. The agent binary keeps its 44 modules and verifies only
bundles and core envelopes with standard-library ECDSA. The trade-off is a 17 MiB core plugin on every
host and a second trust anchor, the core-plugin key. OPA is the largest addition to the agent; gRPC
comes in with go-plugin regardless.

### Data & storage

Under `/var/lib/rackmarshal-agent` (`%ProgramData%\rackmarshal-agent` on Windows); every write is atomic (temp file,
`fsync`, rename):

| Path              | Owner and mode             | Contents                                                                     |
|-------------------|----------------------------|------------------------------------------------------------------------------|
| `identity/`       | `rackmarshal-agent`, `0700`      | certificate, chain, key or TPM blobs, environment record                     |
| `spool/inbox/`    | root:`rackmarshal-agent`, `0770` | fetched bundles, CRLs, and TUF metadata (`tuf/`), untrusted                  |
| `spool/outbox/`   | root:`rackmarshal-agent`, `0750` | reports and inventory, capped at 50 MiB, oldest dropped and counted          |
| `state/`          | root, `0700`               | last accepted generation and bundle, handler state, plugin verifications     |
| `state/trust/`    | root, `0700`               | accepted TUF metadata versions and the verified `trusted_root.json`          |
| `plugins/<name>/` | root, `0555` files         | `rackmarshal-plugin-<name>`, its `.sha256` sidecar, and core update envelopes      |

Packaged core plugins and their envelopes live in `/usr/lib/rackmarshal-agent/plugins/<name>/` (root, `0555`),
owned by the OS package manager.

### Security

- **Privilege separation** — `serve` has no root and no write access to `state/` or `plugins/`. The
  executor's systemd unit sets `IPAddressDeny=any` with `IPAddressAllow=localhost`, and
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`. The address families must stay open: the agent's
  egress proxy is a loopback TCP listener, and `RestrictAddressFamilies=AF_UNIX` alone would block it
  for the executor and every plugin it forks, since the restriction is inherited and applies to the
  socket family, not the address. `IPAddressDeny=any` is what keeps external egress out
  ([systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html),
  [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)). It acts only
  on bundles signed by the provisioner, so compromising `serve` or the gateway does not yield root.
- **Hardening** — `serve` uses `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, and
  `ReadWritePaths` limited to `identity/` and `spool/`.
- **Keys** stay on the host; TPM keys are non-exportable. Tokens are read from files or stdin and never
  logged.
- **Plugin trust** — a compromised provisioner signing certificate can no longer approve an arbitrary
  binary: a non-core release must also carry a Sigstore signature, logged in the transparency log, for
  the identity in its pin, which leaves a public record. Logs carry digests, key IDs, and identities,
  never key material.
- **Core-plugin key** — only public keys are embedded. The private key signs only from the
  `rackmarshal-agent-plugins` release workflow through the HSM or KMS, whose audit log records each use.
  Because a stolen key would otherwise reach every host, two limits apply: a core statement names the
  environments it is valid for, and a revocation list of key IDs and plugin digests, signed by the other
  embedded key and carried in the directive bundle, is applied before any core verification. A revoked
  key or digest is refused even when its signature is valid, so recovery does not wait for an agent
  release. Rotation travels the same path: the current and next public keys are both embedded, and the
  bundle's `coreKeyId` names which is current (0011). The agent accepts core statements from the named
  key and refuses the previous one once a bundle has moved forward. Introducing a third key still needs
  an agent release, but making the next one current does not. Custody separates the two: the current key
  signs only from the release workflow through the HSM or KMS, while the next key stays on an offline
  HSM under split control. Activating it — or publishing the first bundle after a compromise — takes a
  quorum of M of N release engineers and out-of-band approval, so no single compromised signer or
  workflow can move every host, which is the property the two-key design exists for.
- **Validator isolation** — the `rackmarshal-plugin` user, its own cgroup, no root, exec, or writes. `refresh`
  mode has only the TUF grant and no spool access; `verify` mode has no network. Its replies are
  size-capped, and an approval still needs the bundle pin.
- **Fail closed** on any verification, policy, or pin failure; the previous accepted bundle keeps running.
- **Fuzzing** covers DSSE, bundle, and core-statement decoding, and the spool readers, including TUF
  metadata.

### Environment awareness

The four environment values come from enrollment ([CONVENTIONS.md](CONVENTIONS.md#environment)); logs,
reports, bundles, and plugins are all checked against the recorded ID.

| Behavior                                                 | `production` / `staging`                  | `test` / `development` |
|----------------------------------------------------------|-------------------------------------------|------------------------|
| File key store when no TPM                               | allowed, logged at `warn`                 | allowed                |
| Local plugin not pinned by a bundle (`unpinned-plugins`) | refused in `production` unless overridden | allowed, logged        |
| Signature verification (core statement, bundle pin)      | always required                           | always required        |
| Local policy `print`, verbose plans                      | off                                       | on                     |

### Offline behavior

- The executor re-applies the last accepted bundle every `enforce.interval` until its `notAfter`, then
  switches to `audit` mode and raises a condition.
- A new generation is accepted only with a CRL whose `nextUpdate` has not passed; a stale CRL blocks new
  changes but not re-application of the accepted bundle.
- Installed plugins keep launching from their pins, core envelopes, and `SecureConfig`. Installing a new
  non-core plugin needs TUF metadata that has not expired, so stale metadata blocks installs, not
  launches.
- Reports queue in the outbox; `serve` renews in the final third of the certificate lifetime when it
  reconnects, and an expired certificate requires re-enrollment.

### Logging & telemetry

Through `rackmarshal-common` in both processes, with `rackmarshal.agent.id`, `rackmarshal.bundle.generation`,
`rackmarshal.resource.kind`, and `rackmarshal.plugin.name`. Metrics: `rackmarshal.agent.enforce.duration`,
`rackmarshal.agent.resources.drifted`, `rackmarshal.agent.plugin.restarts`, and `rackmarshal.agent.outbox.dropped`.
Telemetry export runs only from `serve`; the executor writes its metrics to the outbox.

The OTLP log sink ([0004](0004-rackmarshal-common.md)) is **off by default on the agent**, unlike the
services. An endpoint is where the network is least likely to reach a collector — that is the point of
managing it — and an agent that retried log export against an unreachable endpoint would spend its
outbox budget on its own telemetry. The console sink writes logfmt to stderr, which journald on Linux
and the Event Log on Windows already collect, and `log.otlp.enabled` turns the sink on where a
collector is in fact reachable. The executor is unchanged: it writes to the outbox, and `serve` ships.

### Configuration

Prefix `RACKMARSHAL_AGENT_`; the gateway client uses `RACKMARSHAL_AGENT_GATEWAY_*` per 0003.

| YAML                                  | Variable                                            | Default                               |
|---------------------------------------|-----------------------------------------------------|---------------------------------------|
| `stateDirectory`                      | `RACKMARSHAL_AGENT_STATE_DIRECTORY`                       | `/var/lib/rackmarshal-agent`                |
| `keystore.backend`                    | `RACKMARSHAL_AGENT_KEYSTORE_BACKEND`                      | `auto` (`tpm`, `windows-pcp`, `file`) |
| `enforce.interval`                    | `RACKMARSHAL_AGENT_ENFORCE_INTERVAL`                      | `30m`                                 |
| `enforce.disabledKinds`               | `RACKMARSHAL_AGENT_ENFORCE_DISABLED_KINDS`                | empty                                 |
| `inventory.fullInterval`              | `RACKMARSHAL_AGENT_INVENTORY_FULL_INTERVAL`               | `6h`                                  |
| `plugins.privileged`                  | YAML only                                           | empty                                 |
| `plugins.grants`                      | YAML only                                           | empty (per plugin: network, paths)    |
| `plugins.core.disabled`               | YAML only                                           | empty (`sigstore`, `sysfacts`)        |
| `plugins.memoryMax`                   | `RACKMARSHAL_AGENT_PLUGINS_MEMORY_MAX`                    | `256MiB`                              |
| `plugins.sigstore.tufMirror`          | `RACKMARSHAL_AGENT_PLUGINS_SIGSTORE_TUF_MIRROR`           | `https://tuf-repo-cdn.sigstore.dev`   |
| `plugins.sigstore.tufRefreshInterval` | `RACKMARSHAL_AGENT_PLUGINS_SIGSTORE_TUF_REFRESH_INTERVAL` | `24h`                                 |
| `outbox.maxBytes`                     | `RACKMARSHAL_AGENT_OUTBOX_MAX_BYTES`                      | `52428800`                            |
| `osControls.mode`                     | `RACKMARSHAL_AGENT_OS_CONTROLS_MODE`                      | `off` (`check`, `apply`)              |

- **Air-gapped hosts** — proposed: `tufMirror` accepts an internal `https://` URL, or a `file://`
  directory populated out of band, for which `refresh` mode gets a read-only path grant and no network.
  The mirror is not trusted: metadata still verifies against the validator's embedded root, so it must
  be a copy of Sigstore's public repository. How mirrors are populated is an open question.

### Build, release & versioning

- **Platforms** — Linux `amd64` and `arm64` with systemd (tier 1); Windows `amd64` as two services, with
  the executor as LocalSystem and `serve` as a virtual service account (tier 2); macOS `arm64` with
  launchd (tier 2, file key store). Built with `CGO_ENABLED=0`.
- **Packaging** — deb, rpm, and apk through [nfpm](https://nfpm.goreleaser.com) v2.47.0 run with
  `go run`; an NSIS installer for Windows and a pkg for macOS. Packages include the units, users, and
  cosign-signed checksums plus the starter's signed SBOM, and the core plugins with their envelopes,
  pinned by `rackmarshal-agent-plugins` version and per-platform SHA-256 (0014). The packaging job verifies
  each envelope against the embedded keys, and each cosign bundle, before building.
- **Upgrades** — through the OS package manager, which a bundle may drive with a `Package` resource for
  `rackmarshal-agent`. The executor applies it last and restarts both units. An agent accepts the current and
  previous bundle `apiVersion`.

### Testing

- **Enrollment** against `sdktest` with a software TPM simulator where available (unverified choice).
- **Verification tables** — wrong signer SPIFFE ID, wrong environment, rollback, expired `notAfter`,
  stale CRL, and a plugin digest that no accepted bundle pins.
- **Core plugins** — an envelope signed by an unknown key, a wrong payload type, `name`, or `platform`,
  a digest mismatch, a non-core binary at a core path, a disabled `sigstore` blocking installs, and
  rotation from the current to the next embedded key.
- **Plugin install** — a matching pin with a wrong publisher identity, a missing transparency-log entry
  or SCT, TUF rollback, freeze (expired timestamp), and root-rotation fixtures, and `verify` mode failing
  any network call under `IPAddressDeny=any`.
- **Handlers** — idempotence (a second apply is a no-op) in containers per distribution.
- **Sandbox and limits** — Tengo escapes, OPA timeouts, plugin memory and pid limits, and crash
  quarantine. Fuzzing, `-race`, and the module allowlist.

## Alternatives considered

- **Single root process** — simpler, but the TLS stack, HTTP client, and bundle parsing would run as
  root.
- **Fully unprivileged agent with sudo rules** — too coarse to express per-resource needs, and hard to
  audit.
- **Linking sigstore-go into the agent binary** — adds about 59 modules to the agent (102 instead of 44)
  and runs them in the root executor, and a Rackmarshal-built verifier would re-implement security-critical
  checks; see [Sigstore verifier measurements](#sigstore-verifier-measurements).
- **Provisioner-only verification** (the previous draft) — no verifier process on hosts, but a
  compromised provisioner signing certificate alone could approve any binary.
- **Keyless Sigstore signatures for core plugins** — verifying them needs the validator, which is itself
  a core plugin; a key embedded in the agent breaks that cycle with standard-library ECDSA.
- **Refresh and verify in one process** — simpler, but the process that decides installs would need
  network access, which the executor's unit forbids.
- **Keyed cosign signatures checked on agents with standard-library ECDSA** — no new modules, but it
  drops the keyless publisher identities that 0001 requires.
- **Standard-library-only inventory** — avoids gopsutil's 4 modules, but means per-OS code for Windows
  and macOS.
- **Direct NCrypt calls instead of certtostore** — avoids `go-ole` and `wmi`, but more Windows code to
  own.
- **A local database (bbolt or SQLite)** — unnecessary for a few small, atomically replaced files.

## Open questions

- **Plugin distribution** — how binaries reach the host: a gateway-served artifact route, or an OCI
  registry?
- **CRL delivery** — which route serves the CRL on the agent ingress, and does `pkg/revocation` accept a
  file or mirror source for the non-gateway path (0003, 0006, 0008)?
- **macOS keys** — Secure Enclave needs cgo; is a file key store acceptable there?
- **Windows service account model** — a virtual service account per service, and how the installer
  creates it.
- **Agent ID** — assigned by `rackmarshal-identity` at enrollment (assumed) or derived from the key?
- **Core plugin downgrades** — may a bundle pin a core-signed version older than the packaged one?
- **Air-gapped TUF mirrors** — who copies Sigstore's repository into a mirror, how often (before
  timestamp metadata expires), and does `rackmarshal-infrastructure` own it? Private Sigstore deployments would
  need a different embedded root.
- **Re-validation on trusted-root change** — re-verify installed plugins and block failures (proposed);
  should a failure also stop a running plugin?
- **Wildcard grants** — the agent's proxy matches the grant's host names directly, so `{host: "*"}` for
  package mirrors grants any destination. Narrow it to the mirrors an operator configures, or keep the
  wildcard and rely on the audit log?

## References

- [0001 — Project Repositories](0001-project-repositories.md), [CONVENTIONS.md](CONVENTIONS.md),
  [0003](0003-rackmarshal-sdk.md), [0004](0004-rackmarshal-common.md), [0011](0011-rackmarshal-provisioner.md),
  [0013](0013-rackmarshal-agent-plugin-sdk.md), [0014](0014-rackmarshal-agent-plugins.md).
- [`hashicorp/go-plugin`](https://github.com/hashicorp/go-plugin) —
  [`SecureConfig`](https://pkg.go.dev/github.com/hashicorp/go-plugin#SecureConfig), `SkipHostEnv`,
  `AutoMTLS`, `UnixSocketConfig`; source read at v1.8.0.
- [sigstore-go](https://github.com/sigstore/sigstore-go) —
  [`verify`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/verify),
  [`root`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/root), and
  [`tuf`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf) (`DefaultMirror`) packages —
  measured; linked by the core validator plugin, not by the agent.
- [sigstore/protobuf-specs](https://github.com/sigstore/protobuf-specs),
  [transparency-dev/merkle](https://github.com/transparency-dev/merkle),
  [sigstore/sigstore](https://github.com/sigstore/sigstore), and
  [certificate-transparency-go](https://github.com/google/certificate-transparency-go) — measured building
  blocks.
- [`go version -m`](https://pkg.go.dev/cmd/go#hdr-Print_Go_version) — module list compiled into a binary.
- [Go `embed`](https://pkg.go.dev/embed) — `//go:embed` for the core-plugin public keys.
- [The Update Framework specification](https://theupdateframework.github.io/specification/latest/) —
  v1.0.36, client workflow §5.3–5.6 (rollback and freeze attack checks).
- [sigstore/root-signing](https://github.com/sigstore/root-signing) — Sigstore's TUF repository,
  published at `https://tuf-repo-cdn.sigstore.dev`.
- [Sigstore cosign](https://docs.sigstore.dev/cosign/signing/overview/).
- [0021 — Plugin extensibility](0021-plugin-extensibility.md) — the result round trip, plugin-supplied
  policy, and the bidirectional validation rule.
- [OPA `v1/rego`](https://pkg.go.dev/github.com/open-policy-agent/opa/v1/rego) and
  [Tengo](https://github.com/d5/tengo).
- [go-tpm](https://github.com/google/go-tpm), [certtostore](https://github.com/google/certtostore), and
  [gopsutil](https://github.com/shirou/gopsutil).
- [DSSE](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md) — protocol, PAE, and payload
  types; [envelope](https://github.com/secure-systems-lab/dsse/blob/master/envelope.md).
- [`syscall.SysProcAttr` (Linux)](https://pkg.go.dev/syscall?GOOS=linux#SysProcAttr) — `Credential`,
  `UseCgroupFD`, `CgroupFD`; [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html).
- [`golang.org/x/sys/windows`](https://pkg.go.dev/golang.org/x/sys/windows) — `CreateJobObject`,
  `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`.
- [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) and
  [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
  — `IPAddressAllow=` and `IPAddressDeny=` take addresses and prefixes.
- [nfpm](https://nfpm.goreleaser.com) — deb, rpm, and apk packaging.
- [`kubeadm join`](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/).
- [go-cli-starter](https://github.com/servercurio/go-cli-starter) — cobra, `ants`, `serve` daemon.
