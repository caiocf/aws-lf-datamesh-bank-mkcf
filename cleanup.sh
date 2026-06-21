#!/bin/bash

# Script de limpeza completa do projeto Lake Formation Data Mesh
# CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
# Dependências: apenas Terraform + AWS CLI

set -e

ENV=${ENV:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS=(riscos transacoes contas parceiros clientes)
MAX_RETRIES=3
RETRY_WAIT=60

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

# ============================================================
# Funcao: limpar ENIs orfas de um Security Group
# ============================================================
cleanup_enis_for_sg() {
    local sg_id="$1"
    local eni_ids

    eni_ids=$(aws ec2 describe-network-interfaces \
        --filters "Name=group-id,Values=$sg_id" \
        --query "NetworkInterfaces[].NetworkInterfaceId" \
        --output text 2>/dev/null || true)

    if [ -z "$eni_ids" ] || [ "$eni_ids" = "None" ]; then
        return 0
    fi

    for eni_id in $eni_ids; do
        echo "  Processando ENI $eni_id..."

        # Verificar se esta attached
        local attachment_id
        attachment_id=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$eni_id" \
            --query "NetworkInterfaces[0].Attachment.AttachmentId" \
            --output text 2>/dev/null || true)

        if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
            echo "    Detaching ENI $eni_id (attachment $attachment_id)..."
            aws ec2 detach-network-interface --attachment-id "$attachment_id" --force 2>/dev/null || true
            sleep 10
        fi

        # Tentar deletar
        echo "    Deletando ENI $eni_id..."
        if ! aws ec2 delete-network-interface --network-interface-id "$eni_id" 2>/dev/null; then
            echo "    Aviso: nao foi possivel deletar ENI $eni_id (pode ainda estar em uso)"
        fi
    done
}

# ============================================================
# Funcao: limpar ENIs orfas de todos os SGs de um dominio
# ============================================================
cleanup_domain_enis() {
    local domain="$1"
    local sg_prefix="lfmesh-$ENV-$domain"

    echo "Buscando Security Groups do dominio $domain..."

    local sg_ids
    sg_ids=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${sg_prefix}*" \
        --query "SecurityGroups[].GroupId" \
        --output text 2>/dev/null || true)

    if [ -z "$sg_ids" ] || [ "$sg_ids" = "None" ]; then
        echo "  Nenhum SG encontrado para $domain."
        return 0
    fi

    for sg_id in $sg_ids; do
        echo "  Verificando ENIs no SG $sg_id..."
        cleanup_enis_for_sg "$sg_id"
    done
}

# ============================================================
# Funcao: esvaziar bucket S3 (suspend versioning + rm + rb force)
# ============================================================
empty_s3_bucket() {
    local bucket="$1"
    if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        return 0
    fi
    echo "  Esvaziando bucket: $bucket"
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Suspended 2>/dev/null || true
    aws s3 rm "s3://$bucket" --recursive --quiet 2>/dev/null || true
    aws s3 rb "s3://$bucket" --force 2>/dev/null || true
    echo "  Pronto: $bucket"
}

# ============================================================
# Funcao: esvaziar todos os buckets de um dominio
# ============================================================
empty_domain_buckets() {
    local domain="$1"
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    for layer in landing bronze silver gold scripts plugins; do
        local bucket="lfmesh-${ENV}-${domain}-${layer}-${account_id}"
        empty_s3_bucket "$bucket"
    done
}

# ============================================================
# Funcao: terraform destroy com retry e limpeza de ENIs
# ============================================================
destroy_domain() {
    local domain="$1"
    local domain_path="$SCRIPT_DIR/envs/$ENV/domains/$domain"
    local attempt=0

    pushd "$domain_path" > /dev/null

    # Limpar ENIs antes da primeira tentativa (evita o timeout de 15min)
    cleanup_domain_enis "$domain"

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        echo "[Tentativa $attempt/$MAX_RETRIES] terraform destroy para $domain..."

        set +e
        terraform destroy -auto-approve
        local exit_code=$?
        set -e

        if [ $exit_code -eq 0 ]; then
            popd > /dev/null
            return 0
        fi

        # Se falhou e ainda temos retries, limpar ENIs e tentar novamente
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo ""
            echo "Destroy falhou. Verificando ENIs orfas e Security Groups pendentes..."
            cleanup_domain_enis "$domain"
            echo "Aguardando ${RETRY_WAIT}s para ENIs serem liberadas..."
            sleep "$RETRY_WAIT"
        fi
    done

    popd > /dev/null
    echo "ERRO: terraform destroy falhou para $domain apos $MAX_RETRIES tentativas."
    return 1
}

# ============================================================
# Funcao: parar runtime do dominio riscos
# ============================================================
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

    if [ -n "$job_run_ids" ] && [ "$job_run_ids" != "None" ]; then
        echo "Parando Glue Streaming ativo: $job_run_ids"
        if ! aws glue batch-stop-job-run --job-name "$glue_job" --job-run-ids $job_run_ids >/dev/null 2>&1; then
            echo "Aviso: nao foi possivel parar o Glue Streaming de riscos."
        fi
        echo "Aguardando 30s para Glue Streaming parar..."
        sleep 30
    else
        echo "Nenhum Glue Streaming ativo encontrado para riscos."
    fi

    echo ""
}

