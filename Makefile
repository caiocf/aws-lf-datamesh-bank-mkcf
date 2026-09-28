ENV ?= dev
# Sem DOMAIN, init/plan/apply executam todos os dominios nesta ordem.
DOMAIN ?= all
DOMAINS := parceiros contas transacoes riscos clientes
AUTO_APPROVE ?= false
DOMAIN_APPLY_FLAGS = $(if $(filter true,$(AUTO_APPROVE)),-auto-approve)

ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
.SHELLFLAGS := /C
CLEANUP_CMD := cleanup.bat
PYTHON := python
else
SHELL := /bin/bash
.SHELLFLAGS := -ec
CLEANUP_CMD := ./cleanup.sh
PYTHON := python3
endif

.PHONY: cleanup cleanup-windows stop-riscos-runtime
.PHONY: init-consumer-roles plan-consumer-roles apply-consumer-roles destroy-consumer-roles
.PHONY: init-foundation plan-foundation apply-foundation destroy-foundation
.PHONY: init-network plan-network apply-network destroy-network
.PHONY: init-observability plan-observability apply-observability destroy-observability
.PHONY: init-domain plan-domain apply-domain destroy-domain
.PHONY: init-domains plan-domains apply-domains

cleanup:
	@echo "Iniciando limpeza completa do projeto..."
	@$(PYTHON) scripts/cleanup-lab.py --environment $(ENV) $(if $(filter true,$(AUTO_APPROVE)),--yes)

cleanup-windows:
	@echo "Iniciando limpeza completa do projeto (Windows)..."
	@python scripts/cleanup-lab.py --environment $(ENV) $(if $(filter true,$(AUTO_APPROVE)),--yes)

stop-riscos-runtime:
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -ExecutionPolicy Bypass -File scripts/stop-riscos-runtime.ps1 -Environment $(ENV)
else
	@producer_rule="lfmesh-$(ENV)-riscos-producer-5min"; \
	watchdog_rule="lfmesh-$(ENV)-riscos-start-streaming-job-15min"; \
	glue_job="lfmesh-$(ENV)-riscos-streaming-to-bronze"; \
	echo "Preparando dominio riscos para destruicao..."; \
	aws events disable-rule --name "$$producer_rule" >/dev/null 2>&1 || true; \
	aws events disable-rule --name "$$watchdog_rule" >/dev/null 2>&1 || true; \
	job_run_ids="$$(aws glue get-job-runs --job-name "$$glue_job" --max-results 10 --query "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='STOPPING' || JobRunState=='WAITING'].Id" --output text 2>/dev/null || true)"; \
	if [ -n "$$job_run_ids" ] && [ "$$job_run_ids" != "None" ]; then \
		echo "Parando Glue Streaming ativo: $$job_run_ids"; \
		aws glue batch-stop-job-run --job-name "$$glue_job" --job-run-ids $$job_run_ids >/dev/null 2>&1 || echo "Aviso: nao foi possivel parar o Glue Streaming de riscos."; \
	else \
		echo "Nenhum Glue Streaming ativo encontrado para riscos."; \
	fi
endif

init-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform init

plan-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform plan

apply-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform apply

destroy-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform destroy

init-foundation:
	cd envs/$(ENV)/foundation && terraform init

plan-foundation:
	cd envs/$(ENV)/foundation && terraform plan

apply-foundation:
	cd envs/$(ENV)/foundation && terraform apply

destroy-foundation:
	cd envs/$(ENV)/foundation && terraform destroy

init-network:
	cd envs/$(ENV)/network && terraform init

plan-network:
	cd envs/$(ENV)/network && terraform plan

apply-network:
	cd envs/$(ENV)/network && terraform apply

destroy-network:
	cd envs/$(ENV)/network && terraform destroy

init-observability:
	cd envs/$(ENV)/observability && terraform init

plan-observability:
	cd envs/$(ENV)/observability && terraform plan

apply-observability:
	cd envs/$(ENV)/observability && terraform apply

destroy-observability:
	cd envs/$(ENV)/observability && terraform destroy

# A cadeia com && preserva a ordem mesmo com make -j e para no primeiro erro.
init-domains plan-domains apply-domains:
	$(foreach domain,$(DOMAINS),$(MAKE) --no-print-directory $(patsubst %-domains,%-domain,$@) ENV=$(ENV) DOMAIN=$(domain) && )echo Dominios concluidos.

ifeq ($(DOMAIN),all)
init-domain: init-domains
plan-domain: plan-domains
apply-domain: apply-domains
else
init-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform init

plan-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform plan

apply-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform apply $(DOMAIN_APPLY_FLAGS)
endif

destroy-domain:
ifeq ($(DOMAIN),all)
	$(error Informe DOMAIN explicitamente para destruir um dominio)
endif
	@$(PYTHON) scripts/cleanup-lab.py --environment $(ENV) --domain $(DOMAIN) $(if $(filter true,$(AUTO_APPROVE)),--yes)
