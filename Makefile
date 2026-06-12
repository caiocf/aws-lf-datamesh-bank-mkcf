SHELL := /bin/bash
ENV ?= dev
DOMAIN ?= clientes

.PHONY: cleanup
cleanup:
	@echo "🧹 Iniciando limpeza completa do projeto..."
	@./cleanup.sh

cleanup-windows:
	@echo "🧹 Iniciando limpeza completa do projeto (Windows)..."
	@cleanup.bat

.PHONY: init-consumer-roles plan-consumer-roles apply-consumer-roles destroy-consumer-roles
init-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform init

plan-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform plan

apply-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform apply

destroy-consumer-roles:
	cd envs/$(ENV)/consumer-roles && terraform destroy

.PHONY: init-foundation plan-foundation apply-foundation destroy-foundation
init-foundation:
	cd envs/$(ENV)/foundation && terraform init

plan-foundation:
	cd envs/$(ENV)/foundation && terraform plan

apply-foundation:
	cd envs/$(ENV)/foundation && terraform apply

destroy-foundation:
	cd envs/$(ENV)/foundation && terraform destroy

.PHONY: init-domain plan-domain apply-domain destroy-domain
init-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform init

plan-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform plan

apply-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform apply

destroy-domain:
	cd envs/$(ENV)/domains/$(DOMAIN) && terraform destroy
