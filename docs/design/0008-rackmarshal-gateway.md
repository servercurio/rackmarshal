<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0008 — rackmarshal-gateway

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `rackmarshal-gateway` is Rackmarshal's only edge. An operator ingress accepts bearer tokens over the
  starter's TLS 1.2+ configuration, and a separate agent ingress requires mutual TLS 1.3 with per-agent
  certificates. It routes only operations the contract exposes to that ingress, verifies tokens and
  revocation and fails closed, and forwards requests to services over mutual TLS. It is built on Echo,
  and forwards through a hardened `Rewrite`-based proxy middleware contributed back to `go-echo-starter`.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 routes all `rackmarshal-sdk` traffic through `rackmarshal-gateway`, which "enforces authentication and
authorization before routing"
([Architecture at a glance](0001-project-repositories.md#architecture-at-a-glance)).
Agents use a dedicated mutual-TLS ingress, separate from the operator and third-party entry point, and the
enrollment route is the only one there that accepts a connection without a client certificate
([Agent enrollment](0001-project-repositories.md#agent-enrollment)). The gateway checks agent
certificates with OCSP, falls back to the CRL, caches both until `nextUpdate` (1 hour and 24 hours), and
fails closed. Tokens carry the environment ID, and every Rackmarshal certificate carries a SPIFFE ID
([Environment identity](0001-project-repositories.md#environment-identity)). 0002 leaves routing, rate
limits, and principal propagation to this document ([0002](0002-rackmarshal-api-schema.md)).

**Goals**

- Two isolated ingresses, with exposure decided by each operation's `x-rackmarshal-audience`, never by guesswork.
- Enforce authentication, environment binding, and revocation at the edge, failing closed.
- Hand services a verified principal over mutual TLS so they never parse credentials themselves.
- Rate-limit, correlate, and trace every request with the fewest possible added dependencies.

**Non-goals**

- Token formats, signing keys, RBAC model, and CA operation — [0006](0006-rackmarshal-identity.md).
- Login flows and the SSO site — [0007](0007-rackmarshal-sso.md).
- Fine-grained, resource-level authorization — each service (e.g. [0009](0009-rackmarshal-inventory.md)).
- Load balancers, DNS, and deployment topology — [0005](0005-rackmarshal-infrastructure.md).

## Proposal

### Responsibilities

- **Operator ingress** — TLS 1.2+, bearer tokens, `operator`-audience operations and the `/sso/` token
  endpoints.
- **Agent ingress** — TLS 1.3 with client certificates, `agent`-audience operations, one enrollment route.
- **Routing** — exact operation matching built from `rackmarshal-api-schema`; the first path segment selects
  the upstream service.
- **Edge security** — token verification, certificate revocation, rate limits, header hygiene.
- **Principal propagation** — `X-Rackmarshal-Principal` to services over mutual TLS.
- **Correlation** — `X-Request-Id`, W3C Trace Context, access logs, and metrics through `rackmarshal-common`.

### Interfaces

#### Listeners

| Listener   | Default port | TLS                        | Client authentication                          |
|------------|--------------|----------------------------|------------------------------------------------|
| `operator` | 8443         | 1.2+, starter cipher suites | `Authorization: Bearer`                       |
| `agent`    | 9443         | 1.3 only                   | X.509-SVID `spiffe://<env-id>/agent/<id>`      |
| `health`   | 8080         | none, private address only | none; `/livez`, `/readyz`, `/healthz` only    |

Both TLS listeners serve the gateway's service certificate,
`spiffe://<environment-id>/service/rackmarshal-gateway`, issued by `rackmarshal-identity` and renewed by
`rackmarshal-sdk`'s `enroll.Renewer`. `rackmarshal-sdk` clients refuse a gateway without that ID
([0003](0003-rackmarshal-sdk.md)). The operator certificate also needs the public DNS
names as SANs (see Open questions). The starter's hardened TLS 1.2 configuration
(`hardenedTLSConfig` in `go-echo-starter`) is kept for the operator listener. The starter's plain-HTTP
redirect and ACME `autocert` paths are removed. Both TLS listeners must sit behind TCP pass-through load
balancing, because TLS terminates at the gateway.

#### Routing and audience enforcement

Proposed: **deny by default, with exact operation matching.** At startup the gateway reads every
document from `rackmarshal-api-schema`'s `pkg/openapi` and builds two Echo routers:

1. For each operation, the method and path template (`{endpointId}` becomes `:endpointId`) go into the
   `operator` router if `x-rackmarshal-audience` contains `operator`, and into the `agent` router if it
   contains `agent`. Operations whose only audience is `internal` go into neither.
2. The first path segment selects the upstream: `inventory` → `rackmarshal-inventory`, `identity` →
   `rackmarshal-identity`, `provisioner` → `rackmarshal-provisioner`. An operation whose segment has no configured
   upstream fails startup.
3. Anything unmatched returns `404` with the problem code `route_not_found`, so an `internal` operation
   and a nonexistent one look the same from outside.

Before matching, the gateway rejects with `400` any path that contains `..` segments, `//`, percent-encoded
`/` or `\`, or invalid UTF-8, and any query string that `url.ParseQuery` rejects. That way the gateway
and the upstream service never interpret a request differently, a risk the `ReverseProxy.Rewrite`
documentation warns about.

Two non-contract route families exist. `GET /gateway/v1alpha1/environment` returns
`{ "id", "name", "tier" }` without authentication, so `rackmarshal-cli` can record a profile's name and tier
after pinning the certificate ([0010](0010-rackmarshal-cli.md)). The second is the OIDC, SAML, and PKI family
under `/identity/`, which `rackmarshal-identity` owns and serves (0006): the issuer's `/authorize`, `/token`,
`/device-authorization`, `/revoke`, `/.well-known/openid-configuration`, and `/jwks.json`, the SAML
bindings, and `/identity/pki/<environment-id>/{ca.pem,crl.der,ocsp}`. The gateway proxies them by path
prefix rather than from the contract, because they are standards-defined and deliberately outside it
(0002). `rackmarshal-sso` serves only browser routes and holds no token-signing keys (0007), so no token
endpoint is routed to it. This keeps every credential exchange on the environment-pinned host.

#### Reverse proxy

Proposed: **a hardened, `Rewrite`-only proxy middleware for Echo v5**, contributed to `go-echo-starter`
as `internal/middleware/proxy`, with one instance bound per upstream. Echo keeps listeners, middleware,
and routing; only the forwarding step is replaced.

Echo's own `middleware.Proxy` is not reused as-is. It builds on `httputil.NewSingleHostReverseProxy`
(`middleware/proxy.go` line 423 in v5.3.1), and that constructor returns a proxy driven by the deprecated
`Director` hook. This is not a defect in Echo — it is a standard-library API that Go itself deprecated and
labels insecure, and Echo flags the consequence in its own comment at `middleware/proxy.go` lines 349-351.
But `Director` carries two properties a gateway that adds trusted headers cannot accept:

- **Ordering.** `Director` runs at `reverseproxy.go:457` and `removeHopByHopHeaders` at `:469` — *after*
  it. A client sending `Connection: X-Rackmarshal-Principal` therefore strips a header the director added.
  `Rewrite` runs at `:503`, after the same stripping, so headers it sets survive.
- **Forwarding headers.** Inbound `Forwarded` and `X-Forwarded-*` are deleted only on the `Rewrite` path
  (`:486-493`); the `Director` path appends to whatever the client sent. Echo's middleware does not
  compensate — it keeps an inbound `X-Real-IP` unless an `IPExtractor` is set, and only appends to
  `X-Forwarded-For` (`middleware/proxy.go:352-364`).

The starter middleware exposes no `Director` field, so the unsafe path is unreachable by configuration. It
always builds `httputil.ReverseProxy` with `Rewrite`, strips inbound forwarding headers, and re-derives the
client address from Echo's configured `IPExtractor`:

```go
// internal/middleware/proxy -- go-echo-starter
type Config struct {
    Skipper        middleware.Skipper
    Target         *url.URL                        // upstream origin; required
    Transport      http.RoundTripper               // required; no implicit default pool
    StripRequest   []string                        // inbound headers dropped before Rewrite
    StripPrefixes  []string                        // e.g. "X-Rackmarshal-"
    SetHeaders     func(*echo.Context) http.Header // applied inside Rewrite, so hop-by-hop safe
    ModifyResponse func(*http.Response) error
    ErrorHandler   func(*echo.Context, error) error
}

func With(cfg Config) echo.MiddlewareFunc
```

Inside `Rewrite` it calls `r.SetURL(cfg.Target)`, sets `r.Out.Host`, applies `StripRequest` and
`StripPrefixes`, calls `r.SetXForwarded()` so the client address comes from the gateway's extractor rather
than the inbound header, and only then applies `SetHeaders`. The gateway binds one per upstream:

```go
proxy.With(proxy.Config{
    Target:        inventoryURL,                    // https://rackmarshal-inventory.<internal>:8443
    Transport:     telemetry.WrapTransport(upstreamTransport), // sdk tlsconfig + common spans
    StripRequest:  []string{"Authorization", "Cookie"},
    StripPrefixes: []string{"X-Rackmarshal-"},
    SetHeaders: func(c *echo.Context) http.Header {
        return http.Header{
            "X-Rackmarshal-Principal": {principal.Encode(c.Request().Context())},
            "X-Request-Id":            {requestID(c.Request().Context())},
        }
    },
    ModifyResponse: scrubResponseHeaders,           // drop Server; enforce Cache-Control: no-store
    ErrorHandler:   problemUpstreamError,           // 502 upstream_unavailable, 504 upstream_timeout
})
```

`upstreamTransport` uses `tlsconfig.Client` from `rackmarshal-sdk` with TLS 1.3, the environment roots, and
`spiffe.Service("rackmarshal-inventory")` as the matcher. The gateway therefore verifies the upstream's trust
domain and its exact service path, so a compromised `rackmarshal-provisioner` cannot answer for
`rackmarshal-inventory`.

#### Principal propagation

The gateway removes the inbound `Authorization` header and sends `X-Rackmarshal-Principal`: unpadded
base64url JSON of the verified identity.

```json
{ "type": "user", "id": "<subject>", "tenantId": "<tenant>", "roles": ["inventory.viewer"],
  "tokenId": "<jti>", "expiresAt": "2026-09-15T12:15:00Z" }
```

For agents, `type` is `agent`, `id` is the agent ID from the certificate, and `tenantId` comes from a
cached lookup of the agent in `rackmarshal-identity` (an `internal` operation that 0006 defines). Services
accept the header only when their mutual-TLS peer is `spiffe://<environment-id>/service/rackmarshal-gateway`,
and reject it from any other peer. Mutual TLS protects the header's integrity, and the bearer token never
travels past the edge. A stdlib-only parser, proposed as `rackmarshal-sdk` `pkg/principal`, keeps every service
consistent (see Open questions).

#### Errors and headers

All gateway-generated errors use `application/problem+json` with the codes `route_not_found`,
`unauthenticated` (401, with `WWW-Authenticate: Bearer`), `forbidden`, `rate_limited` (429, with
`Retry-After`), `certificate_revoked`, `revocation_unavailable`, `upstream_unavailable`, and
`upstream_timeout`. Problem bodies never say why a token failed beyond `unauthenticated`. The reason goes
only to logs.

### Dependencies

- **Rackmarshal** — `rackmarshal-api-schema` (embedded documents), `rackmarshal-sdk` (`spiffe`, `tlsconfig`, `revocation`,
  `enroll`, `principal`), `rackmarshal-common` (`logging`, `environment`, `telemetry`).
- **New third-party module** — [`github.com/go-jose/go-jose/v4`](https://github.com/go-jose/go-jose)
  v4.1.5, for JWKS parsing and JWS verification. Its `go.mod` has no requirements, measured on 2026-09-15.
- **Kept from the starter** — Echo v5.3.1, which links only `golang.org/x/time` (rate limiter),
  `golang.org/x/net` (`netutil.LimitListener`), zerolog, `errorx`, and `yaml.v3`.
- **New starter package** — `internal/middleware/proxy` in `go-echo-starter`, arriving here by seeding
  like the rest of the starter. It adds no module: it needs only Echo and the standard library, both
  already linked. The starter stays a template with nothing exported, rather than becoming an importable
  module with the compatibility obligation that implies.
- **Removed from the starter** — `internal/database` (pgx, bun, goose), swaggo and `cmd/openapi-gen`
  (replaced by embedded contracts, per 0002), ACME `autocert`, and `Masterminds/semver`.
- **Measured footprint** — the starter's `cmd/daemon` links 49 third-party modules (151 in
  `go list -m all`). A throwaway module with the proposed set, plus `rackmarshal-common`'s measured OpenTelemetry
  stack, links **23** (44 in `go list -m all`). Rackmarshal modules themselves are not yet published and are
  not counted.

### Data & storage

No persistent state. In memory: the JWKS (refreshed every 5 minutes, or on an unknown `kid` at most once
every 30 seconds), revocation answers inside `revocation.Checker`, agent-to-tenant lookups (5 minutes), and
rate-limit buckets.

### Security

#### Token verification (operator ingress)

Token formats belong to [0006](0006-rackmarshal-identity.md). For JWT access tokens
([RFC 9068](https://www.rfc-editor.org/rfc/rfc9068)), the gateway enforces:

- **Algorithm allowlist** — `ES256` only, and `typ` must be `at+jwt`, following
  [RFC 8725](https://www.rfc-editor.org/rfc/rfc8725). `none`, HMAC, and embedded `jwk` or `x5u` headers
  are rejected.
- **Keys** — the environment's JWKS, fetched from `rackmarshal-identity` over mutual TLS only.
- **Environment binding** — `iss` must equal `auth.issuer`, which must contain `environment.id` (checked at
  startup). `aud` must contain `spiffe://<environment-id>/service/rackmarshal-gateway`. A token from another
  environment therefore fails on both issuer and audience.
- **Time** — `exp` is required, `nbf` and `iat` are honored, and clock skew is at most 60 seconds.
- **Coarse authorization** — a `bearerAuth` security requirement lists the role names the operation
  needs, which OpenAPI 3.1 permits for non-OAuth schemes. The gateway requires at least one of them in
  `roles`. Tenant- and resource-level checks stay in services.
- **Opaque API tokens**, if 0006 chooses them, go to `rackmarshal-identity` introspection
  ([RFC 7662](https://www.rfc-editor.org/rfc/rfc7662)) over mutual TLS, with results cached for at most
  30 seconds.

#### Agent ingress and revocation

- **TLS configuration** — `tlsconfig.Server` with TLS 1.3, `ClientAuth: VerifyClientCertIfGiven`, the
  environment roots as `ClientCAs`, and `spiffe.Agent()` as the matcher. Revocation is checked in
  `VerifyConnection`, which Go runs "for all connections, including resumptions". `VerifyPeerCertificate`
  is not used, because it is skipped on resumed sessions.
- **Enrollment route** — middleware rejects any request without a verified agent certificate, unless the
  matched operation is the agent enrollment operation that 0002 marks `security: []`. The allowlist holds
  one operation ID, tested from the contract. The enrollment route's body limit is 16 KiB, and its rate
  limit is the strictest.
- **Revocation** — `revocation.Checker` from `rackmarshal-sdk` implements 0001 exactly: OCSP first, then the
  CRL, each cached until `nextUpdate`, rejecting when neither is available within the window. The gateway
  re-checks the cached status on every request, not only at handshake, so a long-lived HTTP/2 connection
  is cut off once its certificate is revoked.
- **Responder addresses** — OCSP and CRL URLs come from gateway configuration (the internal
  `rackmarshal-identity` endpoints), not from certificate AIA or CDP extensions, so agent-supplied certificates
  cannot steer the gateway's outbound requests. This needs a `revocation` option in `rackmarshal-sdk`.

#### Rate limiting

Echo's `RateLimiter` middleware with its memory store (`golang.org/x/time/rate`), keyed per ingress:

| Bucket                       | Key                   | Proposed default          |
|------------------------------|-----------------------|---------------------------|
| Operator, before auth        | client IP             | 20 req/s, burst 40        |
| Operator, after auth         | principal `id`        | 10 req/s, burst 20        |
| `/sso/` token endpoints      | client IP             | 1 req/s, burst 5          |
| Agent                        | agent ID              | 1 req/s, burst 10         |
| Agent enrollment             | client IP             | 10 per minute, burst 5    |

The starter's `netutil.LimitListener` caps connections per listener before the TLS handshake. Client IPs
come from the starter's proxy extractor with `useDirectIP` by default. The starter's `X-Forwarded-For`
extractor always trusts private, loopback, and link-local ranges (`application_proxy.go`). The gateway
removes that implicit trust and honors only explicitly configured ranges, because its callers can come
from private networks.

#### Header and response hygiene

- **Inbound** — `X-Rackmarshal-*`, `Forwarded`, and `X-Forwarded-*` headers from clients are removed, and
  `Cookie` is dropped because Rackmarshal APIs do not use cookies. CSRF and CORS middleware are off because no
  browser origin calls the gateway. [0016](0016-web-ui-architecture.md) settles this: the web surfaces
  are server-rendered relying parties that keep tokens server-side and call the gateway themselves, so a
  browser never originates a cross-origin request to it and no token is ever exposed to one.
- **Responses** — the starter's `Secure` middleware (HSTS, `nosniff`, frame denial) plus
  `Cache-Control: no-store`.
- **Body limits** — 1 MiB on the operator ingress and 8 MiB on the agent ingress (inventory reports). Both
  are enforced on the bytes received; decompression limits belong to the service that decodes the body.

### Environment awareness

- **Startup** — `environment.name`, `tier`, `id`, and `caBundle` are all required, and `id` must match the
  bundle's trust domain, the issuer, and the gateway's own certificate. A mismatch refuses startup.
- **Tiers** — all tiers enforce mutual TLS, token verification, and fail-closed revocation, because there
  is no insecure mode to leak into `production`. `Hardened()` turns off the OpenAPI UI and raises the log
  level floor to `info`. `development` may serve a filtered operator contract at `/openapi.yaml`.
- **Last-resort features** — none defined.

### Logging & telemetry

- **Access logs** — through `rackmarshal-common`, with `http.request.method`, `http.route` (the contract
  template, never the raw path), `http.response.status_code`, and `client.address`, plus `rackmarshal.ingress`,
  `rackmarshal.request.id`, `rackmarshal.upstream.service`, `rackmarshal.principal.type`, `rackmarshal.tenant.id`,
  `rackmarshal.agent.id`, and `rackmarshal.auth.failure_reason`. Tokens, the principal header, and query strings are
  never logged.
- **Request IDs** — an inbound `X-Request-Id` is kept only if it matches `^[A-Za-z0-9._-]{1,64}$`.
  Otherwise the gateway generates a 26-character random base32 ID. The ID is forwarded upstream and echoed
  on every response.
- **Tracing** — `WrapHandler` runs with `WithTrustIncoming(false)` on both external ingresses, starting a
  new trace linked to the caller's span ([0004](0004-rackmarshal-common.md)). `WrapTransport` injects
  `traceparent` upstream, and inbound `tracestate` is not forwarded.
- **Metrics** — `http.server.request.duration` plus `rackmarshal.gateway.auth.failures` (by reason),
  `rackmarshal.gateway.revocation.checks` (by source `ocsp`, `crl`, or `cache`, and by result),
  `rackmarshal.gateway.rate_limited` (by bucket), and `rackmarshal.gateway.upstream.errors` (by service).

### Configuration

Prefix `RACKMARSHAL_GATEWAY_`. Starter keys (`LOG_*`, timeouts) and the `environment` and `telemetry` blocks are
omitted here.

| YAML                                   | Variable                                          | Default            |
|----------------------------------------|---------------------------------------------------|--------------------|
| `server.operator.port`                 | `RACKMARSHAL_GATEWAY_SERVER_OPERATOR_PORT`              | `8443`             |
| `server.operator.maxBodySize`          | `RACKMARSHAL_GATEWAY_SERVER_OPERATOR_MAX_BODY_SIZE`     | `1MiB`             |
| `server.agent.enabled` / `.port`       | `RACKMARSHAL_GATEWAY_SERVER_AGENT_ENABLED` / `_PORT`    | `true` / `9443`    |
| `server.agent.maxBodySize`             | `RACKMARSHAL_GATEWAY_SERVER_AGENT_MAX_BODY_SIZE`        | `8MiB`             |
| `server.health.port`                   | `RACKMARSHAL_GATEWAY_SERVER_HEALTH_PORT`                | `8080`             |
| `certificate.dir`                      | `RACKMARSHAL_GATEWAY_CERTIFICATE_DIR`                   | required           |
| `certificate.enrollmentTokenFile`      | `RACKMARSHAL_GATEWAY_CERTIFICATE_ENROLLMENT_TOKEN_FILE` | first start only   |
| `certificate.serviceAccountTokenFile`  | `RACKMARSHAL_GATEWAY_CERTIFICATE_SERVICE_ACCOUNT_TOKEN_FILE` | first start on Kubernetes |
| `upstreams.<segment>.url`              | `RACKMARSHAL_GATEWAY_UPSTREAMS_INVENTORY_URL`, …        | required per route |
| `upstreams.<segment>.timeout`          | `RACKMARSHAL_GATEWAY_UPSTREAMS_INVENTORY_TIMEOUT`, …    | `30s`              |
| `auth.issuer`                          | `RACKMARSHAL_GATEWAY_AUTH_ISSUER`                       | required           |
| `auth.jwksUrl`                         | `RACKMARSHAL_GATEWAY_AUTH_JWKS_URL`                     | required           |
| `auth.clockSkew`                       | `RACKMARSHAL_GATEWAY_AUTH_CLOCK_SKEW`                   | `60s` (max `60s`)  |
| `revocation.ocspUrl` / `.crlUrl`       | `RACKMARSHAL_GATEWAY_REVOCATION_OCSP_URL` / `_CRL_URL`  | required           |
| `rateLimit.<bucket>.rate` / `.burst`   | `RACKMARSHAL_GATEWAY_RATE_LIMIT_AGENT_RATE`, …          | table above        |
| `proxy.trustedIPRanges`                | `RACKMARSHAL_GATEWAY_PROXY_TRUSTED_IP_RANGES`           | empty              |

### Build, release & versioning

- **Bootstrap** from `go-echo-starter`, removing the database, swaggo, ACME, and HTTP-redirect code. The
  binary is `cmd/rackmarshal-gateway`, and `internal/middleware/proxy` is copied forward with everything
  else. Seeding does not propagate later fixes, so a hardening change to the starter's middleware has to be
  ported deliberately; the gateway's own smuggling tests (below) are what catch a stale copy.
- **Contract coupling** — a new `operator` or `agent` operation is reachable only after the gateway
  upgrades `rackmarshal-api-schema`. A 100-series workflow opens that pull request on each schema release, like
  `rackmarshal-sdk`'s regeneration workflow.
- **Deployment** — the gateway ships every artifact in
  [CONVENTIONS — Deployment artifacts](CONVENTIONS.md#deployment-artifacts): the signed multi-arch image,
  the starter's Helm chart in `charts/rackmarshal-gateway/` with the enrollment init container, signed deb and
  rpm packages with a hardened systemd unit, and a signed NSIS installer. [0005](0005-rackmarshal-infrastructure.md)
  deploys them to Kubernetes, container, and OS targets with Ansible.
- **Versioning** — `v0.x`, per [CONVENTIONS.md](CONVENTIONS.md).

### Testing

- **Audience matrix** — generated from the contract. Every `internal`-only operation returns `404` on both
  ingresses, every `operator` operation returns `404` on the agent ingress, and the reverse.
- **TLS** — with `rackmarshal-sdk` `sdktest`: TLS 1.2 rejected on the agent ingress; missing, expired,
  wrong-trust-domain, and non-agent certificates rejected on every route except enrollment; revoked
  certificates rejected at handshake, on resumption, and mid-connection; OCSP down falls back to the CRL,
  and both down beyond `nextUpdate` rejects.
- **Tokens** — tables of wrong `alg`, `typ`, `iss`, and `aud`, other-environment keys, expired tokens, and
  unknown `kid` refresh throttling.
- **Smuggling and hygiene** — `Connection: X-Rackmarshal-Principal`, spoofed `X-Forwarded-For`, encoded
  slashes, and duplicate `Authorization` headers. The first two are also table tests in the starter's
  `internal/middleware/proxy`, asserting the added header survives the `Connection` list and that the
  client's forwarding values are discarded rather than appended. Both suites are kept, because the seeded
  copy is what actually runs here.
- **Fuzzing** of the path normalizer and principal encoder; `-race`; benchmarks of the per-request
  revocation re-check.

## Alternatives considered

- **Echo `middleware.Proxy` as-is** — not a defect in Echo, but it builds on `NewSingleHostReverseProxy`,
  whose `Director` hook Go itself deprecates and documents as insecure, and it offers no way to substitute
  `Rewrite`. It also adds balancer and retry features the gateway does not need. Hence the starter package
  above rather than a fork of the middleware.
- **A gateway-local `httputil.ReverseProxy` per upstream** — the same hardening with no starter change,
  but it leaves every other seeded service on the unsafe default and gives the fix nowhere to live.
- **Publishing the middleware as `pkg/middleware/proxy`** — the starter exports nothing today, so this
  would make it an importable module for the first time and let a hardening fix reach services through a
  version bump. Rejected for now: it takes on a compatibility obligation for the one package, and the
  starter is a template that services are seeded from, not a dependency they track.
- **Plain `net/http` without Echo** — removes one module, but gives up the starter's middleware, config,
  and rate limiter, and diverges from every other service.
- **Envoy or another off-the-shelf proxy** — mature, but not Go, and it cannot build route tables from
  `x-rackmarshal-audience` or use `rackmarshal-sdk`'s SPIFFE and revocation code without a control plane.
- **Prefix routing on the first segment only**, leaving audience checks to services — simpler and needs no
  contract coupling, but one missed check in a service would expose `internal` operations.
- **Forwarding the bearer token** so services re-verify it — defense in depth, but it spreads tokens and a
  JWT library to every service. It remains an option if 0006 prefers it.
- **[`golang-jwt/jwt/v5`](https://github.com/golang-jwt/jwt)** v5.3.1 — also has no requirements (measured),
  but it has no JWKS support, so key parsing would be hand-written.
- **A separate port for enrollment** with `RequireAndVerifyClientCert` on the main agent port — stronger
  TLS-layer enforcement, but 0001 describes enrollment as a route on the agent ingress. Worth
  reconsidering if the single-operation allowlist proves fragile.
- **A shared rate-limit store** (e.g. Redis) — exact global limits, but adds a client module and a stateful
  dependency. Per-replica limits are proposed first.
- **Advertising limits with `RateLimit` headers** — still an Internet-Draft
  ([draft-ietf-httpapi-ratelimit-headers-11](https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/));
  `Retry-After` alone is used for now.

## Open questions

- **Operator certificate** — may `rackmarshal-identity` add public DNS SANs to the gateway's service certificate,
  or does the operator ingress use a second environment-CA certificate? A WebPKI-terminating load balancer
  would break client pinning (the same question is open in 0003).
- **Principal header** — accept `X-Rackmarshal-Principal` over mutual TLS, or forward tokens? Does
  `pkg/principal` belong in `rackmarshal-sdk`?
- **Unauthenticated operations** — 0002's lint allowlist names only enrollment and health. Add
  `GET /gateway/v1alpha1/environment`?
- **Agent tenant lookup** — cache TTL, and whether disabling an agent in `rackmarshal-identity` should also
  revoke its certificate.
- **Role names** in security requirements, or a dedicated `x-rackmarshal-permission` extension?
- **Rate limits** across replicas — are per-replica limits acceptable at expected scale?

## References

- [0001 — Project Repositories](0001-project-repositories.md) — architecture, agent enrollment,
  environment identity, resolved decisions.
- [0002 — rackmarshal-api-schema](0002-rackmarshal-api-schema.md), [0003 — rackmarshal-sdk](0003-rackmarshal-sdk.md),
  [0004 — rackmarshal-common](0004-rackmarshal-common.md), [CONVENTIONS.md](CONVENTIONS.md).
- [go-echo-starter](https://github.com/servercurio/go-echo-starter) — `internal/application/application_tls.go`
  (`hardenedTLSConfig`, `LimitListener`), `application_proxy.go` (implicit private-range trust),
  `config_ratelimit.go`, `config_security.go`.
- [Echo v5 middleware](https://github.com/labstack/echo/tree/v5.3.1/middleware) — `proxy.go`
  (`NewSingleHostReverseProxy` at line 423; the `X-Real-IP` / `X-Forwarded-For` note at lines 349-364),
  `rate_limiter.go`, `request_id.go` (inspected at v5.3.1).
- [`httputil.ReverseProxy`](https://pkg.go.dev/net/http/httputil#ReverseProxy) — the `Director` field's
  "This function is insecure" note, and the call ordering that motivates `Rewrite`: `Director` at
  `reverseproxy.go:457`, `removeHopByHopHeaders` at `:469`, forwarding-header deletion at `:486-493`, and
  `Rewrite` at `:503` (read at Go 1.27.1);
  [`ProxyRequest.SetXForwarded`](https://pkg.go.dev/net/http/httputil#ProxyRequest.SetXForwarded).
- [`tls.Config`](https://pkg.go.dev/crypto/tls#Config) — `VerifyConnection` runs on resumptions;
  `VerifyPeerCertificate` does not.
- [go-jose v4](https://github.com/go-jose/go-jose) and [golang-jwt v5](https://github.com/golang-jwt/jwt).
- [OpenAPI 3.1.1 Security Requirement Object](https://spec.openapis.org/oas/v3.1.1.html#security-requirement-object)
  — role names for non-OAuth schemes.
- [RFC 9068](https://www.rfc-editor.org/rfc/rfc9068) (JWT access tokens),
  [RFC 8725](https://www.rfc-editor.org/rfc/rfc8725) (JWT best practices),
  [RFC 7662](https://www.rfc-editor.org/rfc/rfc7662) (token introspection),
  [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750) (bearer tokens, `WWW-Authenticate`).
- [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280) and [RFC 6960](https://www.rfc-editor.org/rfc/rfc6960)
  — CRLs and OCSP.
- [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) — problem details;
  [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110#name-retry-after) — `Retry-After`.
- [SPIFFE ID](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md) and
  [X.509-SVID](https://github.com/spiffe/spiffe/blob/main/standards/X509-SVID.md).
- [W3C Trace Context](https://www.w3.org/TR/trace-context/).
- [draft-ietf-httpapi-ratelimit-headers](https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/).
