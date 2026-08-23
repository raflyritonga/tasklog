.DEFAULT_GOAL := help

API_URL ?= http://localhost:8080
LOAD_URL ?= http://localhost:3000
K6_DURATION ?= 10m
DEMO_MS ?= 800
DEMO_RATE ?= 0.5

KC = KUBECONFIG=./kubeconfig
GRAFANA_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml
O11Y_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml -f compose.datadog.yaml

DD_SITE_SHELL = case "$${DD_SITE:-}" in "") DD_SITE_FULL=datadoghq.com ;; *.*) DD_SITE_FULL=$${DD_SITE} ;; *) DD_SITE_FULL=$${DD_SITE}.datadoghq.com ;; esac; export DD_SITE_FULL

.PHONY: help docker-grafana docker-o11y docker-down k8s-cluster k8s-app k8s-o11y k8s-elastic k8s-datadog k8s-down k8s-reset k8s-secrets k8s-elastic-wire load demo-latency demo-errors demo-reset

help:
	@echo "Tasklog"
	@echo ""
	@echo "DOCKER COMPOSE"
	@echo "  docker-grafana   app + telemetry + grafana stack (works with an empty .env)"
	@echo "  docker-o11y      app + telemetry + every configured platform"
	@echo "  docker-down      stop and remove the compose stack"
	@echo ""
	@echo "KUBERNETES  (run in this order)"
	@echo "  k8s-cluster      VM + kind + traefik + metrics-server (ansible)"
	@echo "  k8s-app          app: secrets, pg, redis, api, web, ingress, seed"
	@echo "  k8s-o11y         telemetry + grafana stack (kube-prometheus, loki, tempo)"
	@echo "  k8s-elastic      self-hosted elasticsearch + kibana (ECK)"
	@echo "  k8s-datadog      datadog agent + database monitoring"
	@echo "  k8s-down         delete the tasklog and o11y namespaces"
	@echo "  k8s-reset        destroy the kind cluster and rebuild it empty"
	@echo ""
	@echo "DEMO  (point at either stage with API_URL / LOAD_URL)"
	@echo "  load             k6 load script            LOAD_URL=$(LOAD_URL)"
	@echo "  demo-latency     inject latency            API_URL=$(API_URL)"
	@echo "  demo-errors      inject 500s"
	@echo "  demo-reset       clear all levers"

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
	$(KC) kubectl -n o11y create configmap otel-collector --from-file=config.yaml=deploy/o11y/otel-collector/otel-collector-k8s.yaml --dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y create secret generic vector-config --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | $(KC) kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	$(KC) helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 88.5.3 --namespace o11y -f deploy/o11y/kube-prometheus-stack/values.yaml --wait --timeout 10m
	$(KC) helm upgrade --install loki grafana/loki --version 7.3.0 --namespace o11y -f deploy/o11y/loki/values-k8s.yaml --wait --timeout 10m
	$(KC) helm upgrade --install tempo grafana/tempo --version 1.24.4 --namespace o11y -f deploy/o11y/tempo/values-k8s.yaml --wait --timeout 5m
	$(KC) kubectl -n o11y create configmap grafana-datasources --from-file=datasources.yaml=deploy/o11y/grafana/provisioning-k8s/datasources.yaml --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_datasource=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y create configmap grafana-dashboards --from-file=app.json=deploy/o11y/grafana/provisioning-k8s/dashboard-app.json --from-file=infra.json=deploy/o11y/grafana/provisioning-k8s/dashboard-infra.json --from-file=data.json=deploy/o11y/grafana/provisioning-k8s/dashboard-data.json --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_dashboard=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y create configmap grafana-alerts --from-file=alerts.yaml=deploy/o11y/grafana/provisioning-k8s/alert-rules.yaml --dry-run=client -o yaml | $(KC) kubectl label --local -f - grafana_alert=1 -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl apply -f deploy/o11y/k8s/
	$(KC) kubectl -n o11y rollout restart deployment/otel-collector daemonset/vector
	$(KC) kubectl -n o11y rollout status deployment/otel-collector --timeout=180s
	$(KC) kubectl -n o11y rollout status daemonset/vector --timeout=180s

