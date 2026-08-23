#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ -f ../../.env ]; then
  set -a
  . ../../.env
  set +a
fi

dd_site="${DD_SITE:-}"
case "$dd_site" in
  "") dd_site_full="datadoghq.com" ;;
  *.*) dd_site_full="$dd_site" ;;
  *) dd_site_full="$dd_site.datadoghq.com" ;;
esac

vendors=""
[ -n "${DD_API_KEY:-}" ] && vendors="$vendors datadog"
[ -n "${DT_TENANT_URL:-}" ] && [ -n "${DT_API_TOKEN:-}" ] && vendors="$vendors dynatrace"
[ -n "${ELASTIC_APM_ENDPOINT:-}" ] && vendors="$vendors elastic-apm"
{ [ -n "${ELASTIC_ES_ENDPOINT:-}" ] || [ -n "${ELASTIC_ES_ENDPOINT_K8S:-}" ]; } && [ -n "${ELASTIC_ES_PASSWORD:-}" ] && vendors="$vendors elastic-logs"

render() {
  stage="$1"
  collector="$2"
  vectorconf="$3"
  traces_processors="$4"

  trace_exporters="otlp/tempo"
  metric_exporters="prometheus"
  metric_receivers="otlp"

  cp "otel-collector/snippets/base-$stage.yaml" "$collector"
  cp "vector/snippets/base-$stage.toml" "$vectorconf"

  if [ -n "${DD_API_KEY:-}" ]; then
    cat otel-collector/snippets/exporter-datadog.yaml >> "$collector"
    cat otel-collector/snippets/connector-datadog.yaml >> "$collector"
    cat vector/snippets/sink-datadog.toml >> "$vectorconf"
    trace_exporters="$trace_exporters, datadog, datadog/connector"
    metric_exporters="$metric_exporters, datadog"
    metric_receivers="$metric_receivers, datadog/connector"
  fi

  if [ -n "${DT_TENANT_URL:-}" ] && [ -n "${DT_API_TOKEN:-}" ]; then
    cat otel-collector/snippets/exporter-dynatrace.yaml >> "$collector"
    trace_exporters="$trace_exporters, otlphttp/dynatrace"
    metric_exporters="$metric_exporters, otlphttp/dynatrace"
  fi

  if [ -n "${ELASTIC_APM_ENDPOINT:-}" ]; then
    cat otel-collector/snippets/exporter-elastic.yaml >> "$collector"
    trace_exporters="$trace_exporters, otlphttp/elastic"
    metric_exporters="$metric_exporters, otlphttp/elastic"
  fi

  es_endpoint="${ELASTIC_ES_ENDPOINT:-}"
  if [ "$stage" = "k8s" ] && [ -n "${ELASTIC_ES_ENDPOINT_K8S:-}" ]; then
    es_endpoint="$ELASTIC_ES_ENDPOINT_K8S"
  fi
  if [ -n "$es_endpoint" ] && [ -n "${ELASTIC_ES_PASSWORD:-}" ]; then
    cat vector/snippets/sink-elastic.toml >> "$vectorconf"
  fi

  cat >> "$collector" <<EOF

service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: [$traces_processors]
      exporters: [$trace_exporters]
    metrics:
      receivers: [$metric_receivers]
      processors: [batch]
      exporters: [$metric_exporters]
EOF

  sed -i '' \
    -e "s|__DD_SITE_FULL__|$dd_site_full|g" \
    -e "s|__DT_TENANT_URL__|${DT_TENANT_URL:-}|g" \
    -e "s|__ELASTIC_APM_ENDPOINT__|${ELASTIC_APM_ENDPOINT:-}|g" \
    "$collector"

  sed -i '' \
    -e "s|__DD_SITE_FULL__|$dd_site_full|g" \
    -e "s|__ELASTIC_ES_ENDPOINT__|$es_endpoint|g" \
    -e "s|__DD_API_KEY__|${DD_API_KEY:-}|g" \
    -e "s|__ELASTIC_ES_USER__|${ELASTIC_ES_USER:-elastic}|g" \
    -e "s|__ELASTIC_ES_PASSWORD__|${ELASTIC_ES_PASSWORD:-}|g" \
    "$vectorconf"
}

render compose otel-collector/otel-collector.yaml vector/vector.toml batch
render k8s otel-collector/otel-collector-k8s.yaml vector/vector-k8s.toml "k8sattributes, batch"

if [ -z "$vendors" ]; then
  echo "rendered grafana-only pipeline (no SaaS credentials in .env)"
else
  echo "rendered pipeline with:$vendors"
fi
