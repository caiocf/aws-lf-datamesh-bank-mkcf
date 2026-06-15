# Guia de custos

## Resumo rápido

O projeto deixou de ser um lab "quase grátis" depois das fases `contas`, `transacoes` e `riscos`.

Hoje, os maiores drivers de custo são:

- `contas`: `RDS PostgreSQL` + `DMS` + execução horária de jobs Glue
- `transacoes`: `MSK Provisionado` + `MSK Connect` + jobs Glue
- `riscos`: `Glue Streaming` ativo quase contínuo + `MSK Serverless` por uso + jobs Glue

`clientes`, `parceiros`, `Lake Formation`, `Glue Data Catalog`, `IAM` e S3 com poucos dados continuam baratos. O problema não está no catálogo; está nos serviços de ingestão contínua e streaming deixados ativos.

## Premissas deste documento

- Região do repositório: `us-east-1`
- Valores abaixo são ordem de grandeza, não fechamento contábil
- Preço real varia por região, volume de dados, tempo ativo, storage, logs e Free Tier
- Antes de deixar o ambiente ativo por dias, confirme no AWS Pricing Calculator e no Cost Explorer

## Referências oficiais úteis

- `Athena SQL`: a AWS cobra por dados escaneados; o exemplo oficial usa `3 * $5/TB = $15`
- `AWS Glue ETL`: a página oficial usa `$0.44 por DPU-hour`
- `Glue Data Catalog`: primeiros `1 milhão` de objetos e `1 milhão` de acessos por mês continuam gratuitos
- `Lake Formation`: sem cobrança separada para permissões integradas ao catálogo
- `DMS`: on-demand e serverless cobram por hora, sem compromisso antecipado
- `MSK Serverless`: cobra por `cluster-hour`, `partition-hour`, `GB-in`, `GB-out` e storage
- `MSK Connect`: o exemplo oficial em `us-east-1` usa `$0.11 por MCU-hour`

## Leitura prática por domínio

| Domínio | Recursos principais | Perfil de custo |
|---|---|---|
| `clientes` | S3 + Glue Python Shell + Athena | baixo, custo por execução |
| `parceiros` | API Gateway + Lambda + 2 jobs Glue | baixo a moderado, custo por execução |
| `contas` | RDS `db.t3.micro` + DMS `dms.t3.small` + Secrets Manager + Glue | recorrente, mesmo parado |
| `transacoes` | MSK Provisionado + MSK Connect + Secret + KMS + Glue | recorrente e significativo |
| `riscos` | MSK Serverless + Glue Streaming + EventBridge + Glue | barato parado, caro se o streaming ficar ativo |

## 1. Athena

Athena não é o problema principal deste lab.

- Em consultas pequenas, o custo é quase irrelevante
- O risco cresce quando você faz `SELECT *` em tabelas grandes ou sem pruning
- Como o projeto usa Parquet e particionamento por `pais`, o custo tende a ficar baixo se a consulta for bem filtrada

## 2. Glue

Glue já faz parte forte do custo real deste repositório.

- Jobs batch de `clientes`, `parceiros`, `contas`, `transacoes` e `riscos` cobram por tempo de execução
- A página oficial da AWS usa `$0.44 por DPU-hour`
- O custo batch costuma ser controlável porque os jobs rodam por poucos minutos
- O problema maior é o `Glue Streaming`, porque ele pode ficar ativo continuamente

### 2.1 Impacto do domínio `riscos`

O job `lfmesh-dev-riscos-streaming-to-bronze` está configurado com:

- `2` workers `G.1X`
- micro-batch de `60 seconds`
- watchdog a cada `15 minutos`, que volta a subir o job se ele parar

Estimativa prática:

- assumindo `1 worker G.1X ~= 1 DPU`, o streaming fica em torno de `2 DPUs`
- `2 * $0.44 = ~$0.88/hora`
- `~$21.12/dia`
- `~$633.60` em 30 dias, se ficar praticamente sempre ativo

Essa conta é uma inferência operacional baseada no preço oficial por `DPU-hour`. O valor exato depende do runtime real e da região, mas a conclusão importante não muda: no domínio `riscos`, o `Glue Streaming` é o principal custo do lab enquanto houver run ativa.

