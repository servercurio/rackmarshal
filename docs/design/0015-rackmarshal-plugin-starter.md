<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0015 — rackmarshal-plugin-starter

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `rackmarshal-plugin-starter` is a Rackmarshal-owned GitHub template, derived from `go-cli-starter`,
  with a working example plugin wired to `rackmarshal-agent-plugin-sdk`. It includes a rename tool, a local
  fake agent, and CI that produces the same signed, SBOM-backed release assets as the first-party
  plugins, so third parties can meet `rackmarshal-provisioner`'s import verification and the agents' on-host
  validator without Rackmarshal's help. Third-party plugins are never core-signed.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 defines `rackmarshal-plugin-starter` as "the project-owned scaffold third parties clone to author their
own" plugins. Unlike the general-purpose `go-*-starter` baselines, it is Rackmarshal-specific and depends on
`rackmarshal-agent-plugin-sdk`
([Agent plugin ecosystem](0001-project-repositories.md#agent-plugin-ecosystem)). `rackmarshal-provisioner`
imports only plugin releases whose cosign signature matches a trusted publisher, agents run only the
digests it pins, and the core `sigstore` validator on each host verifies the signature again before
install, so a correct release pipeline must be the default.

**Goals**

- Clone, rename, pass `task test`, and cut a verifiable release, with no Rackmarshal involvement.
- The least-privilege plugin as the default: unprivileged, with no network and no exec.
- The same assets, manifest, and publisher signing model as [0014](0014-rackmarshal-agent-plugins.md).
- A repeatable way to pick up `go-cli-starter` and SDK changes, and clear licensing guidance.

**Non-goals**

- A registry, a marketplace, or Rackmarshal certification of third-party plugins.
- Core signing: third-party plugins are never core-signed and never core plugins (0014).
- The contract ([0013](0013-rackmarshal-agent-plugin-sdk.md)) and agent verification
  ([0012](0012-rackmarshal-agent.md)).
- Legal advice; the licensing section is guidance only.

## Proposal

### Responsibilities

- An example plugin exercising both capability types that passes the conformance suite.
- Author tooling (rename, fake agent, Taskfile), CI workflows, and author documentation.
- Tracking upstream `go-cli-starter`, and publishing releases that downstream repositories can track.

### Interfaces

#### Repository layout

```
rackmarshal-plugin-starter/
├── cmd/rackmarshal-plugin-example/main.go     # serve.Main wiring only
├── internal/
│   ├── example/                         # facts.go (example.greeting), marker.go (Marker kind)
│   ├── config/                          # Config{Environment, Logging, StateDir, Greeting}
│   ├── cli/                             # cobra: serve (default), version, manifest, check-config
│   └── env/  version/                   # kept from go-cli-starter
├── manifest.yaml                        # embedded; least privilege
├── provisioner/                         # the required provisioner bundle (0021)
│   ├── schemas/marker.schema.json       # JSON Schema 2020-12 for the example kind
│   ├── schemas/marker.result.json       # result schema both ends validate against
│   └── policy/host.rego                 # deny-only, scoped to this plugin's kinds
├── testdata/                            # sample resources, development environment
├── tools/rename/  tools/fakeagent/      # standard library + SDK only
├── docs/                                # writing, security, testing, releasing, licensing, upgrading
├── .starter/upstream.yaml               # upstream repository, commit, path classes
├── .github/workflows/
└── Taskfile.yaml, .releaserc.json, LICENSE, SECURITY.md, CONTRIBUTING.md, CODEOWNERS
```

Removed from `go-cli-starter`:

- `internal/database` (pgx, bun, goose) and `internal/pool` (ants);
- the `copy` command and `internal/obfusicate`;
- `internal/health`, replaced by the `Check` RPC;
- the Dockerfile and container tasks;
- `internal/logging`, replaced by `rackmarshal-common` (0001 bootstrap step 4).

#### Example plugin

- **Facts** — `example.greeting` returns the configured `greeting`, with no host access.
- **Resource** — kind `Marker` (`plugins.example.com/v1alpha1`) with `spec.content`. `Plan` reads
  `<stateDir>/markers/<name>`, and `Apply` writes it atomically, showing idempotence that stays inside
  the plugin's own directory.
- **Manifest** — `capabilities: [facts, "resource:plugins.example.com/v1alpha1/Marker"]`,
  `privileges: { runAsRoot: false, execPaths: [], network: [] }`, and
  `platforms: [linux/amd64, linux/arm64]`. It never sets `core: true`; the agent refuses that without a
  core signature (0013).
- **Provisioner bundle** — built by `task bundle` and released as an asset. The example ships schemas and
  a deny-only `host` policy and **no** provisioner service, which is the shape most plugins want: the
  control plane validates and polices the kind while nothing extra runs beside the provisioner
  ([0021](0021-plugin-extensibility.md)). `docs/` explains when a service is worth adding.
- **Result** — `Apply` returns a small `result_json` conforming to `marker.result.json`, so the template
  exercises the round trip and its 16 KiB limit rather than leaving authors to discover both.
- **Rename** — `task rename -- -name acme-backup -module github.com/acme/rackmarshal-plugin-acme-backup`
  (plus `-group` for the example kind; runs `go run ./tools/rename`) rewrites the module path, `cmd/`,
  `RACKMARSHAL_PLUGIN_EXAMPLE` → `RACKMARSHAL_PLUGIN_ACME_BACKUP`, the manifest, the schema `$id`, workflow
  identity strings, and the README. The starter's own CI renames a copy and runs the full suite, so the
  template stays renameable.

#### Configuration

The starter's loading order: defaults → YAML file → `RACKMARSHAL_PLUGIN_<NAME>_*` → flags. The environment
(name, tier, ID) is not configured here: the agent supplies it in `Init` (0013).

| YAML                                 | Variable                                    | Default                         |
|--------------------------------------|---------------------------------------------|---------------------------------|
| `environment.name` / `.tier` / `.id` | `RACKMARSHAL_PLUGIN_EXAMPLE_ENVIRONMENT_NAME` / … | none — required (0013)          |
| `logging.default.level`              | `RACKMARSHAL_PLUGIN_EXAMPLE_LOG_LEVEL`            | `info`                          |
| `stateDir`                           | `RACKMARSHAL_PLUGIN_EXAMPLE_STATE_DIR`            | `/var/lib/rackmarshal-plugin-example` |
| `greeting`                           | `RACKMARSHAL_PLUGIN_EXAMPLE_GREETING`             | `hello`                         |

`environment`, `rpc`, and `logging` are reserved child keys. Authors add their own keys beside them.

#### Local test harness

```sh
task test                  # unit tests via plugintest.InProcess, -race
task test:conformance      # builds the binary; plugintest.Launch + Conformance
task build:local
go run ./tools/fakeagent -plugin bin/rackmarshal-plugin-example-linux-amd64 manifest
go run ./tools/fakeagent -plugin bin/rackmarshal-plugin-example-linux-amd64 \
  -grant "resource:plugins.example.com/v1alpha1/Marker" apply -f testdata/marker.yaml
```

`fakeagent` hashes and launches the binary the way `host.Launch` does. It sends the `development`
environment from `testdata/environment.yaml` and prints plans, results, and log lines. `-env-id`
exercises the mismatch refusal, and it validates every `result_json` against the bundle's result schema
so an author sees the same rejection the agent would produce.

`fakeprovisioner` is the bundle's counterpart: it loads `provisioner/`, compiles the policy, and runs the
admission and dispatch phases over a document, so an author can see a scoped `deny` fire without standing
up a provisioner. Conformance in CI fails a release whose bundle is missing, whose declared kind has no
schema (`schema_missing`), or whose schema matches no declared capability (`schema_unclaimed`), so a
third party finds out at build time rather than at import ([0021](0021-plugin-extensibility.md)).

#### CI workflows

| File                                      | Trigger      | Purpose                                                   |
|-------------------------------------------|--------------|-----------------------------------------------------------|
| `200-flow-pull-request-checks.yaml`       | pull request | compile, tests, vulncheck, conformance, rename smoke test |
| `200-flow-pull-request-formatting.yaml`   | pull request | Conventional Commit titles                                |
| `200-flow-codeql-scanning.yaml`           | pull request | CodeQL                                                    |
| `300-flow-main-branch-checks.yaml`        | push to main | same checks as 200                                        |
| `100-user-deploy-release-artifact.yaml`   | dispatch     | calls the 800 release workflow; dry-run input             |
| `800-call-semantic-release.yaml`          | call         | build, hash, sign, SBOM, index, verify, attest, publish   |
| `800-call-plugin-conformance.yaml`        | call         | build all platforms; conformance on linux/amd64; bundle completeness |
| `800-call-{code-compiles,unit-test,vulncheck}.yaml` | call | unchanged from `go-cli-starter`                       |
| `900-cron-starter-upstream-sync.yaml`     | weekly       | upstream sync pull request or issue                       |

The workflows keep the starter's SHA-pinned actions, `harden-runner`, and a default of
`permissions: contents: read`. `id-token: write` is granted only to the release job, and nothing uses
`pull_request_target`.

### Dependencies

- **Rackmarshal** — `rackmarshal-agent-plugin-sdk` (14 linked modules, measured in 0013) and `rackmarshal-common`
  (`logging`, `environment`).
- **Kept from `go-cli-starter`'s `go.mod`**:
  - `spf13/cobra` v1.10.2 and `spf13/pflag` v1.0.10 (`mousetrap` v1.1.0 on Windows);
  - `gopkg.in/yaml.v3` v3.0.1 and `joomcode/errorx` v1.2.0 for the config loader;
  - `stretchr/testify` v1.12.1 for tests.

  The linked set for this combination is not measured yet; `deps.allow` fixes it in CI.
- **Tools** — cosign v3.1.3 (`sigstore/cosign-installer` v4.1.2), cyclonedx-gomod v1.12.0, and
  golangci-lint v2.13.2.

### Data & storage

None beyond the example's `stateDir`.

### Security

- **Publisher identity** — keyless certificates carry the signing workflow's `job_workflow_ref` as the
  SAN. The starter therefore keeps the signing workflow inside each plugin repository. Calling one
  hosted elsewhere would make every certificate name that repository, so operators could not tell
  publishers apart.
- **Trust snippet** — `docs/releasing.md` tells authors to publish their identity for operators, in the
  `PluginPublisher` form proposed in 0014:

```yaml
kind: PluginPublisher
metadata: { name: acme }
spec:
  keyless:
    issuer: https://token.actions.githubusercontent.com
    repository: acme/rackmarshal-plugin-acme-backup
    workflow: .github/workflows/800-call-semantic-release.yaml
    refs: [refs/heads/main]
```

- **Two verifications** — every release asset ships an `<asset>.sigstore.json` bundle.
  `rackmarshal-provisioner` verifies it at import ([0011](0011-rackmarshal-provisioner.md)), and the core `sigstore`
  validator on each host verifies it again, offline, against the same `PluginPublisher` identity: the
  certificate identity, a transparency-log entry, and, for keyless certificates, an SCT, using a
  TUF-verified trusted root ([0012](0012-rackmarshal-agent.md)). A bundle without a transparency-log entry
  fails on hosts.
- **Key-based option** — when `COSIGN_KEY` is set, for example to a KMS URI, `task sign` runs
  `cosign sign-blob --key` with `--bundle`, and publishers distribute `spec.key.publicKeyPEM`. It suits
  publishers outside GitHub Actions, or private repositories: public-good Sigstore records the signer
  identity, including the repository and workflow path, in the public Rekor log (not re-verified here).
  The bundle must still carry a transparency-log entry for the host validator.
- **Branch protection** — releases run only through dispatch on a protected `main`, with `CODEOWNERS`
  on `.github/workflows/` and `.releaserc.json`. Whoever controls the release workflow can sign as the
  identity.
- **Author guidance** — `docs/security.md`: exec only absolute granted paths, use `os.Root` for writes,
  no shell, no undeclared network, no secrets in facts or logs, and validate inputs against the schema.
- **The example is never trusted** — its signed releases exercise the pipeline, but no default policy
  includes its identity.

### Environment awareness

The example refuses to start without `environment` configuration and refuses an agent from another
environment (0013). The docs require plugins to branch on tier through `rackmarshal-common`, never on the
environment name. Tests cover both refusals.

### Logging & telemetry

`rackmarshal-common` logging to stderr with `service.name` `rackmarshal-plugin-<name>`, as in 0013. No telemetry
export. The docs list the fields the agent adds.

### Configuration

See Interfaces.

### Build, release & versioning

#### Release pipeline

- **Build** — the platforms in `manifest.yaml`: `linux/amd64` and `linux/arm64` by default; darwin and
  windows are opt-in. `CGO_ENABLED=0` and `-trimpath`.
- **`publishCmd`** — `task build && task hash && task sign && task sbom && task index && task verify`,
  producing 0014's assets: `<asset>`, `.sha256`, `.sigstore.json`, `.cdx.json` with its bundle,
  `rackmarshal-plugin-<name>.manifest.yaml`, and `plugins-index.json`, each signed. There is no `coresign`
  step and no `.core.dsse.json`.
- **Verification and attestations** — `task verify` checks every bundle against the repository's own
  identity before publishing, requiring a transparency-log entry as the host validator does. The
  starter's `attest-build-provenance` and `attest-sbom` steps stay.

#### Versioning and upstream tracking

- **The starter** — `v0.x` with semantic-release tags. Each release notes the example's SDK version and
  protocols.
- **Upstream `go-cli-starter`** has no tags or releases (checked 2026-09-15), so
  `.starter/upstream.yaml` pins a commit and classifies paths:

```yaml
repository: servercurio/go-cli-starter
commit: <sha>
sync:     [.golangci.yml, .editorconfig, .github/workflows/800-call-code-compiles.yaml,
           .github/workflows/800-call-unit-test.yaml, .github/workflows/800-call-vulncheck.yaml,
           internal/config/, internal/env/, internal/version/, SECURITY.md]
diverged: [Taskfile.yaml, .releaserc.json, .github/workflows/800-call-semantic-release.yaml,
           internal/cli/, cmd/]
removed:  [Dockerfile, internal/database/, internal/pool/, internal/obfusicate/, internal/health/]
```

- **Weekly sync** — `900-cron-starter-upstream-sync.yaml` diffs upstream from `commit`:
  - `sync` changes become a pull request titled `chore: sync go-cli-starter <short-sha>`, with GPG and
    DCO signing as in the starter's release job;
  - `diverged` changes become an issue for manual review;
  - `removed` paths are ignored.
- **Downstream plugins** — repositories created from a GitHub template start without its history (not
  re-verified). They use the same mechanism pointed at `servercurio/rackmarshal-plugin-starter` release tags.
  `docs/upgrading.md` covers Dependabot SDK bumps and protocol changes.

#### Licensing guidance for third parties

- **Starter license** — Apache-2.0 (0001 shared meta). Copied files keep their notices. Section 4 lets
  authors apply their own terms to their modifications and to the derivative work as a whole, if they
  comply with its conditions. `tools/rename` never changes `LICENSE`; choosing a license is the
  author's decision, made before the first release.
- **Binary obligations** — every plugin binary contains the MPL-2.0 modules `hashicorp/go-plugin` and
  `hashicorp/yamux`. Distributors must tell recipients where that source is available (MPL FAQ). SBOM
  license data plus a release-note section linking module sources covers this.
- **Copyleft plugins** — the GPL FAQ says fork-and-exec plugins that exchange "complex data structures"
  with the host "can make them one single combined program". Separate processes alone don't settle
  licensing, so authors considering the GPL should get legal advice.
- **Names** — `rackmarshal-plugin-<vendor>-<name>` avoids collisions. A name implies no endorsement; trust
  comes only from the publisher identity.

### Testing

- **Example** — unit, conformance, and fuzz tests, with `-race`.
- **Rename smoke test** — rename into a temporary directory, then build, test, and run conformance.
- **Release dry run** on pull requests — build, hash, SBOM, and index, without signing.
- **Upstream sync** — fixture tests for `sync`, `diverged`, and `removed` handling.
- **Hygiene** — the allowlist and cross-compiling every declared platform.

## Alternatives considered

- **[`gonew`](https://go.dev/blog/gonew)** — rewrites module paths, but has no upstream tracking; its
  experimental status is not re-verified.
- **[Copier](https://copier.readthedocs.io)** — `copier update` tracks template changes well, but brings
  a Python toolchain.
- **Git merges from the starter remote** — no tooling, but renamed paths conflict on every merge.
- **`rackmarshal plugin new` in `rackmarshal-cli`** — couples the operator CLI to author tooling.
- **Standard-library `flag` instead of cobra** — fewer modules, but diverges from `go-cli-starter` and
  makes syncs harder.
- **Keyless-only signing** — excludes publishers that don't build on GitHub Actions or that need to keep
  repository names private.
- **A Rackmarshal-hosted reusable signing workflow** — certificates would name Rackmarshal's repository instead of
  the publisher's.
- **Core signing for third-party plugins** — would make Rackmarshal a certifier, contradicting the non-goals,
  and would put the core-plugin key behind code Rackmarshal does not own.
- **A permissive, no-attribution license (e.g. 0BSD) for the template** — removes notice obligations,
  but deviates from 0001's Apache-2.0 shared meta.
- **Deviation from [CONVENTIONS.md](CONVENTIONS.md)** (*Go modules and layout*) — the binary is
  `rackmarshal-plugin-<name>`, not the repository name, matching 0014.

## Open questions

- **Starter license** — keep Apache-2.0 (proposed), or offer the template under 0BSD, which would
  change 0001's shared meta for this repository?
- **Third-party kinds** — how are groups named, and how do schemas reach `rackmarshal-provisioner` and the
  agent (0013, [0002](0002-rackmarshal-api-schema.md))?
- **Publisher onboarding** — documentation only, or a Rackmarshal-maintained list of known identities?
- **Platforms** — should darwin and windows become defaults once the agent supports them (0012)?
- **Sync signing** — which token and GPG key sign the sync commits in downstream repositories?

## References

- [0001](0001-project-repositories.md), [CONVENTIONS.md](CONVENTIONS.md), [0004](0004-rackmarshal-common.md),
  [0011](0011-rackmarshal-provisioner.md), [0012](0012-rackmarshal-agent.md),
  [0013](0013-rackmarshal-agent-plugin-sdk.md), [0014](0014-rackmarshal-agent-plugins.md).
- [go-cli-starter](https://github.com/servercurio/go-cli-starter) — `go.mod`, `Taskfile.yaml`,
  `.releaserc.json`, workflows, and `naming-standards.md`; no tags or releases as of 2026-09-15.
- Cosign — [signing blobs](https://docs.sigstore.dev/cosign/signing/signing_with_blobs/) (keyless and
  key/KMS) and [verifying](https://docs.sigstore.dev/cosign/verifying/verify/).
- [OIDC in Fulcio](https://docs.sigstore.dev/certificate_authority/oidc-in-fulcio/) and
  [GitHub Actions OIDC](https://docs.github.com/en/actions/reference/security/oidc) —
  `job_workflow_ref`.
- [sigstore/cosign-installer](https://github.com/sigstore/cosign-installer);
  [cyclonedx-gomod](https://github.com/CycloneDX/cyclonedx-gomod).
- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) (section 4);
  [MPL 2.0 FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/);
  [GNU GPL FAQ: plug-ins](https://www.gnu.org/licenses/gpl-faq.html#GPLPlugins).
- [`hashicorp/go-plugin`](https://github.com/hashicorp/go-plugin) and
  [`hashicorp/yamux`](https://github.com/hashicorp/yamux) — both MPL-2.0.
- [Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)
  — not re-verified.
- [gonew](https://go.dev/blog/gonew); [Copier](https://copier.readthedocs.io).
