<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0017 — portal

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-16
- **Summary:** `portal` is the tenant-facing web surface: the endpoints a tenant owns, the desired
  state applied to them, and whether reality matches. Every change goes through a plan the operator reads
  before applying, which is the thing a browser does better than a terminal. It is an OIDC relying party
  holding no API token in the browser, and adds no API of its own.

> An initial draft. The stack, session model, and configuration are fixed by
> [0016](0016-web-ui-architecture.md); the visual system is [0019](0019-brand-identity.md). Conventions
> other repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 gives tenants no interface at all. `cli` ([0010](0010-cli.md)) covers every operation,
but it is an operator tool: it assumes a stored profile, a verified environment, and someone comfortable
reading a YAML diff in a terminal. The people who own the endpoints Rackmarshal manages are frequently not that
person, and the operations that matter most to them — seeing what drifted, reading what an apply would
change, and approving it — are exactly the ones that benefit from a rendered page.

**Goals**

- Show a tenant the state of their endpoints without them running a command.
- Make `plan` a first-class screen. 0011 already returns affected endpoints and a diff; nothing
  renders it.
- Let a tenant administrator enroll hosts and manage their own access without a platform administrator.
- Make a valid directive set reachable without knowing the schema, through a guided flow that shows what
  each choice targets before anything is written.
- Never show, or allow action on, another tenant's data.

**Non-goals**

- Platform administration — tenants, environments, PKI, and cross-tenant agents are
  [0018](0018-console.md).
- An API. The portal consumes the gateway through `sdk` and exposes nothing of its own.
- Replacing `cli` for automation. Anything scriptable stays scriptable there.

## Proposal

### Responsibilities

- Render the tenant's endpoints, their facts, labels, history, and drift state from `inventory`.
- Render desired state from `provisioner`: directive sets, policies, scripts, device connections.
- Accept a document by file or paste, validate it against its JSON Schema before it leaves the browser,
  and author a new `DirectiveSet` through a guided flow.
- Run and display plans, and apply them after explicit confirmation.
- Show reconciliation and enforcement history, including failures with the reason.
- Let tenant administrators create, list, and revoke enrollment tokens and API tokens for their tenant.
- Nothing else. Every write is a call the gateway already exposes to the `operator` audience.

### Interfaces

#### Page inventory

| Path                        | Purpose                                                        | Role       |
|-----------------------------|----------------------------------------------------------------|------------|
| `/`                         | Overview: drift summary, agents reporting, recent applies       | member     |
| `/endpoints`                | List with filter by label, class, path, and drift state         | member     |
| `/endpoints/{id}`           | Detail: facts, labels, history, applied generation, conditions  | member     |
| `/endpoints/{id}/facts`     | Full fact set, searchable, as reported by the agent             | member     |
| `/directives`               | Directive sets, policies, scripts, device connections           | member     |
| `/directives/new`           | Guided flow: basics, targeting, resources, review                | member     |
| `/directives/{id}`          | Document detail with revision history                           | member     |
| `/directives/{id}/plan`     | Dry run: affected endpoints and diff                            | member     |
| `/reconciliations`          | Queue and history, with per-endpoint outcome                    | member     |
| `/agents`                   | Agents in this tenant, certificate expiry, last report          | admin      |
| `/agents/enrollment-tokens` | Create, list, revoke                                            | admin      |
| `/access/api-tokens`        | The signed-in user's tokens                                     | member     |
| `/access/members`           | Tenant members and role assignment                              | admin      |
| `/settings`                 | Theme, density, timezone, notification preferences              | member     |

Roles are the tenant roles `identity` already issues; the portal reads them from the session
principal and renders no navigation entry a role cannot use, rather than rendering a control that fails
on submit.

#### The plan screen

This is the screen that justifies the surface. `POST /provisioner/v1alpha1/plans` already returns the
affected endpoints and the diff (0011); the portal renders it as the middle step of a three-step flow:

