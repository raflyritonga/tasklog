.DEFAULT_GOAL := help

-include make.env

KC = KUBECONFIG=./kubeconfig
GRAFANA_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml
O11Y_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml -f compose.datadog.yaml

DD_SITE_SHELL = case "$${DD_SITE:-}" in "") DD_SITE_FULL=datadoghq.com ;; *.*) DD_SITE_FULL=$${DD_SITE} ;; *) DD_SITE_FULL=$${DD_SITE}.datadoghq.com ;; esac; export DD_SITE_FULL

.PHONY: help docker k8s cluster tf clean reset down datadog-tf-plan datadog-tf-apply k8s-elastic-bootstrap docker-grafana docker-o11y docker-down k8s-cluster k8s-app k8s-o11y k8s-o11y-wire k8s-elastic k8s-datadog k8s-dt-oneagent k8s-down k8s-reset k8s-secrets load demo-latency demo-errors demo-cpu demo-reset

help:
	@echo "Tasklog"
	@echo ""
	@echo "SETUP"
	@echo "  cluster        provision the VM + kind + traefik + metrics-server (once)"
	@echo "  docker         full stack on docker compose"
	@echo "  k8s            full stack on kubernetes, in the right order"
	@echo "  tf             datadog monitors + dashboard via terraform"
	@echo ""
	@echo "DEMO           point at a stage with API_URL / LOAD_URL"
	@echo "  load           k6 load script"
	@echo "  demo-errors    inject 500s"
	@echo "  demo-latency   inject latency"
	@echo "  demo-reset     clear all levers"
	@echo ""
	@echo "TEARDOWN"
	@echo "  down           stop the compose stack"
	@echo "  clean          delete the tasklog and o11y namespaces"
	@echo "  reset          destroy the kind cluster and rebuild it empty"
	@echo ""
	@echo "Granular targets exist for each component - see README."

docker: docker-o11y

k8s:
	$(MAKE) k8s-app
	$(MAKE) k8s-o11y
	$(MAKE) k8s-elastic
	$(MAKE) k8s-o11y-wire
	$(MAKE) k8s-elastic-bootstrap
	$(MAKE) k8s-datadog
	@echo ""
	@echo "app      http://tasklog-demo.orb.local"
	@echo "grafana  http://grafana.tasklog-demo.orb.local"
	@echo "kibana   http://kibana.tasklog-demo.orb.local"

cluster: k8s-cluster

tf: datadog-tf-apply

clean: k8s-down

reset: k8s-reset

down: docker-down

docker-grafana:
	bash deploy/o11y/render.sh
	docker compose $(GRAFANA_STACK) up -d --build --wait
	docker compose $(GRAFANA_STACK) up -d --force-recreate otel-collector vector

docker-o11y:
	bash deploy/o11y/render.sh
	set -a; [ -f .env ] && . ./.env; set +a; \
	$(DD_SITE_SHELL); \
	docker compose $(O11Y_STACK) up -d --build --wait; \
	docker compose $(O11Y_STACK) up -d --force-recreate otel-collector vector

docker-down:
	set -a; [ -f .env ] && . ./.env; set +a; DD_SITE_FULL=$${DD_SITE:-datadoghq.com}; export DD_SITE_FULL; \
	docker compose $(O11Y_STACK) down --remove-orphans

k8s-cluster:
	ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
	helm repo add traefik https://traefik.github.io/charts --force-update
	$(KC) helm upgrade --install traefik traefik/traefik --version 41.3.0 --namespace traefik --create-namespace -f deploy/k8s/00_traefik/values.yaml --wait --timeout 5m
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
	$(KC) helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace kube-system --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' --wait --timeout 5m

k8s-app:
	$(KC) kubectl apply -f deploy/k8s/01_namespace.yaml
	$(MAKE) k8s-secrets
	$(KC) kubectl -n tasklog create configmap pg-init --from-file=init.sql=deploy/postgres/init.sql --dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n tasklog delete job seed --ignore-not-found
	$(KC) kubectl apply -f deploy/k8s/
	$(KC) kubectl -n tasklog rollout status deployment/api --timeout=180s
	$(KC) kubectl -n tasklog rollout status deployment/web --timeout=180s

