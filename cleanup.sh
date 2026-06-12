#!/bin/bash

# Script de limpeza completa do projeto Lake Formation Data Mesh
# ⚠️  CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
# Use apenas para limpeza completa após estudos/testes

set -e  # Para execução em caso de erro

ENV=${ENV:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🧹 Iniciando limpeza completa do projeto Lake Formation Data Mesh"
echo "📁 Diretório: $SCRIPT_DIR"
echo "🏷️  Ambiente: $ENV"
echo ""

# Função para confirmar destruição
confirm_destroy() {
    echo "⚠️  ATENÇÃO: Este script vai DESTRUIR TODOS os recursos AWS criados pelo projeto!"
    echo "💰 Isso inclui:"
    echo "   - Buckets S3 e objetos"
    echo "   - IAM Roles e Policies"
    echo "   - Glue Databases e Tables"
    echo "   - Lake Formation settings"
    echo "   - Athena Workgroups"
    echo ""
    read -p "🤔 Tem certeza que quer continuar? (digite 'DESTRUIR' para confirmar): " confirmation
    
    if [ "$confirmation" != "DESTRUIR" ]; then
        echo "❌ Operação cancelada. Nada foi destruído."
        exit 0
    fi
    echo ""
}

# Função para destruir um domínio
destroy_domain() {
    local domain=$1
    local domain_path="envs/$ENV/domains/$domain"
    
    if [ -d "$domain_path" ]; then
        echo "🔥 Destruindo domínio: $domain"
        cd "$domain_path"
        
        if [ -f ".terraform/terraform.tfstate" ] || [ -f "terraform.tfstate" ]; then
            terraform destroy -auto-approve
            echo "✅ Domínio $domain destruído"
        else
            echo "⏭️  Domínio $domain não inicializado, pulando..."
        fi
        
        cd "$SCRIPT_DIR"
    else
        echo "⚠️  Diretório $domain_path não encontrado"
    fi
    echo ""
}

# Função para destruir foundation
destroy_foundation() {
    local foundation_path="envs/$ENV/foundation"
    
    echo "🔥 Destruindo Foundation (Lake Formation, IAM, Athena)"
    cd "$foundation_path"
    
    if [ -f ".terraform/terraform.tfstate" ] || [ -f "terraform.tfstate" ]; then
        terraform destroy -auto-approve
        echo "✅ Foundation destruída"
    else
        echo "⏭️  Foundation não inicializada, pulando..."
    fi
    
    cd "$SCRIPT_DIR"
    echo ""
}

# Função para destruir consumer roles
destroy_consumer_roles() {
    local consumer_path="envs/$ENV/consumer-roles"
    
    if [ -d "$consumer_path" ]; then
        echo "🔥 Destruindo Consumer Roles"
        cd "$consumer_path"
        
        if [ -f ".terraform/terraform.tfstate" ] || [ -f "terraform.tfstate" ]; then
            terraform destroy -auto-approve
            echo "✅ Consumer Roles destruídas"
        else
            echo "⏭️  Consumer Roles não inicializadas, pulando..."
        fi
        
        cd "$SCRIPT_DIR"
    else
        echo "⚠️  Consumer Roles não encontradas"
    fi
    echo ""
}

# Função para limpeza adicional (S3 buckets)
cleanup_remaining_resources() {
    echo "🧽 Verificando recursos remanescentes..."
    
    # Lista buckets que podem ter sido criados
    echo "📦 Buckets S3 do projeto:"
    aws s3 ls | grep "lfmesh-$ENV" || echo "   Nenhum bucket encontrado"
    echo ""
    
    # Verifica IAM roles
    echo "👤 IAM Roles do projeto:"
    aws iam list-roles --query "Roles[?contains(RoleName, 'lfmesh-$ENV')].RoleName" --output table || echo "   Nenhuma role encontrada"
    echo ""
    
    # Verifica Glue databases
    echo "🗄️  Glue Databases do projeto:"
    aws glue get-databases --query "DatabaseList[?contains(Name, 'dl_$ENV')].Name" --output table || echo "   Nenhum database encontrado"
    echo ""
}

# Função para forçar limpeza de buckets S3 (se necessário)
force_cleanup_s3() {
    echo "🗑️  Forçando limpeza de buckets S3 remanescentes..."
    
    # Lista e remove buckets do projeto
    for bucket in $(aws s3 ls | grep "lfmesh-$ENV" | awk '{print $3}'); do
        echo "🔥 Removendo bucket: $bucket"
        aws s3 rb s3://$bucket --force || echo "❌ Falha ao remover $bucket"
    done
    echo ""
}

# Executar limpeza
main() {
    confirm_destroy
    
    echo "🚀 Iniciando sequência de destruição..."
    echo ""
    
    # ORDEM IMPORTANTÍSSIMA: Domínios primeiro, depois Foundation, depois Consumer Roles
    
    # 1. Destruir domínios (dependem da Foundation)
    echo "📊 === FASE 1: DESTRUINDO DOMÍNIOS ==="
    destroy_domain "alertas"
    destroy_domain "parceiros"  
    destroy_domain "transacoes"
    destroy_domain "contas"
    destroy_domain "clientes"
    
    # 2. Destruir Foundation (depende das Consumer Roles)
    echo "🏛️  === FASE 2: DESTRUINDO FOUNDATION ==="
    destroy_foundation
    
    # 3. Destruir Consumer Roles (base de tudo)
    echo "👥 === FASE 3: DESTRUINDO CONSUMER ROLES ==="
    destroy_consumer_roles
    
    # 4. Verificar recursos remanescentes
    echo "🔍 === FASE 4: VERIFICAÇÃO FINAL ==="
    cleanup_remaining_resources
    
    # 5. Perguntar sobre limpeza forçada S3
    read -p "🤔 Quer forçar limpeza de buckets S3 remanescentes? (s/N): " force_s3
    if [[ $force_s3 =~ ^[Ss]$ ]]; then
        force_cleanup_s3
    fi
    
    echo ""
    echo "🎉 Limpeza concluída!"
    echo "💡 Dica: Verifique o console AWS para garantir que não restaram recursos"
    echo "💰 Sua conta deve estar livre de cobranças do projeto"
}

# Verificar se AWS CLI está configurado
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS CLI não configurado. Configure com: aws configure"
    exit 1
fi

# Executar
main