```
select documents ──► plan (no writes) ──► review diff ──► apply
                        │                      │
                        │                      └── per-endpoint: create / update / no change / conflict
                        └── policy decisions shown inline, including denials with the rule that denied
```

- Diffs render per endpoint and per resource, additions and removals distinguished by symbol and label
  rather than colour alone.
- A policy denial is shown where it happened, naming the rule, because 0011 surfaces `policy_denied` with
  the decision rather than a generic failure.
- Conflicts — two sets targeting one endpoint with the same kind and name, which 0011 reports at plan
  time — block apply and name both documents.
- The plan is bound to a document generation. If anything changed since the plan ran, apply refuses and
  re-plans, so the diff the operator approved is the diff that applies.

#### Confirming a destructive action

The portal follows the confirmation rule 0010 sets for the CLI, for the same reason: a member with four
environments open needs an interruption that is hard to perform by reflex.

- Retiring an endpoint, revoking an agent, or applying to `production` requires typing the environment
  name to confirm — the same string 0010's prompt asks for.
- The environment name and tier appear in the confirmation itself, not only in the masthead.
- Applies in `production` additionally show the count of affected endpoints in the confirmation.

#### Live state without a socket

Drift and reconciliation status change while a page is open. The portal polls with htmx
(`hx-trigger="every 30s"`) on the fragments that carry state, and pauses polling when the document is
hidden. This is deliberately the simplest mechanism that works; 0016 records server-sent events as an
open question rather than adopting them before there is evidence they are needed.

### Dependencies

As 0016 fixes: templ, Echo, htmx, Alpine's CSP build, `sdk`, `common`, and the vendored
`tokens.css` from [0019](0019-brand-identity.md). The portal adds no dependency of its own. Charts on the
overview are drawn as inline SVG from the same data the tables use rather than through a charting
library, which keeps the CSP free of another script origin and the module graph unchanged.

### Data & storage

None beyond the session store 0016 specifies, which is PostgreSQL-backed by default precisely so N
replicas share one session. The portal caches nothing between requests: a stale
endpoint list shown to a tenant is worse than a slower page, and the gateway is already the consistency
boundary. Uploaded directive documents are held in memory for the duration of a plan and are never
written to disk.

### Security

- **Tenant scoping** — the tenant comes from the session principal, never from a path or query parameter.
  A resource belonging to another tenant returns `404`, so the portal does not confirm that another
  tenant's object exists. This mirrors the rule CONVENTIONS sets for the API.
- **Role enforcement server-side** — hidden navigation is a convenience, not a control. Every handler
  re-checks the role before calling the gateway.
- **Upload handling** — a directive document is validated against its JSON Schema from `api-schema`
  before it reaches the gateway, and the same 1 MiB limit, alias-node rejection, and unknown-field
  rejection 0011 applies at admission are applied here so a malformed file fails with a readable message
  instead of a `422` from a service the user never sees.
- **No secrets rendered** — `credentialRef` values resolve at apply time in the provisioner (0011) and
  are never fetched by the portal. Any property marked `x-rackmarshal-sensitive` renders as a reference, never
  a value, and the rendered-state view uses the gateway's redacted representation.
- **CSRF, CSP, session, and step-up** — as 0016 specifies. The portal requires no step-up beyond its own
  destructive confirmations; the operations that create trust live in the console.

### Environment awareness

The environment name and tier appear in the masthead of every authenticated page and in the `<title>`, so
a browser tab is self-identifying. `production` carries the tier stripe from 0019 on the masthead and in
every destructive confirmation. `Hardened()` tiers use the shorter session timeouts 0016 sets and
disable the density and debug affordances in `/settings`.

### Logging & telemetry

Through `common`, per CONVENTIONS, with the fields 0016 defines. Every plan and apply emits a span
carrying `rackmarshal.tenant.id`, the document generations involved, and the resulting reconciliation ID, so a
support question about "what did we change at 14:20" resolves from the trace rather than from memory.
Fact values, uploaded document bodies, and token values are never logged.

