#!/bin/bash

# Script de limpeza completa do projeto Lake Formation Data Mesh
# CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
# Dependências: apenas Terraform + AWS CLI

set -e

ENV=${ENV:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS=(riscos transacoes contas parceiros clientes)

echo "=== Limpeza completa do projeto Lake Formation Data Mesh ==="
echo "Diretorio: $SCRIPT_DIR"
echo "Ambiente: $ENV"
echo ""

read -p "ATENCAO: Vai DESTRUIR TODOS os recursos. Digite 'DESTRUIR' para confirmar: " confirmation
if [ "$confirmation" != "DESTRUIR" ]; then
    echo "Operacao cancelada."
    exit 0
fi
echo ""

# Verificar AWS CLI
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERRO: AWS CLI nao configurado."
    exit 1
fi

stop_riscos_runtime() {
    local producer_rule="lfmesh-$ENV-riscos-producer-5min"
    local watchdog_rule="lfmesh-$ENV-riscos-start-streaming-job-15min"
    local glue_job="lfmesh-$ENV-riscos-streaming-to-bronze"
    local job_run_ids

    echo "Preparando dominio riscos para destruicao..."
    aws events disable-rule --name "$producer_rule" >/dev/null 2>&1 || true
    aws events disable-rule --name "$watchdog_rule" >/dev/null 2>&1 || true

    job_run_ids="$(aws glue get-job-runs \
        --job-name "$glue_job" \
        --max-results 10 \
        --query "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='STOPPING' || JobRunState=='WAITING'].Id" \
        --output text 2>/dev/null || true)"

    if [ -n "$job_run_ids" ]; then
        echo "Parando Glue Streaming ativo: $job_run_ids"
        if ! aws glue batch-stop-job-run --job-name "$glue_job" --job-run-ids $job_run_ids >/dev/null 2>&1; then
            echo "Aviso: nao foi possivel parar o Glue Streaming de riscos. Seguindo com terraform destroy..."
        fi
    else
        echo "Nenhum Glue Streaming ativo encontrado para riscos."
    fi

    echo ""
}

echo "=== FASE 1: DESTRUINDO DOMINIOS ==="

for domain in "${DOMAINS[@]}"; do
    domain_path="$SCRIPT_DIR/envs/$ENV/domains/$domain"
    if [ -d "$domain_path/.terraform" ]; then
        echo "Destruindo dominio: $domain"
        if [ "$domain" = "riscos" ]; then
            stop_riscos_runtime
        fi
        pushd "$domain_path" > /dev/null
        terraform destroy -auto-approve
        popd > /dev/null
        echo "Dominio $domain destruido."
    else
        echo "Dominio $domain nao inicializado, pulando..."
    fi
    echo ""
done

echo "=== FASE 2: DESTRUINDO FOUNDATION ==="

if [ -d "$SCRIPT_DIR/envs/$ENV/foundation/.terraform" ]; then
    echo "Destruindo Foundation..."
    pushd "$SCRIPT_DIR/envs/$ENV/foundation" > /dev/null
    terraform destroy -auto-approve
    popd > /dev/null
    echo "Foundation destruida."
else
    echo "Foundation nao inicializada, pulando..."
fi
echo ""

echo "=== FASE 3: DESTRUINDO CONSUMER ROLES ==="

if [ -d "$SCRIPT_DIR/envs/$ENV/consumer-roles/.terraform" ]; then
    echo "Destruindo Consumer Roles..."
    pushd "$SCRIPT_DIR/envs/$ENV/consumer-roles" > /dev/null
    terraform destroy -auto-approve
    popd > /dev/null
    echo "Consumer Roles destruidas."
else
    echo "Consumer Roles nao inicializadas, pulando..."
fi
echo ""

echo "=== VERIFICACAO FINAL ==="
echo "Buckets S3 remanescentes:"
aws s3 ls 2>/dev/null | grep "lfmesh-$ENV" || echo "   Nenhum."
echo ""
echo "Limpeza concluida!"
