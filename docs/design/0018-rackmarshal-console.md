<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0018 — rackmarshal-console

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-16
- **Summary:** `rackmarshal-console` is the platform administrator's surface: tenants, identity and federation,
  the environment's certificate authority and key backend, agent enrollment, plugin publishers, and the
  audit chain. It is separated from `rackmarshal-portal` because it holds the controls that create trust —
  issuing enrollment tokens and approving service enrollments — and those should not share a process with
  the tenant-facing application. Every action here is audited, and the ones that create trust require a
  fresh authentication.

> An initial draft. The stack, session model, and configuration are fixed by
> [0016](0016-web-ui-architecture.md); the visual system is [0019](0019-brand-identity.md). Conventions
> other repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

Everything an administrator does to a Rackmarshal deployment today happens through `rackmarshal-cli` against
`rackmarshal-identity`, `rackmarshal-provisioner`, and the gateway. That works, and for scripted operations it
remains the right tool. What it does not do is show a state that is spread across several services at
once: whether the environment's certificate authority is healthy, whether the audit chain is still being
anchored, which service enrollments are waiting for a second approval, and which core plugin key agents
currently trust.

Those are review surfaces rather than command surfaces. An administrator reads them, notices something
wrong, and acts — which is the shape a page serves better than a command.

**Goals**

- Show deployment-wide state that no single existing command assembles.
- Give the two-person controls a queue, so an approval is something an administrator is presented with
  rather than something they must know to go looking for.
- Make the audit chain's health visible, since a chain nobody checks detects nothing.
- Keep every trust-creating action behind a fresh authentication and a full audit record.

**Non-goals**

- Tenant-level work — endpoints, directive sets, plans, and drift are [0017](0017-rackmarshal-portal.md).
- Replacing `rackmarshal-cli` for automation, break-glass, or air-gapped operation. The console is an
  additional surface, never the only path to an operation.
- Holding any private key or performing any cryptographic operation itself. Signing stays in
  `rackmarshal-identity`'s HSM or KMS backend.
- A metrics or logging product. Telemetry goes to the OpenTelemetry collector; the console links out.

## Proposal

### Responsibilities

- Render deployment state: services and versions, environment identity, certificate authority health,
  revocation freshness, and audit anchor freshness.
- Present the approval queue for service enrollments that require a second operator.
- Administer tenants, platform users, roles, and external identity provider configuration.
- Administer agent enrollment across tenants: tokens, agents, certificate expiry, and revocation.
- Show plugin publishers, verified plugin imports, the current core plugin key, and revocations.
- Nothing that `rackmarshal-cli` cannot also do. Every button maps to an existing gateway operation.

### Interfaces

#### Page inventory

| Path                        | Purpose                                                          | Step-up |
|-----------------------------|------------------------------------------------------------------|---------|
| `/`                         | Deployment overview: services, CA, revocation, anchors, approvals | no      |
| `/approvals`                | Service enrollments awaiting a second operator                    | yes     |
| `/tenants`                  | List, create, suspend                                             | no      |
| `/tenants/{id}`             | Detail: members, roles, federation, quotas                        | no      |
| `/identity/users`           | Platform users, including break-glass local accounts              | no      |
| `/identity/federation`      | External OIDC and SAML providers, per tenant                      | yes     |
| `/pki`                      | CA chain, key backend, signing keys and their state               | no      |
| `/pki/certificates`         | Issued certificates by SPIFFE ID, with expiry and serial          | no      |
| `/pki/revocation`           | CRL and OCSP freshness, revoke a certificate                      | yes     |
| `/agents`                   | Agents across every tenant, last report, certificate expiry       | no      |
| `/agents/enrollment-tokens` | Issue, list, revoke                                               | yes     |
| `/plugins/publishers`       | `PluginPublisher` records and their verification identities       | yes     |
| `/plugins/imports`          | Verified `AgentPlugin` imports, digests, Rekor log entries        | no      |
| `/plugins/core-key`         | Current core key ID, embedded keys, revocation list               | yes     |
| `/audit`                    | The event chain, filtered by actor, action, target, outcome       | no      |
| `/audit/anchors`            | Anchor history and verification status                            | no      |

#### The overview

The overview exists to answer one question — is anything wrong — and it answers it with four things that
would otherwise require four different commands against three services:

```
┌ Environment ─────────────┐ ┌ Certificate authority ───┐
│ qa-east · staging        │ │ backend  pkcs11          │
│ k7m2q9x4bt6vn8rc3wzhy5jd │ │ root     expires in 412d │
└──────────────────────────┘ │ signing  2 active, 1 next│
                             └──────────────────────────┘
┌ Revocation ──────────────┐ ┌ Audit anchors ───────────┐
│ CRL   nextUpdate in 19h  │ │ last     04:37 UTC       │
│ OCSP  nextUpdate in 41m  │ │ interval 1h · 2 missed   │ ← critical
└──────────────────────────┘ └──────────────────────────┘
```

