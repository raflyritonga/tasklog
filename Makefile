.DEFAULT_GOAL := help

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
	@echo "dev: not implemented yet (Stage A, phase 2)"

dev-ghcr:
	@echo "dev-ghcr: not implemented yet (Stage A, phase 3)"

o11y-up:
	@echo "o11y-up: not implemented yet (Stage B, phase 4)"

up:
	@echo "up: not implemented yet (Stage C, phase 6)"

deploy:
	@echo "deploy: not implemented yet (Stage C, phase 7)"

seed:
	@echo "seed: not implemented yet (Stage A, phase 1)"

load:
	@echo "load: not implemented yet (Stage C, phase 11)"

demo-latency:
	@echo "demo-latency: not implemented yet (Stage A, phase 1)"

demo-errors:
	@echo "demo-errors: not implemented yet (Stage A, phase 1)"

demo-reset:
	@echo "demo-reset: not implemented yet (Stage A, phase 1)"

dashboards:
	@echo "dashboards: not implemented yet (Stage C, phase 10)"

secrets:
	@echo "secrets: not implemented yet (Stage C, phase 6)"

down:
	@echo "down: not implemented yet (Stage A, phase 2)"
