# Deploy passo a passo

## 1. Pré-requisitos

- AWS CLI autenticado na conta do lab
- Terraform instalado
- Região usada neste repositório: `us-east-1`
- Foundation aplicada antes dos domínios

Exemplo no PowerShell:

```powershell
$env:AWS_PROFILE = "seu-profile"
$env:AWS_REGION  = "us-east-1"
aws sts get-caller-identity
```

## 2. Foundation

```powershell
Set-Location envs/dev/foundation
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Guarde estes outputs, porque eles serão usados na validação de governança:

```powershell
terraform output consumer_role_arns
terraform output consumer_role_names
terraform output athena_workgroups
terraform output athena_results_bucket
```

## 3. Ordem recomendada dos domínios

Esta é a ordem alinhada com o estado atual do projeto e com o `PLANO-INGESTAO.md`:

1. `clientes`
2. `parceiros`
3. `contas`
4. `transacoes`
5. `riscos`

### 3.1 clientes

```powershell
Set-Location ../domains/clientes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

### 3.2 parceiros

```powershell
Set-Location ../parceiros
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

### 3.3 contas

```powershell
Set-Location ../contas
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observação:
- este domínio cria `RDS PostgreSQL`, `DMS`, `Secrets Manager` e jobs Glue
- o deploy demora mais do que `clientes` e `parceiros`

### 3.4 transacoes

```powershell
Set-Location ../transacoes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observação:
- este domínio cria `MSK Provisionado`, `MSK Connect`, `Secrets Manager`, `KMS` e jobs Glue
- após o deploy, o producer roda a cada 5 minutos e o workflow roda de hora em hora

### 3.5 riscos

```powershell
Set-Location ../riscos
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Se `contas` ou `transacoes` já tiverem criado endpoints na VPC default, ajuste manualmente o `terraform.tfvars` de `riscos` antes do `apply`:

```hcl
aws_region           = "us-east-1"
project_name         = "lfmesh"
environment          = "dev"
create_vpc_endpoints = false
```

Observação:
- este domínio cria `MSK Serverless`, `Glue Streaming`, `EventBridge`, workflow batch e governança na gold
- o producer roda a cada 5 minutos
- a Lambda `lfmesh-dev-riscos-start-streaming-job` roda a cada 15 minutos como watchdog
- o job `lfmesh-dev-riscos-streaming-to-bronze` é iniciado automaticamente no deploy

## 4. Validação no Athena

Use primeiro seu perfil admin do Lake Formation e o workgroup retornado pela foundation.

Para tabelas com `partition projection` usando `pais = injected`, prefira consultas com `WHERE pais = 'BR'`.

### 4.1 Validação rápida das gold tables

```sql
SELECT * FROM dev_gold_clientes.cliente_360 WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_parceiros.parceiros_ativos WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_contas.contas_ativas WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_transacoes.transacoes_curated WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR' LIMIT 10;
```

### 4.2 Validação específica do domínio riscos

```sql
SELECT count(*) FROM dev_bronze_riscos.riscos_raw WHERE pais = 'BR';
SELECT count(*) FROM dev_silver_riscos.riscos WHERE pais = 'BR';
SELECT count(*) FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR';
```

## 5. Validação de governança

Depois da validação admin, assuma as roles consumidoras da foundation pela console ou CLI e teste os workgroups correspondentes.

Resultado esperado no domínio `riscos`:

- `auditoria`: acessa `dev_gold_riscos.alertas_fraude` sem filtro de linha nem exclusão de coluna
- `bi`: vê apenas `pais = 'BR'` e não enxerga a coluna `score_risco`
- `risco-fraude`: vê apenas `pais = 'BR'` e enxerga `score_risco`
- `data-science` e `data-warehouse`: não consomem o data product `riscos` hoje
- consumidores não enxergam `bronze` nem `silver`

## 6. Destruição

Antes de destruir `riscos`, vale pausar os agendamentos e parar o streaming ativo:

```powershell
aws events disable-rule --name lfmesh-dev-riscos-producer-5min
aws events disable-rule --name lfmesh-dev-riscos-start-streaming-job-15min
aws glue get-job-runs --job-name lfmesh-dev-riscos-streaming-to-bronze --max-results 5
aws glue batch-stop-job-run --job-name lfmesh-dev-riscos-streaming-to-bronze --job-run-ids <job-run-id>
```

Depois destrua em ordem reversa:

```powershell
Set-Location envs/dev/domains/riscos
terraform destroy

Set-Location ../transacoes
terraform destroy

Set-Location ../contas
terraform destroy

Set-Location ../parceiros
terraform destroy

Set-Location ../clientes
terraform destroy

Set-Location ../../foundation
terraform destroy
```

Se o objetivo for só economizar custo, destruir `transacoes`, `contas` e `riscos` primeiro já elimina a maior parte do gasto recorrente do lab.