Two of these carry a state that is easy to miss and expensive to miss:

- **Revocation freshness.** 0012 makes a CRL past its `nextUpdate` stop new bundles from being accepted.
  An administrator should see that approaching rather than discover it when agents stop applying.
- **Anchor freshness.** 0006 anchors the audit chain head to append-only storage in a separate account
  every `audit.anchorInterval`, and a failed write is logged and retried rather than blocking operations.
  That is the correct trade-off and it makes a silent gap possible, so the gap is shown here as
  `critical` — a missing anchor is the one failure that erodes the ability to detect every other one.

#### The approval queue

0006 requires a second operator to approve a service enrollment for `service/rackmarshal-gateway`, because that
certificate is what lets a peer assert `X-Rackmarshal-Principal` for any user or tenant. In `rackmarshal-cli` this is
a command an administrator must know to run. Here it is a queue:

- Each entry names the requested SPIFFE ID, the requesting control node, the registered CSR public key
  digest, who requested it, and when it expires.
- The approver is never the requester. The console refuses an approval by the same principal and says so,
  rather than hiding the button, so the two-person rule is legible instead of mysterious.
- Approving requires a step-up authentication completed within the last five minutes.
- The entry shows the key digest in monospace, in full, with no truncation — an administrator comparing
  it against what the control node reported needs every character.

#### Cross-tenant work is explicit

`rackmarshal-portal` derives the tenant from the session and never from the request. The console is the
opposite: it acts across tenants by design, so scope is always explicit and always recorded.

- Any page scoped to one tenant names that tenant in the masthead beside the environment.
- Switching tenant is a deliberate control, never a side effect of following a link.
- Every audit event the console produces carries `rackmarshal.tenant.id` when the action was tenant-scoped, and
  records its absence when it was not, so "which tenant was this done to" is never inferred later.

#### Destructive and trust-creating actions

The console inherits 0010's confirmation convention and adds one rule of its own. Retiring, revoking, and
suspending require typing the environment name, as in `rackmarshal-cli` and `rackmarshal-portal`. Beyond that:

| Action                              | Step-up | Second operator | Confirmation |
|-------------------------------------|---------|-----------------|--------------|
| Issue an enrollment token           | yes     | no              | environment  |
| Approve a service enrollment        | yes     | yes, enforced   | environment  |
| Revoke a certificate                | yes     | no              | environment  |
| Rotate a signing key                | yes     | no              | environment  |
| Change the current core plugin key  | yes     | no              | environment  |
| Suspend a tenant                    | no      | no              | environment  |

Step-up requests `prompt=login` with `max_age=300` against `rackmarshal-identity`, which in hardened tiers
lands on a WebAuthn prompt because 0006 already requires WebAuthn for platform administrators there.

### Dependencies

As 0016 fixes: templ, Echo, htmx, Alpine's CSP build, `rackmarshal-sdk`, `rackmarshal-common`, and the vendored
`tokens.css` from [0019](0019-brand-identity.md). The console adds nothing further. The overview's small
charts are inline SVG rather than a charting library, for the same reason as in 0017: no second script
origin in the content security policy.

### Data & storage

Only the session store 0016 specifies, which is PostgreSQL-backed by default so that N replicas share
one session. The console is otherwise stateless with respect to the deployment: it renders what the
gateway returns and caches none of it, so any replica can serve any request. Audit events in particular are never copied into
a local store, because a second copy with its own retention would weaken the claim the chain makes.

### Security

This surface is the most valuable target in the deployment, so its controls are stated rather than
assumed:

- **No standing authority.** The console holds the signed-in administrator's token and nothing more. It
  has no service account with rights beyond a user, so compromising the process yields whatever the
  currently signed-in sessions hold, not the deployment.
- **No private keys, ever.** Every signing operation happens in `rackmarshal-identity`'s HSM or KMS backend.
  The console renders key metadata — `kid`, backend, state — and never key material, sealed or otherwise.
- **Step-up on trust creation**, as tabulated above, so a stolen session cookie alone cannot issue an
  enrollment token.
- **Two-person enforcement server-side.** The approver-is-not-requester check is enforced by
  `rackmarshal-identity`; the console refuses early only to give a readable message. A console defect cannot
  defeat the rule.
- **Audit before effect.** Every console action produces an audit event in the same transaction as the
  change, per 0006. An action that cannot be audited does not happen.
