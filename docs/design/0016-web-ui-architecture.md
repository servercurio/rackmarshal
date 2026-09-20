<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0016 — Web UI architecture

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-16
- **Summary:** Rackmarshal gains three browser surfaces — the existing `rackmarshal-sso` login site, a new
  `rackmarshal-portal` for tenant users, and a new `rackmarshal-console` for platform administrators — built as
  server-rendered templ applications enhanced with htmx and Alpine on one design system. Browsers never
  hold a Rackmarshal API token: each surface is an OIDC relying party that keeps tokens server-side and calls
  the gateway itself, which is what lets the gateway keep CORS off. `rackmarshal-cli` gains a loopback
  callback server so it can log in through the same authorization code flow.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md). The visual system this
> document assumes is [0019](0019-brand-identity.md).

## Context & goals

0001 enumerates fifteen repositories and none of them renders a page for a human, beyond the login site
0007 gives `rackmarshal-sso`. Everything an operator does today goes through `rackmarshal-cli`
([0010](0010-rackmarshal-cli.md)), and 0007 makes operator administration pages an explicit non-goal for the
SSO service. Two loose ends in the existing set point at this document: 0008 asks outright whether "a
web console [will] need CORS on the operator ingress", and turns CORS and CSRF middleware off on the
grounds that "no browser origin calls the gateway"; and 0010's device authorization grant "needs a
browser on the same machine and fails over SSH", which 0010 records as a candidate for a second login
method.

This document adds the surfaces, fixes the stack they share, and answers both questions.

**Goals**

- One rendering stack and one design system across every browser surface, so a control behaves and looks
  the same in all three.
- A session model in which **no Rackmarshal API token ever reaches a browser**, so the gateway's posture in
  0008 survives unchanged.
- Keep 0007's guarantee that login works without JavaScript except for WebAuthn, and extend WCAG 2.2 AA
  to the new surfaces.
- Give `rackmarshal-cli` a login that works where the device grant is awkward, without a second token type.
- Work in air-gapped installations, which rules out loading anything from a public CDN at runtime.

**Non-goals**

- The page inventory of each surface — [0017](0017-rackmarshal-portal.md) and [0018](0018-rackmarshal-console.md).
- The visual identity itself: palette, type, tokens, and mark usage are [0019](0019-brand-identity.md).
- A published component library. Extraction is deferred; see Open questions.
- Replacing `rackmarshal-cli`. The CLI stays the complete operator interface; the portals are additive.

## Proposal

### Responsibilities

| Surface         | Audience                        | Authentication                | Repository       |
|-----------------|---------------------------------|-------------------------------|------------------|
| Login site      | Anonymous, pre-authentication   | Renders `rackmarshal-identity` challenges | `rackmarshal-sso` (0007) |
| `rackmarshal-portal`  | Tenant users and tenant admins  | OIDC relying party            | New              |
| `rackmarshal-console` | Platform administrators         | OIDC relying party, step-up   | New              |

The split follows 0007's own reasoning. `rackmarshal-sso` is hardened as the only surface anonymous browsers
reach; putting authenticated administration in the same process would undo that. `rackmarshal-portal` and
`rackmarshal-console` are separated from each other for the same reason at a different level: the console
administers the whole deployment — tenants, environments, certificate authorities, agent enrollment —
while the portal serves one tenant's users. A defect in the tenant-facing application should not sit in
the same address space as the controls that issue enrollment tokens.

### Interfaces

#### Rendering stack

| Layer            | Choice                     | Version     | Why                                                        |
|------------------|----------------------------|-------------|------------------------------------------------------------|
| Templates        | templ                      | v0.3.1020   | Typed, compiled to Go; no runtime template parsing         |
| Server interaction | htmx                     | 2.0.10      | HTML over the wire; no client-side API token               |
| Local state      | Alpine.js (CSP build)      | 3.14.1      | Menus, tabs, disclosure; no build step of its own          |
| Styling          | Tailwind CSS               | v4          | Matches the TailAdmin reference; standalone CLI, no Node   |
| Reference theme  | TailAdmin community        | MIT         | Dashboard shell, tables, forms as a structural starting point |

