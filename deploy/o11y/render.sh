#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ -f ../../.env ]; then
  set -a
  . ../../.env
  set +a
fi

trace_exporters="otlp/tempo"
metric_exporters="prometheus"
vendors=""

cp otel-collector/snippets/base.yaml otel-collector/otel-collector.yaml
cp vector/snippets/base.toml vector/vector.toml

if [ -n "${DD_API_KEY:-}" ]; then
  cat otel-collector/snippets/exporter-datadog.yaml >> otel-collector/otel-collector.yaml
  cat vector/snippets/sink-datadog.toml >> vector/vector.toml
  trace_exporters="$trace_exporters, datadog"
  metric_exporters="$metric_exporters, datadog"
  vendors="$vendors datadog"
fi

if [ -n "${DT_TENANT_URL:-}" ] && [ -n "${DT_API_TOKEN:-}" ]; then
  cat otel-collector/snippets/exporter-dynatrace.yaml >> otel-collector/otel-collector.yaml
  trace_exporters="$trace_exporters, otlphttp/dynatrace"
  metric_exporters="$metric_exporters, otlphttp/dynatrace"
  vendors="$vendors dynatrace"
fi

if [ -n "${ELASTIC_APM_ENDPOINT:-}" ]; then
  cat otel-collector/snippets/exporter-elastic.yaml >> otel-collector/otel-collector.yaml
  trace_exporters="$trace_exporters, otlphttp/elastic"
  metric_exporters="$metric_exporters, otlphttp/elastic"
  vendors="$vendors elastic-apm"
fi

if [ -n "${ELASTIC_ES_ENDPOINT:-}" ] && [ -n "${ELASTIC_API_KEY:-}" ]; then
  cat vector/snippets/sink-elastic.toml >> vector/vector.toml
  vendors="$vendors elastic-logs"
fi

cat >> otel-collector/otel-collector.yaml <<EOF

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
      processors: [batch]
      exporters: [$trace_exporters]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [$metric_exporters]
EOF

dd_site="${DD_SITE:-}"
case "$dd_site" in
  "") dd_site_full="datadoghq.com" ;;
  *.*) dd_site_full="$dd_site" ;;
  *) dd_site_full="$dd_site.datadoghq.com" ;;
esac

sed -i '' \
  -e "s|__DD_SITE_FULL__|$dd_site_full|g" \
  -e "s|__DT_TENANT_URL__|${DT_TENANT_URL:-}|g" \
  -e "s|__ELASTIC_APM_ENDPOINT__|${ELASTIC_APM_ENDPOINT:-}|g" \
  otel-collector/otel-collector.yaml

sed -i '' \
  -e "s|__DD_SITE_FULL__|$dd_site_full|g" \
  -e "s|__ELASTIC_ES_ENDPOINT__|${ELASTIC_ES_ENDPOINT:-}|g" \
  vector/vector.toml

if [ -z "$vendors" ]; then
  echo "rendered grafana-only pipeline (no SaaS credentials in .env)"
else
  echo "rendered pipeline with:$vendors"
fi