### Configuration

`RACKMARSHAL_PORTAL`, with the keys 0016 lists. Two are specific to this surface:

| YAML                    | Variable                             | Default                         |
|-------------------------|--------------------------------------|---------------------------------|
| `ui.statusPollInterval` | `RACKMARSHAL_PORTAL_UI_STATUS_POLL_INTERVAL` | `30s`                         |
| `ui.pageSize`           | `RACKMARSHAL_PORTAL_UI_PAGE_SIZE`          | `50` (max `200`)                |

### Build, release & versioning

As 0016 specifies: `templ generate` and the Tailwind standalone CLI at build time, both outputs committed
with a CI drift check; assets embedded with `go:embed`; the full deployment set from CONVENTIONS — OCI
image, Helm chart, deb/rpm, NSIS installer. No cgo, so it cross-compiles normally.

### Testing

- Handler tests cover both render paths for every route — full page and htmx fragment — which is what
  keeps the no-JavaScript guarantee real rather than claimed.
- A plan-rendering test asserts that a denial names its rule and that a conflict blocks apply.
- Cross-tenant tests assert `404` rather than `403` for every resource route.
- axe-core runs against every page in CI, per 0016.
- `playwright-go`, in a nested module, covers login, the plan-to-apply flow, and one polling fragment.

## Alternatives considered

- **Folding the portal into `console` with RBAC** — cheaper, and rejected in 0016 for blast radius.
  Worth restating here: the console issues enrollment tokens and approves service enrollments, and those
  controls should not share a process with the tenant-facing application.
- **Leaving authoring out entirely** — the position this document originally took: directive sets belong
  in version control, where review and history already work, so the portal would only read and plan them.
  Reversed, because it confused two things. Where a document *lives* is version control either way; what
  was actually missing was a way to produce a valid one without already knowing the schema. The guided
  flow writes a document the same shape a repository holds, and the upload path takes an existing file,
  so neither bypasses review — a created set still has to be planned and applied like any other.
- **A free-form YAML editor with schema completion** — more flexible than a wizard and much closer to
  what an experienced operator wants. Not chosen as the only route, because it helps least exactly where
  help is needed: someone who does not yet know the shape. The upload path accepts hand-written YAML for
  the experienced case, and the wizard covers the other.
- **A charting library for the overview** — `chart.js` or similar would be faster to build than inline
  SVG. Rejected to keep the CSP at `script-src 'self'` with no extra origin and the module graph flat.
- **Server-sent events for live status** — better than polling at scale, and an open question in 0016
  rather than a decision here; polling is the smaller thing that is known to work.
- **Optimistic UI on apply** — rejected outright. An apply that appears to succeed and did not is worse
  than a slow one, on a surface that changes infrastructure.

## Open questions

- **Bulk operations** — should the endpoint list support multi-select label edits and bulk retire, or
  does that belong in `cli` where a mistake is easier to script around?
- **Saved views** — per-user filters on the endpoint list would need per-user storage the portal does not
  otherwise have. Session, database, or `localStorage`?
- **Notification preferences** — `/settings` lists them, but no component sends notifications yet. Which
  service owns delivery?
- **Fact search scale** — an endpoint can report thousands of facts. Is client-side filtering adequate,
  or does `inventory` need a fact query parameter?
- **Tenant administrator enrollment tokens** — 0006 marks enrollment token creation `operator` audience.
  Does a tenant administrator hold that, or does the console own all issuance?

## References

- [0009](0009-inventory.md) — endpoints, facts, labels, and history the portal renders.
- [0011](0011-provisioner.md) — directive sets, the plan endpoint, policy decisions, and
  `endpoint_status` drift values.
- [0010](0010-cli.md) — the confirmation convention and output vocabulary this surface matches.
- [0016](0016-web-ui-architecture.md) — stack, session, CSP, and configuration.
- [0019](0019-brand-identity.md) — tokens, drift pills, and the tier stripe.
