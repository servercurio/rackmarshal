<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0005 — infrastructure

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `infrastructure` is an Ansible project that deploys Rackmarshal's own services to three
  target types from one inventory per environment: Kubernetes (each service's Helm chart), containers
  (Podman Quadlet or Docker Compose), and the operating system directly (signed deb and rpm packages
  under systemd, or NSIS-installed Windows services). Conftest checks inventories and all rendered Helm,
  Compose, and Quadlet output in pull-request CI, and a dedicated control node runs signed, merged
  commits. It defines the environment key ceremony, including Kubernetes cluster issuer registration,
  and how each target bootstraps service certificates.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 makes this repository Rackmarshal's *own* deployment: Ansible playbooks, roles, and inventories gated
by OPA policies, with Conftest in pull-request CI and a control node that runs merged playbooks so
deployment credentials never live in CI
([Rackmarshal's own infrastructure](0001-project-repositories.md#rackmarshals-own-infrastructure)). It must not
depend on `agent` or `provisioner`. Each inventory supplies its environment's name, tier,
ID, and CA bundle, and the control node holds a root-signed certificate
([Environment identity](0001-project-repositories.md#environment-identity)).

Kubernetes support is mandatory, beside containers and direct installs on a compatible OS, all through
this one pipeline. Certificate bootstrap depends on the target: the control node delivers single-use
tokens to containers, hosts, and plugin sidecars, while pods enroll with projected service account
tokens that `identity` verifies offline. Service repositories ship the artifacts in
[CONVENTIONS — Deployment artifacts](CONVENTIONS.md#deployment-artifacts).

**Goals**

- One inventory fully describes one environment, including each service's target.
- Configuration, health probes, and enrollment behave identically on every target; only the
  first-enrollment credential differs.
- Policies that block unsafe inventories and rendered output before merge and before every run.
- A repeatable, auditable ceremony to create, rotate, and destroy an environment's trust anchors.
- Service certificate bootstrap with no long-lived shared secrets on hosts or in clusters.

**Non-goals**

- Managing customer endpoints — that is `provisioner` and `agent`.
- Certificate issuance, token formats, and token verification — [0006](0006-identity.md).
- Building images, charts, packages, and Windows installers — each service repository, per CONVENTIONS.
- Creating clusters, installing operating systems, and choosing a telemetry backend; this repository
  starts from a reachable namespace or host and deploys only an in-environment OTLP collector.

## Proposal

### Responsibilities

- Inventories, roles, and playbooks for every Rackmarshal service, PostgreSQL, and the OTLP collector.
- Quadlet and Compose definitions, which live here rather than in service repositories.
- Rego policies for inventories, Ansible content, and rendered output, with their unit tests.
- The control node's configuration and run procedure, and runbooks for the key ceremony, cluster
  registration, rotation, and destruction (`docs/runbooks/`).

### Interfaces

#### Deployment targets

| `target`     | Runtime                                 | Role                          | Consumes        | First enrollment   |
|--------------|-----------------------------------------|-------------------------------|-----------------|--------------------|
| `kubernetes` | Helm release in a dedicated namespace   | `rackmarshal_target_helm`     | chart and image | projected SA token |
| `podman`     | Quadlet `.container` unit under systemd | `rackmarshal_target_quadlet`  | image           | single-use token   |
| `docker`     | Compose project under systemd           | `rackmarshal_target_compose`  | image           | single-use token   |
| `package`    | deb or rpm with its systemd unit        | `rackmarshal_target_packages` | deb / rpm       | single-use token   |
| `windows`    | Windows service                         | `rackmarshal_target_windows`  | NSIS installer  | single-use token   |

`package` supports Enterprise Linux 9 and 10, Debian 12 and 13, and Ubuntu 24.04 and 26.04 LTS on amd64
and arm64; `windows` supports Windows Server 2022 and 2025 ([endoflife.date](https://endoflife.date)).
Kubernetes follows the upstream window of three minors, 1.35–1.37 today
([Releases](https://kubernetes.io/releases/)).

#### Repository layout

```
infrastructure/
├── ansible.cfg  requirements.yml  execution-environment.yml
├── inventories/<env>/                # hosts.yaml; group_vars/all/ with the four files below
├── roles/
│   ├── rackmarshal_service/          # target-neutral model: config, probes, secrets, enrollment
│   ├── rackmarshal_target_helm/  rackmarshal_target_quadlet/  rackmarshal_target_compose/
│   ├── rackmarshal_target_packages/  rackmarshal_target_windows/
│   ├── rackmarshal_host/  rackmarshal_postgresql/  rackmarshal_otel_collector/
│   ├── rackmarshal_control_node/  rackmarshal_identity/  rackmarshal_gateway/
│   └── rackmarshal_sso/  rackmarshal_inventory/  rackmarshal_provisioner/
├── playbooks/                        # site, service, rotate-credentials, render
├── policy/                           # inventory, content, kubernetes, compose, quadlet, systemd, windows
├── molecule/  tests/kubernetes/      # host scenarios; kind and k3s scenarios
└── docs/runbooks/                    # procedures and records/<env>/
```

#### Environment and target selection

`group_vars/all/` holds four files. In `environment.yaml`, `rackmarshal_environment` declares
`name`, `tier`, `id` (26-character base32 from the ceremony), `caBundle` (public roots only; two during
root rotation), and `overrides`. `secrets.yaml` holds secret-manager references only. `artifacts.yaml` is
described below, and `deployment.yaml` selects targets. Services may differ — for example
`gateway` as a package on edge hosts and the rest in a cluster:

```yaml
rackmarshal_deployment:
  defaultTarget: kubernetes          # kubernetes | podman | docker | package | windows
  defaultReplicas: 2                 # every service is replica-safe; see CONVENTIONS
  services:
    gateway: { target: package, hosts: gateway, replicas: 3 }
  clusters:
    - id: east-1                     # lowercase DNS label
      namespace: rackmarshal-qa-east
      gatewayNamespace: rackmarshal-qa-east-gateway   # gateway alone; see Least privilege
      issuer: https://oidc.east-1.example.net
      jwks: files/qa-east/clusters/east-1.jwks.json      # pinned; fingerprint in the ceremony record
      kubeconfig: vault:kv/rackmarshal/qa-east/clusters/east-1  # secret-manager reference
```

Every service tolerates N replicas
([CONVENTIONS — Running multiple replicas](CONVENTIONS.md#running-multiple-replicas)), so `replicas` is
a capacity and availability choice rather than a per-service constraint. The default of 2 is what makes
the rolling upgrade below non-disruptive; 1 is valid and means accepting a restart window. On
`kubernetes` the value sets the chart's `replicaCount` and a `PodDisruptionBudget` with
`minAvailable: replicas - 1`, so a drain evicts one pod at a time and cannot take the last one. At 1
replica that is `minAvailable: 0`, which gives no protection, consistent with accepting a restart
window. On `package` and `windows` it is the number of hosts in the group.

Every rendered Kubernetes object carries the recommended labels
([CONVENTIONS](CONVENTIONS.md#deployment-artifacts)): `app.kubernetes.io/part-of: rackmarshal` names the
application and `app.kubernetes.io/name` and `/component` name the component, so a namespace shared with
other software can still be selected, drained, or filtered in dashboards by product or by service. The
labels mirror `service.namespace` and `service.name` in telemetry, so a Kubernetes selector and a
Loki or metrics query use the same two names.

Every service ships logs, traces, and metrics over OTLP to `telemetry.endpoint`
([0004](0004-common.md)), so each environment needs one OTLP receiver reachable from every
target. `rackmarshal_telemetry` renders that endpoint and its CA bundle into every service's
configuration. An OpenTelemetry Collector is the expected deployment, with Loki behind it for logs;
Loki's own `/otlp/v1/logs` endpoint is a valid target for a small environment that wants no collector.
0004 names which resource attributes may become Loki stream labels, and `service.instance.id` must not
be one: `replicas` above makes the instance count a deployment choice, so as a label it would create a
Loki stream per instance per restart.

`rackmarshal_identity` renders `clusters` into `identity`'s cluster issuer registry
([0006](0006-identity.md)), mapping service account `<namespace>/rackmarshal-<name>` to
`spiffe://<environment-id>/service/<name>`, except that `gateway`'s account is mapped from
`<gatewayNamespace>`. The Kubernetes object keeps the prefix because it shares a
namespace with whatever else is deployed there; the SPIFFE path does not, because the environment's
trust domain already scopes it.

#### Consuming service artifacts

`artifacts.yaml` pins each service's version, image `@sha256:` digest, SHA-256 of the chart and of each
deb, rpm, and Windows installer, and its highest migration (`schemaVersion`). The control node downloads
release assets
to a local cache, checks the SHA-256 from Git, and verifies publisher signatures before any target sees
them: cosign for images, the starter's GPG-signed chart checksum
([go-echo-starter `.releaserc.json`](https://github.com/servercurio/go-echo-starter/blob/main/.releaserc.json)),
and package and Authenticode signatures (verifier tooling is an open question). Charts install from the
verified local file. A 100-series workflow proposes `artifacts.yaml` updates when a service releases.

#### Rendering

`rackmarshal_service` builds one model per instance: the YAML configuration with the CONVENTIONS
`environment` block and `...File` references, the `/livez`, `/readyz`, and `/healthz` probes, secret
files, and the enrollment credential path. `playbooks/render.yaml` runs with `connection: local` and
placeholder secrets, so CI renders every inventory without credentials. Conftest reads:

- `kubernetes` — `helm template` of the verified chart with the rendered values;
- `podman` — the Quadlet unit model as JSON, because Conftest's INI parser keeps one value per key
  ([`parser/ini/ini.go`](https://github.com/open-policy-agent/conftest/blob/master/parser/ini/ini.go))
  and Quadlet repeats keys such as `Secret=`; CI also runs `podman-system-generator --dryrun`
  ([podman-systemd.unit](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html));
- `docker` — `compose.yaml` after `docker compose config`;
- `package` — the systemd drop-in model, and the unit extracted from the verified package;
- `windows` — the service configuration and installer switches.

#### Pinned toolchain

| Component                                                                        | Version                     |
|----------------------------------------------------------------------------------|-----------------------------|
| [ansible-core](https://github.com/ansible/ansible/releases)                      | 2.21.4                      |
| ansible-navigator, ansible-lint, molecule                                        | v26.8.0                     |
| [ansible-builder](https://github.com/ansible/ansible-builder/releases)           | 3.1.1                       |
| [Conftest](https://github.com/open-policy-agent/conftest/releases), [OPA](https://github.com/open-policy-agent/opa/releases) | v0.70.0, v1.20.2 |
| [Helm](https://github.com/helm/helm/releases)                                    | v4.3.0                      |
| [kind](https://github.com/kubernetes-sigs/kind/releases), [k3s](https://github.com/k3s-io/k3s/releases) | v0.33.0, v1.37.0+k3s1 |
| `kubernetes.core`, `community.docker`, `containers.podman`, `ansible.windows`    | 6.5.0, 5.3.0, 1.20.2, 3.8.0 |
| `community.postgresql`, `ansible.posix`, `community.hashi_vault`                 | 5.0.0, 2.2.2, 7.1.0         |

Checked on 2026-09-15 from GitHub releases and the [Galaxy API](https://galaxy.ansible.com/).
`kubernetes.core` 6.4.0 and 6.5.0 add Helm v4 support and map `atomic` to `--rollback-on-failure`
([changelog](https://github.com/ansible-collections/kubernetes.core/blob/main/CHANGELOG.rst)). Service
repositories use [nFPM](https://github.com/goreleaser/nfpm/releases) v2.47.0 and
[NSIS](https://nsis.sourceforge.io) v3. Collections and Helm are baked into the
execution environment image, pinned by digest; Dependabot does not cover Galaxy (unverified), so a
100-series workflow proposes bumps.

#### Policies

Policies use Rego v1 syntax, one namespace per input. Inventory policies run on
`ansible-inventory -i inventories/<env> --list` JSON, so variable precedence applies; content policies run
on role and playbook YAML; the rest run on rendered output. Initial rule set (proposed):

| Scope      | Rules                                                                                     |
|------------|-------------------------------------------------------------------------------------------|
| inventory  | `name` DNS label, `tier` one of four, `id` 26 base32 characters; one ID per inventory      |
| inventory  | every service resolves to a known target; `kubernetes` services name a listed cluster      |
| inventory  | each cluster's `gatewayNamespace` differs from its `namespace`                             |
| inventory  | cluster `jwks` fingerprints match the environment's ceremony record                        |
| inventory  | `identity` and PostgreSQL never bind public interfaces or public load balancers     |
| inventory  | images pinned by `@sha256:`; charts, packages, installers by SHA-256; `schemaVersion` never drops |
| inventory  | `production`: no `kek-sealed-*` feature at all; no other last-resort feature without an override |
| inventory  | service token TTL ≤ 1h; service certificates exactly 7 days; secrets are references only  |
| content    | secret-using tasks set `no_log`; `shell` has `changed_when`; no `validate_certs: false`     |
| kubernetes | all containers non-root, read-only root, no escalation, drop `ALL`, `RuntimeDefault` seccomp |
| kubernetes | no host namespaces or `hostPath`; `NetworkPolicy` present; no Role, RoleBinding, or Secret |
| kubernetes | `automountServiceAccountToken: false`; one projected token, audience `spiffe://<id>/service/identity`, 600 s, init container only |
| kubernetes | key volume is `emptyDir` `medium: Memory`; init and main containers use the same digest     |
| kubernetes | a plugin's enrollment Secret is mounted only by that plugin's sidecar container            |
| compose    | non-root `user`, `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, no host network      |
| quadlet    | non-root `User=`, `ReadOnly=true`, `NoNewPrivileges=true`, `DropCapability=all`, no `AutoUpdate=` |
| systemd    | `NoNewPrivileges=`, `ProtectSystem=strict`, non-root `User=`, token via `LoadCredential=`  |
| windows    | virtual service account, never LocalSystem; key and token paths ACL'd to it               |

#### CI and the control node

- **`200-flow-pull-request-checks.yaml`** — ansible-lint, `ansible-playbook --syntax-check`,
  `opa test policy/`, rendering, Conftest on inventories, content, and rendered output, and target tests
  for changed roles, with no deployment credentials and no network path to any environment.
  **`300-flow-main-branch-checks.yaml`** repeats them on `main`, plus every target test.
- **Control node** — proposed as a dedicated, hardened VM per environment tier group that runs
  `ansible-navigator` in the pinned execution environment. A systemd timer fetches `main`, verifies each
  new commit as below (every Rackmarshal repository requires GPG-signed commits, per
  [Naming & conventions](0001-project-repositories.md#naming--conventions)), renders and re-runs Conftest
  locally, and only then runs `site.yaml` in check mode, followed by apply for inventories whose
  `autoApply` is true. `production` applies require a manual `rackmarshal-deploy apply <env> <commit>` on
  the node.
- **Commit verification** — pull requests may be merged in the GitHub UI, but this repository's branch
  rules allow only merge commits, never squash or rebase
  ([merge methods](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github)).
  The control node accepts a commit on `main` only if `git verify-commit` shows it signed by a key in the
  maintainers' allowlist, or if it is a two-parent merge commit that meets all three of these:
  1. it is signed by GitHub's web-flow key, which signs commits made in the web interface
     ([commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)),
     pinned on the node from <https://github.com/web-flow.gpg> rather than fetched at run time;
  2. every commit it brings in, `git rev-list <p1>..<p2>`, is signed by a maintainer key;
  3. its tree equals the output of `git merge-tree --write-tree <p1> <p2>`
     ([git-merge-tree](https://git-scm.com/docs/git-merge-tree)), so the merge introduces no change of
     its own. A merge whose conflicts were resolved in the UI fails this check and must be redone on a
     branch with signed commits.

  The web-flow key alone therefore proves only that GitHub recorded the merge; every line it deploys
  still traces to a maintainer signature.

#### Upgrade and rollback

Hardened tiers run `<binary> migrate` as a separate step before an upgrade (0009): a Job from the chart,
a one-shot container, or the installed binary. Migrations are forward-only, so policy refuses a rollback
across a `schemaVersion` change. Otherwise rollback is a reverted commit applied like any other, never
`helm rollback` or a manual install, so the next run cannot undo it.

| Target       | Upgrade, one instance or host at a time until `/readyz` passes                            |
|--------------|-------------------------------------------------------------------------------------------|
| `kubernetes` | `kubernetes.core.helm` with `atomic` and `wait`, which rolls back a failed release          |
| `podman`     | new unit with the new digest, `daemon-reload`, restart                                    |
| `docker`     | `community.docker.docker_compose_v2` with `wait: true`                                    |
| `package`    | `apt` or `dnf` install of the verified file with downgrades allowed, restart              |
| `windows`    | `ansible.windows.win_package` with `product_id` and `creates_*`; reinstall to roll back   |

### Dependencies

- **Rackmarshal repositories** — each service's deployment artifacts (CONVENTIONS); enrollment, renewal,
  and the cluster issuer registry from [0006](0006-identity.md). No Go modules.
- **Runtime** — a Kubernetes namespace, Podman, Docker Engine with Compose, systemd, or Windows Server;
  PostgreSQL from distribution packages or a managed service; an OpenTelemetry Collector pinned by digest.
- **Secret manager** — one per environment, reached only from the control node (proposed: HashiCorp
  Vault through `community.hashi_vault`, or the cloud provider's manager).

### Data & storage

No application data. The repository holds inventories, public CA bundles, pinned cluster JWKS, and
policies. The control node keeps run logs, the artifact cache, and the last applied commit per
environment; ceremony and registration records (signed transcripts, certificate and JWKS fingerprints)
are committed under `docs/runbooks/records/<env>/`.

### Security

#### Environment-creation key ceremony

Performed by two people on an offline, freshly imaged workstation, with a written transcript:

1. **Generate the environment ID** — 128 random bits, 26 characters of lowercase base32 (CONVENTIONS).
   IDs are never reused, even after destruction.
2. **Create the root CA** in an offline HSM or an isolated cloud KMS project: ECDSA P-384 (proposed),
   10-year validity, a `spiffe://<environment-id>` URI SAN, and a URI name constraint permitting only
   the trust domain. Go matches URI name constraints against the URI host
   ([`constraints.go`](https://github.com/golang/go/blob/master/src/crypto/x509/constraints.go)),
   which for a SPIFFE ID is the environment ID.
3. **Sign `identity`'s intermediate** from a CSR whose key was generated inside the environment's
   HSM or KMS ([0006](0006-identity.md)): path length 0, same name constraint, 2-year validity,
   renewed by a repeat ceremony at two-thirds of its lifetime.
4. **Sign the control node's bootstrap certificate** from a CSR generated on the control node:
   `spiffe://<environment-id>/control-node/<node-name>`, client authentication only, 30 days. After
   `identity` is running, the control node renews through 0006's renewal endpoint like a service.
5. **Register Kubernetes cluster issuers** — for each listed cluster, one person exports the issuer URL
   and the JWKS from `/openid/v1/jwks`
   ([issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery))
   and the second re-reads them independently. Both compare SHA-256 fingerprints; the transcript records
   cluster ID, issuer, both namespaces, and fingerprint. A cluster administrator installs the service
   account admission policy (see Least privilege and secrets), and the transcript records it.
6. **Publish** the root certificate and an initial root CRL (`nextUpdate` 180 days, re-signed at each
   ceremony), and commit the bundle, fingerprints, and JWKS in the pull request that adds the inventory.

Adding a cluster or rotating its signing keys repeats step 5 alone, with `CODEOWNERS` review and no use of
the root. `production` requires an HSM or KMS for the root, the intermediate, and `identity`'s token
signing keys, with no override. `staging` and lower may use the KEK-sealed stores (`kek-sealed-ca-store`,
`kek-sealed-signing-keys`), and each use is logged, as in 0006.

#### Service certificate bootstrap

`identity` issues its own service certificate from the intermediate on every target (0001). Every
other service enrolls with a CSR through `sdk` `pkg/enroll` ([0003](0003-sdk.md)), keeps an
ECDSA P-256 key, and renews at two-thirds of its 7-day lifetime with the same OCSP and CRL checks.

**Containers and operating systems** (`podman`, `docker`, `package`, `windows`):

1. If the instance's certificate has less than a third of its lifetime left, or none exists, the control
   node generates the service's ECDSA P-256 key pair on the target, in the state directory, then calls
   `identity` over mutual TLS with its control-node certificate for a service enrollment token for
   `service/<repository>` and this host, TTL 15 minutes, registering the key's
   `SHA-256(SubjectPublicKeyInfo)`. `identity` refuses a CSR with any other key (0006), so the token is
   useless off the host.
2. The token is written with `no_log: true` and read through `certificate.enrollmentTokenFile`: a Podman
   secret (`Secret=`); a file on the host's `/run` tmpfs mounted as a Compose secret
   ([Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)); `LoadCredential=`, which
   systemd keeps in non-swappable memory
   ([systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)); or on
   Windows a file under `%ProgramData%\rackmarshal-<name>\` ACL'd to the service account.
3. The key stays in a `0600` (or ACL'd) file in the state directory, so restarts need no new token. When
   `/readyz` passes, the role removes the token; an unused token expires on its own.
4. **`service/gateway`** tokens are `approval: required` (0006): redeemable only after a second operator
   approves them through `service-enrollment-approvals`, with step-up, before the 15-minute TTL ends.
   The role requests every gateway token the run needs in one step, delivers them, prints each token ID
   and key digest for the approver to compare in [0018](0018-console.md)'s approval queue, and then
   waits, polling `/readyz` while the service retries its refused enrollment, for at most the TTL less
   a 2-minute margin for enrollment (proposed). The approver is never the requester (0018). A token left
   unapproved expires unredeemed, the play fails for that host, and the next run issues a new one.
   Renewals need no token and so no approval.

**Kubernetes** — no Ansible run is involved, so pods enroll on start, scale-out, and rescheduling
(plugin sidecars excepted, below):

1. Each service has its own ServiceAccount, and pods set `automountServiceAccountToken: false`; services
   never call the Kubernetes API.
2. A projected `serviceAccountToken` with audience `spiffe://<environment-id>/service/identity` and
   `expirationSeconds: 600`, the minimum
   ([projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)), mounts only into
   an enrollment init container that runs the service's own image as non-root with a read-only root.
3. The init container verifies `identity` against `environment.caBundle` and its SPIFFE ID, then
   sends a CSR with the token from `certificate.serviceAccountTokenFile`. `identity` verifies it
   offline against the registered issuer and JWKS, checks audience and maximum age, allows one enrollment
   per token ID, and enrolls only the service account mapped to that service (0006).
4. Key and certificate go to an `emptyDir` with `medium: Memory`, a tmpfs shared with the main container
   ([volumes](https://kubernetes.io/docs/concepts/storage/volumes/#emptydir)), which renews in place. A
   deleted pod takes its key with it; its replacement enrolls again.
5. The token is never logged, copied, or exposed as a variable. Each namespace enforces the `restricted`
   [Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/), and
   only cluster administrators may create tokens for Rackmarshal service accounts.

**Plugin sidecars on Kubernetes** — a plugin service runs as a sidecar in the provisioner pod
([0021](0021-plugin-extensibility.md)), and the pod's one service account maps to `provisioner`, so the
sidecar cannot enroll with the projected token. It enrolls with a service enrollment token instead:

1. On each run, for each plugin service, the control node requests one single-use token for
   `service/plugin-<name>` per provisioner replica, as in step 1 for hosts. A pod's key cannot be
   generated before the pod exists, so the control node generates each token's key pair itself and
   registers its SPKI SHA-256.
2. It writes the token and key pairs into one Secret per plugin with `kubernetes.core.k8s` and `no_log`
   (see Least privilege and secrets), mounted only into that plugin's sidecar container — never into
   the provisioner container or the enrollment init container. The socket stays on the shared
   `emptyDir`; the sidecar's key and certificate go to its own `medium: Memory` `emptyDir`.
3. The sidecar tries each pair in turn. Redemption is atomic (0006), so each token enrolls one sidecar
   and a sidecar that loses a race moves to the next pair. It renews in place like any service.
4. Keeping the key beside the token in a Secret adds no reach: whoever can read Secrets in the
   namespace can already run a pod as `provisioner` (see Namespaces are identities).

Tokens last 15 minutes, so they cover only the rollout the run drives. A provisioner pod created later
— scale-out, eviction, rescheduling — starts with its plugin sidecars unready until the next run issues
fresh tokens (see Open questions); container restarts within a pod keep the `emptyDir` key.

#### Least privilege and secrets

- **Namespaces are identities** — write access to workloads in a namespace is equivalent to every
  service identity in it: whoever can create a pod there can mount any of its service accounts' projected
  tokens and enroll as that service. `gateway`, whose certificate lets a peer assert any principal
  ([0008](0008-gateway.md)), therefore runs alone in `gatewayNamespace`. In each namespace a
  [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
  restricts each Rackmarshal service account to pods of its own workload: a pod naming
  `rackmarshal-<name>` must carry `app.kubernetes.io/name: <name>`. The policy is cluster-scoped, so a
  cluster administrator installs it at registration (ceremony step 5) and the runbook records it. It stops
  one service's workload from naming another's account by mistake or through a bad chart value; it cannot
  stop someone who writes pods deliberately, because labels are theirs to set, which is why the namespace
  boundary is the control.
- **Access** — the control node's kubeconfig binds a namespaced Role in the shared service namespace,
  limited to the kinds the charts render and granting nothing in `gatewayNamespace`; that namespace has
  its own narrower Role, limited to the kinds the `gateway` chart renders. Neither is ever a ClusterRole.
  Hosts use per-environment SSH keys with `become` only where needed,
  including Windows, officially supported over SSH since ansible-core 2.18 on Windows Server 2022 and
  later ([Windows SSH](https://docs.ansible.com/ansible/latest/os_guide/windows_ssh.html)). Only trusted
  users may control the Docker daemon
  ([attack surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)), so only the
  control node's `become` session touches it.
- **Secret values** never enter Git, Ansible Vault files, CI, unit or Compose files, or Helm values.
  `secrets.yaml` references resolve on the control node at run time, and services read secrets from
  files named by `...File` keys (CONVENTIONS).
- **Kubernetes Secrets** are created by `kubernetes.core.k8s` with `no_log` and mounted as files, never
  passed as Helm values, which Helm stores in release Secrets
  ([storage driver](https://github.com/helm/helm/blob/main/pkg/storage/driver/secrets.go)). The runbook
  checks encryption at rest, which Conftest cannot see.
- The control node's secret-manager credential is short-lived and host-bound, scoped to its environments.
  The KEK for a KEK-sealed store is delivered as a file at startup, never beside the sealed key (0001).

### Environment awareness

- `rackmarshal_environment.tier` drives role defaults on every target: `production` and `staging` enable
  TLS-only listeners, disable OpenAPI UIs, and require pinned artifacts; `development` may run all
  services on one host or one kind cluster.
- Last-resort features enter `overrides` only through a pull request Conftest flags for `CODEOWNERS`.
- Control nodes are dedicated per tier group; `production` targets are unreachable from the others.

### Logging & telemetry

Ansible runs use the JSON callback, written to the control node's journal with
`deployment.environment.name`, `rackmarshal.environment.tier`, and `rackmarshal.environment.id`. Each run records the
commit, playbook, targets, artifact versions, and a changed-task summary. Deployed collectors receive
OTLP/HTTP from services and forward to the environment's backend.

### Configuration

Ansible variables use the `rackmarshal_` prefix in snake_case. Rendered service configuration uses
CONVENTIONS YAML keys and `...File` references, identical on every target except file paths. There is no
`RACKMARSHAL_INFRASTRUCTURE_` prefix because nothing here is a Go executable.

### Build, release & versioning

Not versioned as a library: `main` is the deployable state, and each environment records its applied
commit. Tags `vX.Y.Z` mark execution environment image releases, built with ansible-builder by a
100-series workflow, signed, and pinned by digest in the control node's configuration.

### Testing

- **Policy** — `opa test` with passing and failing fixtures for every rule, and golden rendered output
  per target for a reference inventory.
- **Kubernetes** — kind v0.33.0 (`kindest/node:v1.37.0`) in pull-request CI: install every chart, enroll
  against a SoftHSM-backed `identity`, reschedule pods, reject replayed, wrong-audience, and
  other-service tokens, and refuse at admission a pod that names another service's account. Nightly:
  k3s on `ubuntu-24.04-arm` and kind 1.35 and 1.36 node images
  ([kind v0.33.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0)).
- **Hosts** — Molecule scenarios for `podman`, `docker`, and `package` in systemd-capable containers per
  OS family on `ubuntu-24.04` and `ubuntu-24.04-arm` runners
  ([runner images](https://github.com/actions/runner-images)), with idempotence, upgrade, and rollback
  (Molecule driver details unverified).
- **Windows** — installer install, upgrade, downgrade, and service start on `windows-2025` and `windows-2022`
  runners; `rackmarshal_target_windows` nightly against disposable Windows Server VMs over SSH.
- **End to end** — a disposable `development` inventory per target nightly, with a simulated ceremony
  using SoftHSM, cluster registration, and enrollment of every service.

## Alternatives considered

- **Podman Quadlet only** (previous draft) — simpler, but Kubernetes is now mandatory.
- **Control-node token delivery on Kubernetes** — one enrollment path, but scaled or rescheduled pods
  would wait for an Ansible run.
- **`TokenReview` from `identity`** — sees deleted pods, but needs credentials and a network path
  to every cluster API server, and enrollment fails when one is down.
- **SPIRE Kubernetes attestation** — mature, but 0001 uses SPIFFE IDs without running SPIRE.
- **Quadlet and Compose in service repositories** — closer to the code, but outside this CI's gate.
- **Argo CD or Flux** — continuous reconciliation, but a second deployment path beside Ansible.
- **AWX or [Semaphore UI](https://github.com/semaphoreui/semaphore) (v2.19.12) as the control node** —
  web UI and RBAC, but AWX (0001's example) has paused releases since 24.6.1
  ([README](https://github.com/ansible/awx)) and adds an operator and database; Semaphore is one more
  service to secure.
- **Ansible Vault** — encrypted secrets in Git behind a long-lived shared password.
- **Root-signed service certificates** — no token step, but the root would stay online, against 0001.

## Open questions

- **Collector and PostgreSQL identity** — neither fits the CONVENTIONS SPIFFE paths. Proposed: a
  separate per-environment infrastructure CA held by the secret manager, never trusted for Rackmarshal mutual
  TLS (see also 0004). Is PostgreSQL for Kubernetes targets managed or host-based only (proposed)?
- **Enrollment keys** — should `certificate.dir`, `enrollmentTokenFile`, and `serviceAccountTokenFile`
  ([0008](0008-gateway.md)) become CONVENTIONS keys for every service?
- **Managed clusters** — do providers rotate signing keys often enough that pinned JWKS is impractical
  and 0006's discovery mode becomes the norm (unverified)?
- **Pod deletion** — offline verification cannot see a deleted pod, whose certificate stays valid for up
  to 7 days after its key is gone. Acceptable, or revoke on deletion?
- **Plugin sidecars after rescheduling** — a provisioner pod created between runs waits for the next run
  to enroll its plugin sidecars. Accept that, schedule a run on pod events, or issue spare tokens with
  the 1-hour maximum TTL?
- **Artifact verifiers** — tooling for deb, rpm, and Authenticode signatures, and cosign for charts?
- **Authenticode signing** — which certificate signs the Windows installers, and where does it live?
- **Control-node certificate lapse** — recover by root ceremony, or have two control nodes cross-renew?
- **Secrets** — Vault, cloud managers, or both? On Kubernetes, Secrets or a Secrets Store CSI driver?
- **Intermediate revocation** — should peers check the root CRL for the intermediate, and who publishes
  it between ceremonies?

## References

- [0001](0001-project-repositories.md), [0003](0003-sdk.md), [0004](0004-common.md),
  [0006](0006-identity.md), [0008](0008-gateway.md), [0009](0009-inventory.md),
  [CONVENTIONS.md](CONVENTIONS.md); versions from the release pages under Pinned toolchain.
- Ansible [docs](https://docs.ansible.com/) and
  [Windows SSH](https://docs.ansible.com/ansible/latest/os_guide/windows_ssh.html);
  [`kubernetes.core` changelog](https://github.com/ansible-collections/kubernetes.core/blob/main/CHANGELOG.rst).
- Helm [Secrets storage driver](https://github.com/helm/helm/blob/main/pkg/storage/driver/secrets.go);
  [Conftest INI parser](https://github.com/open-policy-agent/conftest/blob/master/parser/ini/ini.go);
  [Conftest](https://www.conftest.dev); [Open Policy Agent](https://www.openpolicyagent.org/docs/latest/).
- Kubernetes [projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/),
  [issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/),
  [volumes](https://kubernetes.io/docs/concepts/storage/volumes/),
  [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
  [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/),
  [releases](https://kubernetes.io/releases/).
- GitHub [merge methods](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github)
  and [commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)
  (the `web-flow` key at <https://github.com/web-flow.gpg>);
  [git-merge-tree](https://git-scm.com/docs/git-merge-tree).
- [podman-systemd.unit](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html),
  [Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/),
  [Docker security](https://docs.docker.com/engine/security/),
  [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).
- [nFPM](https://nfpm.goreleaser.com), [NSIS](https://nsis.sourceforge.io) (zlib/libpng licensed),
  [`ansible.windows.win_package`](https://docs.ansible.com/ansible/latest/collections/ansible/windows/win_package_module.html),
  [runner images](https://github.com/actions/runner-images), [endoflife.date](https://endoflife.date).
- [Go `crypto/x509` constraints](https://github.com/golang/go/blob/master/src/crypto/x509/constraints.go)
  (Go 1.27.1 source); [SPIFFE ID](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md),
  [X.509-SVID](https://github.com/spiffe/spiffe/blob/main/standards/X509-SVID.md),
  [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280).
- [go-echo-starter](https://github.com/servercurio/go-echo-starter) — `.releaserc.json` and
  `charts/go-echo-starter/`; [AWX](https://github.com/ansible/awx).
