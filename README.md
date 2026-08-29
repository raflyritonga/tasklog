# Tasklog

A small task CRUD app (Nuxt 3 + Go + Postgres + Redis) built to demonstrate one telemetry pipeline delivering to four observability platforms simultaneously: a self-hosted Grafana stack (Prometheus, Loki, Tempo), Datadog, Dynatrace, and Elastic Cloud.

The app is deliberately simple — the observability wiring is the product.

## How it works

- **Instrument once.** The API uses the OpenTelemetry SDK for traces and metrics (OTLP) and writes structured JSON logs to stdout with a `trace_id` on every line.
- **OTel Collector** fans traces and metrics out to Tempo, Prometheus, Datadog, Dynatrace, and Elastic.
- **Vector** fans logs out to Loki, Datadog Logs, and Elasticsearch.
- **Split by design:** Vector = logs, Collector = traces + metrics.
- **RUM** beacons go from the browser directly to the vendor SaaS.
- The whole pipeline is validated on Docker Compose first, then lifted unchanged onto a 2-node kind cluster — only the log source changes (`docker_logs` → `kubernetes_logs`).

## Architecture

```
browser ──► ingress ──► web (Nuxt SSR) ──► api (Go + Echo) ──► Postgres / Redis
                                              │
                    OTel SDK (traces+metrics) │ JSON logs (stdout, trace_id)
                                              ▼
                 OTel Collector ────────► Tempo · Prometheus · Datadog · Dynatrace · Elastic
                 Vector ────────────────► Loki · Datadog Logs · Elasticsearch
                 browser RUM ───────────► vendor SaaS (direct)
```

Stage A runs the app on Docker Compose. Stage B adds the telemetry pipeline on Compose. Stage C lifts everything onto a kind cluster (1 control-plane + 1 worker) in an OrbStack Ubuntu VM.

## Stack

Nuxt 3 · Go (Echo) · PostgreSQL 16 · Redis · OpenTelemetry · Vector · Prometheus · Loki · Tempo · Grafana · k6 · kind · Ansible · GitHub Actions → GHCR

## Setup checklist (manual, one-time)

1. **GitHub / GHCR** — public repo with Actions enabled. After the first CI run, set both GHCR packages (`tasklog-api`, `tasklog-web`) to **Public**, otherwise `docker pull` and the cluster will fail.
2. **Datadog trial** — note your site (e.g. `us5`) → `DD_SITE`, create `DD_API_KEY`, create a RUM browser application → `DD_RUM_APP_ID`, `DD_RUM_CLIENT_TOKEN`.
3. **Dynatrace trial** — tenant URL → `DT_TENANT_URL`; access token with scopes `metrics.ingest, logs.ingest, openTelemetryTrace.ingest, events.ingest` → `DT_API_TOKEN`; operator flow tokens → `DT_OPERATOR_TOKEN`, `DT_DATA_INGEST_TOKEN`; agentless RUM application → `DT_RUM_SCRIPT_URL`.
4. **Elastic Cloud trial** — smallest deployment, nearest region → `ELASTIC_ES_ENDPOINT`, `ELASTIC_APM_ENDPOINT`, `ELASTIC_APM_SECRET_TOKEN`, `ELASTIC_API_KEY`, `KIBANA_URL`; enable RUM in Kibana APM settings.
5. `cp .env.example .env` and fill in the values, including `GHCR_OWNER`.
6. **OrbStack VM** (Stage C only) — machine named `tasklog-demo` (~6 CPU / 12 GB); the name is the domain (`tasklog-demo.orb.local`). Verify `ssh tasklog-demo@orb` and `ping tasklog-demo.orb.local`.

Missing SaaS variables are fine: any exporter or sink without credentials is simply not rendered, and the Grafana-only path works with an empty `.env`.

## Quickstart

### Stage A — app on Docker Compose

```bash
docker compose up -d --build --wait
```

Builds and starts postgres, redis, api, and web. App at `http://localhost:3000` — the database is seeded with 50 tasks on first boot.

### Stage A — run from public GHCR images

```bash
docker compose -f compose.yaml -f compose.ghcr.yaml pull
docker compose -f compose.yaml -f compose.ghcr.yaml up -d
```

Pulls `ghcr.io/<GHCR_OWNER>/tasklog-api` and `.../tasklog-web` instead of building locally. Requires `GHCR_OWNER` in `.env` and both GHCR packages set to Public. Pin a specific build with `IMG_TAG=sha-<short>` (defaults to `dev`).

CI builds and pushes both images on every push to `main`, tagged `dev` and `sha-<short>`. `compose.yaml` also names the GHCR images directly (with local `build:` as fallback), so a plain `docker compose up` pulls the published images once the packages are public.

### Stage B — observability on Compose

Compose files are split by what they are: `compose.yaml` (app), `compose.telemetry.yaml` (the vendor-neutral layer: OTel Collector + Vector), `compose.grafana.yaml` (Grafana, Prometheus, Loki, Tempo, exporters), `compose.datadog.yaml` (Datadog agent).

