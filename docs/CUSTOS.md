# Guia de custos

## Resumo rapido

O projeto deixou de ser um lab "quase gratis" depois das fases `contas`, `transacoes` e `riscos`.

Hoje, os maiores drivers de custo sao:

- `network`: `VPC Interface Endpoints` compartilhados de `Secrets Manager` e `Glue`
- `contas`: `RDS PostgreSQL` + `DMS` + execucao horaria de jobs Glue
- `transacoes`: `MSK Provisioned` + `MSK Connect` + jobs Glue
- `riscos`: `Glue Streaming` ativo quase continuo + `MSK Serverless` por uso + jobs Glue

`clientes`, `parceiros`, `Lake Formation`, `Glue Data Catalog`, `IAM` e S3 com poucos dados continuam baratos. O problema nao esta no catalogo; esta nos servicos de ingestao continua, streaming e infraestrutura conectada a VPC deixados ativos.

## Premissas deste documento

- regiao do repositorio: `us-east-1`
- valores abaixo sao ordem de grandeza, nao fechamento contabil
- preco real varia por regiao, volume de dados, tempo ativo, storage, logs e Free Tier
- antes de deixar o ambiente ativo por dias, confirme no AWS Pricing Calculator e no Cost Explorer

## Leitura pratica por estado

| Estado ou dominio | Recursos principais | Perfil de custo |
| --- | --- | --- |
| `network` | `S3 Gateway Endpoint` + `Glue Interface Endpoint` + `Secrets Manager Interface Endpoint` | recorrente baixo a moderado |
| `clientes` | S3 + Glue Python Shell + Athena | baixo, custo por execucao |
| `parceiros` | API Gateway + Lambda + 2 jobs Glue | baixo a moderado, custo por execucao |
| `contas` | RDS `db.t3.micro` + DMS `dms.t3.small` + Secrets Manager + Glue | recorrente, mesmo parado |
| `transacoes` | MSK Provisioned + MSK Connect + Secret + KMS + Glue | recorrente e significativo |
| `riscos` | MSK Serverless + Glue Streaming + EventBridge + Glue | barato parado, caro se o streaming ficar ativo |

## 1. Shared network

Depois da refatoracao para `envs/dev/network`, parte do custo de rede ficou centralizada.

Recursos compartilhados desse estado:

- `S3 Gateway Endpoint`
- `Secrets Manager Interface Endpoint`
- `Glue Interface Endpoint`

Leitura pratica:

- o `S3 Gateway Endpoint` nao costuma ser o problema principal
- os `Interface Endpoints` criam custo recorrente enquanto o estado `network` estiver ativo
- em compensacao, essa centralizacao elimina duplicacao de endpoints entre dominios e reduz conflito entre estados Terraform

## 2. Athena

Athena nao e o problema principal deste lab.

- em consultas pequenas, o custo e quase irrelevante
- o risco cresce quando voce faz `SELECT *` em tabelas grandes ou sem pruning
- como o projeto usa Parquet e particionamento por `pais`, o custo tende a ficar baixo se a consulta for bem filtrada

## 3. Glue

Glue ja faz parte forte do custo real deste repositorio.

- jobs batch de `clientes`, `parceiros`, `contas`, `transacoes` e `riscos` cobram por tempo de execucao
- o custo batch costuma ser controlavel porque os jobs rodam por poucos minutos
- o problema maior e o `Glue Streaming`, porque ele pode ficar ativo continuamente

### 3.1 Impacto do dominio `riscos`

O job `lfmesh-dev-riscos-streaming-to-bronze` esta configurado com:

- `2` workers `G.1X`
- micro-batch de `60 seconds`
- watchdog a cada `15 minutos`, que volta a subir o job se ele parar

Estimativa pratica:

- assumindo `1 worker G.1X ~= 1 DPU`, o streaming fica em torno de `2 DPUs`
- `2 * $0.44 = ~$0.88/hora`
- `~$21.12/dia`
- `~$633.60` em 30 dias, se ficar praticamente sempre ativo

Essa conta e uma inferencia operacional baseada no preco oficial por `DPU-hour`. O valor exato depende do runtime real e da regiao, mas a conclusao importante nao muda: no dominio `riscos`, o `Glue Streaming` e o principal custo do lab enquanto houver run ativa.

## 4. Continuo / CDC (`contas`)

O dominio `contas` nao e caro por query; ele e caro por permanecer ligado.

Recursos que continuam cobrando:

- `RDS PostgreSQL db.t3.micro`
- `DMS dms.t3.small` quando em modo provisionado
- `Secrets Manager`
- S3, logs e jobs Glue horarios

## 5. Streaming provisionado (`transacoes`)

O dominio `transacoes` e um dos mais caros do projeto porque junta componentes 24x7:

- `MSK Provisioned` com `2 brokers`
- `MSK Connect`
- `Secrets Manager`
- `KMS` customer-managed key
- workflow Glue horario

Conclusao pratica:

- `transacoes` nao e um dominio barato para deixar ativo por varios dias
- se o objetivo for estudo pontual, destrua esse dominio quando terminar

## 6. Custos secundarios que continuam existindo

Alem dos grandes componentes, ainda existem custos menores, mas recorrentes:

- `VPC Interface Endpoints` compartilhados da camada `network`
- `Secrets Manager`
- `CloudWatch Logs`
- `S3` storage e requests
- `KMS` customer-managed key no dominio `transacoes`
- EventBridge invocations

## 7. Como reduzir custo rapido

### Pausar `riscos`

Desabilite os schedules e pare o Glue Streaming:

```powershell
aws events disable-rule --name lfmesh-dev-riscos-producer-5min
aws events disable-rule --name lfmesh-dev-riscos-start-streaming-job-15min
aws glue get-job-runs --job-name lfmesh-dev-riscos-streaming-to-bronze --max-results 5
aws glue batch-stop-job-run --job-name lfmesh-dev-riscos-streaming-to-bronze --job-run-ids <job-run-id>
```

### Eliminar custo recorrente de verdade

Se nao for usar o ambiente por mais tempo:

- destrua `transacoes`
- destrua `contas`
- destrua `riscos`
- destrua `network`

Esses estados concentram quase todo o gasto recorrente relevante.

## 8. Monitoramento recomendado

### AWS Budgets

Crie pelo menos um budget mensal para nao deixar o lab escapar.

### Cost Explorer

Na console:

1. abra `Cost Explorer`
2. filtre os ultimos `30 dias`
3. agrupe por `Service`
4. confirme principalmente `AWS Glue`, `Amazon MSK`, `AWS DMS`, `Amazon RDS`, `AWS Secrets Manager` e `Amazon VPC`

## Resumo final

Estado atual do projeto:

- `network`: pequeno a moderado, mas recorrente
- `clientes` e `parceiros`: baratos
- `contas`: custo recorrente moderado
- `transacoes`: custo recorrente alto
- `riscos`: pode ficar alto rapidamente se o `Glue Streaming` continuar ativo

Se o objetivo e defesa de banca, demo ou estudo pontual, a estrategia correta e:

- subir
- validar
- testar governanca
- destruir ou pausar os estados caros logo depois