k8s-o11y:
	bash deploy/o11y/render.sh
	$(KC) kubectl apply -f deploy/o11y/k8s/01_namespace.yaml
	set -a; [ -f .env ] && . ./.env; set +a; \
	$(KC) kubectl -n o11y create secret generic o11y-vendors \
		--from-literal=DD_API_KEY=$${DD_API_KEY:-} \
		--from-literal=DT_API_TOKEN=$${DT_API_TOKEN:-} \
		--from-literal=ELASTIC_APM_SECRET_TOKEN=$${ELASTIC_APM_SECRET_TOKEN:-} \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -
	set -a; [ -f .env ] && . ./.env; set +a; \
	$(KC) kubectl -n o11y create secret generic grafana-env --from-literal=PG_MONITOR_PASSWORD=$${PG_MONITOR_PASSWORD:-monitor} --dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y delete configmap otel-collector --ignore-not-found
	$(KC) kubectl -n o11y create secret generic otel-collector --from-file=config.yaml=deploy/o11y/otel-collector/otel-collector-k8s.yaml --dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	[ -f deploy/o11y/otel-collector/otel-agent-k8s.yaml ] && $(KC) kubectl -n o11y create secret generic otel-agent --from-file=config.yaml=deploy/o11y/otel-collector/otel-agent-k8s.yaml --dry-run=client -o yaml | $(KC) kubectl apply -f - || true
	$(KC) kubectl -n o11y create secret generic vector-config --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | $(KC) kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	$(KC) helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 88.5.3 --namespace o11y -f deploy/o11y/kube-prometheus-stack/values.yaml --wait --timeout 10m
	$(KC) helm upgrade --install loki grafana/loki --version 7.3.0 --namespace o11y -f deploy/o11y/loki/values-k8s.yaml --wait --timeout 10m
	$(KC) kubectl -n o11y delete statefulset tempo --ignore-not-found --cascade=foreground
	$(KC) helm upgrade --install tempo grafana/tempo --version 1.24.4 --namespace o11y -f deploy/o11y/tempo/values-k8s.yaml --wait --timeout 5m
	$(KC) kubectl -n o11y create configmap grafana-datasources --from-file=datasources.yaml=deploy/o11y/grafana/provisioning-k8s/datasources.yaml --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_datasource=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y create configmap grafana-dashboards --from-file=app.json=deploy/o11y/grafana/provisioning-k8s/dashboard-app.json --from-file=infra.json=deploy/o11y/grafana/provisioning-k8s/dashboard-infra.json --from-file=data.json=deploy/o11y/grafana/provisioning-k8s/dashboard-data.json --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_dashboard=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y create configmap grafana-alerts --from-file=alerts.yaml=deploy/o11y/grafana/provisioning-k8s/alert-rules.yaml --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_alert=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl apply -f deploy/o11y/k8s/
	$(KC) kubectl -n o11y rollout restart deployment/otel-collector daemonset/vector
	-$(KC) kubectl -n o11y rollout restart daemonset/otel-agent
	$(KC) kubectl -n o11y rollout status deployment/otel-collector --timeout=180s
	$(KC) kubectl -n o11y rollout status daemonset/vector --timeout=180s

k8s-elastic:
	$(KC) kubectl apply -f deploy/o11y/k8s/01_namespace.yaml
	helm repo add elastic https://helm.elastic.co --force-update
	$(KC) helm upgrade --install eck-operator elastic/eck-operator --version 3.5.0 --namespace elastic-system --create-namespace --wait --timeout 5m
	$(KC) kubectl apply -f deploy/o11y/elastic/k8s/
	$(KC) kubectl -n o11y wait --for=jsonpath='{.status.phase}'=Ready elasticsearch/elasticsearch --timeout=600s
	$(KC) kubectl -n o11y wait --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=600s
	$(MAKE) k8s-o11y-wire

