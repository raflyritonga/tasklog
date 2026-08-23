.DEFAULT_GOAL := help

API_URL ?= http://localhost:8080
LOAD_URL ?= http://localhost:3000
K6_DURATION ?= 10m
DEMO_MS ?= 800
DEMO_RATE ?= 0.5

.PHONY: help docker-app docker-app-ghcr docker-grafana docker-datadog docker-o11y docker-seed docker-down k8s-cluster k8s-app k8s-o11y k8s-datadog k8s-secrets k8s-down load demo-latency demo-errors demo-reset dashboards

help:
	@echo "Tasklog — make targets"
	@echo ""
	@echo "DOCKER COMPOSE (local)"
	@echo "  docker-app         app only: pg, redis, api, web (local builds)"
	@echo "  docker-app-ghcr    app only, from published GHCR images"
	@echo "  docker-grafana     app + telemetry layer + grafana stack"
	@echo "  docker-datadog     app + telemetry layer + grafana + datadog agent"
	@echo "  docker-o11y        app + telemetry layer + every configured platform"
	@echo "  docker-seed        reseed the compose database"
	@echo "  docker-down        stop and remove the compose stack"
	@echo ""
	@echo "KUBERNETES (kind on the OrbStack VM)"
	@echo "  k8s-cluster        provision VM + kind + traefik + metrics-server (ansible)"
	@echo "  k8s-app            app manifests: namespace, secrets, pg, redis, api, web, ingress, seed"
	@echo "  k8s-o11y           telemetry layer + grafana stack (kube-prometheus, loki, tempo)"
	@echo "  k8s-datadog        datadog agent + database monitoring (needs DD_API_KEY)"
	@echo "  k8s-secrets        render k8s secrets from .env"
	@echo "  k8s-down           delete the tasklog and o11y namespaces"
	@echo ""
	@echo "EITHER TARGET (set API_URL / LOAD_URL to choose)"
	@echo "  load               k6 load script            (LOAD_URL=$(LOAD_URL))"
	@echo "  demo-latency       inject latency            (API_URL=$(API_URL))"
	@echo "  demo-errors        inject 500s"
	@echo "  demo-reset         clear all demo levers"
	@echo "  dashboards         push dashboards to the SaaS platforms"

docker-app:
	docker compose up -d --build --wait

docker-app-ghcr:
	docker compose -f compose.yaml -f compose.ghcr.yaml pull
	docker compose -f compose.yaml -f compose.ghcr.yaml up -d --wait

GRAFANA_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml
DATADOG_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml -f compose.datadog.yaml
O11Y_STACK = -f compose.yaml -f compose.telemetry.yaml -f compose.grafana.yaml -f compose.datadog.yaml

docker-grafana:
	bash deploy/o11y/render.sh
	docker compose $(GRAFANA_STACK) up -d --build --wait
	docker compose $(GRAFANA_STACK) up -d --force-recreate otel-collector vector

docker-datadog:
	bash deploy/o11y/render.sh
	set -a; [ -f .env ] && . ./.env; set +a; \
	case "$${DD_SITE:-}" in "") DD_SITE_FULL=datadoghq.com ;; *.*) DD_SITE_FULL=$${DD_SITE} ;; *) DD_SITE_FULL=$${DD_SITE}.datadoghq.com ;; esac; \
	export DD_SITE_FULL; \
	docker compose $(DATADOG_STACK) up -d --build --wait; \
	docker compose $(DATADOG_STACK) up -d --force-recreate otel-collector vector

docker-o11y:
	bash deploy/o11y/render.sh
	set -a; [ -f .env ] && . ./.env; set +a; \
	case "$${DD_SITE:-}" in "") DD_SITE_FULL=datadoghq.com ;; *.*) DD_SITE_FULL=$${DD_SITE} ;; *) DD_SITE_FULL=$${DD_SITE}.datadoghq.com ;; esac; \
	export DD_SITE_FULL; \
	docker compose $(O11Y_STACK) up -d --build --wait; \
	docker compose $(O11Y_STACK) up -d --force-recreate otel-collector vector

k8s-cluster:
	ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
	helm repo add traefik https://traefik.github.io/charts --force-update
	KUBECONFIG=./kubeconfig helm upgrade --install traefik traefik/traefik --version 41.3.0 --namespace traefik --create-namespace -f deploy/k8s/00_traefik/values.yaml --wait --timeout 5m
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
	KUBECONFIG=./kubeconfig helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace kube-system --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' --wait --timeout 5m

k8s-app:
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/01_namespace.yaml
	$(MAKE) k8s-secrets
	KUBECONFIG=./kubeconfig kubectl -n tasklog create configmap pg-init --from-file=init.sql=deploy/postgres/init.sql --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n tasklog delete job seed --ignore-not-found
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/api --timeout=180s
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/web --timeout=180s

