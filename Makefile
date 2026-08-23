.DEFAULT_GOAL := help

API_URL ?= http://localhost:8080
LOAD_URL ?= http://localhost:3000
K6_DURATION ?= 10m
DEMO_MS ?= 800
DEMO_RATE ?= 0.5

.PHONY: help dev dev-ghcr o11y-up up deploy deploy-o11y deploy-datadog seed load demo-latency demo-errors demo-reset dashboards secrets down

help:
	@echo "Tasklog"
	@echo ""
	@echo "  make dev           app stack on docker compose (local builds)"
	@echo "  make dev-ghcr      app stack on docker compose (GHCR images)"
	@echo "  make o11y-up       observability pipeline on docker compose"
	@echo "  make up            OrbStack VM + kind cluster + ingress (ansible)"
	@echo "  make deploy        app + pipeline onto the kind cluster"
	@echo "  make deploy-o11y   observability stack onto the kind cluster"
	@echo "  make deploy-datadog datadog agent onto the kind cluster (needs DD_API_KEY)"
	@echo "  make seed          seed database with sample tasks"
	@echo "  make load          k6 load script against the app"
	@echo "  make demo-latency  inject latency into /api/tasks*"
	@echo "  make demo-errors   inject errors into /api/tasks*"
	@echo "  make demo-reset    clear both demo levers"
	@echo "  make dashboards    push dashboards to SaaS platforms"
	@echo "  make secrets       render k8s secrets from .env"
	@echo "  make down          stop and remove everything"

dev:
	docker compose up -d --build --wait

dev-ghcr:
	docker compose -f compose.yaml -f compose.ghcr.yaml pull
	docker compose -f compose.yaml -f compose.ghcr.yaml up -d --wait

o11y-up:
	bash deploy/o11y/render.sh
	docker compose -f compose.yaml -f compose.o11y.yaml up -d --build --wait

up:
	ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
	helm repo add traefik https://traefik.github.io/charts --force-update
	KUBECONFIG=./kubeconfig helm upgrade --install traefik traefik/traefik --version 41.3.0 --namespace traefik --create-namespace -f deploy/k8s/00_traefik/values.yaml --wait --timeout 5m
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
	KUBECONFIG=./kubeconfig helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace kube-system --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' --wait --timeout 5m

deploy:
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/01_namespace.yaml
	$(MAKE) secrets
	KUBECONFIG=./kubeconfig kubectl -n tasklog create configmap pg-init --from-file=init.sql=deploy/postgres/init.sql --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n tasklog delete job seed --ignore-not-found
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/api --timeout=180s
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/web --timeout=180s

deploy-o11y:
	bash deploy/o11y/render.sh
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/o11y/k8s/01_namespace.yaml
	set -a; [ -f .env ] && . ./.env; set +a; \
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic o11y-vendors \
		--from-literal=DD_API_KEY=$${DD_API_KEY:-} \
		--from-literal=DT_API_TOKEN=$${DT_API_TOKEN:-} \
		--from-literal=ELASTIC_APM_SECRET_TOKEN=$${ELASTIC_APM_SECRET_TOKEN:-} \
		--from-literal=ELASTIC_API_KEY=$${ELASTIC_API_KEY:-} \
		--dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap otel-collector --from-file=config.yaml=deploy/o11y/otel-collector/otel-collector-k8s.yaml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl -n o11y create configmap vector --from-file=vector.toml=deploy/o11y/vector/vector-k8s.toml --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
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

deploy-datadog:
	set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$${DD_API_KEY:-}" ]; then echo "DD_API_KEY not set in .env - skipping datadog agent"; exit 0; fi; \
	case "$${DD_SITE:-}" in "") site=datadoghq.com ;; *.*) site=$${DD_SITE} ;; *) site=$${DD_SITE}.datadoghq.com ;; esac; \
	KUBECONFIG=./kubeconfig kubectl -n o11y create secret generic datadog-secret --from-literal=api-key=$${DD_API_KEY} --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -; \
	helm repo add datadog https://helm.datadoghq.com --force-update; \
	sed "s|__DD_SITE_FULL__|$$site|" deploy/o11y/datadog/values.yaml > /tmp/tasklog-dd-values.yaml; \
	KUBECONFIG=./kubeconfig helm upgrade --install datadog datadog/datadog --version 3.240.0 --namespace o11y -f /tmp/tasklog-dd-values.yaml --set datadog.apiKeyExistingSecret=datadog-secret --wait --timeout 10m

seed:
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

secrets:
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

down:
	docker compose -f compose.yaml -f compose.o11y.yaml down --remove-orphans
