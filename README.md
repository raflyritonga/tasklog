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
docker compose up
```

App at `http://localhost:3000`. (Available after phase 2.)

### Stage A — run from public GHCR images

```bash
docker compose -f compose.yaml -f compose.ghcr.yaml pull
docker compose -f compose.yaml -f compose.ghcr.yaml up
```

(Available after phase 3.)

### Stage B — observability pipeline on Compose

```bash
make o11y-up
```

Grafana at `http://localhost:3001`. (Available after phase 4.)

### Stage C — Kubernetes

```bash
make up
make secrets
make deploy
```

App at `http://tasklog-demo.orb.local`. (Available after phases 6–8.)

## Make targets

| Target | What it does |
|---|---|
| `dev` | app stack on Docker Compose, local builds |
| `dev-ghcr` | app stack on Docker Compose, GHCR images |
| `o11y-up` | observability pipeline on Compose |
| `up` | OrbStack VM + kind cluster + ingress via Ansible |
| `deploy` | app + pipeline onto the kind cluster |
| `seed` | seed the database with sample tasks |
| `load` | k6 load script |
| `demo-latency` | inject latency into `/api/tasks*` |
| `demo-errors` | inject 500 errors into `/api/tasks*` |
| `demo-reset` | clear both demo levers |
| `dashboards` | push dashboards to the SaaS platforms |
| `secrets` | render k8s Secrets from `.env` |
| `down` | stop and remove everything |

## Design notes

- No abstraction without two concrete users; boring beats clever.
- All environment differences flow through env vars and one `.env`.
- Plain Kubernetes manifests for our own workloads; Helm only for third-party charts.
- Versions pinned everywhere; automation idempotent; small resource footprint.
