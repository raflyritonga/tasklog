# Tasklog

A small task CRUD app (Nuxt 3 + Go + Postgres + Redis) built to demonstrate one telemetry pipeline delivering to **four observability platforms simultaneously**: a self-hosted Grafana stack (Prometheus, Loki, Tempo), self-hosted Elastic (ECK), Datadog, and Dynatrace.

The app is deliberately simple — the observability wiring is the product.

## How it works

- **Instrument once.** The API uses the OpenTelemetry SDK for traces and metrics (OTLP) and writes structured JSON logs to stdout with a `trace_id` on every line. No vendor code in the app for the three core signals.
- **OTel Collector** fans traces and metrics out to Tempo, Prometheus, Elastic APM Server, Datadog, and Dynatrace.
- **Vector** tails logs once and shapes them per platform: Loki labels, full ECS, Datadog conventions, Dynatrace flat keys.
- **Split by design:** Collector = traces + metrics, Vector = logs.
- **RUM** is a browser toggle (Datadog default · Dynatrace · Elastic) — beacons go browser → vendor directly.
- **Agents only where OTLP can't deliver:** Datadog agent (infra + DBM + profile upload), Dynatrace OneAgent (web pod only, profiling), otel-agent DaemonSet (host metrics → Elasticsearch).
- Everything renders from one script: `deploy/o11y/render.sh` emits exporters and sinks **only for credentials present in `.env`** — an empty `.env` yields the pure Grafana path.

```
browser ──► ingress ──► web (Nuxt SSR) ──► api (Go + Echo) ──► Postgres / Redis
                                              │
                    OTel SDK (traces+metrics) │ JSON logs (stdout, trace_id)
                                              ▼
     OTel Collector ──► Tempo · Prometheus · APM Server · Datadog · Dynatrace
     Vector ──────────► Loki · Elasticsearch · Datadog Logs · Dynatrace Logs
     browser RUM ─────► one vendor per browser (toggle, top-right in the app)
```

## Stack

Nuxt 3 · Go (Echo) · PostgreSQL 16 · Redis · OpenTelemetry · Vector · Prometheus · Loki · Tempo · Grafana · ECK (Elasticsearch, Kibana, APM Server) · k6 · kind · Ansible · Terraform · GitHub Actions → GHCR

## Setup (one-time)

1. **GitHub / GHCR** — public repo with Actions enabled; set both GHCR packages (`tasklog-api`, `tasklog-web`) to Public after the first CI run.
2. **Datadog trial** — `DD_SITE`, `DD_API_KEY`, `DD_APP_KEY` (Terraform), RUM app → `DD_RUM_APP_ID` + `DD_RUM_CLIENT_TOKEN`.
3. **Dynatrace trial** — `DT_TENANT_URL` (the `.live.` domain), ingest token → `DT_API_TOKEN`, operator token → `DT_OPERATOR_TOKEN`, RUM script src → `DT_RUM_SCRIPT_URL`; for Terraform detectors: `DT_PLATFORM_TOKEN` + `DT_ACTOR_UUID` (and optionally `DT_SETTINGS_TOKEN`).
4. **Elastic** — nothing to sign up for: Elasticsearch, Kibana and APM Server run in-cluster via ECK; credentials are pulled from the operator's secret at deploy time. Only `ELASTIC_RUM_ENDPOINT` (the APM ingress URL) matters for browser RUM.
5. `cp .env.example .env` and fill in what you have — missing credentials just mean that platform isn't rendered.
6. `cp make.env.example make.env` — demo/load knobs (`API_URL`, `LOAD_URL`, `K6_DURATION`, …) live there, gitignored.
7. **OrbStack VM** (k8s stage) — machine named `tasklog-demo` (~6 CPU / 12 GB); the name is the domain (`tasklog-demo.orb.local`).

## Quickstart

```bash
docker compose up -d --build --wait      # app only, http://localhost:3000
make docker-grafana                      # + self-hosted telemetry, works with empty .env
make docker-o11y                         # + every SaaS with credentials in .env
```

Kubernetes:

```bash
make cluster     # once per VM: kind + Traefik + metrics-server
make k8s         # app + telemetry + grafana + elastic + datadog, in dependency order
make tf          # alerts + dashboards as code on Datadog, Dynatrace, Elastic
make k8s-dt-oneagent   # Dynatrace operator + OneAgent injection (web pod only)
make load        # k6 against LOAD_URL
```

App at `http://tasklog-demo.orb.local`, Grafana at `http://grafana.tasklog-demo.orb.local`, Kibana at `http://kibana.tasklog-demo.orb.local`.

## Make targets

| Target | What it does |
|---|---|
| `cluster` / `k8s` / `docker` | provision, full k8s stack, full compose stack |
| `tf` | Terraform: 2 Datadog monitors + 2 dashboards + percentiles, 2 Elastic rules, 1 Davis detector |
| `k8s-o11y-wire` | render + deliver every vendor config, restart the pipeline — **run after any `k8s-o11y`** |
| `k8s-elastic-bootstrap` | ingest pipelines, templates, saved objects, detection rule |
| `k8s-dt-oneagent` | Dynatrace operator (helm) + DynaKube + web-pod injection |
| `load` / `demo-errors` / `demo-latency` / `demo-cpu` / `demo-reset` | k6 + failure-injection levers (knobs in `make.env`) |
| `down` / `clean` / `reset` | stop compose / delete namespaces / rebuild the cluster |

Granular targets exist per component: `k8s-app`, `k8s-o11y`, `k8s-elastic`, `k8s-datadog`, `k8s-secrets`, `datadog-tf-plan`.

## Profiling — the honest exception

Profiling is the one pillar OTel can't yet deliver, so it's the only vendor code in the app: Datadog's Go profiler, env-gated and off by default.

| Variable | Default | Effect |
|---|---|---|
| `DD_PROFILING_ENABLED` | off | starts the profiler; unset = no Datadog code runs |
| `DD_PROFILING_CONTENTION` | off | adds goroutine/mutex/block profiles (extra overhead) |
| `DD_AGENT_HOST` | `localhost` | upload target — on k8s the node IP (`status.hostIP`) |

Profiles join traces on the exact `service`/`env`/`version` triple; a mismatch uploads fine and silently never links. Dynatrace profiling rides OneAgent on the web pod instead — note the OneAgent host DaemonSet requires amd64 nodes and will not schedule on an arm64 (Apple Silicon) lab.

## Design notes

- No abstraction without two concrete users; boring beats clever.
- Vendors are configuration, not code: adding Dynatrace touched `render.sh`, not the app.
- Vendors reserve field names — `status` means log *level* to Datadog and Dynatrace; the Vector shapers translate per platform, covered by unit tests (`vector test`).
- Plain manifests for our workloads, pinned Helm for third-party, Terraform for SaaS control planes, dashboards in each platform's own idiom.