k8s-o11y:
	bash deploy/o11y/render.sh
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/o11y/k8s/01_namespace.yaml
	set -a; [ -f .env ] && . ./.env; set +a; \
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic o11y-vendors \
		--from-literal=DD_API_KEY=$${DD_API_KEY:-} \
		--from-literal=DATADOG_API_KEY=$${DD_API_KEY:-} \
		--from-literal=DT_API_TOKEN=$${DT_API_TOKEN:-} \
		--from-literal=ELASTIC_APM_SECRET_TOKEN=$${ELASTIC_APM_SECRET_TOKEN:-} \
		--from-literal=ELASTIC_API_KEY=$${ELASTIC_API_KEY:-} \
		--dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap otel-collector --from-file=config.yaml=deploy/o11y/otel-collector/otel-collector-k8s.yaml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic vector-config --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y delete configmap vector --ignore-not-found
	set -a; [ -f .env ] && . ./.env; set +a; \
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic grafana-env --from-literal=PG_MONITOR_PASSWORD=$${PG_MONITOR_PASSWORD:-monitor} --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	KUBECONFIG=./kubeconfig helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 88.5.3 --namespace o11y -f deploy/o11y/kube-prometheus-stack/values.yaml --wait --timeout 10m
	KUBECONFIG=./kubeconfig helm upgrade --install loki grafana/loki --version 7.3.0 --namespace o11y -f deploy/o11y/loki/values-k8s.yaml --wait --timeout 10m
	KUBECONFIG=./kubeconfig helm upgrade --install tempo grafana/tempo --version 1.24.4 --namespace o11y -f deploy/o11y/tempo/values-k8s.yaml --wait --timeout 5m
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap grafana-datasources --from-file=datasources.yaml=deploy/o11y/grafana/provisioning-k8s/datasources.yaml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl label --local -f - grafana_datasource=1 -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap grafana-dashboards --from-file=app.json=deploy/o11y/grafana/provisioning-k8s/dashboard-app.json --from-file=infra.json=deploy/o11y/grafana/provisioning-k8s/dashboard-infra.json --from-file=data.json=deploy/o11y/grafana/provisioning-k8s/dashboard-data.json --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl label --local -f - grafana_dashboard=1 -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y delete configmap grafana-dashboard-golden --ignore-not-found
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap grafana-alerts --from-file=alerts.yaml=deploy/o11y/grafana/provisioning-k8s/alert-rules.yaml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl label --local -f - grafana_alert=1 -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/o11y/k8s/
	KUBECONFIG=./kubeconfig kubectl -n o11y rollout restart deployment/otel-collector daemonset/vector
	KUBECONFIG=./kubeconfig kubectl -n o11y rollout status deployment/otel-collector --timeout=180s
	KUBECONFIG=./kubeconfig kubectl -n o11y rollout status daemonset/vector --timeout=180s

k8s-datadog:
	set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$${DD_API_KEY:-}" ]; then echo "DD_API_KEY not set in .env - skipping datadog agent"; exit 0; fi; \
	case "$${DD_SITE:-}" in "") site=datadoghq.com ;; *.*) site=$${DD_SITE} ;; *) site=$${DD_SITE}.datadoghq.com ;; esac; \
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic datadog-secret --from-literal=api-key=$${DD_API_KEY} --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -; \
	helm repo add datadog https://helm.datadoghq.com --force-update; \
	sed "s|__DD_SITE_FULL__|$$site|" deploy/o11y/datadog/values.yaml > /tmp/tasklog-dd-values.yaml; \
	KUBECONFIG=./kubeconfig helm upgrade --install datadog datadog/datadog --version 3.240.0 --namespace o11y -f /tmp/tasklog-dd-values.yaml --set datadog.apiKeyExistingSecret=datadog-secret --wait --timeout 10m

docker-seed:
	docker compose exec pg psql -U tasklog -d tasklog -c "select seed_tasks();"

load:
	k6 run -e BASE_URL=$(LOAD_URL) -e DURATION=$(K6_DURATION) load/k6.js

demo-latency:
	curl -sS -X POST -H "content-type: application/json" -d '{"ms":$(DEMO_MS)}' $(API_URL)/api/demo/latency

demo-errors:
	curl -sS -X POST -H "content-type: application/json" -d '{"rate":$(DEMO_RATE)}' $(API_URL)/api/demo/errors

demo-reset:
	curl -sS -X POST $(API_URL)/api/demo/reset

dashboards:
	@echo "dashboards: not implemented yet (Stage C, phase 10)"

k8s-secrets:
	set -a; [ -f .env ] && . ./.env; set +a; \
	KUBECONFIG=./kubeconfig kubectl -n tasklog create secret generic tasklog-db \
		--from-literal=POSTGRES_USER=$${POSTGRES_USER:-tasklog} \
		--from-literal=POSTGRES_PASSWORD=$${POSTGRES_PASSWORD:-tasklog} \
		--from-literal=POSTGRES_DB=$${POSTGRES_DB:-tasklog} \
		--from-literal=DATABASE_URL="postgres://$${POSTGRES_USER:-tasklog}:$${POSTGRES_PASSWORD:-tasklog}@pg:5432/$${POSTGRES_DB:-tasklog}?sslmode=disable" \
		--dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	set -a; [ -f .env ] && . ./.env; set +a; \
	KUBECONFIG=./kubeconfig kubectl -n tasklog create secret generic web-rum \
		--from-literal=NUXT_PUBLIC_RUM_PROVIDER=$${NUXT_PUBLIC_RUM_PROVIDER:-none} \
		--from-literal=NUXT_PUBLIC_DD_SITE=$${DD_SITE:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_APP_ID=$${DD_RUM_APP_ID:-} \
		--from-literal=NUXT_PUBLIC_DD_RUM_CLIENT_TOKEN=$${DD_RUM_CLIENT_TOKEN:-} \
		--from-literal=NUXT_PUBLIC_DT_RUM_SCRIPT_URL=$${DT_RUM_SCRIPT_URL:-} \
		--from-literal=NUXT_PUBLIC_ELASTIC_APM_ENDPOINT=$${ELASTIC_APM_ENDPOINT:-} \
		--dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -

docker-down:
	set -a; [ -f .env ] && . ./.env; set +a; DD_SITE_FULL=$${DD_SITE:-datadoghq.com}; export DD_SITE_FULL; \
	docker compose $(O11Y_STACK) down --remove-orphans

k8s-down:
	KUBECONFIG=./kubeconfig kubectl delete namespace tasklog --ignore-not-found
	KUBECONFIG=./kubeconfig kubectl delete namespace o11y --ignore-not-found