k8s-o11y-wire:
	set -a; [ -f .env ] && . ./.env; set +a; \
	ELASTIC_ES_ENDPOINT_K8S=http://elasticsearch-es-http.o11y.svc:9200; \
	ELASTIC_APM_ENDPOINT_K8S=http://apm-apm-http.o11y.svc:8200; \
	ELASTIC_ES_USER=elastic; \
	ELASTIC_ES_PASSWORD=$$($(KC) kubectl -n o11y get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'); \
	export ELASTIC_ES_ENDPOINT_K8S ELASTIC_APM_ENDPOINT_K8S ELASTIC_ES_USER ELASTIC_ES_PASSWORD; \
	bash deploy/o11y/render.sh; \
	$(KC) kubectl -n o11y create secret generic vector-config --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	$(KC) kubectl -n o11y create secret generic otel-collector --from-file=config.yaml=deploy/o11y/otel-collector/otel-collector-k8s.yaml --dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	[ -f deploy/o11y/otel-collector/otel-agent-k8s.yaml ] && $(KC) kubectl -n o11y create secret generic otel-agent --from-file=config.yaml=deploy/o11y/otel-collector/otel-agent-k8s.yaml --dry-run=client -o yaml | $(KC) kubectl apply -f - || true
	set -a; [ -f .env ] && . ./.env; set +a; \
	ESPW=$$($(KC) kubectl -n o11y get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'); \
	$(KC) kubectl -n o11y create secret generic grafana-env \
		--from-literal=PG_MONITOR_PASSWORD=$${PG_MONITOR_PASSWORD:-monitor} \
		--from-literal=ELASTIC_ES_PASSWORD=$$ESPW \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y rollout restart deployment/otel-collector daemonset/vector
	-$(KC) kubectl -n o11y rollout restart daemonset/otel-agent
	$(KC) kubectl -n o11y rollout status deployment/otel-collector --timeout=180s
	$(KC) kubectl -n o11y rollout status daemonset/vector --timeout=180s
	$(KC) kubectl -n o11y create configmap grafana-datasources --from-file=datasources.yaml=deploy/o11y/grafana/provisioning-k8s/datasources.yaml --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_datasource=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y rollout restart daemonset/vector deployment/kps-grafana
	$(KC) kubectl -n o11y rollout status daemonset/vector --timeout=180s

k8s-elastic-bootstrap:
	ESAUTH="elastic:$$($(KC) kubectl -n o11y get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')"; \
	KIBANA_URL=http://kibana.tasklog-demo.orb.local ESAUTH="$$ESAUTH" bash deploy/o11y/elastic/kibana-cleanup.sh; \
	$(KC) kubectl -n o11y exec -i statefulset/elasticsearch-es-default -c elasticsearch -- \
		curl -sS -u "$$ESAUTH" -X PUT -H 'Content-Type: application/json' "http://localhost:9200/logs-tasklog*,traces-tasklog*,metrics-tasklog*/_settings" \
		-d '{"index":{"refresh_interval":"1s"}}'; \
	echo; \
	$(KC) kubectl -n o11y exec -i statefulset/elasticsearch-es-default -c elasticsearch -- \
		curl -sS -u "$$ESAUTH" -X PUT "http://localhost:9200/_ingest/pipeline/tasklog-logs" \
		-H 'Content-Type: application/json' --data-binary @- < deploy/o11y/elastic/ingest-pipeline.json; \
	echo; \
	$(KC) kubectl -n o11y exec -i statefulset/elasticsearch-es-default -c elasticsearch -- \
		curl -sS -u "$$ESAUTH" -X PUT "http://localhost:9200/_ingest/pipeline/tasklog-otel-apm-compat" \
		-H 'Content-Type: application/json' --data-binary @- < deploy/o11y/elastic/apm-compat-pipeline.json; \
	echo; \
	$(KC) kubectl -n o11y exec -i statefulset/elasticsearch-es-default -c elasticsearch -- \
		curl -sS -u "$$ESAUTH" -X PUT "http://localhost:9200/_component_template/traces-otel@custom" \
		-H 'Content-Type: application/json' --data-binary @- < deploy/o11y/elastic/traces-otel-custom-template.json; \
	echo; \
	$(KC) kubectl -n o11y exec -i statefulset/elasticsearch-es-default -c elasticsearch -- sh -c \
		'curl -sS -u "'$$ESAUTH'" "http://localhost:9200/traces-tasklog.otel-default/_settings" | grep -q tasklog-otel-apm-compat || curl -sS -u "'$$ESAUTH'" -X POST "http://localhost:9200/traces-tasklog.otel-default/_rollover"' || true; \
	echo; \
	curl -sS -u "$$ESAUTH" -X POST "http://kibana.tasklog-demo.orb.local/api/saved_objects/_import?overwrite=true" \
		-H 'kbn-xsrf: true' -F file=@deploy/o11y/elastic/kibana-objects.ndjson; \
	echo; \
	curl -sS -u "$$ESAUTH" -X POST "http://kibana.tasklog-demo.orb.local/api/saved_objects/_import?overwrite=true" \
		-H 'kbn-xsrf: true' -F file=@deploy/o11y/elastic/kibana-objects-traces.ndjson; \
	echo; \
	resp=$$(curl -sS -u "$$ESAUTH" -X POST "http://kibana.tasklog-demo.orb.local/api/detection_engine/rules" \
		-H 'kbn-xsrf: true' -H 'Content-Type: application/json' --data-binary @deploy/o11y/elastic/security-detection-rule.json); \
	echo "$$resp" | grep -q "already exists" && curl -sS -u "$$ESAUTH" -X PUT "http://kibana.tasklog-demo.orb.local/api/detection_engine/rules" \
		-H 'kbn-xsrf: true' -H 'Content-Type: application/json' --data-binary @deploy/o11y/elastic/security-detection-rule.json > /dev/null || true; \
	echo

k8s-datadog:
	set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$${DD_API_KEY:-}" ]; then echo "DD_API_KEY not set in .env - skipping datadog agent"; exit 0; fi; \
	$(DD_SITE_SHELL); \
	$(KC) kubectl -n o11y create secret generic datadog-secret --from-literal=api-key=$${DD_API_KEY} --dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	helm repo add datadog https://helm.datadoghq.com --force-update; \
	sed -e "s|__DD_SITE_FULL__|$$DD_SITE_FULL|" -e "s|__DEPLOY_ENV__|$${DEPLOY_ENV:-dev}|" deploy/o11y/datadog/values.yaml > /tmp/tasklog-dd-values.yaml; \
	$(KC) helm upgrade --install datadog datadog/datadog --version 3.240.0 --namespace o11y -f /tmp/tasklog-dd-values.yaml --set datadog.apiKeyExistingSecret=datadog-secret --wait --timeout 10m

k8s-dt-oneagent:
	set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$${DT_TENANT_URL:-}" ] || [ -z "$${DT_OPERATOR_TOKEN:-}" ]; then echo "DT_TENANT_URL or DT_OPERATOR_TOKEN not set in .env - skipping dynatrace oneagent"; exit 0; fi; \
	$(KC) helm upgrade dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator --version 1.10.2 --create-namespace --namespace dynatrace --install --atomic --timeout 10m; \
	$(KC) kubectl -n dynatrace create secret generic tasklog \
		--from-literal=apiToken=$${DT_OPERATOR_TOKEN} \
		--from-literal=dataIngestToken=$${DT_API_TOKEN:-} \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	sed "s|__DT_API_URL__|$${DT_TENANT_URL}/api|" deploy/o11y/dynatrace/oneagent/dynakube.yaml | $(KC) kubectl apply -f -; \
	$(KC) kubectl label namespace tasklog dynatrace-inject=enabled --overwrite; \
	$(KC) kubectl -n tasklog apply -f deploy/k8s/05_web.yaml; \
	$(KC) kubectl -n tasklog rollout restart deployment/web; \
	$(KC) kubectl -n tasklog rollout status deployment/web --timeout=180s

k8s-secrets:
	set -a; [ -f .env ] && . ./.env; set +a; \
	$(KC) kubectl -n tasklog create secret generic tasklog-db \
		--from-literal=POSTGRES_USER=$${POSTGRES_USER:-tasklog} \
		--from-literal=POSTGRES_PASSWORD=$${POSTGRES_PASSWORD:-tasklog} \
		--from-literal=POSTGRES_DB=$${POSTGRES_DB:-tasklog} \
		--from-literal=DATABASE_URL="postgres://$${POSTGRES_USER:-tasklog}:$${POSTGRES_PASSWORD:-tasklog}@pg:5432/$${POSTGRES_DB:-tasklog}?sslmode=disable" \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -
	set -a; [ -f .env ] && . ./.env; set +a; \
	$(KC) kubectl -n tasklog create secret generic web-rum \
		--from-literal=NUXT_PUBLIC_RUM_PROVIDER=$${NUXT_PUBLIC_RUM_PROVIDER:-datadog} \
		--from-literal=NUXT_PUBLIC_DD_SITE=$${DD_SITE:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_APP_ID=$${DD_RUM_APP_ID:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_CLIENT_TOKEN=$${DD_RUM_CLIENT_TOKEN:-} \
		--from-literal=NUXT_PUBLIC_DT_RUM_SCRIPT_URL=$${DT_RUM_SCRIPT_URL:-} \
		--from-literal=NUXT_PUBLIC_ELASTIC_APM_ENDPOINT=$${ELASTIC_RUM_ENDPOINT:-} \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -

k8s-down:
	$(KC) kubectl delete namespace tasklog --ignore-not-found
	$(KC) kubectl delete namespace o11y --ignore-not-found

k8s-reset:
	ssh tasklog-demo@orb sudo kind delete cluster --name tasklog
	$(MAKE) k8s-cluster

TF_ENV = set -a; [ -f .env ] && . ./.env; set +a; \
	case "$${DD_SITE:-}" in "") site=datadoghq.com ;; *.*) site=$${DD_SITE} ;; *) site=$${DD_SITE}.datadoghq.com ;; esac; \
	export TF_VAR_dd_api_key=$${DD_API_KEY} TF_VAR_dd_app_key=$${DD_APP_KEY} TF_VAR_dd_site=$$site; \
	export TF_VAR_elastic_password=$$($(KC) kubectl -n o11y get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}' 2>/dev/null || echo ""); \
	export TF_VAR_dt_tenant_url=$${DT_TENANT_URL:-} TF_VAR_dt_api_token=$${DT_SETTINGS_TOKEN:-$${DT_API_TOKEN:-}}; \
	export TF_VAR_dt_platform_token=$${DT_PLATFORM_TOKEN:-} TF_VAR_dt_actor_uuid=$${DT_ACTOR_UUID:-}

datadog-tf-plan:
	$(TF_ENV); terraform -chdir=terraform init -input=false && terraform -chdir=terraform plan

datadog-tf-apply:
	$(TF_ENV); terraform -chdir=terraform init -input=false && terraform -chdir=terraform apply -auto-approve

load:
	k6 run -e BASE_URL=$(LOAD_URL) -e DURATION=$(K6_DURATION) load/k6.js

demo-latency:
	curl -sS -X POST -H "content-type: application/json" -d '{"ms":$(DEMO_MS)}' $(API_URL)/api/demo/latency

demo-errors:
	curl -sS -X POST -H "content-type: application/json" -d '{"rate":$(DEMO_RATE)}' $(API_URL)/api/demo/errors

demo-cpu:
	curl -sS -X POST -H "content-type: application/json" -d '{"ms":$(DEMO_CPU_MS)}' $(API_URL)/api/demo/cpu

demo-reset:
	curl -sS -X POST $(API_URL)/api/demo/reset
