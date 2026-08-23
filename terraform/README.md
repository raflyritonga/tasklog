# Datadog as code

Grafana is provisioned natively (files mounted by the chart) and Elastic through its
saved-objects API. Datadog's idiomatic path is Terraform, so that is what this uses —
different tool per platform is the point, not an inconsistency.

```bash
make datadog-tf-plan
make datadog-tf-apply
```

Credentials come from `.env` (`DD_API_KEY`, `DD_APP_KEY`, `DD_SITE`) via `TF_VAR_*`; state
is local and gitignored.

Before the first apply, confirm the metric names in Datadog's Metrics Explorer. The OTel
collector forwards our instrument names unchanged (`http.server.request.count`,
`http.server.request.duration`), but if your org rewrites them, override:

```bash
make datadog-tf-apply TF_VAR_request_metric=otel.http.server.request.count
```