k8s-elastic:
	$(KC) kubectl apply -f deploy/o11y/k8s/01_namespace.yaml
	helm repo add elastic https://helm.elastic.co --force-update
	$(KC) helm upgrade --install eck-operator elastic/eck-operator --version 3.5.0 --namespace elastic-system --create-namespace --wait --timeout 5m
	$(KC) kubectl apply -f deploy/o11y/elastic/k8s/
	$(KC) kubectl -n o11y wait --for=jsonpath='{.status.phase}'=Ready elasticsearch/elasticsearch --timeout=600s
	$(KC) kubectl -n o11y wait --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=600s
	$(MAKE) k8s-elastic-wire

k8s-elastic-wire:
	set -a; [ -f .env ] && . ./.env; set +a; \
	ELASTIC_ES_ENDPOINT_K8S=http://elasticsearch-es-http.o11y.svc:9200; \
	ELASTIC_ES_USER=elastic; \
	ELASTIC_ES_PASSWORD=$$($(KC) kubectl -n o11y get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'); \
	export ELASTIC_ES_ENDPOINT_K8S ELASTIC_ES_USER ELASTIC_ES_PASSWORD; \
	bash deploy/o11y/render.sh; \
	$(KC) kubectl -n o11y create secret generic vector-config --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n o11y rollout restart daemonset/vector
	$(KC) kubectl -n o11y rollout status daemonset/vector --timeout=180s

k8s-datadog:
	set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$${DD_API_KEY:-}" ]; then echo "DD_API_KEY not set in .env - skipping datadog agent"; exit 0; fi; \
	$(DD_SITE_SHELL); \
	$(KC) kubectl -n o11y create secret generic datadog-secret --from-literal=api-key=$${DD_API_KEY} --dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	helm repo add datadog https://helm.datadoghq.com --force-update; \
	sed "s|__DD_SITE_FULL__|$$DD_SITE_FULL|" deploy/o11y/datadog/values.yaml > /tmp/tasklog-dd-values.yaml; \
	$(KC) helm upgrade --install datadog datadog/datadog --version 3.240.0 --namespace o11y -f /tmp/tasklog-dd-values.yaml --set datadog.apiKeyExistingSecret=datadog-secret --wait --timeout 10m

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
		--from-literal=NUXT_PUBLIC_RUM_PROVIDER=$${NUXT_PUBLIC_RUM_PROVIDER:-none} \
		--from-literal=NUXT_PUBLIC_DD_SITE=$${DD_SITE:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_APP_ID=$${DD_RUM_APP_ID:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_CLIENT_TOKEN=$${DD_RUM_CLIENT_TOKEN:-} \
		--from-literal=NUXT_PUBLIC_DT_RUM_SCRIPT_URL=$${DT_RUM_SCRIPT_URL:-} \
		--from-literal=NUXT_PUBLIC_ELASTIC_APM_ENDPOINT=$${ELASTIC_APM_ENDPOINT:-} \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -

k8s-down:
	$(KC) kubectl delete namespace tasklog --ignore-not-found
	$(KC) kubectl delete namespace o11y --ignore-not-found

k8s-reset:
	ssh tasklog-demo@orb sudo kind delete cluster --name tasklog
	$(MAKE) k8s-cluster

load:
	k6 run -e BASE_URL=$(LOAD_URL) -e DURATION=$(K6_DURATION) load/k6.js

demo-latency:
	curl -sS -X POST -H "content-type: application/json" -d '{"ms":$(DEMO_MS)}' $(API_URL)/api/demo/latency

demo-errors:
	curl -sS -X POST -H "content-type: application/json" -d '{"rate":$(DEMO_RATE)}' $(API_URL)/api/demo/errors

demo-reset:
	curl -sS -X POST $(API_URL)/api/demo/reset
