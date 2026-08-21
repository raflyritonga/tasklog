.DEFAULT_GOAL := help

API_URL ?= http://localhost:8080
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
	@echo "dev-ghcr: not implemented yet (Stage A, phase 3)"

o11y-up:
	@echo "o11y-up: not implemented yet (Stage B, phase 4)"

up:
	@echo "up: not implemented yet (Stage C, phase 6)"

deploy:
	@echo "deploy: not implemented yet (Stage C, phase 7)"

seed:
	docker compose exec pg psql -U tasklog -d tasklog -c "select seed_tasks();"

load:
	@echo "load: not implemented yet (Stage C, phase 11)"

demo-latency:
	curl -sS -X POST -H "content-type: application/json" -d '{"ms":$(DEMO_MS)}' $(API_URL)/api/demo/latency

demo-errors:
	curl -sS -X POST -H "content-type: application/json" -d '{"rate":$(DEMO_RATE)}' $(API_URL)/api/demo/errors

demo-reset:
	curl -sS -X POST $(API_URL)/api/demo/reset

dashboards:
	@echo "dashboards: not implemented yet (Stage C, phase 10)"

secrets:
	@echo "secrets: not implemented yet (Stage C, phase 6)"

down:
	docker compose down --remove-orphans