```bash
make docker-grafana
```

Self-hosted only: app + telemetry layer + Grafana stack. Grafana at `http://localhost:3001`, Prometheus `:9090`, Loki `:3100`, Tempo `:3200`.

```bash
make docker-o11y
```

Everything: the same baseline plus every SaaS platform whose credentials are in `.env`. Vendor exporters and sinks are rendered only for credentials that exist, so an empty `.env` yields the pure Grafana path.

### Stage C — Kubernetes

```bash
make cluster
make k8s
```

Provisions the OrbStack VM + kind cluster + Traefik + metrics-server, deploys the app, then lifts the observability stack onto the cluster. App at `http://tasklog-demo.orb.local`, Grafana at `http://grafana.tasklog-demo.orb.local` — three provisioned dashboards (Application, Infrastructure, Data stores) plus the alert pack, from the same files as the compose stage.

## Make targets

| Target | What it does |
|---|---|
| `cluster` | provision the VM + kind + Traefik + metrics-server (run once) |
| `docker` | full stack on Docker Compose |
| `k8s` | full stack on Kubernetes, in the right order |
| `tf` | Datadog monitors + dashboard via Terraform |
| `load` | k6 load script (`LOAD_URL=…`) |
| `demo-errors` / `demo-latency` / `demo-reset` | failure-injection levers (`API_URL=…`) |
| `down` | stop the compose stack |
| `clean` | delete the `tasklog` and `o11y` namespaces |
| `reset` | destroy the kind cluster and rebuild it empty |

### Full run

```bash
make cluster     # once per VM
make k8s         # app + telemetry + grafana + elastic + datadog, ordered
make tf          # datadog monitors and dashboard
make load LOAD_URL=http://tasklog-demo.orb.local K6_DURATION=5m
```

`make k8s` runs the components in dependency order, which matters: the app's pod
annotations must exist before the Datadog agent starts, Elasticsearch must be live before
its ingest pipeline and dashboard are created, and the Elastic wiring step must follow the
Grafana stack because that stack rebuilds the Vector config and the Grafana secret without
Elastic credentials.

### Granular targets

Each component can be run alone: `k8s-app`, `k8s-o11y`, `k8s-elastic`, `k8s-o11y-wire`,
`k8s-elastic-bootstrap`, `k8s-datadog`, `k8s-secrets`, `docker-grafana` (self-hosted only,
works with an empty `.env`), `docker-o11y`, `datadog-tf-plan`.

Rule of thumb: after any `k8s-o11y` run, follow with `k8s-o11y-wire` — install puts the stack up, wire renders and delivers every vendor config (it must run in-cluster reach because the Elasticsearch password only exists there).

## Datadog continuous profiling

The only vendor SDK in the Go API, and deliberately opt-in. Datadog has no OTLP ingestion
path for Go profiles, so unlike traces, metrics and logs this signal cannot be produced
vendor-neutrally — the choice is vendor code or no profiling, not vendor code or a
portable equivalent.

| Variable | Default | Effect |
|---|---|---|
| `DD_PROFILING_ENABLED` | unset (off) | starts the profiler; with it unset no Datadog code runs |
| `DD_PROFILING_CONTENTION` | unset (off) | adds goroutine, mutex and block profiles, which carry runtime overhead |
| `DD_AGENT_HOST` | `localhost` | upload target. **On Kubernetes this must be the node IP** (`status.hostIP`), because the agent is a DaemonSet |
| `DEPLOY_ENV` | `dev` | must match the agent's `env:` host tag, or profiles never join their traces |

Enabled by default in `deploy/k8s/04_api.yaml` and in `compose.datadog.yaml`; remove
`DD_PROFILING_ENABLED` from either to get a build with no vendor code executing.

Cost of the dependency, measured: **+4.4 MB binary (+11%)** and **+20 indirect modules**.

Two things that make this fail silently and are worth knowing before debugging it:

- **Service, env and version must match the OTel resource exactly.** Datadog joins a
  profile to a trace on that triple. A mismatch uploads successfully and the profile simply
  never appears on the trace's Profiles tab — which reads as "profiling is broken" but is a
  tagging bug. This is why the agent's `env:` tag is templated from `DEPLOY_ENV` rather than
  hardcoded; it previously said `env:poc` while the app said `env:dev`.
- **The agent's APM port is open for profiles, not traces.** `datadog.apm.portEnabled: true`
  exists only because the profiler has no transport other than the local trace-agent. Traces
  still leave the app as OTLP to the collector, which owns the Datadog trace export. If you
  are auditing where traces come from, it is not port 8126.

Where to look in Datadog: **APM → Profiles**, filtered to `service:tasklog-api`. Flame
graphs appear within a few minutes of load; the Profiles tab on an individual trace is the
correlation payoff, and it is what the tag matching above buys.

## Design notes

- No abstraction without two concrete users; boring beats clever.
- All environment differences flow through env vars and one `.env`.
- Plain Kubernetes manifests for our own workloads; Helm only for third-party charts.
- Versions pinned everywhere; automation idempotent; small resource footprint.
