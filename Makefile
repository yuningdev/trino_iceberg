# ===========================================================================
# Trino playground - distributed Trino over an Iceberg lakehouse on MinIO.
# `make help` lists everything.
# ===========================================================================
SHELL := /bin/bash
COMPOSE := docker compose
COMPOSE_POLARIS := docker compose -f docker-compose.yml -f docker-compose.polaris.yml

include .env
export

.DEFAULT_GOAL := help

.PHONY: help up down restart clean build ps logs logs-trino logs-hms health cli \
        sql seed features checks scale ui minio-ui bucket doctor wait \
        polaris-up polaris-down polaris-bootstrap pyspark compare

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Trino UI   http://localhost:$(TRINO_PORT)   (any username, no password)"
	@echo "  MinIO UI   http://localhost:$(MINIO_CONSOLE_PORT)   ($(MINIO_ROOT_USER) / $(MINIO_ROOT_PASSWORD))"

build: ## Build the patched Hive Metastore image (postgres jdbc + hadoop-aws)
	$(COMPOSE) build hive-metastore

up: ## Start the whole stack and block until Trino reports ready
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory wait health

down: ## Stop containers, keep MinIO/Postgres data
	$(COMPOSE) down --remove-orphans

restart: down up ## down + up

clean: ## Stop everything and delete all data volumes (destructive)
	$(COMPOSE_POLARIS) down --volumes --remove-orphans

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Tail logs for all services
	$(COMPOSE) logs -f --tail=100

logs-trino: ## Tail coordinator + worker logs
	$(COMPOSE) logs -f --tail=100 trino-coordinator trino-worker

logs-hms: ## Tail Hive Metastore logs
	$(COMPOSE) logs -f --tail=200 hive-metastore

wait: ## Block until the coordinator's healthcheck passes
	@printf 'waiting for trino-coordinator'
	@for i in $$(seq 1 120); do \
		status="$$(docker inspect -f '{{.State.Health.Status}}' trino-coordinator 2>/dev/null)"; \
		if [ "$$status" = healthy ]; then echo ' ready'; exit 0; fi; \
		if [ "$$status" = unhealthy ]; then echo ' unhealthy'; echo 'see: make logs-trino'; exit 1; fi; \
		printf '.'; sleep 2; \
	done; \
	echo ' timed out after 240s'; echo 'see: make logs-trino'; exit 1

health: ## Print the cluster topology Trino actually sees
	@echo ""
	@$(COMPOSE) exec -T trino-coordinator trino --server http://localhost:8080 \
		--execute "SELECT node_id, node_version, coordinator, state FROM system.runtime.nodes ORDER BY coordinator DESC" \
		--output-format ALIGNED

cli: ## Open an interactive Trino shell (catalog: iceberg)
	@./scripts/trino-cli.sh

seed: ## Create the demo Iceberg schema and load TPC-H data into MinIO
	@./scripts/run-sql.sh sql/00_sanity.sql sql/10_seed_iceberg.sql

sql: ## Run every script in ./sql in order
	@./scripts/run-sql.sh

features: ## Run the Iceberg feature tour (run `make seed` first)
	@./scripts/run-sql.sh sql/20_iceberg_features.sql

checks: ## Run the distributed-execution checks
	@./scripts/run-sql.sh sql/30_distributed_checks.sql

scale: ## Resize the worker pool, e.g. `make scale N=4`
	@test -n "$(N)" || { echo "usage: make scale N=<workers>"; exit 1; }
	$(COMPOSE) up -d --no-recreate --scale trino-worker=$(N)
	@$(MAKE) --no-print-directory health

ui: ## Open the Trino web UI
	@open "http://localhost:$(TRINO_PORT)" 2>/dev/null || echo "http://localhost:$(TRINO_PORT)"

minio-ui: ## Open the MinIO console
	@open "http://localhost:$(MINIO_CONSOLE_PORT)" 2>/dev/null || echo "http://localhost:$(MINIO_CONSOLE_PORT)"

bucket: ## List what is actually sitting in the lakehouse bucket
	@$(COMPOSE) run --rm --entrypoint sh minio-init -c \
		'mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" >/dev/null && mc ls --recursive "local/$$LAKEHOUSE_BUCKET" | head -60'

doctor: ## Validate the compose files and check the Docker daemon
	@echo "== compose syntax"
	@$(COMPOSE) config -q && echo "   base stack      OK"
	@$(COMPOSE_POLARIS) config -q && echo "   polaris overlay OK"
	@echo "== docker"
	@v="$$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"; \
	if [ -n "$$v" ]; then \
		docker info --format '   server {{.ServerVersion}} on {{.OSType}}/{{.Architecture}}'; \
	else \
		echo "   !! daemon unreachable - start Docker Desktop, then re-run make doctor"; \
	fi
	@echo "== host"
	@echo "   arch $$(uname -m)"

polaris-up: ## Start the stack with Apache Polaris as a second catalog
	$(COMPOSE_POLARIS) up -d --build
	@$(MAKE) --no-print-directory wait

polaris-bootstrap: ## Create the Polaris catalog + grants (run after polaris-up)
	@./scripts/polaris-bootstrap.sh

polaris-down: ## Stop the Polaris overlay
	$(COMPOSE_POLARIS) down --remove-orphans

compare: ## Write 500k rows as Iceberg + as plain Hive (both via HMS), then evaluate
	@./scripts/run-sql.sh sql/40_format_comparison.sql sql/41_format_evaluation.sql

pyspark: ## Run a script from ./pyspark, e.g. `make pyspark S=spark/practice.py`
	@test -n "$(S)" || { echo "usage: make pyspark S=<path under ./pyspark>"; exit 1; }
	@test -f "pyspark/$(S)" || { echo "no such script: pyspark/$(S)"; exit 1; }
	$(COMPOSE) run --rm spark /opt/pyspark/$(S)
