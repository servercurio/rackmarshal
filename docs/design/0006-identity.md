<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0006 — identity

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `identity` is the environment's authorization server and certificate authority. It
  implements a minimal OIDC provider and SAML IdP, stores accounts, tenants, RBAC, sessions, and API
  tokens in PostgreSQL, and delegates login pages to `sso`. Its intermediate CA issues agent,
  service, and control-node certificates from enrollment tokens, or from projected service account
  tokens for services on Kubernetes, and publishes OCSP and CRLs, with keys in an HSM or KMS through
  PKCS#11.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 assigns `identity` the internal SAML/OIDC IdP, accounts, API tokens, RBAC, tenancy, and
sessions ([Auth split](0001-project-repositories.md#auth-split)); the internal CA, enrollment tokens,
and OCSP/CRL ([Agent enrollment](0001-project-repositories.md#agent-enrollment)); and environment-bound
tokens and service certificate bootstrap
([Environment identity](0001-project-repositories.md#environment-identity)). It is first in the
[auth spine](0001-project-repositories.md#sequencing--phases) and must never be internet-facing.

**Goals**

- One issuer per environment for every user, API, and certificate credential.
- Keys that never leave an HSM or KMS in `production`.
- A small, auditable protocol surface with a measured dependency set.

**Non-goals**

- Login pages, external IdP federation, and cookies — [0007](0007-sso.md).
- Request authentication at the edge and routing — [0008](0008-gateway.md).
- The offline root and environment creation — [0005](0005-infrastructure.md).
- Key storage on agents — [0012](0012-agent.md).

## Proposal

### Responsibilities

- **Authorization server** — OIDC provider (authorization code with PKCE, refresh, device
  authorization, token exchange) and SAML 2.0 IdP.
- **Directory** — accounts, groups, service accounts, tenants, role bindings, federated identity links.
- **Credentials** — password and WebAuthn verification, sessions, refresh tokens, API tokens.
- **CA** — enrollment tokens, Kubernetes service account token verification, CSR issuance, renewal,
  revocation, OCSP responder, CRL.
- **Audit** — an append-only record of every security-relevant change and decision.

### Interfaces

#### Listeners and reachability

A single TLS 1.3 mutual-TLS listener on a private interface. Callers reach it three ways:

- **`gateway`** forwards `operator` and `agent` operations and the public protocol endpoints.
- **`sso`** and other services call `internal` operations directly with service certificates.
- **Service enrollment** is the one route that accepts a connection without a client certificate
  (`security: []`), because the enrolling service and `gateway` have no certificate yet. This
  answers 0003's open question for services; agents still enroll through the gateway.

#### Login delegation

Proposed: the **login-challenge model** of [Ory Hydra](https://www.ory.com/docs/oauth2-oidc/custom-login-consent/flow).
`/authorize` and the SAML SSO endpoint create a login challenge and redirect the browser to
`sso` with `login_challenge=<id>`. `sso` authenticates the user, then accepts the challenge
over mutual TLS, and the browser returns to `/authorize` to receive a code. `identity` keeps all
protocol logic; `sso` keeps all pages and federation.

#### Protocol endpoints

Standards-defined, outside the versioned REST paths (0002 non-goal). The issuer carries the environment
ID: `https://<operator-ingress>/identity/oidc/<environment-id>`.

| Path under the issuer (`/identity/oidc/<environment-id>`)       | Standard                                   |
|-----------------------------------------------------------------|--------------------------------------------|
| `/.well-known/openid-configuration`                              | OIDC Discovery, RFC 8414                   |
| `/jwks.json`                                                     | RFC 7517                                   |
| `/authorize`                                                     | RFC 6749, PKCE S256 required (RFC 7636)    |
| `/token`                                                         | code, `refresh_token`, device code, RFC 8693 |
| `/device-authorization`                                          | RFC 8628                                   |
| `/revoke`                                                        | RFC 7009                                   |

SAML: `/identity/saml/<environment-id>/metadata` and `/sso` (HTTP-Redirect and HTTP-POST bindings).
PKI: `/identity/pki/<environment-id>/ca.pem`, `/crl.der`, and `/ocsp` (RFC 6960 GET and POST), named
in each certificate's AIA and CRL distribution point extensions.

No implicit or password grants, following the OAuth 2.0 security BCP
([RFC 9700](https://www.rfc-editor.org/rfc/rfc9700)). Redirect URIs match exactly.

#### REST API sketch (generated to `gen/openapi/identity/v1alpha1/openapi.yaml`)

| Method and path                                              | Audience   | Auth           |
|--------------------------------------------------------------|------------|----------------|
| `GET/POST /identity/v1alpha1/tenants`, `/{tenantId}`          | operator   | bearer         |
| `GET/POST /identity/v1alpha1/accounts`, `/{accountId}`        | operator   | bearer         |
| `GET/POST /identity/v1alpha1/roles`, `/role-bindings`         | operator   | bearer         |
| `GET/POST/DELETE /identity/v1alpha1/api-tokens`               | operator   | bearer         |
| `GET/POST /identity/v1alpha1/identity-providers`              | operator   | bearer         |
| `POST /identity/v1alpha1/enrollment-tokens`                   | operator   | bearer         |
| `GET/DELETE /identity/v1alpha1/enrollment-tokens`, `/{tokenId}` | operator | bearer         |
| `GET /identity/v1alpha1/agents`, `/{agentId}`                 | operator   | bearer         |
| `DELETE /identity/v1alpha1/agents/{agentId}`                  | operator   | bearer         |
| `GET /identity/v1alpha1/agents/{agentId}`                     | internal   | mTLS, services |
| `POST /identity/v1alpha1/agent-enrollments`                   | agent      | none           |
| `POST /identity/v1alpha1/certificate-renewals`                | agent, internal | mTLS; SPIFFE ID copied from the peer |
| `POST /identity/v1alpha1/revocations`                         | operator   | bearer         |
| `POST /identity/v1alpha1/service-enrollment-tokens`           | internal   | mTLS, control node only |
| `POST /identity/v1alpha1/service-enrollments`                 | internal   | none           |
| `GET /identity/v1alpha1/cluster-issuers`                      | internal   | mTLS, control node only |
| `GET/PUT /identity/v1alpha1/login-challenges/{challengeId}`   | internal   | mTLS, `sso` only |
| `POST /identity/v1alpha1/password-verifications`, `/webauthn-assertions` | internal | mTLS, `sso` only |
| `POST /identity/v1alpha1/federated-logins`                    | internal   | mTLS, `sso` only |
| `POST /identity/v1alpha1/device-approvals`                    | internal   | mTLS, `sso` only |
| `POST /identity/v1alpha1/token-introspections`                | internal   | mTLS, `gateway` only |

User codes, tokens, and passwords travel only in request bodies marked `x-rackmarshal-sensitive`, never in
paths (CONVENTIONS). Tenancy comes from the token's principal, not the path (0002's proposal).

The agent resource carries the agent ID, its tenant, host labels from the enrollment token, certificate
serial and expiry, and enabled state. `gateway` reads it as an `internal` operation to resolve an
agent's tenant for `X-Rackmarshal-Principal` (0008), `inventory` reads the host labels on first contact
(0009), and `cli` lists and revokes agents and enrollment tokens (0010). `DELETE` disables the
agent and revokes its certificate in the same transaction, so disabling takes effect within the
revocation cache window rather than at certificate expiry.

#### Tokens

- **Access tokens** — JWT per [RFC 9068](https://www.rfc-editor.org/rfc/rfc9068), ES256, 10 minutes.
  `iss` is the issuer URL above; `aud` is `spiffe://<environment-id>/service/gateway`. Claims:
  `sub` (principal ID), `client_id`, `scope`, `jti`, `amr`, `forge_tenant`, `forge_roles`. The gateway
  verifies locally against JWKS and rejects any `iss` or `aud` naming another environment.
- **ID tokens** — for third-party OIDC relying parties only; never accepted as bearer tokens.
- **Refresh tokens** — opaque, 256 random bits, stored as SHA-256, rotated on every use with reuse
  detection that revokes the family. Idle 8 hours, absolute 7 days (proposed).
- **API tokens** — `forge_pat_<environment-id>_<secret>`, stored as SHA-256 (256-bit secrets need no
  slow hash). The gateway exchanges one for a signed access token through `token-introspections`
  (RFC 8693 semantics) and caches the result for at most its 5-minute lifetime, so every bearer token a
  service sees is a signed, environment-bound JWT. Maximum lifetime 365 days, default 90.
- **SAML assertions** — signed with a per-environment key; the audience restriction and issuer carry
  the environment ID.
- **Signing key rotation** — every 30 days; JWKS publishes current, next, and previous keys.

#### Enrollment tokens

Format (answers 0003's open question), parseable offline:
`fe1.<environment-id>.<ca-sha256>.<token-id>.<secret>`, where `<ca-sha256>` is the root certificate's
SHA-256 in unpadded lowercase base32 (52 characters) and `<secret>` is 256 bits. Only the secret's
SHA-256 is stored.

| Kind    | Bound to                                    | TTL default / max | Created by                |
|---------|---------------------------------------------|-------------------|---------------------------|
| agent   | environment, tenant, optional host labels   | 1h / 24h          | operator via `cli`  |
| service | environment, `service/<repository>`, host, CSR public key | 15m / 1h | control node certificate |

Redemption is one
`UPDATE … SET used_at = now() WHERE id = $1 AND used_at IS NULL AND expires_at > now() RETURNING …`
in the enrollment transaction, so a token cannot be used twice.

A service token is bound to a key, not only to a name: the control node generates the key pair on the
target, registers `SHA-256(SubjectPublicKeyInfo)` when it requests the token, and `service-enrollments`
refuses a CSR whose public key does not match. A stolen token is then useless without the private key
that never left the host. This matters most for `service/gateway`, whose certificate is what lets
a peer assert `X-Rackmarshal-Principal` for any user or tenant (0008); issuing that identity additionally
requires the token to be marked `approval: required`, redeemable only after a second operator approves
it through `POST /identity/v1alpha1/service-enrollment-approvals`.

#### Kubernetes service account enrollment

Services on Kubernetes ([0005](0005-infrastructure.md)) enroll with a projected service account
token instead of a service enrollment token, on the same `service-enrollments` operation. The request
carries exactly one of `enrollmentToken` or `serviceAccountToken`, both `x-rackmarshal-sensitive`. Agents
cannot use this path. Pods enroll on start, scale-out, and rescheduling without the control node.

**Cluster issuer registry** — loaded from `kubernetes.clusterIssuersFile`, which `infrastructure`
renders from the inventory. There is no write API, so a registration arrives only through a signed
commit and the control node, and each JWKS fingerprint is recorded at the environment's key ceremony.
`GET cluster-issuers` returns the loaded entries and the file's SHA-256 so the control node can detect
drift.

```yaml
clusters:
  - id: east-1                          # lowercase DNS label
    state: active                       # active | retired
    issuer: https://oidc.east-1.example.net
    jwks:
      mode: pinned                      # pinned (default) | discovery
      file: /etc/rackmarshal-identity/clusters/east-1.jwks.json
      # discovery: { caFile: /etc/rackmarshal-identity/clusters/east-1-ca.pem, refresh: 1h }
    serviceAccounts:
      - { namespace: rackmarshal-qa-east, name: inventory, service: inventory }
```

**Verification** — offline; `identity` never calls a cluster's API server:

1. **Header** — the token is at most 8 KiB, `alg` is `RS256` or `ES256`
   ([RFC 8725](https://www.rfc-editor.org/rfc/rfc8725)), and `none`, HMAC, and `jwk`, `jku`, `x5u`, or
   `x5c` headers are rejected.
2. **Issuer and key** — `iss` must exactly equal an `active` cluster's `issuer`, and the signature must
   verify with a key from that cluster's JWKS only. In `discovery` mode the JWKS comes from the issuer's
   discovery document over HTTPS verified only against `caFile`, is cached for `refresh`, and every key
   change is audited
   ([issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery)).
3. **Audience** — `aud` must be exactly one value, `spiffe://<environment-id>/service/identity`,
   so a token for another environment or audience fails.
4. **Age** — `exp`, `iat`, and `nbf` are required with 60 seconds of skew, and `now − iat` must not
   exceed `kubernetes.maxTokenAge` (10 minutes) whatever `exp` says. Projected tokens last at least 600 s
   ([projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)).
5. **Pod binding** — `jti`, `kubernetes.io.namespace`, `kubernetes.io.serviceaccount`, and
   `kubernetes.io.pod.uid` are required; Kubernetes embeds the JTI and pod and node claims by default
   since 1.32 ([service account claims](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)).
   `sub` must be `system:serviceaccount:<namespace>:<name>` and agree with those claims.
6. **Mapping** — the service account must be listed for that cluster, and its `service` is the only
   SPIFFE ID the certificate may carry: only `inventory`'s service account obtains
   `spiffe://<environment-id>/service/inventory`. Any other name in the CSR fails.

**Replay** — issuance inserts `SHA-256(iss, jti)` into `service_account_enrollments` in the same
transaction, so one token yields one certificate. A retry with the same token and the same CSR public
key returns the certificate already issued, for an init container that failed after enrolling; any other
reuse fails and is audited. Rows are deleted after the token's `exp`.

**Deregistration** — setting a cluster to `retired` rejects its tokens and renewals of certificates it
enrolled, and revokes those certificates with reason `cessationOfOperation`. An entry is deleted only
after its last certificate expires. Offline checks cannot see a deleted pod; its certificate stays valid
until revoked or expired (see Open questions).

After enrollment the service renews over mutual TLS like any other service.

#### Certificate profiles

| Profile       | SPIFFE ID                                    | EKU               | Lifetime                     |
|---------------|----------------------------------------------|-------------------|------------------------------|
| agent         | `/agent/<agent-id>` (issued by identity)     | client            | 30–90 days per tenant (30)   |
| service       | `/service/<repository>`                      | client, server    | 7 days                       |
| control node  | `/control-node/<node-name>` (renewal only)   | client            | 30 days                      |
| OCSP signer   | none; delegated responder (RFC 6960 §4.2.2.2) | `OCSPSigning`    | 7 days                       |

All leaf keys are ECDSA P-256 CSRs (CONVENTIONS); a renewal must present a new key. Holders renew at
two-thirds of the lifetime. On startup `identity` issues its own service certificate from the
intermediate and renews it in-process (0001).

#### Revocation

- **OCSP** — signed by the delegated responder certificate, whose key is local, so HSM load stays off
  the hot path. `thisUpdate` now, `nextUpdate` 1 hour, cached per serial for 15 minutes.
- **CRL** — regenerated every 12 hours and on each revocation, `nextUpdate` 24 hours, signed by the
  intermediate through the key backend.
- Built with [`golang.org/x/crypto/ocsp`](https://pkg.go.dev/golang.org/x/crypto/ocsp) and
  [`x509.CreateRevocationList`](https://pkg.go.dev/crypto/x509#CreateRevocationList).

### Dependencies

Measured on 2026-09-15 with throwaway modules (`go list -deps`, Go 1.27.1):

| Module                                            | Version  | Linked modules | Use                          |
|---------------------------------------------------|----------|----------------|------------------------------|
| `github.com/go-jose/go-jose/v4`                    | v4.1.5   | 1              | JWS/JWT, JWKS, SA tokens     |
| `github.com/miekg/pkcs11` (cgo)                    | v1.1.2   | 0 external     | on-premises HSM and CloudHSM |
| `aws-sdk-go-v2/service/kms`                        | v1.61.0  | 5              | pure-Go KMS signing backend  |
| `github.com/crewjam/saml`                          | v0.5.1   | 6              | SAML IdP                     |
| `github.com/go-webauthn/webauthn`                  | v0.18.1  | 12             | WebAuthn verification        |
| `golang.org/x/crypto` (`argon2`, `ocsp`)           | starter  | 0 new          | passwords, OCSP              |

- **Starter stack kept** — Echo v5, pgx, bun, goose. swaggo is removed; the service serves the
  embedded `api-schema` document (0002).
- **PKCS#11 on every platform** — `pkcs11` covers on-premises HSMs, AWS CloudHSM
  ([PKCS#11 library](https://docs.aws.amazon.com/cloudhsm/latest/userguide/pkcs11-library.html)), and
  Google Cloud KMS through `libkmsp11`
  ([Cloud KMS PKCS#11](https://docs.cloud.google.com/kms/docs/reference/pkcs11-library)), and is
  supported on Linux, Windows, and macOS. `miekg/pkcs11` (BSD-3-Clause, maintained) pulls in no
  external Go module — it binds the PKCS#11 C API directly, with `#cgo` directives for each platform —
  so it needs cgo and a native build per platform rather than a cross-compile. Building with
  `CGO_ENABLED=0` is not an option that yields a working backend: Go then skips every file in the
  package, and the binary links none of its loader (verified 2026-09-15 on v1.1.2, whose
  `CGO_ENABLED=0` build contains no `dlopen`, `pkcs11.New`, or `pkcs11.Ctx` symbol).
- **`aws-kms` as a second backend** — a pure-Go backend on the AWS KMS SDK, measured at 5 linked
  modules and 3 MiB (`go version -m`, Go 1.27.1, `linux/amd64`, `CGO_ENABLED=0`, stripped), against 32
  linked modules including gRPC for Google's Cloud KMS client. It suits deployments that want no cgo
  toolchain at all. A small `crypto.Signer` adapter over `miekg/pkcs11` avoids `crypto11` (now
  `eclipse-keypont/crypto11` v1.6.8, which adds `pkg/errors` and a pool module).
- **crewjam/saml** is the only maintained Go SAML IdP found; its five published advisories are fixed
  in 0.4.14 or earlier, but its last tag is v0.5.1 and its `go.mod` pins `goxmldsig` v1.4.0 while
  v1.6.1 is current. Rackmarshal requires the current `goxmldsig`.
- **Rackmarshal** — `api-schema`, `sdk` (`pkg/spiffe`, `pkg/tlsconfig`, `pkg/revocation`),
  `common`.

### Data & storage

PostgreSQL through the starter's pgx, bun, and goose migrations. Every tenant-scoped table carries
`tenant_id`, and repositories require it in every query.

| Table                          | Key columns                                                                  |
|--------------------------------|------------------------------------------------------------------------------|
| `tenants`                      | `id`, `name`, `agent_cert_lifetime` (30–90 days)                             |
| `principals`                   | `id`, `kind` (account, service_account), `status`, `created_at`              |
| `accounts`                     | `principal_id`, `username`, `email`, `password_hash` (Argon2id PHC string)   |
| `webauthn_credentials`         | `principal_id`, `credential_id`, `public_key`, `sign_count`                  |
| `tenant_memberships`, `role_bindings` | `principal_id`, `tenant_id`, `role`                                   |
| `identity_providers`           | `id`, `tenant_id`, `protocol`, `metadata`, `claim_mappings`, `jit_enabled`   |
| `federated_identities`         | `provider_id`, `external_subject`, `principal_id` (unique pair)              |
| `sessions`, `login_challenges` | `id`, `principal_id`, `amr`, `expires_at`, `revoked_at`                      |
| `refresh_tokens`, `api_tokens` | `token_hash`, `family_id`, `principal_id`, `expires_at`, `revoked_at`        |
| `enrollment_tokens`            | `id`, `kind`, `secret_hash`, `bindings`, `expires_at`, `used_at`             |
| `service_account_enrollments`  | `cluster_id`, `token_hash`, `pod_uid`, `key_sha256`, `serial`, `expires_at`  |
| `certificates`                 | `serial`, `spiffe_id`, `profile`, `not_after`, `revoked_at`, `reason`        |
| `signing_keys`                 | `kid`, `purpose`, `backend`, `key_ref`, `sealed_key`, `state`                |
| `audit_events`                 | `seq`, `time`, `actor`, `action`, `target`, `outcome`, `prev_hash`, `hash`   |
| `audit_anchors`                | `interval_start` (PK), `seq`, `hash`, `state`, `attempts`, `object_key`      |
| `crl_cache`                    | `generation` (PK), `der`, `this_update`, `next_update`, `signed_at`          |

- Passwords use Argon2id at no less than OWASP's minimum, 19 MiB, 2 iterations, parallelism 1
  ([Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)).
- The service's database role has no `UPDATE` or `DELETE` on `audit_events`, which is the control that
  stops the service from rewriting its own history. Each row also hashes the previous one, which alone
  detects tampering only against a head recorded elsewhere, since a database superuser could recompute
  the whole chain. So the head is anchored outside the database: every `audit.anchorInterval` one
  replica — the one that wins the claim row described under Scaling — signs
  `{seq, hash, time, environmentId}` with its HSM or KMS key and writes it to append-only
  storage in a different cloud account from the environment, under an object-lock or WORM retention
  policy, using credentials that may only `PutObject` — no delete, overwrite, or read. An attacker who
  takes the environment entirely therefore still cannot rewrite its audit history, because the account
  holding the anchors is not one the environment's own credentials reach. The signing key is the one
  input the database role cannot reach and the retention policy is what stops an anchor being replaced,
  so detection no longer depends on a reader having saved an earlier head. A failed anchor write is
  logged and retried rather than blocking audited operations, and the gap is itself visible in the
  anchors as a missing interval. `rackmarshal-cli audit verify` ([0010](0010-cli.md)) does the
  comparison with read access to the anchor account alone.
- `sealed_key` is populated only for the KEK-sealed backend.

#### Scaling

`identity` runs N replicas and elects nothing. Request handling is already stateless — every
read and write goes to PostgreSQL — so the work is confined to four places where a single writer would
otherwise be assumed, per
[CONVENTIONS — Running multiple replicas](CONVENTIONS.md#running-multiple-replicas).

- **Audit chain.** Each row commits to the one before it, so appends serialize. The transaction takes
  `pg_advisory_xact_lock(hashtext('rackmarshal.audit'))`, reads the head, and inserts with
  `seq = head.seq + 1` and `prev_hash = head.hash`. `seq` is deliberately not a sequence: a rolled-back
  transaction would burn a number and leave a gap, and a gap in a hash chain cannot be told apart from
  a deleted record. The lock covers the append alone and releases on commit. Audit volume is bounded by
  authenticated operations, so one append at a time is not the constraint at expected scale; the
  recorded alternative if it becomes one is to sequence the chain by `chain_id` and have the verifier
  check each chain.
- **Anchoring.** Every replica computes the current interval and writes a claim row —
  `INSERT INTO audit_anchors (interval_start, …) VALUES (…) ON CONFLICT DO NOTHING`. Only the replica
  whose insert affected a row signs the head and performs the `PutObject`; the others do nothing. The
  row carries `state` (`pending`, `written`) and `attempts`, so a failed write is visible in the
  database as well as by its absence from the anchor store, and any replica may retry it on a later
  tick. A retry can leave two objects for one interval, both valid signatures over the same head:
  `rackmarshal-cli audit verify` requires at least one valid anchor per interval, not exactly one.
- **Signing keys.** The invariants are schema, not coordination:
  `CREATE UNIQUE INDEX signing_keys_one_current ON signing_keys (purpose) WHERE state = 'current'`, and
  the same for `next`. Rotation is a single transaction that promotes `next` to `current`, `current` to
  `previous`, and inserts a fresh `next`. A second replica rotating concurrently violates the index and
  rolls back having done nothing, so two `current` keys cannot be published whether or not either
  replica took a lock.
- **CRL.** Every revocation increments a `crl_generation` counter. A replica serving `/crl.der` reads
  the signed DER for the current generation from `crl_cache`; on a miss it generates, signs, and
  `INSERT … ON CONFLICT DO NOTHING`, then reads back whichever row won. Replicas therefore serve
  byte-identical CRLs. That matters because agents cache by `nextUpdate`: replicas signing their own
  CRLs would hand out different `thisUpdate` times and make agent caches flap on every reconnect.

OCSP needs none of this. Responses are signed per request by the delegated responder, whose key is
local to the replica, and each replica holds its own responder certificate issued under the same CA
with `OCSPSigning` and `id-pkix-ocsp-nocheck`. A client that sees a different responder certificate
from a different replica validates it the same way.

### Security

- **Key backends** — `pkcs11` (preferred, every platform), `aws-kms` (pure Go), or `kek-sealed`.
  `kek-sealed` stores AES-256-GCM
  ciphertext with the key ID as associated data, and loads the KEK only from `kekFile` into memory.
  It calls `AllowLastResort("kek-sealed-ca-store")` for the CA key and
  `AllowLastResort("kek-sealed-signing-keys")` for token keys, so both are refused in `production`
  without an override.
- **CA constraints** — the intermediate has path length 0 and a URI name constraint for the trust
  domain (0005), so even a misissued leaf cannot name another environment.
- **Caller pinning** — internal operations check the caller's SPIFFE ID: `sso` for login
  operations, `gateway` for introspection, `control-node/*` for service enrollment tokens and
  cluster issuers.
- **Brute force** — failed password, WebAuthn, and user-code attempts are counted per account and per
  source in PostgreSQL, with exponential delays rather than hard lockouts that attackers could abuse.
- **No enumeration** — verification responses do not distinguish unknown accounts from bad passwords.
- **Service account tokens** — accepted only in the request body, never logged or stored; only the
  SHA-256 of `iss` and `jti` is kept. Pinned JWKS files hold public keys only.
- **Fuzzing** — token, service account token, CSR, and SAML request parsers.

### Environment awareness

- `environment.id` and `caBundle` are required (CONVENTIONS); startup fails if the intermediate does
  not chain to the bundle or does not carry the environment's trust domain.
- `Hardened()` tiers disable the OpenAPI UI, require WebAuthn for platform administrators, and refuse
  the `kek-sealed` backends without an override.
- `development` may use SoftHSM through the same `pkcs11` backend.

### Logging & telemetry

- Audit events are also logged at `info` with `rackmarshal.audit.action`, `rackmarshal.audit.outcome`,
  `rackmarshal.principal.id`, `rackmarshal.tenant.id`, and `rackmarshal.certificate.serial`; enrollments add
  `rackmarshal.enrollment.credential` and `rackmarshal.kubernetes.cluster.id`. Secrets, token values including
  service account tokens, and CSR contents are never logged.
- Metrics: `rackmarshal.identity.tokens.issued`, `rackmarshal.identity.certificates.issued`,
  `rackmarshal.identity.enrollments.failed`, `rackmarshal.identity.ocsp.responses`, and
  `rackmarshal.identity.keybackend.sign.duration`.

### Configuration

Prefix `RACKMARSHAL_IDENTITY_`, plus the starter's `server` and `database` blocks and CONVENTIONS' `logging`,
`telemetry`, and `environment` blocks. The DSN moves to `database.dsnFile`.

| YAML                               | Variable                                    | Default                  |
|------------------------------------|---------------------------------------------|--------------------------|
| `issuer.baseUrl`                   | `RACKMARSHAL_IDENTITY_ISSUER_BASE_URL`            | none — required          |
| `keys.backend`                     | `RACKMARSHAL_IDENTITY_KEYS_BACKEND`               | `pkcs11`                 |
| `keys.pkcs11.module`               | `RACKMARSHAL_IDENTITY_KEYS_PKCS11_MODULE`         | none                     |
| `keys.pkcs11.tokenLabel`           | `RACKMARSHAL_IDENTITY_KEYS_PKCS11_TOKEN_LABEL`    | none                     |
| `keys.pkcs11.pinFile`              | `RACKMARSHAL_IDENTITY_KEYS_PKCS11_PIN_FILE`       | none                     |
| `keys.awsKms.keyId`                | `RACKMARSHAL_IDENTITY_KEYS_AWS_KMS_KEY_ID`        | none                     |
| `keys.awsKms.region`               | `RACKMARSHAL_IDENTITY_KEYS_AWS_KMS_REGION`        | none                     |
| `keys.kekFile`                     | `RACKMARSHAL_IDENTITY_KEYS_KEK_FILE`              | none                     |
| `ca.intermediateCertFile`          | `RACKMARSHAL_IDENTITY_CA_INTERMEDIATE_CERT_FILE`  | none — required          |
| `tokens.accessTtl`                 | `RACKMARSHAL_IDENTITY_TOKENS_ACCESS_TTL`          | `10m`                    |
| `tokens.signingKeyRotation`        | `RACKMARSHAL_IDENTITY_TOKENS_SIGNING_KEY_ROTATION`| `720h`                   |
| `enrollment.agentDefaultTtl`       | `RACKMARSHAL_IDENTITY_ENROLLMENT_AGENT_DEFAULT_TTL` | `1h` (max `24h`)       |
| `kubernetes.clusterIssuersFile`    | `RACKMARSHAL_IDENTITY_KUBERNETES_CLUSTER_ISSUERS_FILE` | none (path disabled) |
| `kubernetes.maxTokenAge`           | `RACKMARSHAL_IDENTITY_KUBERNETES_MAX_TOKEN_AGE`   | `10m` (max `15m`)        |
| `certificates.serviceLifetime`     | `RACKMARSHAL_IDENTITY_CERTIFICATES_SERVICE_LIFETIME` | `168h` (fixed by 0001) |
| `revocation.ocspNextUpdate`        | `RACKMARSHAL_IDENTITY_REVOCATION_OCSP_NEXT_UPDATE`| `1h`                     |
| `revocation.crlNextUpdate`         | `RACKMARSHAL_IDENTITY_REVOCATION_CRL_NEXT_UPDATE` | `24h`                    |
| `audit.anchorInterval`             | `RACKMARSHAL_IDENTITY_AUDIT_ANCHOR_INTERVAL`      | `1h`                     |
| `audit.anchor.uri`                 | `RACKMARSHAL_IDENTITY_AUDIT_ANCHOR_URI`           | none — required in `production` |

Validation rejects values beyond 0001's bounds: agent token TTL over 24 hours, agent certificates
outside 30–90 days, or a service lifetime other than 7 days. It also rejects a
`kubernetes.maxTokenAge` over 15 minutes, a cluster without `jwks`, and a service account mapped to more
than one service.

### Build, release & versioning

- Bootstrap from `go-echo-starter`; replace its logging with `common` and its OpenAPI generator
  with the embedded contract.
- **Builds** — release binaries are built natively per platform with `CGO_ENABLED=1`, on Linux
  `amd64`/`arm64`, Windows `amd64`, and macOS `arm64` runners, so `pkcs11` is available everywhere.
  That rules out cross-compiling arm64 from an amd64 runner: each OS and architecture needs its own
  runner and C toolchain. The OCI image is also a cgo build, produced per architecture on a native
  runner rather than cross-compiled, so `pkcs11` — the default backend — works in the published
  container. Linux binaries and the image link glibc, so they are built on the oldest target in the
  support matrix — Enterprise Linux 9, glibc 2.34 ([0005](0005-infrastructure.md)) — which keeps
  them loadable on EL10, Debian 12 and 13, and Ubuntu 24.04 and 26.04, all of which ship a newer glibc.
  Building on a newer glibc than the target host does not run there. A `CGO_ENABLED=0` build remains
  available for deployments that want no cgo and ships `aws-kms` and `kek-sealed` only, which then must
  be selected explicitly. Whether the starter's Taskfile builds with cgo today is unverified.
- `v0.x` until accepted; API versions follow [0002](0002-api-schema.md).

### Testing

- **Protocol** — the [OpenID Foundation conformance suite](https://openid.net/certification/) in a
  300-series workflow for the Basic and Config OP profiles.
- **CA** — SoftHSM2 for the `pkcs11` backend on each native runner, and a fake KMS for `aws-kms`;
  issuance, renewal, and revocation with a fake
  clock; chains verified through `sdk` `pkg/tlsconfig`.
- **Enrollment** — concurrent redemption of one token succeeds exactly once; wrong environment, tenant,
  and expired tokens fail. Service account tokens from kind and synthetic issuers fail with a wrong
  issuer, audience, algorithm, or key, an age over `maxTokenAge`, an unmapped or other service's
  account, a retired cluster, or a replay with a different CSR key.
- **Data** — migrations up and down on PostgreSQL in CI; a test asserts every tenant-scoped query
  filters by `tenant_id`.

## Alternatives considered

- **[zitadel/oidc](https://github.com/zitadel/oidc) `op` package** (v3.51.0) — certified OP library,
  but links 18 modules including chi, gorilla/securecookie, and OpenTelemetry.
- **[ory/fosite](https://github.com/ory/fosite)** (v0.49.0) — links 53 modules including gRPC and the
  official OTLP exporter.
- **Cloud KMS SDKs** — native APIs without a PKCS#11 library, but Google's client brings gRPC and every
  cloud adds its own module tree. A build-tagged `awskms` backend is the fallback if PKCS#11 proves
  impractical on AWS KMS.
- **Opaque bearer API tokens** checked by introspection on every request — simpler, but the token
  services see would be unsigned, which 0001's environment binding rules out.
- **Hosting login pages in `identity`** — fewer hops, but puts an internet-facing surface on the
  identity store, which 0001's auth split exists to avoid.
- **PASETO tokens** — simpler format, but no OIDC or RFC 9068 interoperability.
- **TOTP second factor** — widely supported and phishable; deferred behind WebAuthn.
- **`TokenReview` against each cluster** — sees deleted pods, but gives `identity` credentials and
  a network path to every cluster API server, and enrollment fails when one is down.
- **A write API for cluster issuers** — adds clusters without a deployment, but moves registration
  outside signed commits and Conftest.

## Open questions

- **Gateway exceptions** — `/authorize`, `/token`, `/device-authorization`, JWKS, and agent enrollment
  must pass the gateway unauthenticated. Agree the allowlist with [0008](0008-gateway.md).
- **Authorization decisions** — roles in the token with a role-to-permission table cached by the
  gateway (proposed), or a decision call per request?
- **SAML IdP scope** — required in v1alpha1, or deferred until a relying party needs it, given
  crewjam/saml's release cadence?
- **SAML signing algorithm** — ECDSA P-256 per CONVENTIONS, or RSA for relying parties that lack ECDSA?
- **Root CA hash in enrollment tokens** during root rotation — one hash or both?
- **Local accounts in `production`** — break-glass only, with federation required for everyone else?
- **Pinned JWKS on managed clusters** — do providers rotate service account signing keys often enough
  that `discovery` mode becomes necessary (unverified)?
- **Deleted pods** — offline checks cannot see a pod's deletion. Should deployment tooling revoke its
  certificate before the 7-day expiry?

## References

- [0001 — Project Repositories](0001-project-repositories.md) — auth split, agent enrollment,
  environment identity and awareness.
- [0002](0002-api-schema.md), [0003](0003-sdk.md), [0004](0004-common.md),
  [0005](0005-infrastructure.md), [0007](0007-sso.md), [CONVENTIONS.md](CONVENTIONS.md).
- [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749), [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636),
  [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009), [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517),
  [RFC 8414](https://www.rfc-editor.org/rfc/rfc8414), [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628),
  [RFC 8693](https://www.rfc-editor.org/rfc/rfc8693), [RFC 9068](https://www.rfc-editor.org/rfc/rfc9068),
  [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700).
- [OpenID Connect Core](https://openid.net/specs/openid-connect-core-1_0.html) and
  [Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html);
  [SAML 2.0](https://docs.oasis-open.org/security/saml/v2.0/).
- [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280), [RFC 6960](https://www.rfc-editor.org/rfc/rfc6960),
  [RFC 2986](https://www.rfc-editor.org/rfc/rfc2986).
- [Ory login and consent flow](https://www.ory.com/docs/oauth2-oidc/custom-login-consent/flow) —
  `login_challenge` delegation model.
- [go-jose](https://github.com/go-jose/go-jose), [miekg/pkcs11](https://github.com/miekg/pkcs11),
  [crewjam/saml](https://github.com/crewjam/saml) and its
  [security advisories](https://github.com/crewjam/saml/security/advisories),
  [goxmldsig](https://github.com/russellhaering/goxmldsig),
  [go-webauthn](https://github.com/go-webauthn/webauthn).
- [AWS CloudHSM PKCS#11 library](https://docs.aws.amazon.com/cloudhsm/latest/userguide/pkcs11-library.html),
  [AWS KMS SDK for Go](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/kms),
  [cgo](https://pkg.go.dev/cmd/cgo);
  [Cloud KMS PKCS#11 library](https://docs.cloud.google.com/kms/docs/reference/pkcs11-library).
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
- [`golang.org/x/crypto/ocsp`](https://pkg.go.dev/golang.org/x/crypto/ocsp) and
  [`crypto/x509`](https://pkg.go.dev/crypto/x509).
- [OpenID certification and conformance suite](https://openid.net/certification/).
- Kubernetes [service account tokens](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/),
  [issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery),
  [projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/), and
  [feature gates](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/)
  (`ServiceAccountTokenJTI`, `ServiceAccountTokenPodNodeInfo`); [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519)
  and [RFC 8725](https://www.rfc-editor.org/rfc/rfc8725).
- [go-echo-starter](https://github.com/servercurio/go-echo-starter) — Echo v5, pgx, bun, goose.
