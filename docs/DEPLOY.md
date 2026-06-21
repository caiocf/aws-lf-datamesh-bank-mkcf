# Deploy passo a passo

## 1. Pre-requisitos

- AWS CLI autenticado na conta do lab
- Terraform instalado
- regiao usada neste repositorio: `us-east-1`
- permissao para IAM, S3, Glue, Athena, Lake Formation, Lambda, CloudWatch, RDS, DMS e MSK

Exemplo no PowerShell:

```powershell
$env:AWS_PROFILE = "seu-profile"
$env:AWS_REGION  = "us-east-1"
aws sts get-caller-identity
```

## 2. Consumer roles (opcional, mas recomendado)

Use esta etapa se quiser simular usuarios e aplicacoes consumidoras de forma mais realista.

```powershell
Set-Location envs/dev/consumer-roles
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
terraform output all_consumer_role_arns
```

Se for usar essas roles para assumir as personas do lab, depois copie os ARNs para `trusted_principal_arns` na `foundation`.

## 3. Foundation

```powershell
Set-Location ../foundation
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Guarde estes outputs, porque eles serao usados na validacao de governanca:

```powershell
terraform output consumer_role_arns
terraform output consumer_role_names
terraform output athena_workgroups
terraform output athena_results_bucket
```

## 4. Shared network

Antes dos dominios conectados a VPC, aplique a camada compartilhada `network`:

```powershell
Set-Location ../network
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Essa camada:

- usa a `default VPC` do lab
- cria os `VPC Endpoints` compartilhados de `S3`, `Secrets Manager` e `Glue`
- publica outputs consumidos por `contas`, `transacoes` e `riscos`

Importante:

- `contas`, `transacoes` e `riscos` leem `envs/dev/network/terraform.tfstate` via `terraform_remote_state`
- esses dominios continuam com `terraform apply` individual, mas o state `network` precisa existir antes

## 5. Ordem recomendada dos dominios

Esta e a ordem alinhada com o estado atual do projeto e com o plano de ingestao:

1. `clientes`
2. `parceiros`
3. `contas`
4. `transacoes`
5. `riscos`

### 5.1 clientes

```powershell
Set-Location ../domains/clientes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- o deploy cria `EventBridge`, uma Lambda orquestradora e o workflow Glue
- o `terraform apply` invoca a Lambda uma vez para disparar a primeira execucao
- depois disso, o schedule diario passa a chamar a Lambda, que por sua vez executa `StartWorkflowRun`

### 5.2 parceiros

```powershell
Set-Location ../parceiros
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- o deploy cria `API Gateway`, Lambda ingestor, `EventBridge` e workflow Glue
- o API Gateway grava access logs no CloudWatch para auditoria
- o `terraform apply` invoca a Lambda uma vez para semear a primeira carga
- depois disso, o schedule diario continua disparando a Lambda, que grava no bronze e inicia o workflow

### 5.3 contas

```powershell
Set-Location ../contas
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- este dominio cria `RDS PostgreSQL`, `DMS`, `Secrets Manager` e jobs Glue
- a Lambda seed executa dentro da VPC compartilhada (via `network`) para conectar ao RDS de forma privada
- o deploy demora mais do que `clientes` e `parceiros`

### 5.4 transacoes

```powershell
Set-Location ../transacoes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- este dominio cria `MSK Provisioned`, `MSK Connect`, `Secrets Manager`, `KMS` e jobs Glue
- apos o deploy, o producer roda a cada 5 minutos e o workflow roda de hora em hora

### 5.5 riscos

```powershell
Set-Location ../riscos
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- este dominio cria `MSK Serverless`, `Glue Streaming`, `EventBridge`, workflow batch e governanca na gold
- o producer roda a cada 5 minutos
- a Lambda `lfmesh-dev-riscos-start-streaming-job` roda a cada 15 minutos como watchdog
- o job `lfmesh-dev-riscos-streaming-to-bronze` e iniciado automaticamente no deploy

## 6. Observabilidade

```powershell
Set-Location ../../observability
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- deve ser aplicada **apos** todos os dominios para que as metricas referenciadas existam
- cria 43 alarmes CloudWatch, SNS topics, dashboard consolidado e EventBridge rules para captura de falhas
- detalhes em [OBSERVABILIDADE.md](OBSERVABILIDADE.md)

## 7. Validacao no Athena

Use primeiro seu perfil admin do Lake Formation e o workgroup retornado pela foundation.

Para tabelas com `partition projection` usando `pais = injected`, prefira consultas com `WHERE pais = 'BR'`.

Se alguma tabela ainda vier vazia logo apos o deploy, espere os jobs Glue terminarem antes de repetir o `SELECT`.

### 7.1 Validacao rapida das gold tables

```sql
SELECT * FROM dev_gold_clientes.cliente_360 WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_parceiros.parceiros_ativos WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_contas.contas_ativas WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_transacoes.transacoes_curated WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR' LIMIT 10;
```

### 7.2 Validacao especifica do dominio riscos

```sql
SELECT count(*) FROM dev_bronze_riscos.riscos_raw WHERE pais = 'BR';
SELECT count(*) FROM dev_silver_riscos.riscos WHERE pais = 'BR';
SELECT count(*) FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR';
```

## 8. Validacao de governanca

Depois da validacao admin, assuma as roles consumidoras da foundation pela console ou CLI e teste os workgroups correspondentes.

Resultado esperado no dominio `riscos`:

- `auditoria`: acessa `dev_gold_riscos.alertas_fraude` sem filtro de linha nem exclusao de coluna
- `bi`: ve apenas `pais = 'BR'` e nao enxerga a coluna `score_risco`
- `risco-fraude`: ve apenas `pais = 'BR'` e enxerga `score_risco`
- `data-science` e `data-warehouse`: nao consomem o data product `riscos` hoje
- consumidores nao enxergam `bronze` nem `silver`

## 9. Destruicao

Antes de destruir `riscos`, vale pausar os agendamentos e parar o streaming ativo:

```powershell
aws events disable-rule --name lfmesh-dev-riscos-producer-5min
aws events disable-rule --name lfmesh-dev-riscos-start-streaming-job-15min
aws glue get-job-runs --job-name lfmesh-dev-riscos-streaming-to-bronze --max-results 5
aws glue batch-stop-job-run --job-name lfmesh-dev-riscos-streaming-to-bronze --job-run-ids <job-run-id>
```

Depois destrua em ordem reversa:

```powershell
Set-Location envs/dev/observability
terraform destroy

Set-Location ../domains/riscos
terraform destroy

Set-Location ../transacoes
terraform destroy

Set-Location ../contas
terraform destroy

Set-Location ../parceiros
terraform destroy

Set-Location ../clientes
terraform destroy

Set-Location ../../network
terraform destroy

Set-Location ../foundation
terraform destroy

Set-Location ../consumer-roles
terraform destroy
```

Se o objetivo for so economizar custo, destruir `transacoes`, `contas` e `riscos` primeiro ja elimina a maior parte do gasto recorrente do lab.
