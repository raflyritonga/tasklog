# Instrumenting Tasklog with Datadog

This branch ships with **no instrumentation**. The api only logs plain-text startup and shutdown lines, and there are no traces, metrics or RUM. Work through the steps in order; each one ends with a check, and later steps assume the earlier ones passed.

| # | Step | Code change? |
|---|---|---|
| 1 | Agent on k3s | no |
| 2 | Unified service tagging + admission label | manifests only |
| 3 | Go api: tracer, logs, DB/Redis spans | **yes** (Go isn't supported by Single Step Instrumentation) |
| 4 | Node web + Python report: Single Step Instrumentation | **no** — compare this with step 3 |
| 5 | nginx: tracing module | Dockerfile |
| 6 | Integrations: Postgres DBM, Redis, nginx | annotations + SQL |
| 7 | RUM | no (nginx) or yes (SDK) |
| 8 | Profiling | a few lines (Go), env var (Node, Python) |

The Go snippets match the published APIs of dd-trace-go v2 and its contrib packages.

## 0 · Fill in `.env.datadog`

Every Datadog value lives in `.env.datadog` — never in `.env`, which belongs to `main`. Fill in `DD_API_KEY` and `DD_SITE` now. The other `DD_*` variables are used in steps 6 and 7.

Run this once in your shell before each step's commands, so the commands can read those values:

```bash
set -a; . ./.env.datadog; set +a
```

## 1 · Agent on k3s

```bash
kubectl create namespace datadog
kubectl -n datadog create secret generic datadog-secret --from-literal=api-key="$DD_API_KEY"
```

Create `deploy/datadog/values.yaml`:

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  clusterName: tasklog-k3s
  criSocketPath: /run/k3s/containerd/containerd.sock
  kubelet:
    tlsVerify: false
  logs:
    enabled: true
    containerCollectAll: true
  apm:
    portEnabled: true
  processAgent:
    enabled: true
clusterAgent:
  enabled: true
  admissionController:
    enabled: true
    mutateUnlabelled: false
```

Two lines in this file are k3s-specific:

- `criSocketPath`: k3s runs its own containerd at a non-standard socket path.
- `kubelet.tlsVerify: false`: the k3s kubelet uses a self-signed certificate.

Install the chart:

```bash
helm repo add datadog https://helm.datadoghq.com
helm upgrade --install datadog datadog/datadog -n datadog -f deploy/datadog/values.yaml --set datadog.site="$DD_SITE"
```

The site comes from `.env.datadog`, so the values file holds no account-specific values. Re-run this same command after every values change in later steps.

**Check:** Infrastructure → Kubernetes shows `tasklog-k3s`. Also run `kubectl -n datadog exec ds/datadog -c agent -- agent status`; it should show no collector errors.

## 2 · Unified service tagging + admission label

For each of `api`, `web` and `nginx`, add these labels to **both** the Deployment metadata and the pod template:

```yaml
metadata:
  labels:
    tags.datadoghq.com/env: dev
    tags.datadoghq.com/service: tasklog-api
    tags.datadoghq.com/version: datadog
```

Set `service` per workload: `tasklog-api`, `tasklog-report`, `tasklog-web`, `tasklog-nginx`. The labels go on the `report` Deployment too.

On the **pod template** only, also add:

```yaml
    admission.datadoghq.com/enabled: "true"
```

With that label, the admission controller injects `DD_AGENT_HOST`, `DD_ENV`, `DD_SERVICE` and `DD_VERSION` into the containers. The tracer and profiler read those variables, so the code never hardcodes where the agent is or what the service is called.

Then deploy:

```bash
make k8s
```

**Check:** `kubectl -n tasklog exec deploy/api -- env | grep DD_` lists the injected variables.

## 3 · Go api — tracer, logs, DB and Redis spans

Add the libraries:

```bash
cd app/api
go get github.com/DataDog/dd-trace-go/v2 \
  github.com/DataDog/dd-trace-go/contrib/labstack/echo.v4/v2 \
  github.com/DataDog/dd-trace-go/contrib/jackc/pgx.v5/v2 \
  github.com/DataDog/dd-trace-go/contrib/redis/go-redis.v9/v2 \
  github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

### 3a · `main.go` — imports

```go
import (
	echotrace "github.com/DataDog/dd-trace-go/contrib/labstack/echo.v4/v2"
	pgxtrace "github.com/DataDog/dd-trace-go/contrib/jackc/pgx.v5/v2"
	redistrace "github.com/DataDog/dd-trace-go/contrib/redis/go-redis.v9/v2"
	slogtrace "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
)
```

### 3b · `main.go` — tracer and logger

Replace `logger := slog.Default()` with:

```go
	tracer.Start()
	defer tracer.Stop()

	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				a.Key = "timestamp"
			}
			return a
		},
	})
	logger := slog.New(slogtrace.WrapHandler(handler))
	slog.SetDefault(logger)
```

`WrapHandler` adds the active trace and span ids to every record that's logged with a context. That's what links each log line to its trace.

### 3c · `main.go` — Postgres and Redis spans

```go
	db, err := pgxtrace.NewPoolWithConfig(ctx, dbConfig)
```

That replaces `pgxpool.NewWithConfig`. Then add one line after the Redis client is created:

```go
	rdb := redis.NewClient(&redis.Options{Addr: cfg.redisAddr})
	redistrace.WrapClient(rdb)
```

Use `WrapClient`, not `redistrace.NewClient`. `NewClient` returns a `redis.UniversalClient`, but the health and task packages take a `*redis.Client`, so the code wouldn't compile. `WrapClient` adds hooks to the existing client and keeps its type.

### 3d · `main.go` — middleware, in this order

```go
	e.Use(echotrace.Middleware())
	e.Use(requestLogger(logger))
	e.Use(demo.Middleware(levers))
```

Order matters:

- The trace middleware goes **first**, so the span exists in the request context when the logger reads it.
- The demo levers go **last**, so injected errors get both traced and logged.

### 3e · new file `app/api/logging.go`

This logger uses Datadog's standard attribute names, so logs facet correctly with no pipeline remapping:

```go
package main

import (
	"log/slog"
	"time"

	"github.com/labstack/echo/v4"
)

func requestLogger(logger *slog.Logger) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()
			err := next(c)
			if err != nil {
				c.Error(err)
			}
			req := c.Request()
			code := c.Response().Status
			attrs := []any{
				slog.Group("http",
					"method", req.Method,
					"status_code", code,
					"route", c.Path(),
					slog.Group("url_details", "path", req.URL.Path),
				),
				slog.Group("network", slog.Group("client", "ip", c.RealIP())),
				"duration", time.Since(start).Nanoseconds(),
			}
			if err != nil {
				attrs = append(attrs, slog.Group("error", "message", err.Error()))
			}
			level := slog.LevelInfo
			if code >= 500 {
				level = slog.LevelError
			}
			logger.Log(req.Context(), level, req.Method+" "+req.URL.Path, attrs...)
			return nil
		}
	}
}
```

The logger calls `c.Error(err)` *before* logging, so the response is already written and `status_code` is the real code. If it skipped that, Echo would write the error response after the logger ran, and every error would log as 200.

Three of the field names prevent problems seen on `main`:

| Field | Why this name |
|---|---|
| `http.status_code` | Datadog reads a top-level `status` field as the *log level*. Never log the HTTP code as `status`. |
| `duration` | Nanoseconds is Datadog's standard unit for duration. |
| `level` | Maps to the log status on its own, because there's no `status` field to outrank it. |

### 3f · Build, ship, check

```bash
go build ./... && go vet ./...
```

Commit and push; CI rebuilds `:datadog`. Then:

```bash
kubectl -n tasklog rollout restart deployment/api
```

Annotate the api pod so its logs use the Go pipeline:

```yaml
annotations:
  ad.datadoghq.com/api.logs: '[{"source":"go","service":"tasklog-api"}]'
```

**Check:**

- APM → Services shows `tasklog-api`. A `GET /api/tasks` trace has Postgres and Redis child spans.
- A log's side panel → Trace tab opens that trace.
- During `make demo-errors`, logs show level *Error* with `@http.status_code:500`.

> **Zero-code alternative for Go:** [Orchestrion](https://datadoghq.dev/orchestrion/) instruments the same libraries at compile time. Run `go install github.com/DataDog/orchestrion@latest`, then `orchestrion pin`, then build with `orchestrion go build`. Skip 3a–3d if you go that way, but keep 3e — Orchestrion traces requests, it doesn't write your request logs.

## 4 · Node web + Python report — Single Step Instrumentation

This step exists for the comparison. Step 3 had you write a tracer setup, middleware, DB and Redis wrappers and a logger. Here you change **zero** lines of code: Node.js and Python are both supported, so the admission controller injects `dd-trace-js` into web and `dd-trace-py` into report when their pods are created.

Add this to the Helm values (requires Agent 7.64+):

```yaml
datadog:
  apm:
    instrumentation:
      enabled: true
      targets:
        - name: tasklog
          namespaceSelector:
            matchNames:
              - tasklog
          ddTraceVersions:
            js: "5"
            python: "3"
```

```bash
helm upgrade --install datadog datadog/datadog -n datadog -f deploy/datadog/values.yaml --set datadog.site="$DD_SITE"
kubectl -n tasklog rollout restart deployment/web deployment/report
```

Injection only happens when a pod is created, which is why the restart is required.

**Check:**

- APM → Services shows `tasklog-web` and `tasklog-report`.
- Keep the app open in a browser: the stats panel calls both report endpoints every 30 seconds, so `tasklog-report` gets traffic even when nobody clicks anything.
- Open a `GET /api/reports/summary` trace: the Flask request span has a Postgres child span of about **300 ms**. That's the deliberate `pg_sleep(0.3)` in the query. You wrote nothing, yet the trace shows exactly where the time goes.
- `kubectl -n tasklog get pod -l app=report -o jsonpath='{.items[0].spec.initContainers[*].name}'` lists the injector's init containers. That's the injection, visible.

**What you didn't get for free:** the report service writes no request logs (gunicorn's access log is off). If you want them, add `--access-logfile -` to its gunicorn command and set `DD_LOGS_INJECTION=true` on the pod, so the injected tracer stamps trace ids into the log lines.

## 5 · nginx — tracing module

Datadog builds the module for **each exact nginx version**. The repo pins `nginx:1.30.5-alpine`, which the module supports. Create `deploy/nginx/Dockerfile`:

```dockerfile
FROM nginx:1.30.5-alpine
ARG TARGETARCH
ARG MODULE_RELEASE=<nginx-datadog release tag>
ADD https://github.com/DataDog/nginx-datadog/releases/download/${MODULE_RELEASE}/ngx_http_datadog_module-${TARGETARCH}-1.30.5.so.tgz /tmp/module.tgz
RUN tar -xzf /tmp/module.tgz -C /usr/lib/nginx/modules && rm /tmp/module.tgz \
 && sed -i '1i load_module modules/ngx_http_datadog_module.so;' /etc/nginx/nginx.conf
```

Pick the artifact that matches your architecture and nginx 1.30.5 on the [releases page](https://github.com/DataDog/nginx-datadog/releases).

`load_module` must be in the main context of `nginx.conf`. `default.conf` is included inside the `http` block, which is too late to load a module.

Build the image, push it, and point `08_nginx.yaml` at it. The pod gets `DD_AGENT_HOST` from the admission label in step 2; check your module release's README for how it reads that variable.

**Check:** a request through nginx produces one trace that starts at `tasklog-nginx`, then continues into api, then into Postgres.

## 6 · Integrations

### Postgres — Database Monitoring

**a.** Add these args to the `postgres` container in `02_postgres.yaml`:

```yaml
          args: ["postgres", "-c", "shared_preload_libraries=pg_stat_statements", "-c", "pg_stat_statements.track=all", "-c", "track_activity_query_size=4096"]
```

**b.** Create the monitoring user and the explain function. The password comes from `DD_POSTGRES_PASSWORD` in `.env.datadog`, passed to `psql` as a variable, so it never appears in the SQL text.

```bash
kubectl -n tasklog exec -i deploy/pg -- psql -U "${POSTGRES_USER:-tasklog}" -d "${POSTGRES_DB:-tasklog}" -v pw="$DD_POSTGRES_PASSWORD" <<'SQL'
create extension if not exists pg_stat_statements;
create user datadog with password :'pw';
grant pg_monitor to datadog;
create schema if not exists datadog;
grant usage on schema datadog to datadog;
grant usage on schema public to datadog;
create or replace function datadog.explain_statement(l_query text, out explain json)
returns setof json language plpgsql returns null on null input security definer as $$
declare curs refcursor; plan json;
begin
  open curs for execute pg_catalog.concat('explain (format json) ', l_query);
  fetch curs into plan; close curs; return query select plan;
end; $$;
grant execute on function datadog.explain_statement(text) to datadog;
SQL
```

`init.sql` only runs on an empty volume, so a running cluster needs this exec. To make fresh clusters reproducible, append everything **except** the `create user` line to `deploy/postgres/init.sql` — that file is committed, and the password must stay out of git.

**c.** Annotate the `pg` pod template:

```yaml
      annotations:
        ad.datadoghq.com/postgres.checks: |
          {"postgres":{"init_config":{},"instances":[{"host":"%%host%%","port":5432,"username":"datadog","password":"%%env_DD_POSTGRES_PASSWORD%%","dbname":"tasklog","dbm":true}]}}
```

`%%env_…%%` is resolved by the **agent**, so give the agent the same password. First create a secret from `.env.datadog`:

```bash
kubectl -n datadog create secret generic datadog-postgres --from-literal=password="$DD_POSTGRES_PASSWORD"
```

Then add it to the Helm values and re-run the install command:

```yaml
agents:
  containers:
    agent:
      env:
        - name: DD_POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: datadog-postgres
              key: password
```

**Optional:** set `DD_DBM_PROPAGATION_MODE=full` on the api to link its traces to the exact DBM query samples. Check which dd-trace-go release supports this for pgx before relying on it.

**Check:** Database Monitoring lists the host. Query Metrics shows the `tasks` queries. The report summary query is the slowest at about 300 ms; open it to see its **Explain Plan**.

### Redis

```yaml
      annotations:
        ad.datadoghq.com/redis.checks: |
          {"redisdb":{"init_config":{},"instances":[{"host":"%%host%%","port":6379}]}}
```

### nginx

Add a status server to `deploy/nginx/default.conf`:

```nginx
server {
    listen 81;
    location /nginx_status { stub_status; access_log off; }
}
```

Add `containerPort: 81` to the nginx container. Then annotate the pod:

```yaml
      annotations:
        ad.datadoghq.com/nginx.checks: |
          {"nginx":{"init_config":{},"instances":[{"nginx_status_url":"http://%%host%%:81/nginx_status"}]}}
        ad.datadoghq.com/nginx.logs: '[{"source":"nginx","service":"tasklog-nginx"}]'
```

`make k8s` reloads the nginx ConfigMap.

**Check:** Integrations → Redis and NGINX show data, and the built-in *NGINX — Overview* dashboard populates.

## 7 · RUM

First create a RUM application under Digital Experience. Copy its application ID and client token into `DD_RUM_APPLICATION_ID` and `DD_RUM_CLIENT_TOKEN` in `.env.datadog`. Then pick one option:

- **A · Inject at nginx (no code).** RUM Auto-Instrumentation uses the module from step 5 to insert the browser SDK into HTML responses. Choose *Auto-Instrumentation with NGINX* in Digital Experience; it generates the directives for your app. The upstream must not compress HTML; Nuxt's server doesn't by default.

  Keep the ID and token out of the committed config. The official nginx image runs `envsubst` on files in `/etc/nginx/templates/*.template` at startup, so write `${DD_RUM_APPLICATION_ID}` and `${DD_RUM_CLIENT_TOKEN}` in a template and pass the two variables to the nginx container from a secret.
- **B · Browser SDK in Nuxt (full control).** Add `@datadog/browser-rum` and a client-only plugin. `main` has one you can adapt: `git show main:app/web/plugins/rum.client.ts`. Set `allowedTracingUrls` to your app's origin, so browser requests carry trace headers and RUM joins the backend traces.

  Nuxt reads `NUXT_PUBLIC_*` env vars at runtime, so the values reach the browser without a rebuild. Create the secret from `.env.datadog`:

  ```bash
  kubectl -n tasklog create secret generic web-rum \
    --from-literal=NUXT_PUBLIC_DD_RUM_APPLICATION_ID="$DD_RUM_APPLICATION_ID" \
    --from-literal=NUXT_PUBLIC_DD_RUM_CLIENT_TOKEN="$DD_RUM_CLIENT_TOKEN" \
    --from-literal=NUXT_PUBLIC_DD_SITE="$DD_SITE"
  ```

  Then add `envFrom: [{secretRef: {name: web-rum}}]` to the web container, and declare the three keys under `runtimeConfig.public` in `nuxt.config.ts`.

**Check:** browse the app for a minute; sessions appear under RUM, and replays play back. k6 never shows up here, because it doesn't execute JavaScript.

## 8 · Profiling

**Go api** — add to `main.go`, right after `tracer.Start()`:

```go
	"github.com/DataDog/dd-trace-go/v2/profiler"
```

```go
	if err := profiler.Start(profiler.WithProfileTypes(profiler.CPUProfile, profiler.HeapProfile)); err != nil {
		logger.Warn("profiler failed to start", "err", err.Error())
	}
	defer profiler.Stop()
```

Because the dd-trace-go tracer from step 3 is running, profiles break down **per endpoint** too. `main` couldn't do that with OTel tracing.

**Node web and Python report** — set `DD_PROFILING_ENABLED=true` on each container. The injected tracer reads it, so again there's no code.

**Check:** APM → Profiles → `service:tasklog-api` shows a flame graph within minutes, and the Profiles tab on a trace opens the matching profile.

## Monitors

Create these in the UI:

- 5xx ratio above 5% on `service:tasklog-api`
- p95 latency above 800 ms
- a DBM long-running-query monitor

Trigger them with `make demo-errors` or `make demo-latency` plus `make load`, then run `make demo-reset`.

## Final verification

| Signal | Where | Expected |
|---|---|---|
| Infra | Infrastructure → Kubernetes | cluster, nodes, every tasklog pod |
| Logs | Logs, `service:tasklog-api` | JSON parsed; Error during `demo-errors`; `@http.status_code` facet |
| Traces | APM → Traces | nginx → api → Postgres/Redis, and nginx → report → Postgres, each as one trace |
| Correlation | log → Trace tab | that request's trace |
| DBM | Database Monitoring | query metrics + explain plans |
| Integrations | Redis / NGINX dashboards | populated |
| RUM | Digital Experience | your session + replay |
| Profiling | APM → Profiles | flame graphs for tasklog-api, tasklog-report, tasklog-web |

## Gotchas specific to this branch's strict limits

- **The tracers run inside fixed limits.** An injected tracer adds roughly 30–60 MB to `web` and `report`, and dd-trace-go plus the profiler adds a little to `api`. Requests = limits leaves no room to burst. If a pod restarts with `OOMKilled` after you enable APM, raise that pod's memory in its manifest and in the `long-running` quota together.
- **Injected init containers face the quota and the LimitRange.** If pods stop appearing after you enable Single Step Instrumentation, run `kubectl -n tasklog get events --sort-by=.lastTimestamp` and look for `exceeded quota` or `maximum ... per Container`. The quota has 150m / 192Mi of headroom for this.
- **`kubectl scale` and HPAs are rejected by design.** The `long-running` quota allows 6 pods. To try a second replica, raise `pods` in [01_namespace.yaml](deploy/k3s/01_namespace.yaml) first.
- **Throttling is expected.** The CPU limits are tight on purpose. Graph `kubernetes.cpu.cfs.throttled.seconds` per container during `make load` — that's how a fixed-size deployment shows saturation.

## Gotchas learned on `main`

- **Never log an HTTP code as `status`.** Datadog treats `status` as the log level.
- **The `env`/`service`/`version` triple must match everywhere.** A mismatch doesn't error; data arrives but never joins.
- **Admission injection only applies to new pods.** Restart the deployment after any change to injection.
- **`init.sql` runs once, on an empty volume.** On a live cluster, apply SQL changes with `kubectl exec … psql`.
- **The nginx module must match the nginx version exactly.** Upgrade both together.
- **The `:datadog` tag is mutable.** Keep `imagePullPolicy: Always` so pods pull the new build.
