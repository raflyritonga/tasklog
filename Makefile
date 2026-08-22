.DEFAULT_GOAL := help

API_URL ?= http://localhost:8080
LOAD_URL ?= http://localhost:3000
K6_DURATION ?= 10m
DEMO_MS ?= 800
DEMO_RATE ?= 0.5

.PHONY: help dev dev-ghcr o11y-up up deploy seed load demo-latency demo-errors demo-reset dashboards secrets down

help:
	@echo "Tasklog"
	@echo ""
	@echo "  make dev           app stack on docker compose (local builds)"
	@echo "  make dev-ghcr      app stack on docker compose (GHCR images)"
	@echo "  make o11y-up       observability pipeline on docker compose"
	@echo "  make up            OrbStack VM + kind cluster + ingress (ansible)"
	@echo "  make deploy        app + pipeline onto the kind cluster"
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

deploy:
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/01_namespace.yaml
	$(MAKE) secrets
	KUBECONFIG=./kubeconfig kubectl -n tasklog create configmap pg-init --from-file=init.sql=deploy/postgres/init.sql --dry-run=client -o yaml | KUBECONFIG=./kubeconfig kubectl apply -f -
	KUBECONFIG=./kubeconfig kubectl apply -f deploy/k8s/
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/api --timeout=180s
	KUBECONFIG=./kubeconfig kubectl -n tasklog rollout status deployment/web --timeout=180s

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

down:
	docker compose -f compose.yaml -f compose.o11y.yaml down --remove-orphans
