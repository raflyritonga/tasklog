.DEFAULT_GOAL := help

ENV_FILE = .env.datadog
KC = KUBECONFIG=./kubeconfig
LOAD_ENV = set -a; . ./$(ENV_FILE); set +a
COMPOSE = docker compose --env-file $(ENV_FILE)

.PHONY: help env-check docker docker-ghcr down k8s k8s-secrets k8s-config k8s-down load demo-latency demo-errors demo-cpu demo-reset

help:
	@echo "Tasklog (datadog branch) - app only, ready for Datadog instrumentation"
	@echo ""
	@echo "LOCAL"
	@echo "  docker         build and run app + nginx on docker compose (http://localhost:8000)"
	@echo "  docker-ghcr    same, from the published :datadog images"
	@echo "  down           stop the compose stack"
	@echo ""
	@echo "K3S             kubeconfig at ./kubeconfig"
	@echo "  k8s            deploy everything to the tasklog namespace"
	@echo "  k8s-down       delete the tasklog namespace"
	@echo ""
	@echo "DEMO            knobs in .env.datadog (APP_URL, K6_DURATION, DEMO_*)"
	@echo "  load           k6 load script"
	@echo "  demo-errors    inject 500s"
	@echo "  demo-latency   inject latency"
	@echo "  demo-cpu       burn cpu per request"
	@echo "  demo-reset     clear all levers"
	@echo ""
	@echo "See DATADOG.md for the instrumentation guide."

env-check:
	@test -f $(ENV_FILE) || { echo "$(ENV_FILE) not found: cp .env.datadog.example $(ENV_FILE) and fill it in"; exit 1; }

docker: env-check
	$(COMPOSE) up -d --build --wait

docker-ghcr: env-check
	$(COMPOSE) -f compose.yaml -f compose.ghcr.yaml pull
	$(COMPOSE) -f compose.yaml -f compose.ghcr.yaml up -d --wait

down: env-check
	$(COMPOSE) down --remove-orphans

k8s: env-check
	$(KC) kubectl apply -f deploy/k3s/01_namespace.yaml
	$(MAKE) k8s-secrets
	$(MAKE) k8s-config
	$(KC) kubectl -n tasklog delete job seed --ignore-not-found
	$(KC) kubectl apply -f deploy/k3s/
	$(KC) kubectl -n tasklog rollout restart deployment/nginx
	$(KC) kubectl -n tasklog rollout status deployment/api --timeout=180s
	$(KC) kubectl -n tasklog rollout status deployment/web --timeout=180s
	$(KC) kubectl -n tasklog rollout status deployment/report --timeout=120s
	$(KC) kubectl -n tasklog rollout status deployment/nginx --timeout=120s

k8s-secrets: env-check
	$(LOAD_ENV); \
	$(KC) kubectl -n tasklog create secret generic tasklog-db \
		--from-literal=POSTGRES_USER=$${POSTGRES_USER:-tasklog} \
		--from-literal=POSTGRES_PASSWORD=$${POSTGRES_PASSWORD:-tasklog} \
		--from-literal=POSTGRES_DB=$${POSTGRES_DB:-tasklog} \
		--from-literal=DATABASE_URL="postgres://$${POSTGRES_USER:-tasklog}:$${POSTGRES_PASSWORD:-tasklog}@pg:5432/$${POSTGRES_DB:-tasklog}?sslmode=disable" \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -

k8s-config:
	$(KC) kubectl -n tasklog create configmap pg-init --from-file=init.sql=deploy/postgres/init.sql --dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) kubectl -n tasklog create configmap nginx-conf --from-file=default.conf=deploy/nginx/default.conf --dry-run=client -o yaml | $(KC) kubectl apply -f -

k8s-down:
	$(KC) kubectl delete namespace tasklog --ignore-not-found

load: env-check
	$(LOAD_ENV); k6 run -e BASE_URL="$$APP_URL" -e DURATION="$$K6_DURATION" load/k6.js

demo-latency: env-check
	$(LOAD_ENV); curl -sS -X POST -H "content-type: application/json" -d "{\"ms\":$$DEMO_MS}" "$$APP_URL/api/demo/latency"

demo-errors: env-check
	$(LOAD_ENV); curl -sS -X POST -H "content-type: application/json" -d "{\"rate\":$$DEMO_RATE}" "$$APP_URL/api/demo/errors"

demo-cpu: env-check
	$(LOAD_ENV); curl -sS -X POST -H "content-type: application/json" -d "{\"ms\":$$DEMO_CPU_MS}" "$$APP_URL/api/demo/cpu"

demo-reset: env-check
	$(LOAD_ENV); curl -sS -X POST "$$APP_URL/api/demo/reset"
