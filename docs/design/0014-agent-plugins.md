<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0014 — agent-plugins

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `agent-plugins` is one Go module that builds five first-party plugin executables —
  the Sigstore validator, system facts, packages, files, and services — released together on one
  version. Each binary ships with a SHA-256, a keyless cosign bundle signed from GitHub Actions, and a
  CycloneDX SBOM, so `provisioner` can verify each release and `agent` can pin and install
  exactly the plugin versions its desired state names. The core plugins, `sigstore` and `sysfacts`, are
  also core-signed with a KMS- or HSM-held key and bundled in every `agent` package.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 lists `agent-plugins` as the first-party plugin executables, built on
`agent-plugin-sdk` and seeded from `go-cli-starter`
([Repository inventory](0001-project-repositories.md#repository-inventory)). `provisioner`
verifies each plugin release's Sigstore signature against trusted publisher identities, the core
`sigstore` validator verifies it again on the host, and the agent pins its SHA-256 before every launch;
core plugins are trusted through keys embedded in the agent
([Agent plugin ecosystem](0001-project-repositories.md#agent-plugin-ecosystem)). The contract,
grants, and environment check come from [0013](0013-agent-plugin-sdk.md).

**Goals**

- A modest, justified first plugin set for common server convergence.
- Core plugins that every agent package bundles and trusts through a core signature: the on-host
  Sigstore validator and system facts.
- A layout that keeps each binary's dependencies and privileges separate.
- Release artifacts that meet the provisioner's and the host validator's verification: signature,
  digest, SBOM, and manifest.
- A documented path from a release to a pinned plugin on a host.

**Non-goals**

- Import verification — [0011](0011-provisioner.md); installation, core-signature checks, and
  sandboxing — [0012](0012-agent.md). The contract — 0013.
- Third-party plugins — [0015](0015-plugin-starter.md). Agentless devices —
  [0011](0011-provisioner.md).
- Templating or scripting on hosts; Tengo runs in the agent and provisioner (0001).

## Proposal

### Responsibilities

- Source, tests, manifests, and releases for the first-party plugins.
- Per-plugin build matrices, SBOMs, signatures, and a signed release index.
- Core signing of `sigstore` and `sysfacts`, and the core artifacts `agent` packages.
- A compatibility statement across plugin releases, SDK versions, and protocol versions.

### Interfaces

#### Repository layout

Proposed: **one Go module with one `cmd/` directory per plugin.**

```
agent-plugins/
├── cmd/rackmarshal-plugin-{sigstore,sysfacts,packages,files,services}/main.go   # serve.Main wiring only
├── internal/
│   ├── sigstore/  sysfacts/  packages/  files/  services/   # one tree per plugin; no imports between
│   ├── execx/                           # exec: absolute paths, no shell, clean env, caps
│   ├── fsx/                             # os.Root-confined, no-follow, atomic writes
│   └── version/
├── manifests/<name>.yaml                # embedded in each binary; published per release
├── deps/<name>.allow                    # linked-module allowlist per binary
├── keys/core-plugins.pem                # core-plugin public keys (current and next), as in agent
├── tools/coresign/                      # DSSE core statements; standard library only
├── plugins.yaml                         # per-plugin platforms and core flag, read by Taskfile and CI
├── e2e/                                 # nested module: container-based resource tests
└── Taskfile.yaml, .releaserc.json
```

```yaml
# plugins.yaml
- { name: sigstore, core: true,  platforms: [linux/amd64, linux/arm64] }
- { name: sysfacts, core: true,  platforms: [linux/amd64, linux/arm64] }
- { name: packages, core: false, platforms: [linux/amd64, linux/arm64] }
- { name: files,    core: false, platforms: [linux/amd64, linux/arm64] }
- { name: services, core: false, platforms: [linux/amd64, linux/arm64] }
```

- **Why one module** — plugins are executables nobody imports. One `go.mod` means one set of
  dependency versions (one gRPC version), one Dependabot stream, and one `govulncheck` run. Go links
  only imported packages, so a dependency added for `sysfacts` stays out of `packages`.
- **Isolation** — a golangci-lint `depguard` rule forbids imports between plugin trees and keeps
  sigstore-go out of every tree but `internal/sigstore`. `deps/<name>.allow` is checked against
  `go list -deps -f '{{with .Module}}{{.Path}}{{end}}' ./cmd/rackmarshal-plugin-<name>`.

#### Initial plugin set

| Plugin     | Core | Capability                                | Kinds (`rackmarshal.servercurio.com/v1alpha1`) | Privileges                            |
|------------|------|-------------------------------------------|------------------------------------------|---------------------------------------|
| `sigstore` | yes  | `verifier:sigstore`                       | —                                        | unprivileged; TUF egress in `refresh` |
| `sysfacts` | yes  | `facts`                                   | —                                        | unprivileged                          |
| `packages` | no   | `resource:…/Package`                      | `Package`                                | root, exec, network                   |
| `files`    | no   | `resource:…/File`, `resource:…/Directory` | `File`, `Directory`                      | root, granted paths                   |
| `services` | no   | `resource:…/Service`                      | `Service`                                | root, exec `systemctl`                |

- **`sigstore`** — the on-host validator behind 0013's `VerifierService`, on sigstore-go v1.3.0
  `pkg/verify` and `pkg/tuf`. `RefreshTrust` fetches TUF metadata from the granted repository and
  returns it without trusting it. `VerifyArtifact` has no network: it re-verifies the metadata chain from
  the Sigstore root embedded in the binary (sigstore-go's
  [`DefaultRoot`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf)) with go-tuf v2's
  [`trustedmetadata`](https://pkg.go.dev/github.com/theupdateframework/go-tuf/v2/metadata/trustedmetadata),
  which verifies bytes without I/O, loads `trusted_root.json` with `root.NewTrustedRootFromJSON`, and
  calls `verify.NewVerifier` with `WithTransparencyLog`, `WithIntegratedTimestamps`, and, for keyless
  publishers, `WithSignedCertificateTimestamps`. The policy is `WithArtifactDigest` plus
  `WithCertificateIdentity` built from the publisher's structured fields (or `WithKey`), never a
  free-form regular expression. Whether go-tuf's `trustedmetadata` is within the 79 measured modules is
  unverified.
- **`sysfacts`** — OS release, kernel, CPU, memory, filesystems, interfaces, and uptime. Linux first,
  read from `/proc`, `/sys`, and `/etc/os-release` with `golang.org/x/sys/unix`, which gRPC already
  links. No facts that require root.
- **`packages`** — `Package` (`name`, optional `version`, `state`) through `apt-get`/`dpkg-query` and
  `dnf`/`rpm`. Arguments go in arrays after `--`, and names must match the schema pattern. Repository
  configuration is out of scope at first.
- **`files`** — `File` (`path`, `content`, `mode`, `owner`, `group`, `state`) and `Directory`.
  Content arrives already rendered, so the root plugin has no template engine. Writes are confined to
  granted prefixes by [`os.Root`](https://pkg.go.dev/os#Root): written to a temporary file, synced, and
  renamed.
- **`services`** — `Service` (`name`, `state`, `enabled`). `Plan` reads
  `systemctl show --property=ActiveState,UnitFileState`; `Apply` calls `systemctl`. systemd only.
- **Why these four** — package, file, and service cover basic server convergence, much like the core
  modules of configuration-management tools such as Ansible's builtin `package`, `copy`, and `service`
  (not re-checked). Separate binaries keep the unprivileged fact collector away from root and network
  grants.
- **Why these are core** — `sigstore` must be present before any other plugin can be installed, and
  `sysfacts` lets every agent report facts before its first bundle. `packages`, `files`, and `services`
  stay downloadable, pinned by bundles.
- **Deferred** — users and groups, firewall, scheduled jobs, containers, Windows services, and non-Linux
  facts. Each needs its own privilege review.

The kinds' schemas and Go types live in `api-schema` (`desiredstatev1alpha1`, 0002), which has no
dependencies.

### Dependencies

- **Rackmarshal** — `agent-plugin-sdk`, `common` (`logging`, `environment`), and
  `api-schema`.
- **Third party** — for every plugin except `sigstore`, only the SDK's 14 measured modules (0013) plus
  zerolog through `common`: about 16 per binary. That is an estimate until the Rackmarshal modules exist;
  `deps/*.allow` records the actual list.
- **`rackmarshal-plugin-sigstore`** — go-plugin v1.8.0 with sigstore-go v1.3.0 `pkg/verify` and `pkg/tuf`
  links **79** modules, 65 beyond go-plugin; `go list -m all` reports 372, and the stripped binary is
  17 MiB. Measured 2026-09-15 with Go 1.27.1 (`linux/amd64`, `CGO_ENABLED=0`,
  `-trimpath -ldflags "-s -w"`, modules `go version -m` lists as compiled in;
  [0012](0012-agent.md#sigstore-verifier-measurements)). `deps/sigstore.allow` records the 79.
  Because the module is shared, sigstore-go's requirements join every plugin's version selection, even
  though the other binaries do not link them.
- **Measured, not chosen** — `shirou/gopsutil/v4` v4.26.8 (BSD) adds 3 linked modules per OS:
  - linux: `tklauser/go-sysconf`, `tklauser/numcpus`;
  - darwin: `ebitengine/purego`, `go-sysconf`;
  - windows: `go-ole/go-ole`, `yusufpapurcu/wmi`.

  Measured 2026-09-15; revisit when non-Linux facts are in scope.
- **Tools** (not in `go.mod`) — cyclonedx-gomod v1.12.0 (latest, as the starter pins); cosign v3.1.3
  through `sigstore/cosign-installer` v4.1.2; golangci-lint v2.13.2; and the starter's semantic-release.
  syft goes along with the container build. Core signing uses the cloud KMS CLI (see Core signing).

### Data & storage

Plugins keep no state. Installed binaries on hosts belong to 0012.

### Security

- **Exec** — `execx` runs only absolute paths from the grant, never through a shell. It sets an
  explicit environment (`LC_ALL=C`, `DEBIAN_FRONTEND=noninteractive`), puts `--` before operands,
  enforces context timeouts, and caps captured output at 1 MiB.
- **Filesystem** — `os.Root` rejects escapes through symlinks; writes are atomic; owner and mode changes
  are explicit.
- **Parsers** — `os-release`, `dpkg-query`, `rpm`, and `systemctl show` output are fuzzed against golden
  fixtures, and `sigstore` fuzzes bundle and TUF metadata inputs.
- **Validator** — no root, exec, or writes. Network only in `refresh` mode, to its granted TUF host; in
  `verify` mode any network use is a bug: the agent gives it no proxy, so the attempt fails (0012).
- **Supply chain** — SHA-pinned actions and `harden-runner`, as in the starter. `id-token: write` only
  in the release job. `CODEOWNERS` on `.github/workflows/`, since whoever changes the signing workflow
  controls what the identity signs. `govulncheck` and CodeQL.
- **Identity scope** — Fulcio puts the signing workflow's `job_workflow_ref` in the certificate SAN.
  That is the reusable 800 workflow in this repository, so the identity names `agent-plugins`.
- **Core-plugin key** — ECDSA P-256 in an HSM or cloud KMS. Only the release job's identity, federated
  from GitHub OIDC with no stored credentials, may sign with it, only on protected refs, and only after
  `task verify` passes; the KMS or HSM audit log records every use. Key IDs and digests are logged,
  never key material or tokens.

### Environment awareness

Plugins require `environment` configuration and perform 0013's check. Tier logic uses `common`.
For example, `packages` makes installing from unauthenticated repositories the last-resort feature
`unauthenticated-packages`, which `production` refuses unless overridden.

### Logging & telemetry

JSON logs go to stderr and the agent re-emits them (0013). Fields: `rackmarshal.resource.kind`,
`rackmarshal.resource.name`, `rackmarshal.resource.changed`. Commands are logged by executable and argument count
only, since arguments can carry resource data. No telemetry export.

### Configuration

Prefixes are `RACKMARSHAL_PLUGIN_SIGSTORE`, `_SYSFACTS`, `_PACKAGES`, `_FILES`, and `_SERVICES`, with the
SDK's `environment` and `rpc` keys and `common`'s `logging`. Grants carry paths, executables, and
network destinations, so plugin keys stay few:

| YAML          | Variable                             | Default                          |
|---------------|--------------------------------------|----------------------------------|
| `manager`     | `RACKMARSHAL_PLUGIN_PACKAGES_MANAGER`      | `auto` (`apt` or `dnf` by probe) |
| `lockTimeout` | `RACKMARSHAL_PLUGIN_PACKAGES_LOCK_TIMEOUT` | `5m`                             |
| `collectors`  | `RACKMARSHAL_PLUGIN_SYSFACTS_COLLECTORS`   | all                              |

### Build, release & versioning

#### Build matrix

`plugins.yaml` declares each plugin's platforms, and `task build` loops over them with the starter's
`CGO_ENABLED=0`, `-trimpath`, and `-ldflags "-s -w"`. All five plugins ship `linux/amd64` and
`linux/arm64` first. The starter's other four targets (darwin and windows) are added per plugin when
implemented, and pull requests cross-compile every declared platform. The Dockerfile, GHCR push, and
container SBOM are removed, since plugins are host binaries.

#### One release train

Proposed: **one semantic-release version for the repository** (`vX.Y.Z`, `v0.x` per CONVENTIONS).
Every release rebuilds every plugin, and commit scopes such as `feat(packages): …` group the notes.

- **Why** — changes to the shared `go.mod`, `go.sum`, or `internal/execx`, such as a gRPC security fix,
  must release every binary. semantic-release-monorepo 8.0.2 assigns commits to a package only by files
  under that package's directory, so a dependency fix at the repository root would release nothing.
- **Cost** — every release gives each plugin a new version and digest. The agent pins plugins
  individually, so operators still upgrade them one at a time.

#### Assets, signing, and SBOMs

Per plugin and platform, with `<asset>` = `rackmarshal-plugin-<name>-<os>-<arch>`:

| Asset                                        | Purpose                                                  |
|----------------------------------------------|----------------------------------------------------------|
| `<asset>`, `<asset>.sha256`                  | executable and the digest the agent pins                 |
| `<asset>.sigstore.json`                      | cosign bundle: signature, certificate, Rekor proof       |
| `<asset>.core.dsse.json` (core plugins only) | DSSE core statement signed with the core-plugin key      |
| `<asset>.cdx.json` + bundle                  | CycloneDX SBOM with licenses                             |
| `rackmarshal-plugin-<name>.manifest.yaml` + bundle | capabilities, privileges, protocol versions              |
| `rackmarshal-plugin-<name>.provisioner.tar.zst` + bundle | **required** provisioner bundle: schemas, Rego, result schema |
| `plugins-index.json` + bundle                | name, version, platform, SHA-256, protocols, SDK version |

The provisioner bundle is per plugin rather than per platform, because it is data rather than an
executable. It is required of every plugin, including the core ones: a release without it is not a valid
plugin release, since the control plane could then neither validate nor police the kinds that release
declares ([0021](0021-plugin-extensibility.md)).

`.releaserc.json` keeps the starter's analyzer rules, with a `publishCmd` of
`task build && task hash && task sign && task coresign && task sbom && task index && task verify`.
The release job installs cosign first. `task sign` and `task verify` run:

```sh
repo=servercurio/agent-plugins
wf=.github/workflows/800-call-semantic-release.yaml
cosign sign-blob --yes --bundle "bin/${f}.sigstore.json" "bin/${f}"
cosign verify-blob "bin/${f}" --bundle "bin/${f}.sigstore.json" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/${repo}/${wf}@${GITHUB_REF}"
```

- **Keyless** — GitHub OIDC (`https://token.actions.githubusercontent.com`) through Fulcio, so there
  are no long-lived keys. The bundle carries the Rekor inclusion proof, so `provisioner` and the
  host validator can verify offline with a `trusted_root.json`; cosign v3.1.3 deprecates `--offline` in
  favor of `--bundle` plus `--trusted-root`. Every plugin, core or not, still gets a keyless bundle.
- **`task verify`** fails the release if the identity drifts, for example after a workflow rename, or if
  a core envelope does not verify against `keys/core-plugins.pem`.
- **SBOMs** — `cyclonedx-gomod app -licenses -main cmd/rackmarshal-plugin-<name>` per plugin and platform,
  since each binary links a different package set. Whether it honors `GOOS`/`GOARCH` is unverified, so a
  test compares its components with `go version -m <asset>`. `-licenses` surfaces the MPL-2.0 go-plugin
  and yamux modules.
- **Kept and replaced** — the starter's `attest-build-provenance` and `attest-sbom` steps stay. Cosign
  bundles replace the starter's GPG `.sha256.asc` files, leaving agents one signature system for
  publisher signatures. Release commits stay GPG-signed.

#### Core signing

`task coresign` runs for each plugin that `plugins.yaml` marks `core: true`, per platform:

1. **Statement** — `tools/coresign` writes the payload
   `{"name":"sigstore","version":"0.4.0","platform":"linux/amd64","sha256":"…","protocolVersions":[1]}`
   and its [DSSE](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md) pre-authentication
   encoding for payload type `application/vnd.rackmarshal.core-plugin.v1+json`.
2. **Sign** — proposed: the cloud KMS CLI signs those bytes with the P-256 key, with short-lived
   credentials from GitHub OIDC: `aws kms sign --message-type RAW --signing-algorithm ECDSA_SHA_256`,
   which returns a DER signature ([AWS CLI](https://docs.aws.amazon.com/cli/latest/reference/kms/sign.html)),
   or `gcloud kms asymmetric-sign --digest-algorithm sha256`
   ([gcloud](https://docs.cloud.google.com/sdk/gcloud/reference/kms/asymmetric-sign)).
3. **Assemble and check** — `tools/coresign` builds `<asset>.core.dsse.json` and verifies it with
   `crypto/ecdsa` against `keys/core-plugins.pem` before upload.

This adds no Go modules: `tools/coresign` uses only the standard library, and the CLI is a runner tool.
Whether GitHub-hosted runner images include both CLIs is unverified. The signer is an open question.

#### How the agent installs trusted versions

Proposed for [0011](0011-provisioner.md) and [0012](0012-agent.md), with the kinds in 0002:

```yaml
apiVersion: rackmarshal.servercurio.com/v1alpha1
kind: PluginPublisher
metadata: { name: servercurio }
spec:
  keyless:
    issuer: https://token.actions.githubusercontent.com
    repository: servercurio/agent-plugins
    workflow: .github/workflows/800-call-semantic-release.yaml
    refs: [refs/heads/main, "refs/heads/release/*"]
---
apiVersion: rackmarshal.servercurio.com/v1alpha1
kind: Plugin
metadata: { name: packages }
spec:
  publisher: servercurio
  version: 0.4.0
  baseURL: https://github.com/rackmarshal/agent-plugins/releases/download/v0.4.0
  agent:
    sha256: { linux/amd64: "…", linux/arm64: "…" }
    grant: { capabilities: [resource:rackmarshal.servercurio.com/v1alpha1/Package] }
  provisioner:
    bundle: { sha256: "…" }       # required; these plugins ship no provisioner service
```

1. **Import** — `provisioner` verifies `plugins-index.json`, the manifest, and every listed
   asset's `.sigstore.json` against the publisher with sigstore-go, and writes the verified digests into
   `Plugin` ([0011](0011-provisioner.md)). Nothing auto-updates to "latest". The publisher
   identity is built from structured fields, never a free-form regular expression. Bundle pins carry
   that identity.
2. **Download** — the agent fetches `<asset>` and `<asset>.sigstore.json` from `baseURL`. That may be a
   mirror, because the pinned digest and the signature, not the transport, establish integrity.
3. **Verify** — the agent checks the SHA-256 against the pin in its provisioner-signed bundle, and the
   core `sigstore` validator verifies `<asset>.sigstore.json` against the pin's publisher identity with a
   TUF-verified trusted root. The agent binary still links no verifier
   ([0012](0012-agent.md#sigstore-verifier-measurements)).
4. **Compatibility** — the manifest's `protocolVersions` must overlap the agent's.
5. **Install** — atomically into the root-owned `…/plugins/<name>/rackmarshal-plugin-<name>`, with its digest
   written beside it as `rackmarshal-plugin-<name>.sha256` (0012). One binary per plugin: rolling back means
   pinning the older version in the bundle, which re-downloads and re-verifies it. Every launch pins
   the digest through `SecureConfig`.

Core plugins take a different path: `agent`'s packaging consumes `sigstore` and `sysfacts` from a
release pinned by version and per-platform SHA-256, verifying the core envelopes and cosign bundles
before building (0012). A newer core release can reach hosts through a bundle pin with its
`<asset>.core.dsse.json`.

#### SDK compatibility

Manifests record `protocolVersions`, and `plugins-index.json` records the SDK version from build info.
Release notes carry a table of plugin release, SDK version, and protocols. Dependabot keeps the SDK
current, and when the SDK drops a protocol, plugins keep serving N-1 until the agent's window closes
(0013).

### Testing

- **Unit** — `execx.Runner` fakes, golden command output, and handlers through
  `plugintest.InProcess`.
- **Conformance** — each built binary through `plugintest.Launch` and `Conformance`, including
  idempotence.
- **Validator** — bundles with a wrong identity, ref, or digest, a missing Rekor entry or SCT, and a
  key-based publisher; TUF fixtures for rollback, expired metadata, and root rotation; and `verify` mode
  run with networking disabled.
- **Core signing** — `task verify` rejects an envelope with an unknown key, wrong payload type, name,
  platform, or digest; pull-request dry runs sign with a throwaway test key, never the release key.
- **End to end** (nested `e2e`):
  - `packages` in `ubuntu:noble` and `rockylinux:9` containers, and `files` in a container;
  - `services` on a GitHub-hosted Ubuntu runner, assuming `sudo systemctl` is allowed (unverified).
- **Hygiene** — `-race`, fuzzers, allowlists, cross-compiling all declared platforms, and a release dry
  run.

## Alternatives considered

- **Module per plugin** (`go.work`) — four Dependabot streams and possible gRPC skew, with no consumer
  benefit.
- **Repository per plugin** — contradicts 0001's single `agent-plugins` repository.
- **Per-plugin versions with semantic-release-monorepo** — misses dependency fixes made at the root.
- **One multi-call binary** — every plugin would link every dependency and share one digest, and fact
  collection would run from the root binary.
- **A separate module for `sigstore`** — keeps sigstore-go out of the shared module graph, but brings
  back a second gRPC version stream.
- **[GoReleaser](https://goreleaser.com) v2.18.1** — a capable release tool, but a second toolchain
  beside the starter's semantic-release and Taskfile.
- **Key-based cosign (KMS) for publisher signatures** — adds key custody and rotation. Keyless ties
  signatures to this workflow and still verifies offline. Third parties may use keys (0015). The core
  key exists for a different decision: trust the agent can check before any validator runs.
- **cosign `sign-blob --key <kms-uri>` for core statements** — cosign is already in the release job and
  supports AWS, GCP, and Azure KMS URIs, but whether its output over the DSSE encoding is a plain ECDSA
  signature usable in the envelope is unverified.
- **PKCS#11 signing for an on-premises HSM** — needs cgo, the concern 0006 raises for `miekg/pkcs11`;
  cosign's PKCS#11 support is also behind a `pkcs11key` build tag.
- **GitHub artifact attestations only** — also Sigstore-backed, but fetched per artifact from GitHub,
  while bundles next to assets let the provisioner verify releases imported from mirrors.
- **gopsutil** (measured above) and **go-systemd over D-Bus** (adds `godbus`; not measured).
- **Deviation from [CONVENTIONS.md](CONVENTIONS.md)** (*Go modules and layout*: binaries take the repo
  name) — binaries are named `rackmarshal-plugin-<name>`, which maps to `RACKMARSHAL_PLUGIN_<NAME>`.

## Open questions

- **First release** — Linux only, with apt and dnf. Acceptable?
- **Core facts** — do OS, architecture, and hostname belong in the agent (0012), leaving `sysfacts` for
  extended facts?
- **GPG** — keep GPG hash signatures beside cosign bundles for manual verification?
- **Index** — is `plugins-index.json` defined here, or as a kind in 0002?
- **Kinds** — the kind names and the `rackmarshal.servercurio.com/v1alpha1` group, to confirm with 0002 and
  0011.
- **Growth** — at what plugin count, if any, do per-plugin versions pay for their tooling?
- **Core signer** — a cloud KMS CLI with `tools/coresign` (proposed), cosign with a KMS URI, or PKCS#11
  for an HSM (cgo, as in [0006](0006-identity.md))? Which KMS, and who creates and holds the next
  key?

## References

- [0001](0001-project-repositories.md), [CONVENTIONS.md](CONVENTIONS.md),
  [0002](0002-api-schema.md), [0004](0004-common.md), [0006](0006-identity.md),
  [0012](0012-agent.md), [0013](0013-agent-plugin-sdk.md).
- [go-cli-starter](https://github.com/servercurio/go-cli-starter) — `Taskfile.yaml` (six targets, `hash`,
  `sign`, `sbom`), `.releaserc.json`, `800-call-semantic-release.yaml` (`id-token: write`, attest steps).
- Cosign — [signing blobs](https://docs.sigstore.dev/cosign/signing/signing_with_blobs/),
  [verifying](https://docs.sigstore.dev/cosign/verifying/verify/), and
  [Sigstore bundle](https://docs.sigstore.dev/about/bundle/).
- [cosign v3.1.3 verify options](https://github.com/sigstore/cosign/blob/v3.1.3/cmd/cosign/cli/options/verify.go)
  — `--offline` deprecation, `--trusted-root`.
- [Cosign key management](https://docs.sigstore.dev/cosign/key_management/overview/) — KMS URIs;
  [hardware tokens](https://docs.sigstore.dev/cosign/key_management/hardware-based-tokens/) — the
  `pkcs11key` build tag.
- [OIDC in Fulcio](https://docs.sigstore.dev/certificate_authority/oidc-in-fulcio/) — GitHub SAN
  `https://github.com/{job_workflow_ref}`.
- [Fulcio OID info](https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md);
  [GitHub Actions OIDC](https://docs.github.com/en/actions/reference/security/oidc).
- [sigstore-go](https://github.com/sigstore/sigstore-go) —
  [`verify`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/verify) (`NewVerifier`,
  `WithArtifactDigest`, `WithCertificateIdentity`),
  [`root`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/root) (`NewTrustedRootFromJSON`), and
  [`tuf`](https://pkg.go.dev/github.com/sigstore/sigstore-go/pkg/tuf) (`DefaultRoot`, `DefaultMirror`).
- [go-tuf v2 `trustedmetadata`](https://pkg.go.dev/github.com/theupdateframework/go-tuf/v2/metadata/trustedmetadata)
  and the [TUF specification](https://theupdateframework.github.io/specification/latest/).
- [DSSE protocol](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md) — PAE and payload
  types.
- [`aws kms sign`](https://docs.aws.amazon.com/cli/latest/reference/kms/sign.html) and
  [`gcloud kms asymmetric-sign`](https://docs.cloud.google.com/sdk/gcloud/reference/kms/asymmetric-sign).
- [sigstore/cosign-installer](https://github.com/sigstore/cosign-installer);
  [GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).
- [semantic-release-monorepo](https://github.com/pmowrer/semantic-release-monorepo);
  [commit-analyzer](https://github.com/semantic-release/commit-analyzer).
- [cyclonedx-gomod](https://github.com/CycloneDX/cyclonedx-gomod); [gopsutil](https://github.com/shirou/gopsutil);
  [Go `os.Root`](https://pkg.go.dev/os#Root); [GoReleaser](https://goreleaser.com).
- [Ansible builtin modules](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/index.html)
  — not re-checked (rate-limited 2026-09-15).