Os jobs batch horários `bronze-to-silver` e `silver-to-gold` somam custo extra, mas pequeno perto do streaming contínuo.

## 3. Contínuo / CDC (`contas`)

O domínio `contas` não é caro por query; ele é caro por permanecer ligado.

Recursos que continuam cobrando:

- `RDS PostgreSQL db.t3.micro`
- `DMS dms.t3.small` quando em modo provisionado
- `Secrets Manager`
- S3, logs e jobs Glue horários

Ou seja: mesmo sem muita atividade, esse domínio continua gerando custo por infraestrutura base.

## 4. Streaming provisionado (`transacoes`)

O domínio `transacoes` é um dos mais caros do projeto porque junta componentes 24x7:

- `MSK Provisionado` com `2 brokers`
- `MSK Connect`
- `Secrets Manager`
- `KMS` customer-managed key
- workflow Glue horário

Ponto importante:

- o `MSK Connect` está configurado com `1 worker` e `1 MCU`
- usando a referência oficial de `$0.11 por MCU-hour` em `us-east-1`, só o connector fica na ordem de:
  - `744 horas/mês * $0.11 = ~$81.84/mês`
- isso ainda não inclui o custo do cluster `MSK Provisionado`, storage, logs e jobs Glue

Conclusão prática:

- `transacoes` não é um domínio barato para deixar ativo por vários dias
- se o objetivo for estudo pontual, destrua esse domínio quando terminar

## 5. MSK Serverless

`MSK Serverless` melhora o custo parado em relação ao MSK Provisionado, mas não torna o pipeline todo barato sozinho.

No domínio `riscos`:

- o cluster serverless cobra por uso real
- porém o custo dominante passa a ser o consumer em `Glue Streaming`
- por isso o ganho de serverless fica parcialmente anulado quando o streaming roda quase o tempo todo

## 6. Custos secundários que continuam existindo

Além dos grandes componentes, ainda existem custos menores, mas recorrentes:

- `Secrets Manager`
- `CloudWatch Logs`
- `S3` storage e requests
- `KMS` customer-managed key no domínio `transacoes`
- EventBridge invocations

Sozinhos eles não são o maior problema, mas somam no total.

## 7. Como reduzir custo rápido

### Pausar `riscos`

Desabilite os schedules e pare o Glue Streaming:

```powershell
aws events disable-rule --name lfmesh-dev-riscos-producer-5min
aws events disable-rule --name lfmesh-dev-riscos-start-streaming-job-15min
aws glue get-job-runs --job-name lfmesh-dev-riscos-streaming-to-bronze --max-results 5
aws glue batch-stop-job-run --job-name lfmesh-dev-riscos-streaming-to-bronze --job-run-ids <job-run-id>
```

### Eliminar custo recorrente de verdade

Se não for usar o ambiente por mais tempo:

- destrua `transacoes`
- destrua `contas`
- destrua `riscos`

Esses três domínios concentram quase todo o gasto recorrente relevante.

## 8. Monitoramento recomendado

### AWS Budgets

Crie pelo menos um budget mensal para não deixar o lab escapar:

```powershell
aws budgets create-budget `
  --account-id (aws sts get-caller-identity --query Account --output text) `
  --budget '{
    "BudgetName": "lfmesh-study-budget",
    "BudgetLimit": {"Amount": "50", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }'
```

### Cost Explorer

Na console:

1. abra `Cost Explorer`
2. filtre os últimos `30 dias`
3. agrupe por `Service`
4. confirme principalmente `AWS Glue`, `Amazon MSK`, `AWS DMS`, `Amazon RDS` e `AWS Secrets Manager`

## Resumo final

Estado atual do projeto:

- `clientes` e `parceiros`: baratos
- `contas`: custo recorrente moderado
- `transacoes`: custo recorrente alto
- `riscos`: pode ficar alto rapidamente se o `Glue Streaming` continuar ativo

Se o objetivo é defesa de banca, demo ou estudo pontual, a estratégia correta é:

- subir
- validar
- testar governança
- destruir ou pausar os domínios caros logo depois