# ============================================================
# Funcao: parar runtime do dominio transacoes
# ============================================================
stop_transacoes_runtime() {
    local producer_rule="lfmesh-$ENV-transacoes-producer-5min"
    local connector_prefix="lfmesh-$ENV-transacoes-s3-sink"

    echo "Preparando dominio transacoes para destruicao..."
    aws events disable-rule --name "$producer_rule" >/dev/null 2>&1 || true

    # Parar MSK Connect connector se ativo
    local connector_arn
    connector_arn=$(aws kafkaconnect list-connectors \
        --connector-name-prefix "$connector_prefix" \
        --query "connectors[?connectorState=='RUNNING'].connectorArn" \
        --output text 2>/dev/null || true)

    if [ -n "$connector_arn" ] && [ "$connector_arn" != "None" ]; then
        echo "Deletando MSK Connector: $connector_arn"
        aws kafkaconnect delete-connector --connector-arn "$connector_arn" >/dev/null 2>&1 || true
        echo "Aguardando 30s para connector parar..."
        sleep 30
    fi

    echo ""
}

# ============================================================
# FASE 1: OBSERVABILIDADE
# ============================================================
echo "=== FASE 1: DESTRUINDO OBSERVABILIDADE ==="

if [ -d "$SCRIPT_DIR/envs/$ENV/observability/.terraform" ]; then
    echo "Destruindo Observabilidade..."
    pushd "$SCRIPT_DIR/envs/$ENV/observability" > /dev/null
    terraform destroy -auto-approve
    popd > /dev/null
    echo "Observabilidade destruida."
else
    echo "Observabilidade nao inicializada, pulando..."
fi
echo ""

# ============================================================
# FASE 2: DOMINIOS
# ============================================================
echo "=== FASE 2: DESTRUINDO DOMINIOS ==="

for domain in "${DOMAINS[@]}"; do
    domain_path="$SCRIPT_DIR/envs/$ENV/domains/$domain"
    if [ -d "$domain_path/.terraform" ]; then
        echo "Destruindo dominio: $domain"
        if [ "$domain" = "riscos" ]; then
            stop_riscos_runtime
        fi
        if [ "$domain" = "transacoes" ]; then
            stop_transacoes_runtime
        fi
        empty_domain_buckets "$domain"
        destroy_domain "$domain"
        echo "Dominio $domain destruido."
    else
        echo "Dominio $domain nao inicializado, pulando..."
    fi
    echo ""
done

# ============================================================
# FASE 3: FOUNDATION
# ============================================================
echo "=== FASE 3: DESTRUINDO FOUNDATION ==="

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

# ============================================================
# FASE 4: CONSUMER ROLES
# ============================================================
echo "=== FASE 4: DESTRUINDO CONSUMER ROLES ==="

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

# ============================================================
# FASE 5: NETWORK
# ============================================================
echo "=== FASE 5: DESTRUINDO NETWORK ==="

if [ -d "$SCRIPT_DIR/envs/$ENV/network/.terraform" ]; then
    echo "Destruindo Shared Network..."
    pushd "$SCRIPT_DIR/envs/$ENV/network" > /dev/null
    terraform destroy -auto-approve
    popd > /dev/null
    echo "Shared Network destruida."
else
    echo "Shared Network nao inicializada, pulando..."
fi
echo ""

# ============================================================
# VERIFICACAO FINAL
# ============================================================
echo "=== VERIFICACAO FINAL ==="
echo "Buckets S3 remanescentes:"
aws s3 ls 2>/dev/null | grep "lfmesh-$ENV" || echo "   Nenhum."
echo ""
echo "Limpeza concluida!"
