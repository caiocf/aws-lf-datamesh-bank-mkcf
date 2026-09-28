param(
    [ValidatePattern('^[a-zA-Z0-9_-]+$')]
    [string]$Environment = 'dev'
)

$producer = "lfmesh-$Environment-riscos-producer-5min"
$watchdog = "lfmesh-$Environment-riscos-start-streaming-job-15min"
$job = "lfmesh-$Environment-riscos-streaming-to-bronze"

Write-Host 'Preparando dominio riscos para destruicao...'
# As regras podem ja ter sido removidas em uma destruicao parcial.
aws events disable-rule --name $producer *> $null
aws events disable-rule --name $watchdog *> $null

$query = "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING' || JobRunState=='STOPPING' || JobRunState=='WAITING'].Id"
$result = aws glue get-job-runs --job-name $job --max-results 10 --query $query --output text 2>&1
if ($LASTEXITCODE -ne 0) {
    $awsError = ($result | Out-String).Trim()
    if ($awsError -match '\(EntityNotFoundException\)') {
        Write-Host 'Job Glue de riscos ja nao existe; continuando a destruicao dos recursos restantes.'
        return
    }
    throw "Nao foi possivel consultar as execucoes Glue de riscos: $awsError"
}

$runIds = @((($result -join ' ') -split '\s+') | Where-Object { $_ -and $_ -ne 'None' })
if ($runIds.Count -gt 0) {
    Write-Host ('Parando Glue Streaming ativo: ' + ($runIds -join ', '))
    aws glue batch-stop-job-run --job-name $job --job-run-ids @runIds
    if ($LASTEXITCODE -ne 0) {
        throw 'Nao foi possivel solicitar a parada do Glue Streaming de riscos.'
    }
} else {
    Write-Host 'Nenhum Glue Streaming ativo encontrado para riscos.'
}
