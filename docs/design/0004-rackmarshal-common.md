<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0004 — rackmarshal-common

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-15
- **Summary:** `rackmarshal-common` gives every Rackmarshal Go executable the same logging, environment handling, and
  telemetry. It provides a zerolog wrapper with trace correlation and service and environment fields, an
  `environment` package for the four tiers, and OpenTelemetry setup whose Rackmarshal-built OTLP/HTTP exporter
  sends traces and metrics without linking gRPC.

> An initial draft with concrete proposals, bounded by the
> [Resolved decisions](0001-project-repositories.md#resolved-decisions) in 0001. Conventions other
> repositories depend on are summarized in [CONVENTIONS.md](CONVENTIONS.md).

## Context & goals

0001 settles the stack in
[Logging and telemetry](0001-project-repositories.md#logging-and-telemetry-rackmarshal-common). The library wraps
the starters' zerolog `logging` package and correlates logs with traces through a zerolog hook. Traces and
metrics use the OpenTelemetry API and SDK, exported by a permanent Rackmarshal-built OTLP/HTTP exporter on
`go.opentelemetry.io/proto/slim/otlp`. Every log event and telemetry resource carries the environment
name ([Environment awareness](0001-project-repositories.md#environment-awareness)). During bootstrap,
every Go repository replaces its starter's logging and telemetry with `rackmarshal-common`, while config
loading and middleware stay in the starters
([Bootstrapping](0001-project-repositories.md#bootstrapping-a-repository-from-a-starter)).

The starters' logging differs by template:

- `go-library-starter` has `logging.Default`, `Initialize`, and `<PREFIX>_LOG_*`.
- `go-echo-starter` and `go-cli-starter` have a `Daemon` logger under `<PREFIX>_DAEMON_LOG_*`.
- `go-echo-starter` adds an `Access` logger under `<PREFIX>_HTTP_ACCESS_LOG_*`, with camelCase fields
  such as `remoteIp`.

**Goals**

- Replace the starters' logging with minimal call-site changes.
- Tag every log event and telemetry resource with the service and its environment.
- Export traces and metrics over OTLP/HTTP without gRPC, from a measured dependency set enforced in CI.
- Implement tier parsing, validation, hardened defaults, and last-resort gating once.

**Non-goals**

- Config file loading and web-framework middleware, which stay in the starters (0001).
- Exporting logs over OTLP; logs stay on stdout (see Open questions).
- Certificates, SPIFFE IDs, and TLS configuration — [0003](0003-rackmarshal-sdk.md).
- Collector deployment and telemetry backends — [0005](0005-rackmarshal-infrastructure.md).

## Proposal

### Responsibilities

- **`logging`** — zerolog setup, the default and access loggers, the trace hook, and service and
  environment fields.
- **`environment`** — environment config, tier rules, and the last-resort gate. It lives here because
  logs and telemetry need the environment and 0001 requires one behavior everywhere, though that goes
  beyond "logging and telemetry" (see Open questions).
- **`service`** — service name, version, and instance ID, shared by logs and telemetry.
- **`telemetry`** — provider setup, W3C propagation, HTTP wrappers, and the OTLP/HTTP exporter.

### Interfaces

#### Package layout

```
rackmarshal-common/
├── pkg/
│   ├── environment/          # Tier, Config, Validate, Hardened, AllowLastResort
│   ├── service/              # Info{Name, Version, InstanceID}, NewInstanceID
│   ├── logging/              # Config, Initialize, Default, Access, Internal, TraceHook
│   ├── logging/logfmt/       # human-readable console writer
│   ├── logging/otlpsink/     # zerolog to OpenTelemetry log bridge
│   ├── telemetry/            # Config, Setup, WrapTransport, WrapHandler
│   └── telemetry/otlphttp/   # TraceExporter, MetricExporter, LogExporter
├── internal/
│   ├── envvar/               # os.LookupEnv helpers using the starters' AddPrefix rules
│   └── transform/            # SDK data to OTLP protobuf, ported from opentelemetry-go
├── parity/                   # nested module: compares transform output with the official exporter
└── deps.allow                # module allowlist enforced in CI
```

#### Wiring in an executable

```go
// After the starter's Configure(): defaults → file → RACKMARSHAL_INVENTORY_* → flags.
if err := cfg.Environment.Validate(); err != nil { return err } // name and known tier required
svc := service.Info{Name: "rackmarshal-inventory", Version: version.Number(), InstanceID: service.NewInstanceID()}
logging.Initialize(cfg.Logging, cfg.Environment, svc)

shutdown, err := telemetry.Setup(ctx, cfg.Telemetry, cfg.Environment, svc,
    telemetry.WithClientTLS(certs.ClientTLSConfig)) // e.g. built with rackmarshal-sdk's tlsconfig
if err != nil { return err }
defer shutdown(context.Background())

logging.Default.Info().Ctx(ctx).Str("rackmarshal.tenant.id", tenantID).Msg("endpoint registered")
```

The starters build a logger from environment variables before config is loaded. `Initialize` may
therefore run twice: first without environment fields, then again once the environment validates.

#### `environment`

```go
type Tier string // "production", "staging", "test", "development"

type Config struct {
    Name      string   `yaml:"name" json:"name"`
    Tier      Tier     `yaml:"tier" json:"tier"`
    ID        string   `yaml:"id" json:"id"`
    CABundle  string   `yaml:"caBundle" json:"caBundle"`
    Overrides []string `yaml:"overrides" json:"overrides"`
}

func (c *Config) FromEnv(prefix string)  // <prefix>_ENVIRONMENT_NAME, _TIER, _ID, _CA_BUNDLE, _OVERRIDES
func (c *Config) Validate() error        // name is a DNS label; tier is one of four; ID syntax if set
func (c *Config) RequireIdentity() error // ID and CABundle present, for mutual-TLS components
func (c *Config) Hardened() bool         // production or staging
func (c *Config) AllowLastResort(feature string, log *zerolog.Logger) error
```

- **Required values** — `Validate` has no defaults: a missing name or tier, or an unknown tier, fails
  startup.
- **Trust domain** — `RequireIdentity` checks only that the values are present. Matching the ID against
  the roots' trust domain happens in `rackmarshal-sdk`'s `tlsconfig`, so SPIFFE parsing exists once.
- **Last-resort gate** — `AllowLastResort` returns an error in `production` unless `feature` is in
  `Overrides`. Every use in `production` is logged at `warn`, and at `info` in other tiers, with
  `rackmarshal.override.feature`. Feature names are kebab-case and owned by their documents, such as
  `kek-sealed-ca-store` in [0006](0006-rackmarshal-identity.md).

#### `logging`

- **Config** — keeps the starters' `LoggerConfig` (`enabled`, `level`, `includeCaller`) inside
  `Config{Default, Access, Console, OTLP}`, read from `<PREFIX>_LOG_*` and `<PREFIX>_ACCESS_LOG_*`.
  `prettyPrint` is replaced by `console.format`.
- **Two sinks, one logger.** Services keep one `logging.Default`, and zerolog fans the encoded event out
  with [`zerolog.MultiLevelWriter`](https://pkg.go.dev/github.com/rs/zerolog#MultiLevelWriter) to a
  console sink and an OTLP sink. Both are
  [`zerolog.LevelWriter`](https://pkg.go.dev/github.com/rs/zerolog#LevelWriter)s, so each drops events
  below its own level before parsing anything, and each is configured independently — a console at
  `info` for the operator tailing a unit, an OTLP sink at `debug` for the backend that can afford it.
  Neither sink can fail the other: a sink returns its error to the fan-out, which records it and
  continues.
- **Console output** — logfmt, on stdout, human first. Once logs ship over OTLP, stdout stops being the
  machine path and becomes the thing a person reads over SSH or in `journalctl`, so it is formatted for
  that: `time level message` first, then `trace_id` and `span_id`, then the remaining fields sorted by
  key so successive lines diff cleanly. Values are quoted only when they contain a space, `=`, or `"`,
  per [logfmt](https://brandur.org/logfmt). Colour is used only when stdout is a terminal *and* the tier
  is `development`; `mattn/go-isatty` and `go-colorable` are already linked for it. `console.format` may
  be set to `json` for a deployment whose collector still scrapes container stdout.
- **Timestamps** — `time` is written in RFC 3339 with nanoseconds, in UTC, using
  `func() time.Time { return time.Now().UTC() }`. All three starters set
  `zerolog.TimestampFunc = time.Now().UTC`, which is a method value: it captures a single instant, so
  every event carries the time of `Initialize`. A test run on 2026-09-15 confirmed this, and the fix
  should also go upstream to the starters.
- **Fields** — zerolog's field-name globals are pinned to `time`, `level`, `message`, and `error`. Every
  event also carries `service.name`, `service.version`, `service.instance.id`,
  `deployment.environment.name`, `rackmarshal.environment.tier`, and `rackmarshal.environment.id` when set.
- **Trace correlation** — `TraceHook` implements [`zerolog.Hook`](https://pkg.go.dev/github.com/rs/zerolog#Hook).
  For events logged with `Event.Ctx(ctx)`, it reads the span context from `Event.GetCtx()` and adds
  `trace_id`, `span_id`, and `trace_flags` in lowercase hex, following
  [trace context in non-OTLP logs](https://opentelemetry.io/docs/specs/otel/compatibility/logging_trace_context/).
  It imports only `go.opentelemetry.io/otel/trace`.
- **OTLP sink** — `logging/otlpsink` is a log appender in the sense the OpenTelemetry
  [Logs Bridge API](https://opentelemetry.io/docs/specs/otel/logs/api/) defines: zerolog stays the API
  that Rackmarshal code calls, and the bridge turns each encoded event into an
  [`otel/log.Record`](https://pkg.go.dev/go.opentelemetry.io/otel/log#Record) emitted through a
  `LoggerProvider` from `otel/sdk/log`. No Rackmarshal code calls the OpenTelemetry log API directly, so
  adopting OTLP changes no call sites.

| zerolog | `log.Record` | Note |
|---------|--------------|------|
| `message` | `SetBody` | |
| `time` | `SetTimestamp` | `SetObservedTimestamp` is the time the sink received it |
| level | `SetSeverity`, `SetSeverityText` | mapping below |
| `error` | `SetErr` | |
| `trace_id`, `span_id`, `trace_flags` | the record's trace context | not attributes |
| everything else | `AddAttributes`, typed | `json.Number` becomes int64 or float64 |

  Trace context is the place the two mechanisms have to meet, and they meet through the existing hook
  rather than beside it: `TraceHook` remains the only thing that reads a span out of a context, and the
  bridge parses the `trace_id` and `span_id` it wrote back out of the encoded event. One path in, so a
  console line and its OTLP record can never disagree about which trace they belong to.

  Severity follows
  [the OpenTelemetry severity numbers](https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber),
  verified against `otel/log` v0.22.0: `trace` to `SeverityTrace1` (1), `debug` to `SeverityDebug1` (5),
  `info` to `SeverityInfo1` (9), `warn` to `SeverityWarn1` (13), `error` to `SeverityError1` (17),
  `fatal` to `SeverityFatal1` (21), and `panic` to `SeverityFatal4` (24).

Moving from the starters, including OpenTelemetry
[HTTP attribute](https://opentelemetry.io/docs/specs/semconv/registry/attributes/http/) names for access
logs:

| Starter                                              | `rackmarshal-common`                                     |
|------------------------------------------------------|----------------------------------------------------|
| `logging.Daemon`                                     | `logging.Default`                                  |
| `<PREFIX>_DAEMON_LOG_*`, `<PREFIX>_HTTP_ACCESS_LOG_*` | `<PREFIX>_LOG_*`, `<PREFIX>_ACCESS_LOG_*`         |
| `method`, `status`                                   | `http.request.method`, `http.response.status_code` |
| `uriPath`, `routePath`, `remoteIp`                   | `url.path`, `http.route`, `client.address`         |
| Unix-second `time`                                   | RFC 3339 UTC `time`                                |

#### `telemetry`

- **`Setup`** builds a resource with the same `service.*`, `deployment.environment.name`, and
  `rackmarshal.environment.*` attributes. It then creates a `TracerProvider` with a batch span processor and
  `ParentBased(TraceIDRatioBased(ratio))` sampling, a `MeterProvider` with a periodic reader, a
  `LoggerProvider` with a batch processor feeding `logging/otlpsink`, and the global W3C
  `propagation.TraceContext` propagator. All four share one resource, so a log record, its span, and the
  metrics around it carry identical `service.*` and `rackmarshal.environment.*` attributes and join on the
  backend without a mapping rule. OpenTelemetry errors go to `logging.Default`,
  rate-limited. When disabled, `Setup` installs no-op providers but keeps the propagator.
- **Standard variables** — `OTEL_*` variables are not read; configuration has one path.
- **Wrappers** — `WrapTransport(http.RoundTripper)` injects `traceparent` and records client spans, for
  `rackmarshal-sdk`'s `WithTransportWrapper`. `WrapHandler(http.Handler, ...Option)` extracts the incoming
  context, records server spans, and records the `http.server.request.duration` histogram. Services
  adapt it to Echo in their own middleware.
- **Incoming traces** — `WithTrustIncoming(false)`, the default for public ingress, starts a new trace
  linked to the caller's span instead of adopting it. Internal mutual-TLS listeners set it to true.
- **Instrumentation** — Rackmarshal code imports only the OpenTelemetry API (`otel`, `otel/trace`,
  `otel/metric`), never the SDK or the exporters.

#### `telemetry/otlphttp`

- **Interfaces** — `TraceExporter` implements
  [`sdktrace.SpanExporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/trace#SpanExporter).
  `MetricExporter` implements
  [`sdkmetric.Exporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/metric#Exporter), with
  cumulative temporality by default. `LogExporter` implements
  [`sdklog.Exporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/log#Exporter), whose contract
  states that "all retry logic must be contained in this function" — the log SDK implements none — so it
  reuses the retry policy below rather than defining a second one.
- **Wire format** — protobuf `ExportTraceServiceRequest`, `ExportMetricsServiceRequest`, and
  `ExportLogsServiceRequest` from the slim module, POSTed as `application/x-protobuf` to
  `<endpoint>/v1/traces`, `/v1/metrics`, and `/v1/logs`, gzip-compressed by default, per the
  [OTLP specification](https://opentelemetry.io/docs/specs/otlp/). The slim module already carries
  `collector/logs/v1` at v1.11.0, so logs add no proto dependency.
- **Retries** — 429, 502, 503, and 504 are retried with exponential backoff and jitter, honoring
  `Retry-After`, within the export timeout. Other failures drop the batch and log once; partial success
  logs the rejected count at `warn`.
- **Transport** — no redirects; response bodies are read up to 64 KiB; TLS is verified against
  `tls.caBundle`, or the environment CA bundle by default. A client certificate, if any, comes from the
  `WithClientTLS` callback, so renewed service certificates apply without restarts.
- **Transform** — ported from opentelemetry-go's `exporters/otlp/otlptrace/internal/tracetransform` and
  `exporters/otlp/otlpmetric/otlpmetrichttp/internal/transform` (both present at v1.46.0), with imports
  switched from `go.opentelemetry.io/proto/otlp` to the slim module. Apache-2.0 notices are kept, and the
  port is re-synced on every OpenTelemetry upgrade.

#### Shipping to Loki

`telemetry.endpoint` normally names an OpenTelemetry Collector, and anything that speaks OTLP works
unchanged. Loki is called out because it is the expected backend and because it has one property that
will bite an operator who is not warned: Loki 3.x accepts OTLP directly at `/otlp/v1/logs`, promotes a
small set of resource attributes to **stream labels**, and puts everything else in **structured
metadata**. Labels are the index, so a label with many distinct values creates a stream per value.

The attributes this library emits therefore split as follows, and this is the default label set an
operator should configure:

| Attribute | Placement | Why |
|-----------|-----------|-----|
| `service.name`, `service.version` | label | Bounded by the number of Rackmarshal services and releases |
| `deployment.environment.name`, `rackmarshal.environment.tier` | label | One value per environment |
| `service.instance.id` | **structured metadata** | One value per replica per restart; as a label it makes a stream per pod, and 0005 sets replica count per environment |
| `rackmarshal.tenant.id`, `rackmarshal.agent.id`, `rackmarshal.request.id` | **structured metadata** | Unbounded by design — a label here is a stream per tenant, per agent, or per request |
| `trace_id`, `span_id` | **structured metadata** | Unbounded, and queried by exact match rather than scanned |

`rackmarshal.environment.id` is a label in a single-environment Loki and structured metadata in a shared
one, which is the only entry an operator has to think about.

### Dependencies

- **Rackmarshal repositories** — none. Consumed by every Rackmarshal Go executable and by `rackmarshal-sdk`'s examples.
- **Third-party modules** — re-measured on 2026-09-20 with a throwaway module adding the log signal to
  the previous set: zerolog v1.35.1, the OpenTelemetry API, SDK, and metric SDK v1.46.0, the log API and
  log SDK v0.22.0, and `proto/slim/otlp` v1.11.0, plus a protobuf marshal and a `net/http` POST. It
  links **18 modules**, two more than the 16 measured on 2026-09-15:
  - zerolog stack: `rs/zerolog`, `mattn/go-colorable`, `mattn/go-isatty`, `golang.org/x/sys`
  - OpenTelemetry: `otel`, `otel/trace`, `otel/metric`, `otel/sdk`, `otel/sdk/metric`, `auto/sdk`,
    `proto/slim/otlp`, and **new** `otel/log`, `otel/sdk/log`
  - Supporting: `google.golang.org/protobuf`, `go-logr/logr`, `go-logr/stdr`, `google/uuid`,
    `cespare/xxhash/v2`

  The log signal adds exactly those two modules: every other requirement of `otel/sdk/log` v0.22.0 was
  already linked, and the slim proto module already carried `collector/logs/v1`. `go list -m all`
  reports 34 modules and no gRPC. 0001 estimates "about 8" for the exporter on an
  unverified counting basis, so this measured list, not the estimate, seeds `deps.allow`.
- **Versions** — v1.46.0 is the latest stable OpenTelemetry Go release (v1.47.0-rc.1 exists), pinned
  exactly. The log API and SDK are v0.22.0 and **not yet 1.0**, so they carry no compatibility guarantee
  and may break on a minor bump; they are pinned exactly and upgraded deliberately. That is the real
  cost of adopting the signal now, and it is accepted because the blast radius is contained: no
  Rackmarshal code imports `otel/log`, only `logging/otlpsink` and `telemetry/otlphttp` do, so a breaking
  change is a change in two files in this repository and in none of its consumers.
- **Tests** use the standard library and `testify`, which every starter already requires. The official
  exporters appear only in the nested `parity` module.

### Data & storage

None beyond in-memory export batches. The span processor's queue is bounded and logs its drop count.

The log processor's queue is bounded the same way, and the rule it enforces is that **a log call never
blocks on a network**. On overflow the batch processor drops the oldest records and increments
`rackmarshal.logs.dropped` by reason (`queue_full`, `export_failed`); it does not apply backpressure to the
caller. A logging statement sits inside request handling, so the alternative — blocking until a
collector acknowledges — would convert a telemetry outage into a service outage. Dropped logs are
visible in the metric, and the console sink is unaffected, so nothing is lost silently.

### Security

- **No secrets in telemetry.** Resource attributes and default fields hold no credentials. Collector
  headers come from `headersFile` and are never logged. Values marked `x-rackmarshal-sensitive`
  ([0002](0002-rackmarshal-api-schema.md)) are never logged.
- **TLS for telemetry.** A plaintext `http://` endpoint is a last-resort feature (`plaintext-telemetry`):
  refused in `production` without an override, and warned in `staging`.
- **Bounded input.** Incoming `traceparent` values at public ingress start new traces, exporter
  responses are size-capped, and zerolog JSON-escapes values, so field content cannot rackmarshal log lines.

### Environment awareness

| Default              | `production`              | `staging`       | `test`          | `development`   |
|----------------------|---------------------------|-----------------|-----------------|-----------------|
| Console log format   | logfmt                    | logfmt          | logfmt          | logfmt, colour  |
| OTLP log sink        | on                        | on              | off             | off             |
| Trace sample ratio   | 0.1                       | 0.1             | 1.0             | 1.0             |
| Plaintext telemetry  | refused unless overridden | allowed, warned | allowed         | allowed         |
| Last-resort features | refused unless overridden | allowed, logged | allowed, logged | allowed, logged |

Explicit configuration overrides every default except the `production` last-resort gate, which requires
`overrides` (0001).

### Logging & telemetry

This repository is the implementation; see Interfaces. Its own diagnostics — exporter failures, dropped
batches, partial-success rejections — go to `logging.Internal`, a logger wired to the console sink alone
and rate-limited.

That separation is structural rather than a convention to remember, because with an OTLP log sink the
feedback loop is real: an export failure logged through `logging.Default` would be handed to the sink
that just failed, whose next failure would log again. A collector outage would become a log storm that
grows while the collector is least able to absorb it. `logging.Internal` cannot reach the OTLP sink, so
the loop cannot form.

### Configuration

| YAML                           | Variable                                 | Default                     |
|--------------------------------|------------------------------------------|-----------------------------|
| `logging.default.level`        | `<PREFIX>_LOG_LEVEL`                     | `info`                      |
| `logging.access.enabled`       | `<PREFIX>_ACCESS_LOG_ENABLED`            | `true`                      |
| `logging.console.enabled`      | `<PREFIX>_LOG_CONSOLE_ENABLED`           | `true`                      |
| `logging.console.format`       | `<PREFIX>_LOG_CONSOLE_FORMAT`            | `logfmt` (or `json`)        |
| `logging.console.level`        | `<PREFIX>_LOG_CONSOLE_LEVEL`             | `logging.default.level`     |
| `logging.otlp.enabled`         | `<PREFIX>_LOG_OTLP_ENABLED`              | by tier                     |
| `logging.otlp.level`           | `<PREFIX>_LOG_OTLP_LEVEL`                | `logging.default.level`     |
| `logging.otlp.accessLogs`      | `<PREFIX>_LOG_OTLP_ACCESS_LOGS`          | `true`                      |
| `logging.otlp.queueSize`       | `<PREFIX>_LOG_OTLP_QUEUE_SIZE`           | `2048`                      |
| `logging.otlp.batchTimeout`    | `<PREFIX>_LOG_OTLP_BATCH_TIMEOUT`        | `5s`                        |
| `environment.name` / `.tier`   | `<PREFIX>_ENVIRONMENT_NAME` / `_TIER`    | none — required             |
| `telemetry.enabled`            | `<PREFIX>_TELEMETRY_ENABLED`             | `true`                      |
| `telemetry.endpoint`           | `<PREFIX>_TELEMETRY_ENDPOINT`            | none — required if enabled  |
| `telemetry.timeout`            | `<PREFIX>_TELEMETRY_TIMEOUT`             | `10s`                       |
| `telemetry.headersFile`        | `<PREFIX>_TELEMETRY_HEADERS_FILE`        | empty                       |
| `telemetry.traces.sampleRatio` | `<PREFIX>_TELEMETRY_TRACES_SAMPLE_RATIO` | by tier                     |
| `telemetry.metrics.interval`   | `<PREFIX>_TELEMETRY_METRICS_INTERVAL`    | `60s`                       |
| `telemetry.tls.caBundle`       | `<PREFIX>_TELEMETRY_TLS_CA_BUNDLE`       | `environment.caBundle`      |

### Build, release & versioning

- **Bootstrap** from `go-library-starter`. Its `logging` package seeds `pkg/logging`; `greeter`, `pool`,
  `health`, `config`, and `obfusicate` are removed, and the version accessor drops `Masterminds/semver`.
- **Upgrades** — a Dependabot group moves `go.opentelemetry.io/*` together. Each upgrade re-syncs the
  transform port, passes `parity`, and ships as a minor release.
- **Versioning** — `v0.x` until accepted. Renaming or removing a log field, attribute, or config key is
  a breaking change.
- **CI** — the starters' workflows plus the `deps.allow` check from [CONVENTIONS.md](CONVENTIONS.md).

### Testing

- **`logging`** — golden JSON per tier; timestamps advance between events; trace fields appear only for
  valid spans.
- **`environment`** — tables for validation, variable hydration, and `AllowLastResort` across tiers and
  overrides.
- **Exporter** — an `httptest` collector decodes protobuf and gzip. Tests cover retry codes and
  `Retry-After` with a fake clock, partial success, the response cap, client-certificate rotation, and
  flush on shutdown.
- **Parity** — for fixed inputs, the ported transform's protobuf output equals the official exporter's,
  in the nested `parity` module.
- **Hygiene** — `-race`, allocation benchmarks on the export path, and the module allowlist.

## Alternatives considered

- **Official OTLP/HTTP exporters** — they link gRPC even over HTTP; rejected by 0001.
- **[`log/slog`](https://pkg.go.dev/log/slog) with an OpenTelemetry bridge** — standard library, but it
  replaces the starters' zerolog in every repository.
- **Leaving logs on stdout for a collector to scrape** — no new modules and no pre-1.0 dependency, but
  it puts the parsing contract in the collector's configuration instead of in this repository, loses the
  typed attributes and native trace context OTLP carries, and lets a format change here silently break a
  pipeline there.
- **A zerolog `Hook` instead of a `LevelWriter`** for the bridge — a hook sees fields before encoding and
  would avoid re-parsing JSON, but zerolog does not pass every field to a hook, so the record would be
  incomplete. Parsing the encoded event is what `ConsoleWriter` already does, and only a sink whose level
  admits the event pays for it.
- **JSON on the console alongside OTLP** — keeps existing scrapers working and remains available through
  `console.format: json`; not the default, because once OTLP carries the machine path, stdout is read by
  people.
- **Prometheus pull exporter** — adds `client_golang` and its dependencies plus a second metrics path.
- **`otelhttp` contrib instrumentation** — an extra module for what two small wrappers do.
- **Honoring standard `OTEL_*` variables** — familiar, but a second configuration path that bypasses the
  starters' config validation and dump.
- **Reverse-domain attribute prefix** (`com.servercurio.rackmarshal.*`) — what the semantic-convention
  [naming guidance](https://opentelemetry.io/docs/specs/semconv/general/naming/) recommends, but verbose.
- **`environment` in each repository or in `rackmarshal-sdk`** — duplicates tier logic, or mixes
  configuration into the security library.

## Open questions

- **Scope** — do the `environment` and `service` packages fit a library 0001 describes as logging and
  telemetry?
- **Attribute prefix** — `rackmarshal.*` or `com.servercurio.rackmarshal.*`?
- **Sampling** — are the default ratios right, and is tail sampling at the collector in scope for
  [0005](0005-rackmarshal-infrastructure.md)?
- **Collector identity** — does the in-environment collector hold a Rackmarshal certificate, and under which
  SPIFFE path, given that `/service/<repository>` names only Rackmarshal repositories?
- **Temporality** — cumulative (proposed) or delta?
- **Timestamps** — do existing log pipelines depend on the starters' Unix-second timestamps?
- **Log sampling** — access logs on a busy gateway are the highest-volume records by far.
  `logging.otlp.accessLogs` is on or off today; is a sampled middle setting needed, and should it share
  the trace sampler's decision so a sampled trace keeps its access log?
- **Pre-1.0 log SDK** — v0.22.0 carries no compatibility guarantee. Pin and upgrade deliberately, or wait
  for 1.0 and keep stdout scraping until then?

## References

- [0001 — Project Repositories](0001-project-repositories.md) — telemetry stack, environment awareness,
  bootstrap procedure.
- [0003 — rackmarshal-sdk](0003-rackmarshal-sdk.md) — TLS configuration and the transport wrapper hook.
- [CONVENTIONS.md](CONVENTIONS.md) — log fields, attribute names, environment keys.
- [zerolog](https://github.com/rs/zerolog) — [`Hook`](https://pkg.go.dev/github.com/rs/zerolog#Hook),
  `Event.Ctx`, `Event.GetCtx`.
- [OpenTelemetry Go](https://github.com/open-telemetry/opentelemetry-go) — signal status and the
  [OTLP/HTTP exporter](https://github.com/open-telemetry/opentelemetry-go/tree/main/exporters/otlp/otlptrace/otlptracehttp).
- [opentelemetry-go#2579](https://github.com/open-telemetry/opentelemetry-go/issues/2579) — the official
  OTLP/HTTP exporters depend on gRPC.
- [`go.opentelemetry.io/proto/slim/otlp`](https://github.com/open-telemetry/opentelemetry-proto-go/blob/main/slim/otlp/go.mod)
  — OTLP protobuf types without gRPC.
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/) — paths, content type, gzip, retryable
  codes, `Retry-After`.
- [Trace context in non-OTLP logs](https://opentelemetry.io/docs/specs/otel/compatibility/logging_trace_context/).
- [Deployment](https://opentelemetry.io/docs/specs/semconv/registry/attributes/deployment/),
  [service](https://opentelemetry.io/docs/specs/semconv/registry/attributes/service/), and
  [HTTP](https://opentelemetry.io/docs/specs/semconv/registry/attributes/http/) attribute registries.
- [Semantic convention naming](https://opentelemetry.io/docs/specs/semconv/general/naming/).
- [OpenTelemetry SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).
- [`sdktrace.SpanExporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/trace#SpanExporter),
  [`sdkmetric.Exporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/metric#Exporter), and
  [`sdklog.Exporter`](https://pkg.go.dev/go.opentelemetry.io/otel/sdk/log#Exporter) — the last states
  that the SDK implements no retry logic.
- [OpenTelemetry Logs Bridge API](https://opentelemetry.io/docs/specs/otel/logs/api/) and the
  [log data model](https://opentelemetry.io/docs/specs/otel/logs/data-model/) — the appender pattern and
  `SeverityNumber`; [`otel/log`](https://pkg.go.dev/go.opentelemetry.io/otel/log) v0.22.0, read for
  `Record` and the severity constants cited above.
- [Loki OTLP ingestion](https://grafana.com/docs/loki/latest/send-data/otel/) — `/otlp/v1/logs`, and
  which resource attributes become stream labels rather than structured metadata.
- [logfmt](https://brandur.org/logfmt) — the console format and its quoting rules.
- [W3C Trace Context](https://www.w3.org/TR/trace-context/).
- [Go method values](https://go.dev/ref/spec#Method_values) — why `time.Now().UTC` captures one instant.
- [go-library-starter](https://github.com/servercurio/go-library-starter),
  [go-echo-starter](https://github.com/servercurio/go-echo-starter), and
  [go-cli-starter](https://github.com/servercurio/go-cli-starter) — the `logging` packages being replaced.
