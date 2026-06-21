# Observabilidade — Estratégia Multi-Account

Este documento define a estratégia de observabilidade do data mesh bancário, modelada para um cenário multi-account real onde cada domínio opera em sua própria conta AWS.

## Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│               Conta de Observabilidade Central               │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  CloudWatch Cross-Account Dashboard                    │  │
│  │  (métricas agregadas via OAM de todas as contas)       │  │
│  └────────────────────────────────────────────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐     │
│  │ SNS Critical │  │ SNS Warning  │  │ SNS DataQuality│     │
│  │ (PagerDuty)  │  │ (Slack)      │  │ (Equipe dados) │     │
│  └──────────────┘  └──────────────┘  └────────────────┘     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  CloudWatch Observability Access Manager — OAM Sink    │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
         ▲         ▲         ▲         ▲         ▲
         │OAM Link │OAM Link │OAM Link │OAM Link │OAM Link
┌────────┴──┐ ┌────┴─────┐ ┌─┴──────┐ ┌┴─────────┐ ┌┴────────┐
│ Clientes  │ │Parceiros │ │ Contas │ │Transacoes│ │ Riscos  │
│           │ │          │ │        │ │          │ │         │
│ • Alarmes │ │ • Alarmes│ │• Alarmes│ │• Alarmes │ │• Alarmes│
│ • Logs    │ │ • Logs   │ │• Logs  │ │• Logs    │ │• Logs   │
└───────────┘ └──────────┘ └────────┘ └──────────┘ └─────────┘
```

## Responsabilidades por camada

| Camada | Dono | Responsabilidade |
|--------|------|------------------|
| Conta produtora (domínio) | Equipe do domínio | Alarmes locais, logs com retenção local, OAM Link para conta central |
| Conta de observabilidade | Plataforma / SRE | OAM Sink, dashboard cross-account, SNS → integrações |
| Conta de log archive | Segurança | Retenção de longo prazo via subscription filters (fora do escopo deste lab) |

## Simulação no lab (conta única)

No lab atual, cada domínio é um diretório Terraform separado simulando uma conta. A observabilidade segue o mesmo padrão:

- `modules/observability-domain` → instanciado por cada domínio (alarmes locais)
- `modules/observability-central` → instanciado em `envs/dev/observability/` (dashboard + SNS + EventBridge rules + Log Group de falhas)
- OAM Links não funcionam same-account — no lab, o dashboard referencia métricas diretamente

## SLIs e SLOs (referencia de design — nao implementados como tracking)

A tabela abaixo define os indicadores e objetivos que seriam monitorados em producao. No lab, os **alarmes implementados** cobrem a deteccao de violacao (threshold breaching), mas nao calculam percentuais de conformidade nem error budgets.

| Dominio | SLI | SLO | Alarme que cobre |
|---------|-----|-----|------------------|
| clientes | Glue Workflow success rate | ≥ 99% (7d) | `glue-job-failed` (detecta falha, sem % calc) |
| clientes | Tempo ingestao ate gold | ≤ 15 min | `glue-job-duration-high` (alerta se > 80% timeout) |
| parceiros | Glue Workflow success rate | ≥ 99% (7d) | `glue-job-failed` |
| contas | DMS CDC latency (source) | ≤ 5 min | `dms-cdc-latency-source > 300s` ✅ |
| contas | DMS task uptime | continuous | `dms-task-stopped` ✅ |
| contas | Glue Workflow success rate | ≥ 99% (7d) | `glue-job-failed` |
| transacoes | MSK consumer lag (offset) | ≤ 10.000 msgs | `msk-offset-lag > 10000` ✅ |
| transacoes | MSK Connect uptime | ≥ 99.5% (7d) | `msk-connect-failed` (detecta queda, sem % calc) |
| transacoes | Glue Workflow success rate | ≥ 99% (7d) | `glue-job-failed` |
| riscos | Glue Streaming uptime | ≥ 99% (7d) | `glue-streaming-stopped` (detecta parada, sem % calc) |
| riscos | MSK consumer lag (tempo) | ≤ 10 min | `msk-time-lag > 600s` ✅ |
| riscos | Glue Workflow success rate | ≥ 99% (7d) | `glue-job-failed` |
| todos | Data freshness (gold) | ≤ 2 horas | ❌ Nao implementado |

> **Nota:** A métrica `GoldDataAgeSeconds` (namespace `DataMesh/<domain>`) está definida como evolução futura. Requer Lambda que publique `now() - LastModified` do último objeto no bucket gold.

## Matriz de Alarmes — Implementados (43 alarmes)

### Glue Job Failed (12 alarmes — Critical)

Padrao: `lfmesh-dev-<dominio>-glue-<job>-failed`

| Alarme | Dominio |
|--------|--------|
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-csv-to-parquet-failed` | clientes |
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-bronze-to-silver-failed` | clientes |
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-silver-to-gold-failed` | clientes |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-api-to-parquet-failed` | parceiros |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-bronze-to-silver-failed` | parceiros |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-silver-to-gold-failed` | parceiros |
| `lfmesh-dev-contas-glue-lfmesh-dev-contas-bronze-to-silver-failed` | contas |
| `lfmesh-dev-contas-glue-lfmesh-dev-contas-silver-to-gold-failed` | contas |
| `lfmesh-dev-transacoes-glue-lfmesh-dev-transacoes-bronze-to-silver-failed` | transacoes |
| `lfmesh-dev-transacoes-glue-lfmesh-dev-transacoes-silver-to-gold-failed` | transacoes |
| `lfmesh-dev-riscos-glue-lfmesh-dev-riscos-bronze-to-silver-failed` | riscos |
| `lfmesh-dev-riscos-glue-lfmesh-dev-riscos-silver-to-gold-failed` | riscos |

Metrica: `Glue / numFailedTasks >= 1` | Period: 5 min | MissingData: notBreaching

### Glue Job Duration High (12 alarmes — Warning)

Padrao: `lfmesh-dev-<dominio>-glue-<job>-duration-high`

| Alarme | Dominio |
|--------|--------|
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-csv-to-parquet-duration-high` | clientes |
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-bronze-to-silver-duration-high` | clientes |
| `lfmesh-dev-clientes-glue-lfmesh-dev-clientes-silver-to-gold-duration-high` | clientes |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-api-to-parquet-duration-high` | parceiros |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-bronze-to-silver-duration-high` | parceiros |
| `lfmesh-dev-parceiros-glue-lfmesh-dev-parceiros-silver-to-gold-duration-high` | parceiros |
| `lfmesh-dev-contas-glue-lfmesh-dev-contas-bronze-to-silver-duration-high` | contas |
| `lfmesh-dev-contas-glue-lfmesh-dev-contas-silver-to-gold-duration-high` | contas |
| `lfmesh-dev-transacoes-glue-lfmesh-dev-transacoes-bronze-to-silver-duration-high` | transacoes |
| `lfmesh-dev-transacoes-glue-lfmesh-dev-transacoes-silver-to-gold-duration-high` | transacoes |
| `lfmesh-dev-riscos-glue-lfmesh-dev-riscos-bronze-to-silver-duration-high` | riscos |
| `lfmesh-dev-riscos-glue-lfmesh-dev-riscos-silver-to-gold-duration-high` | riscos |

Metrica: `Glue / elapsedTime > 480000ms` (80% de 10 min timeout) | Period: 5 min | MissingData: notBreaching

### Lambda Errors (6 alarmes — Warning)

| Alarme | Dominio |
|--------|--------|
| `lfmesh-dev-clientes-lambda-lfmesh-dev-clientes-workflow-starter-errors` | clientes |
| `lfmesh-dev-parceiros-lambda-lfmesh-dev-parceiros-workflow-starter-errors` | parceiros |
| `lfmesh-dev-contas-lambda-lfmesh-dev-contas-db-seed-errors` | contas |
| `lfmesh-dev-transacoes-lambda-lfmesh-dev-transacoes-producer-errors` | transacoes |
| `lfmesh-dev-riscos-lambda-lfmesh-dev-riscos-producer-errors` | riscos |
| `lfmesh-dev-riscos-lambda-lfmesh-dev-riscos-start-streaming-job-errors` | riscos |

Metrica: `AWS/Lambda / Errors >= 1` | Period: 5 min | MissingData: notBreaching

### Lambda Throttles (6 alarmes — Warning)

| Alarme | Dominio |
|--------|--------|
| `lfmesh-dev-clientes-lambda-lfmesh-dev-clientes-workflow-starter-throttles` | clientes |
| `lfmesh-dev-parceiros-lambda-lfmesh-dev-parceiros-workflow-starter-throttles` | parceiros |
| `lfmesh-dev-contas-lambda-lfmesh-dev-contas-db-seed-throttles` | contas |
| `lfmesh-dev-transacoes-lambda-lfmesh-dev-transacoes-producer-throttles` | transacoes |
| `lfmesh-dev-riscos-lambda-lfmesh-dev-riscos-producer-throttles` | riscos |
| `lfmesh-dev-riscos-lambda-lfmesh-dev-riscos-start-streaming-job-throttles` | riscos |

Metrica: `AWS/Lambda / Throttles >= 1` | Period: 5 min | MissingData: notBreaching

### DMS (3 alarmes — contas)

| Alarme | Metrica | Condicao | Severidade |
|--------|---------|----------|------------|
| `lfmesh-dev-contas-dms-cdc-latency-source` | CDCLatencySource | > 300s | Critical |
| `lfmesh-dev-contas-dms-cdc-latency-target` | CDCLatencyTarget | > 300s | Warning |
| `lfmesh-dev-contas-dms-task-stopped` | CDCLatencySource (SampleCount) | < 1 | Critical |

Period: 5 min | EvalPeriods: 2 | MissingData: breaching (detecta task parado)

### MSK (3 alarmes — transacoes)

| Alarme | Metrica | Condicao | Severidade |
|--------|---------|----------|------------|
| `lfmesh-dev-transacoes-msk-offset-lag` | MaxOffsetLag | > 10.000 | Warning |
| `lfmesh-dev-transacoes-msk-time-lag` | EstimatedMaxTimeLag | > 600s | Critical |
| `lfmesh-dev-transacoes-msk-connect-failed` | RunningTaskCount | < 1 | Critical |

Period: 5 min | EvalPeriods: 2 | MissingData: notBreaching (lag) / breaching (connect)

### Glue Streaming (1 alarme — riscos)

| Alarme | Metrica | Condicao | Severidade |
|--------|---------|----------|------------|
| `lfmesh-dev-riscos-glue-streaming-stopped` | numCompletedTasks | < 1 por 10 min | Critical |

Period: 5 min | EvalPeriods: 2 | MissingData: breaching

### Não implementados (evolução futura)

| Tipo | Descrição | Motivo |
|------|-----------|--------|
| Composite alarm | ≥ 2 domínios com Glue failure simultâneo | Requer dados históricos para calibrar |
| Data Freshness | `GoldDataAgeSeconds > 7200` | Requer Lambda custom para publicar métrica |
| Cross-domain correlation | Falha em contas + transacoes | Requer composite alarm |

## Runbooks

### RUN-001: Glue Job Failed

**Sintoma**: Alarme `<domain>-glue-<job>-failed` disparou ou job aparece no painel "SOMENTE os que falharam".

**Passos**:
1. Verifique o painel Log Insights no dashboard — mostra job name, estado e horário
2. Acesse Glue Console → Jobs → selecione o job com falha
3. Causas comuns:
   - `Max concurrent runs exceeded` → transitório, próxima execução resolve
   - `File not present on S3` → pipeline upstream falhou ou DMS reload em andamento
   - Out of memory → aumentar worker_type ou number_of_workers
4. Re-execute o workflow manualmente após correção:
   ```bash
   aws glue start-workflow-run --name <workflow-name>
   ```

### RUN-002: DMS CDC Latency Alta / Task Parado

**Sintoma**: Alarme `contas-dms-cdc-latency-source` ou `contas-dms-task-stopped` disparou.

**Passos**:
1. Verifique status da task: `aws dms describe-replication-tasks --filters Name=replication-task-id,Values=lfmesh-dev-contas-cdc`
2. Se status = `failed` com erro `WAL conversational protocol error`:
   - O replication slot foi invalidado por inatividade
   - Parar e reiniciar com reload:
     ```bash
     aws dms stop-replication-task --replication-task-arn <arn>
     # Aguardar status "stopped"
     aws dms start-replication-task --replication-task-arn <arn> --start-replication-task-type reload-target
     ```
3. Causas comuns:
   - RDS com carga elevada → verificar painel RDS (CPU/connections)
   - WAL acumulado > `max_slot_wal_keep_size` (10 GB) → slot invalidado
   - Network issues → verificar security groups e VPC endpoints
4. **Prevenção implementada:** HeartbeatConfig habilitado (grava heartbeat a cada 5 min no PostgreSQL para manter o slot ativo)

### RUN-003: MSK Consumer Lag Alto

**Sintoma**: Alarme `transacoes-msk-offset-lag` ou `transacoes-msk-time-lag` disparou.

**Passos**:
1. Verifique se o consumer está ativo:
   - transacoes: painel "MSK Connect" → RunningTaskCount deve ser 1
   - riscos: painel "Glue Streaming" → numCompletedTasks deve ser > 0
2. Causas comuns:
   - Consumer parou → reiniciar connector/streaming job
   - Burst de produção → lag temporário, monitorar tendência
   - Under-provisioned → aumentar MCU (connector) ou workers (Glue)
3. Para riscos, o watchdog (Lambda a cada 15 min) deve reiniciar automaticamente

### RUN-004: MSK Connect Connector Failed

**Sintoma**: Alarme `transacoes-msk-connect-failed` disparou.

**Passos**:
1. `aws kafkaconnect describe-connector --connector-arn <arn>`
2. Verifique logs em `/aws/msk-connect/lfmesh-dev-transacoes`
3. Causas comuns:
   - Credenciais SCRAM expiradas → rotacionar secret
   - S3 permission denied → verificar IAM role do connector
   - Topic deletado → recriar com producer Lambda
4. Recrie o connector se necessário (MSK Connect não tem restart nativo)

### RUN-005: Glue Streaming Parou (riscos)

**Sintoma**: Alarme `riscos-glue-streaming-stopped` disparou.

**Passos**:
1. Verificar se o watchdog Lambda reiniciou o job (verificar logs `/aws/lambda/lfmesh-dev-riscos-start-streaming-job`)
2. Se não reiniciou:
   ```bash
   aws glue start-job-run --job-name lfmesh-dev-riscos-streaming-to-bronze
   ```
3. Causas comuns:
   - MSK Serverless indisponível → verificar cluster status
   - Checkpoint corruption → limpar checkpoint no S3 e reiniciar
   - Erro no script → verificar logs em `/aws-glue/jobs/lfmesh-dev-riscos-streaming`
4. **Nota:** O job roda com `timeout=0` (ilimitado, recomendação AWS para streaming). O watchdog Lambda (a cada 15 min) reinicia automaticamente se o job parar.

## Dashboard — Layout

O dashboard central `lfmesh-dev-observability` contém 11 widgets:

```
┌─────────────────────────────────────────────────────────────┐
│  [TEXT] Header — visão geral dos widgets e legenda           │
├─────────────────────────────────────────────────────────────┤
│  [LINE] Glue Jobs — Duração por Job (segundos)               │
├──────────────────────────────┬──────────────────────────────┤
│  [LINE] Succeeded vs Failed   │  [LOG] SOMENTE os que       │
│  (contagem total EventBridge) │  falharam (nome+estado+hora)│
├──────────────────────────────┼──────────────────────────────┤
│  [LINE] Lambda — Errors       │  [LINE] Lambda — Invocations│
├──────────────────────────────┴──────────────────────────────┤
│  [LINE] DMS — CDC Latency + Incoming Changes                │
├─────────────────────────────────────────────────────────────┤
│  [LINE] RDS — CPU | Conexões | Storage Total vs Livre | IOPS│
├──────────────────────────────┬──────────────────────────────┤
│  [LINE] MSK — Consumer Lag    │  [LINE] MSK Connect — S3    │
│  (offset + bytes/s)           │  Sink (tasks + records/s)   │
├──────────────────────────────┼──────────────────────────────┤
│  [LINE] Glue Streaming —      │  [LINE] Data Volume —       │
│  micro-batches processados    │  Objetos Gold + Requests    │
└──────────────────────────────┴──────────────────────────────┘
```

Dashboard URL: `https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=lfmesh-dev-observability`

## Evidências

Snapshots dos painéis, status dos alarmes e incidentes resolvidos estão em [EVIDENCIAS-OBSERVABILIDADE.md](EVIDENCIAS-OBSERVABILIDADE.md).

## Deploy

```bash
# Após todos os domínios estarem aplicados
cd envs/dev/observability
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

A observabilidade deve ser aplicada **depois** dos domínios para que as métricas referenciadas existam.

## Evolução para multi-account real

Quando migrar para contas separadas:

1. Criar conta dedicada de observabilidade no AWS Organizations
2. Criar OAM Sink na conta central
3. Em cada conta de domínio, criar OAM Link apontando para o Sink
4. Dashboard cross-account usa `accountId` nos widgets para referenciar métricas de outras contas
5. SNS na conta central recebe alarmes via EventBridge cross-account ou CloudWatch cross-account actions
6. Logs de longo prazo via subscription filter → conta de log archive
7. Implementar métricas custom (GoldDataAgeSeconds, RecordsProcessed) via Lambda em cada domínio
8. Criar composite alarms para correlação cross-domain
