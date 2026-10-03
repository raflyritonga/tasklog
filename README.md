# Tasklog — `datadog` branch

The Tasklog app with **zero observability wiring**: no OpenTelemetry, no vendor SDK, no agent config, no Terraform. It exists to be instrumented with Datadog from scratch — the step-by-step guide is in [DATADOG.md](DATADOG.md).

## What's here

```
browser ──► Traefik (k3s ingress) ──► nginx ──┬─ /api/reports/* ──► report (Python + Flask) ──► Postgres
                                              ├─ /api/*         ──► api (Go + Echo) ──────────► Postgres / Redis
                                              └─ /*             ──► web (Nuxt SSR)
```

- **web** — Nuxt 3 SSR UI.
- **api** — Go + Echo CRUD with cache-aside Redis, health probes (`/healthz`, `/readyz`), and failure-injection levers (`/api/demo/*`). Instrumented **by hand**, because Go has no Single Step Instrumentation.
- **report** — Python + Flask, one endpoint (`/api/reports/summary`), about 85 MB of RAM on one gunicorn worker. Its query carries a deliberate `pg_sleep(0.3)`. Instrumented with **zero code** through Single Step Instrumentation — the contrast with the api is the point.
- **nginx** — edge reverse proxy; one config ([deploy/nginx/default.conf](deploy/nginx/default.conf)) shared by k3s and compose.
- **Postgres 16** + **Redis 7.4** (capped at 48 MB with LRU eviction), seeded with 50 tasks.

The UI shows live stats from `report`: totals by status, a completion bar, and tasks created per day over the last 7 days. It refreshes every 30 seconds and right after each change, so `report` gets steady traffic whenever the app is open. A status filter narrows the task list. If `report` goes down, the panel keeps the last values and says it's stale, and the rest of the app keeps working.
- No telemetry at all: the api prints only plain startup/shutdown lines. Request logging, tracing and profiling are added by you in [DATADOG.md](DATADOG.md).

## Setup

1. `cp .env.datadog.example .env.datadog` and fill it in: the app's database settings plus your Datadog keys (`DD_API_KEY`, `DD_SITE`, and the DBM/RUM values used later in the guide). This branch reads **only** `.env.datadog`. `.env` belongs to `main`, and every `make` target refuses to run until `.env.datadog` exists, so compose can't fall back to `main`'s `.env`.
2. In the same file, set `APP_URL` (the nginx entry point: `http://localhost:8000` on compose, a k3s node's address on k3s) plus the `K6_DURATION` and `DEMO_*` knobs used by `load` and `demo-*`.
3. For k3s: copy the cluster's kubeconfig to `./kubeconfig` (on the server it's `/etc/rancher/k3s/k3s.yaml`; replace `127.0.0.1` with the server's address if you run `make` from another machine).
4. Images: pushing this branch builds `ghcr.io/<owner>/tasklog-{api,web,report}:datadog` via CI — set the three GHCR packages to Public, or import locally built images into k3s with `docker save <image> | sudo k3s ctr images import -`.

## Run

```bash
make docker      # local: app + nginx on compose, http://localhost:8000
make k8s         # k3s: everything in the tasklog namespace, via the built-in Traefik ingress
make load        # k6 against APP_URL
make demo-errors # failure levers: demo-errors / demo-latency / demo-cpu / demo-reset
```

On k3s the ingress has no host rule, so the app answers on any node's address, port 80.

| Target | What it does |
|---|---|
| `docker` / `docker-ghcr` / `down` | compose up (built locally / from GHCR images) / down |
| `k8s` / `k8s-down` | deploy to k3s / delete the namespace |
| `k8s-secrets` / `k8s-config` | DB secret from `.env.datadog` / ConfigMaps for init SQL + nginx |
| `load`, `demo-*` | k6 load and failure-injection levers |

## Runtime model — one pod each, fixed resources

Every workload runs **exactly one pod**, with `strategy: Recreate`, so a rollout never runs two pods at once. Every container has **requests = limits** (Guaranteed QoS): nothing can burst, and it gets evicted last under node pressure.

| Pod | CPU | Memory |
|---|---|---|
| pg | 250m | 256Mi |
| web | 200m | 256Mi |
| report | 100m | 192Mi |
| api | 100m | 128Mi |
| nginx | 50m | 64Mi |
| redis | 50m | 64Mi |
| **total** | **750m** | **960Mi** |

The namespace enforces this ([01_namespace.yaml](deploy/k3s/01_namespace.yaml)):

- A `long-running` quota allows **6 pods** — one per workload. Any scale-up, HPA, or extra pod is rejected when the pod is created.
- A separate `jobs` quota allows the seed Job one pod at a time.
- A `LimitRange` gives defaults to any container that doesn't declare limits, and caps every container at 250m / 256Mi.

The CPU limits are deliberately tight: under `make load` or `make demo-cpu` you'll see CPU throttling, which is a useful signal to find in Datadog.

## Next

Follow [DATADOG.md](DATADOG.md) in order: agent on k3s → unified tagging → Go api with dd-trace-go (Go has no Single Step Instrumentation) → Node web via Single Step Instrumentation → nginx module → Postgres DBM, Redis, nginx → RUM → profiling.
