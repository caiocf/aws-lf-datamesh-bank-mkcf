@echo off
REM Script de limpeza completa do projeto Lake Formation Data Mesh
REM ⚠️ CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
REM Use apenas para limpeza completa após estudos/testes

setlocal enabledelayedexpansion

if "%ENV%"=="" set ENV=dev

echo 🧹 Iniciando limpeza completa do projeto Lake Formation Data Mesh
echo 📁 Diretório: %CD%
echo 🏷️ Ambiente: %ENV%
echo.

REM Função para confirmar destruição
echo ⚠️ ATENÇÃO: Este script vai DESTRUIR TODOS os recursos AWS criados pelo projeto!
echo 💰 Isso inclui:
echo    - Buckets S3 e objetos
echo    - IAM Roles e Policies
echo    - Glue Databases e Tables
echo    - Lake Formation settings
echo    - Athena Workgroups
echo.
set /p confirmation="🤔 Tem certeza que quer continuar? (digite 'DESTRUIR' para confirmar): "

if not "%confirmation%"=="DESTRUIR" (
    echo ❌ Operação cancelada. Nada foi destruído.
    exit /b 0
)
echo.

REM Verificar se AWS CLI está configurado
aws sts get-caller-identity >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ AWS CLI não configurado. Configure com: aws configure
    exit /b 1
)

echo 🚀 Iniciando sequência de destruição...
echo.

REM ORDEM IMPORTANTÍSSIMA: Domínios primeiro, depois Foundation, depois Consumer Roles

echo 📊 === FASE 1: DESTRUINDO DOMÍNIOS ===

REM Destruir domínio alertas
if exist "envs\%ENV%\domains\alertas" (
    echo 🔥 Destruindo domínio: alertas
    cd "envs\%ENV%\domains\alertas"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Domínio alertas destruído
    ) else (
        echo ⏭️ Domínio alertas não inicializado, pulando...
    )
    cd ..\..\..\..
) else (
    echo ⚠️ Diretório alertas não encontrado
)
echo.

REM Destruir domínio parceiros
if exist "envs\%ENV%\domains\parceiros" (
    echo 🔥 Destruindo domínio: parceiros
    cd "envs\%ENV%\domains\parceiros"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Domínio parceiros destruído
    ) else (
        echo ⏭️ Domínio parceiros não inicializado, pulando...
    )
    cd ..\..\..\..
) else (
    echo ⚠️ Diretório parceiros não encontrado
)
echo.

REM Destruir domínio transacoes
if exist "envs\%ENV%\domains\transacoes" (
    echo 🔥 Destruindo domínio: transacoes
    cd "envs\%ENV%\domains\transacoes"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Domínio transacoes destruído
    ) else (
        echo ⏭️ Domínio transacoes não inicializado, pulando...
    )
    cd ..\..\..\..
) else (
    echo ⚠️ Diretório transacoes não encontrado
)
echo.

REM Destruir domínio contas
if exist "envs\%ENV%\domains\contas" (
    echo 🔥 Destruindo domínio: contas
    cd "envs\%ENV%\domains\contas"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Domínio contas destruído
    ) else (
        echo ⏭️ Domínio contas não inicializado, pulando...
    )
    cd ..\..\..\..
) else (
    echo ⚠️ Diretório contas não encontrado
)
echo.

REM Destruir domínio clientes
if exist "envs\%ENV%\domains\clientes" (
    echo 🔥 Destruindo domínio: clientes
    cd "envs\%ENV%\domains\clientes"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Domínio clientes destruído
    ) else (
        echo ⏭️ Domínio clientes não inicializado, pulando...
    )
    cd ..\..\..\..
) else (
    echo ⚠️ Diretório clientes não encontrado
)
echo.

echo 🏛️ === FASE 2: DESTRUINDO FOUNDATION ===
if exist "envs\%ENV%\foundation" (
    echo 🔥 Destruindo Foundation (Lake Formation, IAM, Athena)
    cd "envs\%ENV%\foundation"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Foundation destruída
    ) else (
        echo ⏭️ Foundation não inicializada, pulando...
    )
    cd ..\..\..
) else (
    echo ⚠️ Diretório foundation não encontrado
)
echo.

echo 👥 === FASE 3: DESTRUINDO CONSUMER ROLES ===
if exist "envs\%ENV%\consumer-roles" (
    echo 🔥 Destruindo Consumer Roles
    cd "envs\%ENV%\consumer-roles"
    if exist ".terraform\terraform.tfstate" (
        terraform destroy -auto-approve
        echo ✅ Consumer Roles destruídas
    ) else (
        echo ⏭️ Consumer Roles não inicializadas, pulando...
    )
    cd ..\..\..
) else (
    echo ⚠️ Consumer Roles não encontradas
)
echo.

echo 🔍 === FASE 4: VERIFICAÇÃO FINAL ===
echo 🧽 Verificando recursos remanescentes...

echo 📦 Buckets S3 do projeto:
aws s3 ls | findstr "lfmesh-%ENV%" || echo    Nenhum bucket encontrado
echo.

echo 👤 IAM Roles do projeto:
aws iam list-roles --query "Roles[?contains(RoleName, 'lfmesh-%ENV%')].RoleName" --output table || echo    Nenhuma role encontrada
echo.

echo 🗄️ Glue Databases do projeto:
aws glue get-databases --query "DatabaseList[?contains(Name, 'dl_%ENV%')].Name" --output table || echo    Nenhum database encontrado
echo.

set /p force_s3="🤔 Quer forçar limpeza de buckets S3 remanescentes? (s/N): "
if /i "%force_s3%"=="s" (
    echo 🗑️ Forçando limpeza de buckets S3 remanescentes...
    REM Nota: No Windows, a remoção forçada de buckets S3 requer script adicional
    echo ⚠️ Para remoção forçada de buckets, execute manualmente:
    echo aws s3 rb s3://bucket-name --force
)

echo.
echo 🎉 Limpeza concluída!
echo 💡 Dica: Verifique o console AWS para garantir que não restaram recursos
echo 💰 Sua conta deve estar livre de cobranças do projeto

pause