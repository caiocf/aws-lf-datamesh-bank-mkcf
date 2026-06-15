@echo off
REM Script de limpeza completa do projeto Lake Formation Data Mesh
REM CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
REM Dependencias: apenas Terraform + AWS CLI

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0

if "%ENV%"=="" set ENV=dev

echo === Limpeza completa do projeto Lake Formation Data Mesh ===
echo Diretorio: %SCRIPT_DIR%
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

pushd "%SCRIPT_DIR%" >nul

echo === FASE 1: DESTRUINDO DOMINIOS ===

for %%D in (riscos transacoes contas parceiros clientes) do (
    if exist "envs\%ENV%\domains\%%D\.terraform" (
        echo Destruindo dominio: %%D
        if /I "%%D"=="riscos" (
            call :stop_riscos_runtime
        )
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
popd >nul
pause
exit /b 0

:stop_riscos_runtime
set PRODUCER_RULE=lfmesh-%ENV%-riscos-producer-5min
set WATCHDOG_RULE=lfmesh-%ENV%-riscos-start-streaming-job-15min
set GLUE_JOB=lfmesh-%ENV%-riscos-streaming-to-bronze
set JOB_RUN_IDS=

echo Preparando dominio riscos para destruicao...
aws events disable-rule --name "%PRODUCER_RULE%" >nul 2>&1
aws events disable-rule --name "%WATCHDOG_RULE%" >nul 2>&1

for /f "usebackq delims=" %%R in (`aws glue get-job-runs --job-name "%GLUE_JOB%" --max-results 10 --query "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='STOPPING' || JobRunState=='WAITING'].Id" --output text 2^>nul`) do (
    set JOB_RUN_IDS=%%R
)

if defined JOB_RUN_IDS (
    echo Parando Glue Streaming ativo: !JOB_RUN_IDS!
    aws glue batch-stop-job-run --job-name "%GLUE_JOB%" --job-run-ids !JOB_RUN_IDS! >nul
) else (
    echo Nenhum Glue Streaming ativo encontrado para riscos.
)

echo.
exit /b 0
