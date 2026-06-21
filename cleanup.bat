@echo off
REM Script de limpeza completa do projeto Lake Formation Data Mesh
REM CUIDADO: Este script DESTROI TODOS os recursos criados pelo projeto!
REM Dependencias: apenas Terraform + AWS CLI

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0

if "%ENV%"=="" set ENV=dev
set MAX_RETRIES=3
set RETRY_WAIT=60

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

echo === FASE 1: DESTRUINDO OBSERVABILIDADE ===

if exist "envs\%ENV%\observability\.terraform" (
    echo Destruindo Observabilidade...
    pushd "envs\%ENV%\observability"
    terraform destroy -auto-approve
    set TF_EXIT=!errorlevel!
    popd
    if not "!TF_EXIT!"=="0" (
        echo ERRO: terraform destroy falhou na Observabilidade com exit code !TF_EXIT!.
        popd >nul
        exit /b !TF_EXIT!
    )
    echo Observabilidade destruida.
) else (
    echo Observabilidade nao inicializada, pulando...
)
echo.

echo === FASE 2: DESTRUINDO DOMINIOS ===

for %%D in (riscos transacoes contas parceiros clientes) do (
    if exist "envs\%ENV%\domains\%%D\.terraform" (
        echo Destruindo dominio: %%D
        if /I "%%D"=="riscos" (
            call :stop_riscos_runtime
        )
        if /I "%%D"=="transacoes" (
            call :stop_transacoes_runtime
        )
        call :empty_domain_buckets %%D
        call :destroy_domain %%D
        if not "!TF_EXIT!"=="0" (
            echo ERRO: terraform destroy falhou no dominio %%D apos !MAX_RETRIES! tentativas.
            popd >nul
            exit /b !TF_EXIT!
        )
        echo Dominio %%D destruido.
    ) else (
        echo Dominio %%D nao inicializado, pulando...
    )
    echo.
)

echo === FASE 3: DESTRUINDO FOUNDATION ===

if exist "envs\%ENV%\foundation\.terraform" (
    echo Destruindo Foundation...
    pushd "envs\%ENV%\foundation"
    terraform destroy -auto-approve
    set TF_EXIT=!errorlevel!
    popd
    if not "!TF_EXIT!"=="0" (
        echo ERRO: terraform destroy falhou na Foundation com exit code !TF_EXIT!.
        popd >nul
        exit /b !TF_EXIT!
    )
    echo Foundation destruida.
) else (
    echo Foundation nao inicializada, pulando...
)
echo.

echo === FASE 4: DESTRUINDO CONSUMER ROLES ===

if exist "envs\%ENV%\consumer-roles\.terraform" (
    echo Destruindo Consumer Roles...
    pushd "envs\%ENV%\consumer-roles"
    terraform destroy -auto-approve
    set TF_EXIT=!errorlevel!
    popd
    if not "!TF_EXIT!"=="0" (
        echo ERRO: terraform destroy falhou em Consumer Roles com exit code !TF_EXIT!.
        popd >nul
        exit /b !TF_EXIT!
    )
    echo Consumer Roles destruidas.
) else (
    echo Consumer Roles nao inicializadas, pulando...
)
echo.

echo === FASE 5: DESTRUINDO NETWORK ===

