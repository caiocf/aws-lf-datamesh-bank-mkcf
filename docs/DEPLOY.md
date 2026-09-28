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

1. `parceiros`
2. `contas`
3. `transacoes`
4. `riscos`
5. `clientes`

`clientes` concede permissoes sobre as tabelas gold de `contas`, `transacoes` e `riscos`. Esses catalogos precisam existir antes dos grants, mesmo sem dados; caso contrario, o apply retorna `Table not found`.

Como alternativa aos comandos manuais abaixo, prepare os arquivos `terraform.tfvars` de cada dominio e execute, na raiz do repositorio, `make init-domains`, `make plan-domains` e `make apply-domains`. O Makefile respeita essa ordem, para no primeiro erro e por padrao solicita confirmacao em cada apply. As camadas `consumer-roles`, `foundation` e `network` devem estar prontas antes. Para um unico dominio, use por exemplo `make apply-domain DOMAIN=clientes`.

Para aplicar os dominios sem confirmacao interativa, habilite explicitamente a opcao:

```bash
make apply-domains AUTO_APPROVE=true
```

`AUTO_APPROVE` e `false` por padrao. Com `true`, dispensa a confirmacao do Terraform em `apply-domains` e `apply-domain`, por exemplo `make apply-domain DOMAIN=clientes AUTO_APPROVE=true`. Nesses alvos, aprova todas as acoes do plano, incluindo eventuais alteracoes e exclusoes, e nao reutiliza o plano exibido anteriormente por `make plan-domains`.

A mesma opcao dispensa a confirmacao `DESTRUIR` do script em `cleanup`, `cleanup-windows` e `destroy-domain`, autorizando a limpeza completa ou do dominio selecionado. Os demais alvos do Makefile nao usam `AUTO_APPROVE`.

### 5.1 parceiros

```powershell
Set-Location ../domains/parceiros
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- o deploy cria `API Gateway`, Lambda ingestor, `EventBridge` e workflow Glue
- o API Gateway grava access logs no CloudWatch para auditoria
- o `terraform apply` invoca a Lambda uma vez para semear a primeira carga
- depois disso, o schedule diario continua disparando a Lambda, que grava no bronze e inicia o workflow

### 5.2 contas

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

### 5.3 transacoes

```powershell
Set-Location ../transacoes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- este dominio cria `MSK Provisioned`, `MSK Connect`, `Secrets Manager`, `KMS` e jobs Glue
- apos o deploy, o producer roda a cada 5 minutos e inicia o workflow; o trigger horario do Glue fica desativado para evitar disparos duplicados
- o workflow de transacoes permite uma execucao por vez (`max_concurrent_runs = 1`); se estiver ocupado, a Lambda mantem a publicacao Kafka e ignora apenas o novo disparo. O proximo agendamento tenta novamente. Outros erros continuam sendo reportados
- o limite vale para execucoes do workflow; evite iniciar jobs individuais manualmente em paralelo, pois isso contorna a protecao do pipeline

### 5.4 riscos

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

### 5.5 clientes

```powershell
Set-Location ../clientes
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Observacao:

- o deploy cria `EventBridge`, uma Lambda orquestradora e o workflow Glue
- o `terraform apply` invoca a Lambda uma vez para disparar a primeira execucao
- depois disso, o schedule diario passa a chamar a Lambda, que por sua vez executa `StartWorkflowRun`

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

Use o fluxo comum de limpeza (Python 3.9+, AWS CLI e Terraform):

```powershell
make cleanup
# Apenas quando a destruicao ja estiver autorizada:
make cleanup AUTO_APPROVE=true
# Um dominio:
make destroy-domain DOMAIN=riscos
```

O script para agendamentos e escritores (Glue, DMS e MSK Connect), aguarda a parada e esvazia os buckets incluindo todas as versoes e delete markers. A ordem do Terraform e observabilidade, clientes, riscos, transacoes, contas, parceiros, foundation, consumer-roles e network. A limpeza usa os states locais de `envs/<ambiente>` e recusa locks existentes.

`aws s3 rm --recursive` e `aws s3 rb --force` nao removem todas as versoes de buckets versionados. O helper `scripts/empty-lab-buckets.py` usa `VersionId`, lotes de ate 1.000, valida erros individuais e confere se o bucket ficou vazio. Nao force detach de ENIs de servicos ainda ativos.

Para diagnosticar o escopo sem excluir:

```powershell
python scripts/empty-lab-buckets.py --domain riscos
```

Se o objetivo for so economizar custo, destruir `transacoes`, `contas` e `riscos` primeiro ja elimina a maior parte do gasto recorrente do lab.
