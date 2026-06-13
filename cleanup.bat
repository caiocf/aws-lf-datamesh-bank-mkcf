@echo off
REM Script de limpeza completa do projeto Lake Formation Data Mesh
REM CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
REM Dependencias: apenas Terraform + AWS CLI

setlocal enabledelayedexpansion

if "%ENV%"=="" set ENV=dev

echo === Limpeza completa do projeto Lake Formation Data Mesh ===
echo Diretorio: %CD%
echo Ambiente: %ENV%
echo.

set /p confirmation="ATENCAO: Vai DESTRUIR TODOS os recursos. Digite 'DESTRUIR' para confirmar: "
if not "%confirmation%"=="DESTRUIR" (
    echo Operacao cancelada.
    exit /b 0
)
echo.

REM Verificar AWS CLI
aws sts get-caller-identity >nul 2>&1
if %errorlevel% neq 0 (
    echo ERRO: AWS CLI nao configurado.
    exit /b 1
)

echo === FASE 1: DESTRUINDO DOMINIOS ===

for %%D in (alertas parceiros transacoes contas clientes) do (
    if exist "envs\%ENV%\domains\%%D\.terraform" (
        echo Destruindo dominio: %%D
        pushd "envs\%ENV%\domains\%%D"
        terraform destroy -auto-approve
        popd
        echo Dominio %%D destruido.
    ) else (
        echo Dominio %%D nao inicializado, pulando...
    )
    echo.
)

echo === FASE 2: DESTRUINDO FOUNDATION ===

if exist "envs\%ENV%\foundation\.terraform" (
    echo Destruindo Foundation...
    pushd "envs\%ENV%\foundation"
    terraform destroy -auto-approve
    popd
    echo Foundation destruida.
) else (
    echo Foundation nao inicializada, pulando...
)
echo.

echo === FASE 3: DESTRUINDO CONSUMER ROLES ===

if exist "envs\%ENV%\consumer-roles\.terraform" (
    echo Destruindo Consumer Roles...
    pushd "envs\%ENV%\consumer-roles"
    terraform destroy -auto-approve
    popd
    echo Consumer Roles destruidas.
) else (
    echo Consumer Roles nao inicializadas, pulando...
)
echo.

echo === VERIFICACAO FINAL ===
echo Buckets S3 remanescentes:
aws s3 ls 2>nul | findstr "lfmesh-%ENV%" || echo    Nenhum.
echo.
echo Limpeza concluida!
pause