if exist "envs\%ENV%\network\.terraform" (
    echo Destruindo Shared Network...
    pushd "envs\%ENV%\network"
    terraform destroy -auto-approve
    set TF_EXIT=!errorlevel!
    popd
    if not "!TF_EXIT!"=="0" (
        echo ERRO: terraform destroy falhou em Shared Network com exit code !TF_EXIT!.
        popd >nul
        exit /b !TF_EXIT!
    )
    echo Shared Network destruida.
) else (
    echo Shared Network nao inicializada, pulando...
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

REM ============================================================
REM Sub-rotina: destroy_domain com retry e limpeza de ENIs
REM ============================================================
:destroy_domain
set DOMAIN_NAME=%~1
set TF_EXIT=0

pushd "envs\%ENV%\domains\%DOMAIN_NAME%"

REM Limpar ENIs antes da primeira tentativa (evita o timeout de 15min)
call :cleanup_enis %DOMAIN_NAME%

set ATTEMPT=0
:retry_loop
set /a ATTEMPT+=1
echo [Tentativa !ATTEMPT!/%MAX_RETRIES%] terraform destroy para %DOMAIN_NAME%...

terraform destroy -auto-approve
set TF_EXIT=!errorlevel!

if "!TF_EXIT!"=="0" (
    popd
    exit /b 0
)

REM Se falhou e ainda temos retries, limpar ENIs e tentar novamente
if !ATTEMPT! lss %MAX_RETRIES% (
    echo.
    echo Destroy falhou. Verificando ENIs orfas e Security Groups pendentes...
    call :cleanup_enis %DOMAIN_NAME%
    echo Aguardando %RETRY_WAIT%s para ENIs serem liberadas...
    timeout /t %RETRY_WAIT% /nobreak >nul
    goto :retry_loop
)

popd
exit /b !TF_EXIT!

REM ============================================================
REM Sub-rotina: limpeza de ENIs orfas associadas a SGs do dominio
REM ============================================================
:cleanup_enis
set CLEANUP_DOMAIN=%~1
set SG_PREFIX=lfmesh-%ENV%-%CLEANUP_DOMAIN%

echo Buscando Security Groups do dominio %CLEANUP_DOMAIN%...

REM Buscar SGs do dominio
for /f "usebackq delims=" %%S in (`aws ec2 describe-security-groups --filters "Name=group-name,Values=%SG_PREFIX%*" --query "SecurityGroups[].GroupId" --output text 2^>nul`) do (
    for %%G in (%%S) do (
        echo Verificando ENIs no SG %%G...
        call :detach_and_delete_enis %%G
    )
)

exit /b 0

REM ============================================================
REM Sub-rotina: detach e delete de ENIs de um Security Group
REM ============================================================
:detach_and_delete_enis
set SG_ID=%~1

REM Listar ENIs associadas ao SG
for /f "usebackq delims=" %%E in (`aws ec2 describe-network-interfaces --filters "Name=group-id,Values=%SG_ID%" --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2^>nul`) do (
    for %%N in (%%E) do (
        echo   Processando ENI %%N...

        REM Verificar se esta attached
        for /f "usebackq delims=" %%A in (`aws ec2 describe-network-interfaces --network-interface-ids %%N --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2^>nul`) do (
            if not "%%A"=="None" if not "%%A"=="" (
                echo     Detaching ENI %%N ^(attachment %%A^)...
                aws ec2 detach-network-interface --attachment-id %%A --force >nul 2>&1
                timeout /t 10 /nobreak >nul
            )
        )

        REM Tentar deletar
        echo     Deletando ENI %%N...
        aws ec2 delete-network-interface --network-interface-id %%N >nul 2>&1
        if !errorlevel! neq 0 (
            echo     Aviso: nao foi possivel deletar ENI %%N ^(pode ainda estar em uso^)
        )
    )
)

exit /b 0

REM ============================================================
REM Sub-rotina: esvaziar buckets S3 de um dominio (versioning torna force_destroy lento)
REM ============================================================
:empty_domain_buckets
set EB_DOMAIN=%~1
echo Esvaziando buckets S3 do dominio %EB_DOMAIN%...
for /f "usebackq delims=" %%A in (`aws sts get-caller-identity --query Account --output text 2^>nul`) do set EB_ACCOUNT=%%A
for %%L in (landing bronze silver gold scripts plugins) do (
    set "EB_BUCKET=lfmesh-%ENV%-!EB_DOMAIN!-%%L-!EB_ACCOUNT!"
    aws s3api head-bucket --bucket "!EB_BUCKET!" >nul 2>&1 && (
        echo   Esvaziando: !EB_BUCKET!
        aws s3api put-bucket-versioning --bucket "!EB_BUCKET!" --versioning-configuration Status=Suspended >nul 2>&1
        aws s3 rm "s3://!EB_BUCKET!" --recursive --quiet >nul 2>&1
        aws s3 rb "s3://!EB_BUCKET!" --force >nul 2>&1
        echo   Pronto: !EB_BUCKET!
    ) || (
        echo   Bucket !EB_BUCKET! nao existe, pulando.
    )
)
echo.
exit /b 0

REM ============================================================
REM Sub-rotina: parar runtime do dominio riscos
REM ============================================================
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
    echo Aguardando 30s para Glue Streaming parar...
    timeout /t 30 /nobreak >nul
) else (
    echo Nenhum Glue Streaming ativo encontrado para riscos.
)

echo.
exit /b 0

REM ============================================================
REM Sub-rotina: parar runtime do dominio transacoes
REM ============================================================
:stop_transacoes_runtime
set TX_PRODUCER_RULE=lfmesh-%ENV%-transacoes-producer-5min
set TX_GLUE_JOB=lfmesh-%ENV%-transacoes-bronze-to-silver
set TX_CONNECTOR=lfmesh-%ENV%-transacoes-s3-sink

echo Preparando dominio transacoes para destruicao...
aws events disable-rule --name "%TX_PRODUCER_RULE%" >nul 2>&1

REM Parar MSK Connect connector se ativo
for /f "usebackq delims=" %%C in (`aws kafkaconnect list-connectors --connector-name-prefix "%TX_CONNECTOR%" --query "connectors[?connectorState=='RUNNING'].connectorArn" --output text 2^>nul`) do (
    if not "%%C"=="" (
        echo Deletando MSK Connector: %%C
        aws kafkaconnect delete-connector --connector-arn %%C >nul 2>&1
    )
)

echo.
exit /b 0