templ compiles templates into Go functions, so a template that references a missing field fails at build
time rather than in a handler. Generated `_templ.go` files are committed and CI fails on drift, matching
the rule CONVENTIONS already sets for generated API code.

**No jQuery.** htmx covers requests and swapping, Alpine covers local reactivity, and a third DOM idiom
would overlap both. The TailAdmin community edition already ships Alpine rather than jQuery, so the
reference theme does not pull one in either.

**Alpine runs its CSP build.** Alpine's default distribution evaluates expression strings with the
`Function` constructor, which cannot work under a content security policy without `'unsafe-eval'`. The
CSP build restricts expressions to component-scoped methods and properties declared in `Alpine.data`,
which costs some expressiveness in markup and buys a policy with no `unsafe-eval` on any surface. This is
a hard requirement, not a preference: these are the pages that administer the deployment.

**Nothing loads from a CDN.** htmx, Alpine, the compiled stylesheet, and the fonts are served by the
application from its own origin, fingerprinted and cached. 0012 already contemplates air-gapped
installations with local TUF mirrors; a login page that needs `fonts.googleapis.com` would not render
there. Self-hosting also removes the third-party origins a CSP would otherwise have to allow.

#### How a page reaches the API

```
browser ──TLS──► rackmarshal-portal ──mTLS + Bearer──► rackmarshal-gateway ──► rackmarshal-inventory, …
   │                  │
   │                  └── session cookie ⇄ server-side session: access + refresh token
   └── holds a session cookie only; never a Rackmarshal API token
```

The browser talks only to the portal or console origin. That process holds the user's tokens, calls the
gateway through `rackmarshal-sdk` exactly as `rackmarshal-cli` does, and returns HTML. Three things follow:

- **0008's CORS question resolves to "no".** No browser origin calls the gateway, so CORS and CSRF
  middleware stay off there and 0008's Open question can be struck. The portals are ordinary `operator`
  audience clients of the gateway.
- **No token storage problem in the browser.** There is no access token in `localStorage`, no refresh
  token in JavaScript reach, and no silent-renewal iframe.
- **`rackmarshal-sdk` stays the only client.** The portals add no second way to call Rackmarshal, so the
  CONVENTIONS rule that API calls go through the generated client holds here too.

#### Browser session

