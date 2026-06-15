ENV ?= dev
DOMAIN ?= clientes

ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
.SHELLFLAGS := /C
CLEANUP_CMD := cleanup.bat
else
SHELL := /bin/bash
.SHELLFLAGS := -ec
CLEANUP_CMD := ./cleanup.sh
endif

.PHONY: cleanup cleanup-windows stop-riscos-runtime
.PHONY: init-consumer-roles plan-consumer-roles apply-consumer-roles destroy-consumer-roles
.PHONY: init-foundation plan-foundation apply-foundation destroy-foundation
.PHONY: init-domain plan-domain apply-domain destroy-domain

cleanup:
	@echo "Iniciando limpeza completa do projeto..."
	@$(CLEANUP_CMD)

cleanup-windows:
	@echo "Iniciando limpeza completa do projeto (Windows)..."
	@cleanup.bat

stop-riscos-runtime:
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -ExecutionPolicy Bypass -Command "$$producer='lfmesh-$(ENV)-riscos-producer-5min'; $$watchdog='lfmesh-$(ENV)-riscos-start-streaming-job-15min'; $$job='lfmesh-$(ENV)-riscos-streaming-to-bronze'; Write-Host 'Preparando dominio riscos para destruicao...'; aws events disable-rule --name $$producer *> $$null; aws events disable-rule --name $$watchdog *> $$null; $$ids = aws glue get-job-runs --job-name $$job --max-results 10 --query \"JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='STOPPING' || JobRunState=='WAITING'].Id\" --output text 2>$$null; if ($$LASTEXITCODE -eq 0 -and $$ids -and $$ids -ne 'None') { Write-Host ('Parando Glue Streaming ativo: ' + $$ids); aws glue batch-stop-job-run --job-name $$job --job-run-ids $$ids *> $$null } else { Write-Host 'Nenhum Glue Streaming ativo encontrado para riscos.' }"
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

init-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform init

plan-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform plan

apply-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform apply

destroy-domain:
ifeq ($(DOMAIN),riscos)
	@$(MAKE) --no-print-directory stop-riscos-runtime ENV=$(ENV)
endif
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform destroy
