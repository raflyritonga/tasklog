#!/usr/bin/env bash
set -euo pipefail

kb() { curl -sS -u "$ESAUTH" -H 'kbn-xsrf: true' "$@"; }

echo "removing managed dashboard packs (keeping Kubernetes/system OTel - the agent feeds them now)..."
kb "$KIBANA_URL/api/saved_objects/_find?type=dashboard&per_page=100&fields=title" \
  | python3 -c '
import json,sys
for o in json.load(sys.stdin)["saved_objects"]:
    keep = o["id"].startswith("tasklog") or o["id"].startswith("kubernetes_otel") or o["id"].startswith("system_otel") or o["id"].startswith("otel")
    if not keep:
        print(o["id"])' \
  | while read -r id; do
      kb -X DELETE "$KIBANA_URL/api/saved_objects/dashboard/$id?force=true" > /dev/null || true
      echo "  deleted dashboard $id"
    done

echo "removing clutter data views..."
for dv in kibana-event-log-data-view security-solution-attack-default \
          security-solution-alert-default security-solution-default \
          cases-analytics-managed-default 'logs-*' 'metrics-*'; do
  kb -X DELETE "$KIBANA_URL/api/data_views/data_view/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$dv")" > /dev/null 2>&1 || true
  echo "  removed $dv (or already absent)"
done
echo "kept: APM static data view (the Applications UI reads it)"