Each surface is an OIDC relying party of `rackmarshal-identity`, using the authorization code flow with PKCE
([RFC 7636](https://www.rfc-editor.org/rfc/rfc7636)) against the endpoints 0006 owns at
`/identity/oidc/<environment-id>/`.

| Property   | Value                                                                       |
|------------|-----------------------------------------------------------------------------|
| Cookie     | `__Host-forge_portal_session` / `__Host-forge_console_session`              |
| Attributes | `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, no `Domain`                 |
| Contents   | An opaque 256-bit identifier; tokens stay in the server-side session store  |
| Idle life  | 30 minutes (`production`), renewed on use                                   |
| Absolute   | 8 hours (`production`), no renewal past it                                  |

The `__Host-` prefix forbids a `Domain` attribute and requires `Secure` and `Path=/`, so a sibling
host in the same registrable domain cannot set a cookie the portal will accept
([cookie prefixes](https://www.rfc-editor.org/rfc/rfc6265bis#name-cookie-name-prefixes)). `SameSite=Lax`
rather than `Strict` so that following a link from a notification lands the user in a logged-in page;
every state-changing request carries a CSRF token regardless.

#### `rackmarshal-cli` login through a loopback callback

0010 keeps the device authorization grant, which works over SSH but requires the operator to carry a
code to another machine. This document adds a second method for the case where a browser is available on
the same machine, using the same authorization code flow the portals use:

1. `rackmarshal-cli login` binds a listener on `127.0.0.1:0` — a kernel-assigned port, never a fixed one — and
   generates a PKCE verifier and a `state` value.
2. It opens the system browser at `/identity/oidc/<environment-id>/authorize` with
   `redirect_uri=http://127.0.0.1:<port>/callback`, printing the URL for the operator to paste if no
   browser opens.
3. `rackmarshal-sso` renders login as it does for any other client (0007). Nothing about the flow is
   CLI-specific.
4. The callback lands on the loopback listener, which checks `state`, exchanges the code with the PKCE
   verifier, stores credentials as 0010 already specifies, and renders a plain confirmation page served
   from the CLI binary itself.
5. The listener stops on success, on error, or after 300 seconds, whichever comes first, and accepts
   exactly one request.

Loopback redirection is the method [RFC 8252 §7.3](https://www.rfc-editor.org/rfc/rfc8252#section-7.3)
prescribes for native applications; it requires the authorization server to accept an arbitrary port on
`127.0.0.1`, which 0006 must permit for the CLI client registration. `--device-code` keeps the old flow
for headless and SSH sessions, and the CLI falls back to it automatically when it cannot bind a
listener or no display is present.

#### Progressive enhancement

| Surface     | Without JavaScript                                   | With JavaScript                      |
|-------------|------------------------------------------------------|--------------------------------------|
| Login       | Fully functional except WebAuthn (0007's guarantee)  | Unchanged                            |
| Portal      | Every read path and every form submits and renders   | Partial swaps, live status, filters  |
| Console     | Every read path and every form submits and renders   | Partial swaps, live status, filters  |

Because htmx degrades to ordinary form posts and link navigations when its attributes are ignored, the
enhancement boundary is cheap to hold: handlers render a full page when the request has no `HX-Request`
header and a fragment when it does. Nothing is reachable only through a swap.

### Dependencies

Per CONVENTIONS, every direct dependency is justified with what it pulls in.

- **`github.com/a-h/templ` v0.3.1020** — runtime is a small package; the generator runs through
  `go run github.com/a-h/templ/cmd/templ@v0.3.1020` so it never enters `go.mod`.
- **`github.com/labstack/echo/v4`** — already the HTTP server in `go-echo-starter` and in 0006–0009.
- **`github.com/gorilla/csrf`** — double-submit CSRF tokens. Alternative considered: Echo's own CSRF
  middleware, which is already present; the decision is recorded under Alternatives.
- **`rackmarshal-sdk`** — the only API client, with `pkg/enroll` for the service certificate and
  `pkg/tlsconfig` for the gateway connection.
- **`rackmarshal-common`** — logging and telemetry, as every Rackmarshal Go repository does.
- **An OIDC relying-party library** — open question; `coreos/go-oidc` pulls `go-jose`, which is a larger
  graph than the flow needs. A hand-written code-exchange client over `rackmarshal-sdk`'s pinned HTTP client is
  the alternative, since discovery and JWKS handling are the only parts that carry real complexity.

Front-end assets are vendored, not fetched: `htmx.min.js`, `alpine.csp.min.js`, the compiled stylesheet,
and the WOFF2 faces are committed under `internal/web/static/` with their SHA-256 digests recorded, and
CI re-downloads and compares them.

### Data & storage

Neither portal owns product data; both read and write through the gateway. The only state they keep is
the session.

| Store        | Contents                                              | Lifetime         |
|--------------|-------------------------------------------------------|------------------|
| Session      | Access token, refresh token, principal, tenant, roles | Absolute 8 hours |
| Flow state   | PKCE verifier, `state`, nonce, return path            | 10 minutes       |

The session store is an interface with two implementations: PostgreSQL, which is the default, and
in-process, which is permitted only when `environment.tier` is `development` and refused at startup
otherwise. The default has to be the replica-safe one. An in-process store does not fail loudly under a
second replica — it fails as intermittent logouts, once, for whichever users land on the other pod, and
that is a poor thing to discover in production. PostgreSQL reuses the database conventions 0006 and
0009 already set. Tokens in the store are encrypted with a key from the same HSM or KMS backend 0006 uses, so
a database backup does not contain usable bearer tokens. Sessions are deleted on logout, on refresh
failure, and when the environment ID of the session does not match the process's own.

### Security

- **CSP** — `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:;
  font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`.
  No `unsafe-inline` and no `unsafe-eval`, which the Alpine CSP build and self-hosted assets make
  achievable. Inline styles in templates are forbidden by lint rather than by policy exception.
- **CSRF** — every unsafe method carries a token bound to the session, sent by htmx through
  `hx-headers` on the body element and by a hidden field in non-JS forms. htmx is configured with
  `selfRequestsOnly: true` so an injected attribute cannot direct a request to another origin.
- **Response headers** — the starter's hardened set from 0007: HSTS, `nosniff`, `frame-ancestors 'none'`,
  `Referrer-Policy: same-origin`, and `Cache-Control: no-store` on every authenticated response.
- **Tenancy** — the portal derives the tenant from the session principal and never from a path or query
  parameter, matching the rule CONVENTIONS sets for the API. A request whose target resource resolves to
  another tenant fails as `404`, not `403`, so the portal does not confirm the existence of another
  tenant's objects.
- **Step-up for the console** — administrative actions that create trust (issuing an enrollment token,
  approving a service enrollment, rotating a key) require a fresh authentication within the last five
  minutes, requested through `prompt=login` and `max_age=300`. 0006 already requires WebAuthn for
  platform administrators in hardened tiers, so the step-up lands on a WebAuthn prompt there.
- **No token in a URL** — the code exchange happens server-side; `state` and `code` appear only on the
  redirect, which is not logged with its query string.

### Environment awareness

Both surfaces take the standard `environment` block (CONVENTIONS) and refuse to start without `name`,
`tier`, and `id`. The tier is not decoration here: an operator with four tabs open needs to know which
environment a destructive control belongs to.

- Every authenticated page renders the environment name and tier in the masthead, using the tier ramp in
  0019, and the `<title>` carries it too so that a browser tab shows it.
- `Hardened()` tiers shorten the idle session to 30 minutes, require the step-up above, and disable any
  development affordance.
- A session whose recorded environment ID no longer matches the process's own is destroyed rather than
  migrated, which is the browser-side counterpart to the mismatch rules 0012 and 0013 apply to agents
  and plugins.

### Logging & telemetry

Through `rackmarshal-common`, per CONVENTIONS. Page handlers emit `http.route`, `http.response.status_code`,
and `rackmarshal.tenant.id`; htmx requests additionally carry `rackmarshal.web.partial` with the fragment name, so a
swap can be distinguished from a full render in a trace. Session identifiers, tokens, CSRF tokens, and
`state` values are never logged. Spans propagate to the gateway through W3C Trace Context, so a slow
table in the portal resolves to the `rackmarshal-inventory` query behind it.

### Configuration

Prefixes are `RACKMARSHAL_PORTAL` and `RACKMARSHAL_CONSOLE`, per the CONVENTIONS rule, with the shared child keys
`logging`, `telemetry`, `environment`, and `gateway`.

| YAML                       | Variable                              | Default                       |
|----------------------------|---------------------------------------|-------------------------------|
| `server.httpsPort`         | `<PREFIX>_SERVER_HTTPS_PORT`          | `8443`                        |
| `session.backend`          | `<PREFIX>_SESSION_BACKEND`            | `postgres` (`memory` dev only)|
| `session.idleTimeout`      | `<PREFIX>_SESSION_IDLE_TIMEOUT`       | `30m`                         |
| `session.absoluteTimeout`  | `<PREFIX>_SESSION_ABSOLUTE_TIMEOUT`   | `8h`                          |
| `oidc.clientId`            | `<PREFIX>_OIDC_CLIENT_ID`             | none — required               |
| `oidc.clientSecretFile`    | `<PREFIX>_OIDC_CLIENT_SECRET_FILE`    | none — required               |
| `oidc.redirectUrl`         | `<PREFIX>_OIDC_REDIRECT_URL`          | none — required               |

### Build, release & versioning

- **Generate** — `task generate` runs `templ generate` and the Tailwind v4 standalone CLI, which is a
  single binary and needs no `npm install`. Both outputs are committed; `task check:drift` regenerates
  and fails on a diff, as CONVENTIONS requires of generated code.
- **Assets** — the stylesheet and scripts are content-hashed at build time and embedded with `go:embed`,
  so the binary serves them without a filesystem dependency, matching how 0006–0009 embed their
  contracts.
- **Artifacts** — the deployment set CONVENTIONS lists: OCI image, Helm chart, deb/rpm, and an NSIS
  installer. Neither surface needs cgo, so both cross-compile normally, unlike `rackmarshal-identity`.
- **Versioning** — `v0.x` from Conventional Commits, as everywhere else.

### Testing

- **Component** — templ components render to a buffer and assert on structure; no browser needed.
- **Handler** — `httptest` covers both render paths for every handler: a full page without `HX-Request`
  and a fragment with it, which is what keeps the no-JavaScript guarantee honest.
- **Browser** — `playwright-go` in a nested module (per the CONVENTIONS rule that test tooling stays out
  of the consumer graph) covers login, the step-up, and one swap per surface.
- **Accessibility** — axe-core runs against every rendered page in CI and fails on a violation, which is
  how the WCAG 2.2 AA claim in 0007 and 0019 stays true rather than aspirational.
- **Security** — tests assert the CSP header has no `unsafe-*`, that a missing CSRF token is rejected,
  and that a cross-tenant resource returns `404`.

## Alternatives considered

- **A single-page application (React, Vue) against the gateway** — the conventional choice, and the
  reason it is rejected is concrete: the browser would need a Rackmarshal API token, which means token storage
  in the browser, CORS on the operator ingress, and a public client registration. That reverses 0008's
  posture and adds an exfiltration target, in exchange for interactions these surfaces do not need.
- **One repository for both portals, RBAC-gated** — cheaper to build and deploy, and genuinely tempting.
  Rejected because the console issues enrollment tokens and approves service enrollments; those controls
  should not share a process with the tenant-facing application.
- **Folding the portals into `rackmarshal-gateway`** — would avoid two new services, but the gateway is an
  authorization enforcement point whose value depends on being small.
- **Echo's built-in CSRF middleware** — one less dependency. `gorilla/csrf` is proposed instead for its
  explicit `__Host-` handling and per-form token rotation; this is a weak preference and either is
  defensible.
- **Go's `html/template` instead of templ** — no code generation step and nothing new to learn.
  Rejected because errors surface at render time in a handler rather than at build time, and these
  surfaces render tables of security-relevant state.
- **jQuery 4** — considered per the original request and rejected above; jQuery 4.0.0 is stable as of
  January 2026, so this is a scope decision rather than a maturity one.

## Open questions

- **Shared components** — the portal and console will duplicate a dashboard shell, a table, and a form
  set. Extract them into a `rackmarshal-web-kit` library once the duplication is real, or accept it for two
  consumers? Extraction adds a sixteenth repository.
- **OIDC relying-party library** — `coreos/go-oidc` and its `go-jose` graph, or a hand-written exchange
  over `rackmarshal-sdk`'s HTTP client with a small JWKS cache?
- **Session store ownership** — PostgreSQL reuses existing conventions, but it gives the portal and
  console a database they otherwise would not have. `rackmarshal-sso` already keeps its sessions in
  `rackmarshal-identity` and holds no database of its own (0007); the portals could do the same and stay
  storage-free. That trades a database for a dependency on identity's availability for every page
  render, which is why it is not proposed outright.
- **Console step-up scope** — which operations require re-authentication, beyond the three named above?
- **Notification surface** — do the portals need server-sent events for live drift status, or is htmx
  polling on a 30-second interval sufficient at expected scale?

## References

- [templ](https://templ.guide) — typed HTML templating for Go; v0.3.1020.
- [htmx](https://htmx.org/docs/) — 2.0.10 is the current major line.
- [Alpine.js](https://alpinejs.dev/essentials/installation) — 3.14.1; the CSP build is documented at
  [alpinejs.dev/advanced/csp](https://alpinejs.dev/advanced/csp).
- [TailAdmin community edition](https://github.com/TailAdmin/tailadmin-free-tailwind-dashboard-template)
  — MIT licensed, Tailwind CSS v4.
- [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636) — PKCE.
- [RFC 8252 §7.3](https://www.rfc-editor.org/rfc/rfc8252#section-7.3) — loopback redirection for native
  applications.
- [RFC 6265bis](https://www.rfc-editor.org/rfc/rfc6265bis#name-cookie-name-prefixes) — `__Host-` cookie
  prefix.
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/) — the AA conformance level 0007 already commits to.
- [Content Security Policy Level 3](https://www.w3.org/TR/CSP3/) — `unsafe-eval` and `unsafe-inline`.
