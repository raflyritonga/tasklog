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
make docker-app
```

Builds and starts postgres, redis, api, and web. App at `http://localhost:3000` — the database is seeded with 50 tasks on first boot. `make docker-down` stops everything.

### Stage A — run from public GHCR images

```bash
make docker-app-ghcr
```

Pulls `ghcr.io/<GHCR_OWNER>/tasklog-api` and `.../tasklog-web` instead of building locally. Requires `GHCR_OWNER` in `.env` and both GHCR packages set to Public. Pin a specific build with `IMG_TAG=sha-<short>` (defaults to `dev`). Equivalent raw command:

```bash
docker compose -f compose.yaml -f compose.ghcr.yaml pull
docker compose -f compose.yaml -f compose.ghcr.yaml up -d
```

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

Everything: the same baseline plus every SaaS platform whose credentials are in `.env`. Vendor exporters and sinks are rendered only for credentials that exist, so an empty `.env` yields the pure Grafana path. `make docker-datadog` adds just the Datadog agent on top of the baseline.

### Stage C — Kubernetes

```bash
make k8s-cluster
make k8s-app
make k8s-o11y
make k8s-datadog
```

Provisions the OrbStack VM + kind cluster + Traefik + metrics-server, deploys the app, then lifts the observability stack onto the cluster. App at `http://tasklog-demo.orb.local`, Grafana at `http://grafana.tasklog-demo.orb.local` — three provisioned dashboards (Application, Infrastructure, Data stores) plus the alert pack, from the same files as the compose stage.

## Make targets

| Target | What it does |
|---|---|
| **Docker Compose** | |
| `docker-app` | app only: pg, redis, api, web (local builds) |
| `docker-app-ghcr` | app only, from published GHCR images |
| `docker-grafana` | app + telemetry layer + Grafana stack |
| `docker-datadog` | same, plus the Datadog agent |
| `docker-o11y` | same, plus every configured platform |
| `docker-seed` | reseed the compose database |
| `docker-down` | stop and remove the compose stack |
| **Kubernetes** | |
| `k8s-cluster` | provision VM + kind + Traefik + metrics-server (Ansible) |
| `k8s-app` | app manifests, secrets, seed job |
| `k8s-o11y` | telemetry layer + Grafana stack on the cluster |
| `k8s-datadog` | Datadog agent + database monitoring |
| `k8s-secrets` | render k8s Secrets from `.env` |
| `k8s-down` | delete the `tasklog` and `o11y` namespaces |
| **Either target** | set `API_URL` / `LOAD_URL` |
| `load` | k6 load script |
| `demo-latency` / `demo-errors` / `demo-reset` | failure-injection levers |
| `dashboards` | push dashboards to the SaaS platforms |

## Design notes

- No abstraction without two concrete users; boring beats clever.
- All environment differences flow through env vars and one `.env`.
- Plain Kubernetes manifests for our own workloads; Helm only for third-party charts.
- Versions pinned everywhere; automation idempotent; small resource footprint.