- **Session separation.** The console uses its own `__Host-` prefixed cookie and its own OIDC client
  registration, so a portal session is never a console session and the two cannot be confused.
- **CSP, CSRF, and headers** exactly as 0016 specifies, with no relaxation for this surface.

### Environment awareness

The environment name, tier, and ID appear in the masthead and the `<title>`, as in 0017. The console adds
one behaviour: because it administers the environment itself, it displays the environment ID in full
rather than truncated, and compares it against the ID in the session on every request, destroying the
session on a mismatch. `Hardened()` tiers enforce the step-up table above; in `development` the step-up
is still required for the approval queue, so the two-person flow is exercised where it is being built.

### Logging & telemetry

Through `rackmarshal-common`, per CONVENTIONS, with 0016's fields. Console spans carry the administrator
principal, the action, and the target, and never the values being administered. Specifically: no key
material, no token values, no CSR contents, and no audit event bodies enter logs or spans — the console
renders those to the operator and forgets them.

### Configuration

`RACKMARSHAL_CONSOLE`, with 0016's keys. Two are specific to this surface:

| YAML                     | Variable                                | Default |
|--------------------------|-----------------------------------------|---------|
| `ui.stepUpMaxAge`        | `RACKMARSHAL_CONSOLE_UI_STEP_UP_MAX_AGE`      | `300s`  |
| `ui.anchorStaleAfter`    | `RACKMARSHAL_CONSOLE_UI_ANCHOR_STALE_AFTER`   | `2` missed intervals |

### Build, release & versioning

As 0016 specifies: `templ generate` and the Tailwind standalone CLI, both outputs committed with a drift
check; assets embedded with `go:embed`; the CONVENTIONS deployment set — OCI image, Helm chart, deb/rpm,
NSIS installer. No cgo, so it cross-compiles normally.

### Testing

- Handler tests cover the full-page and fragment render paths for every route, as in 0017.
- The approval queue has a dedicated test that the same principal cannot both request and approve, and
  that the console's early refusal matches what `rackmarshal-identity` enforces.
- Step-up tests assert that every action in the table above rejects a session older than `stepUpMaxAge`.
- An anchor-freshness test asserts a missed interval renders as `critical`, not as a quiet absence.
- axe-core runs against every page in CI, per 0016.

## Alternatives considered

- **One portal with an admin section behind RBAC** — decided against in 0016; restated here because the
  approval queue is the concrete reason. A two-person control that shares a process with the tenant
  application is one defect away from being a one-person control.
- **Putting the console behind the `internal` audience** — appealing, since these are internal
  operations. Rejected because the console acts as a signed-in human, and `internal` operations are
  service-to-service and deliberately never routed by the gateway (CONVENTIONS).
- **A read-only console, with all writes through `rackmarshal-cli`** — genuinely tempting, and it would remove
  most of the security surface above. Rejected because the approval queue is the point: an approval that
  requires leaving the page to run a command will be done from the page's information without reading it.
- **Embedding a metrics dashboard** — rejected; Rackmarshal exports OpenTelemetry and the collector's own tools
  are better at this. The console links out rather than re-implementing.

## Open questions

- **Break-glass** — 0006 asks whether local accounts in `production` are break-glass only. If they are,
  should the console refuse to authenticate them at all, forcing break-glass through `rackmarshal-cli`?
- **Approval notification** — the queue is visible when an administrator visits. Who tells them a request
  is waiting, given Rackmarshal has no notification component?
- **Audit retention and export** — the console renders the chain, but an auditor will want an export.
  Does that belong here, in `rackmarshal-cli`, or in neither?
- **Multi-environment view** — an operator running four environments has four consoles. Is a single
  cross-environment surface desirable, or does it undermine the environment isolation 0001 establishes?
- **Core key changeover** — 0012 leaves the ceremony open. If the next key is held on an offline HSM
  under split control, the console can at most display the changeover; should it initiate one at all?

## References

- [0006](0006-rackmarshal-identity.md) — tenants, users, federation, PKI, key backends, the service-enrollment
  second approval, and the audit chain with its external anchors.
- [0007](0007-rackmarshal-sso.md) — the login site and per-tenant external IdP configuration.
- [0011](0011-rackmarshal-provisioner.md) — plugin publishers, verified imports, and the bundle fields the
  core-key page reads.
- [0012](0012-rackmarshal-agent.md) — the core plugin key, its revocation list, and CRL freshness rules.
- [0016](0016-web-ui-architecture.md) — stack, session, step-up mechanism, CSP, and configuration.
- [0019](0019-brand-identity.md) — tokens, tier stripe, and state vocabulary.
