# AWS Lake Formation Data Mesh - referencia em conta unica

Este projeto Terraform implementa um laboratorio de data mesh bancario em uma unica conta AWS. O objetivo e demonstrar, de ponta a ponta, governanca com Lake Formation, catalogo com Glue, armazenamento em S3, consultas com Athena e multiplos padroes de ingestao de dados sem depender de uma topologia multi-account real.

O repositorio nao e mais um lab "quase gratis". O estado atual inclui dominios com RDS, DMS, MSK, MSK Connect, Glue Jobs e Glue Streaming. Use este projeto para estudo, demonstracao tecnica e defesa arquitetural, sempre destruindo os recursos apos o uso.

## Estado atual do laboratorio

Dominios implementados hoje:

- `clientes`
- `parceiros`
- `contas`
- `transacoes`
- `riscos`

Cada dominio simula uma conta produtora independente. A governanca central fica no modulo `foundation`, enquanto o diretorio `consumer-roles` cria principals mais realistas para simular usuarios e aplicacoes consumidoras.

Os dominios `contas`, `transacoes` e `riscos` compartilham uma baseline de rede por ambiente em `envs/dev/network`. Essa camada e a unica dona dos `VPC Endpoints` do lab e precisa ser aplicada antes dos dominios conectados a VPC.

## Matriz de dominios

| Dominio | Fonte principal | Modo de ingestao | Servicos principais | Data product gold |
| --- | --- | --- | --- | --- |
| `clientes` | CSV local | Batch diario | S3 landing, EventBridge, Lambda, Glue Python Shell (ingestao), Glue ETL PySpark (transformacao), Glue Workflow | `dev_gold_clientes.cliente_360` |
| `parceiros` | API mock JSON | Batch diario | API Gateway, EventBridge, Lambda, Glue Workflow | `dev_gold_parceiros.parceiros_ativos` |
| `contas` | PostgreSQL | CDC continuo + curadoria horaria | RDS, DMS, Lambda seed, Glue Workflow | `dev_gold_contas.contas_ativas` |
| `transacoes` | Eventos Kafka | Streaming + curadoria horaria | MSK Provisioned, Lambda, MSK Connect, Glue Workflow | `dev_gold_transacoes.transacoes_curated` |
| `riscos` | Eventos Kafka | Streaming + curadoria horaria | MSK Serverless, Lambda, Glue Streaming, Glue Workflow | `dev_gold_riscos.alertas_fraude` |

## Como o repositorio esta organizado

### `modules/consumer-roles`

Cria roles para simular usuarios e aplicacoes de contas consumidoras. Essas roles podem ser usadas como `trusted_principal_arns` na `foundation`, permitindo assumir as roles consumidoras do lab com `sts:AssumeRole`.

### `modules/foundation`

Cria os recursos centrais de governanca:

- `aws_lakeformation_data_lake_settings`
- LF-Tags corporativas
- roles consumidoras por persona
- bucket de resultados do Athena
- workgroups Athena por persona

Personas criadas na `foundation`:

- `bi`
- `data-science`
- `data-warehouse`
- `risco-fraude`
- `auditoria`

### `modules/domain`

Padrao compartilhado por todos os dominios:

- 1 bucket S3 por camada: `bronze`, `silver`, `gold`
- 1 Glue Database por camada
- Glue Tables externas
- role produtora do dominio
- roles de registro Lake Formation por camada
- registro de buckets no Lake Formation
- grants para consumidores
- Data Cells Filters por persona na camada `gold`

Cada dominio complementa esse padrao com um `ingestion.tf` proprio.

### `envs/dev/network`

Estado compartilhado de rede do ambiente:

- descobre a `default VPC` do lab
- expõe subnets padronizadas para MSK, Lambda, DMS e Glue Connection
- cria `VPC Endpoints` compartilhados para `S3`, `Secrets Manager` e `Glue`
- publica outputs consumidos por `contas`, `transacoes` e `riscos` via `terraform_remote_state`

### `modules/observability-domain`

Modulo instanciado por cada conta produtora (dominio). Cria:

- CloudWatch Alarms locais (Glue Job failed/duration, Lambda errors/throttles, DMS latency, MSK lag, MSK Connect status, Glue Streaming stopped, data freshness)
- OAM Link condicional para compartilhar metricas com conta central (multi-account real)

### `modules/observability-central`

Modulo instanciado na conta de observabilidade. Cria:

- SNS Topics (critical, warning, data-quality)
- CloudWatch Dashboard consolidado com widgets por dominio
- OAM Sink condicional para receber metricas cross-account

### `envs/dev/observability`

Instancia ambos os modulos no lab single-account. Simula a separacao de responsabilidades entre conta central e contas produtoras.

## Governanca e seguranca

O projeto usa Lake Formation como plano central de autorizacao:

- `bronze` e `silver` sao camadas internas do produtor
- `gold` e a camada exposta como data product
- consumidores recebem `DESCRIBE` nos databases e `SELECT` apenas no que for permitido
- controles finos por linha e coluna sao aplicados com `Data Cells Filters`
- buckets S3 usam `public access block` e criptografia server-side

### Mascaramento de dados (PII)

O dominio `clientes` implementa mascaramento de PII como padrao de referencia:

- **Bronze**: dado bruto preservado (copia fiel da fonte)
- **Silver**: campos originais mantidos + colunas `cpf_hash` e `email_hash` (SHA256 com salt irreversivel) para joins tecnicos
- **Gold**: campos `cpf` e `email` substituidos por versoes mascaradas (`***.***.***-XX`, `x***@dominio`) e hashes. O dado original nao existe na camada exposta

Resultado: nenhuma persona consumidora ve CPF ou email em texto claro, mesmo com acesso direto ao S3. O campo `nome` permanece em claro na gold por decisao de design (necessario para risco-fraude e auditoria), mas e controlado por Data Cells Filter — `bi` e `data-science` nao o veem. Data Science pode fazer joins cross-dominio via hash.

### Exemplos de governanca implementada

- `auditoria` recebe acesso completo aos data products gold definidos para a persona
- `bi` recebe filtros por pais e remocao de colunas sensiveis (hashes e nome) em varios dominios
- `data-science` recebe acesso a hashes para joins, sem ver nome
- `risco-fraude` recebe acesso ampliado ao dominio `riscos` e todas as colunas mascaradas de `clientes`

### Roles consumidoras e permissoes por dominio

A `foundation` cria 5 roles consumidoras que simulam personas de contas consumidoras:

| Role | Descricao | Capacidades base |
|------|-----------|------------------|
| `lfmesh-dev-consumer-bi` | Analistas BI | Athena, Glue Catalog (leitura), LF GetDataAccess |
| `lfmesh-dev-consumer-data-science` | Cientistas de dados | Idem + hashes para joins cross-dominio |
| `lfmesh-dev-consumer-data-warehouse` | Data Warehouse (Redshift Spectrum conceitual) | Idem |
| `lfmesh-dev-consumer-risco-fraude` | Time de risco e fraude | Idem + acesso ampliado a riscos |
| `lfmesh-dev-consumer-auditoria` | Auditoria e compliance | Full SELECT nos data products gold |

Matriz de acesso nos data products gold:

| Dominio / Persona | `bi` | `data-science` | `data-warehouse` | `risco-fraude` | `auditoria` |
|---|:---:|:---:|:---:|:---:|:---:|
| `cliente_360` | filtrado (sem nome, hashes) | filtrado (sem nome) | DESCRIBE apenas | filtrado (todas colunas) | full |
| `parceiros_ativos` | filtrado (BR) | filtrado (BR) | DESCRIBE apenas | DESCRIBE apenas | full |
| `contas_ativas` | filtrado (sem saldo, BR) | filtrado (BR) | DESCRIBE apenas | DESCRIBE apenas | full |
| `transacoes_curated` | filtrado (BR) | filtrado (BR) | DESCRIBE apenas | filtrado (BR) | full |
| `alertas_fraude` | filtrado (sem score_risco, BR) | DESCRIBE apenas | DESCRIBE apenas | filtrado (BR) | full |

Todas as roles usam workgroups Athena dedicados (`lfmesh-dev-<persona>`) com resultados isolados no bucket `lfmesh-dev-athena-results`.

### Usuarios e aplicacoes simulados (`consumer-roles`)

O modulo `consumer-roles` cria principals mais realistas para simular o assume-role entre contas:

Usuarios simulados:

| Role | Persona | Departamento |
|------|---------|-------------|
| `lfmesh-dev-user-ana-silva-bi` | Analista BI | business-intelligence |
| `lfmesh-dev-user-carlos-santos-ds` | Cientista de Dados | data-science |
| `lfmesh-dev-user-maria-costa-dw` | Engenheira DW | data-warehouse |
| `lfmesh-dev-user-pedro-oliveira-risk` | Analista de Risco | risk-management |
| `lfmesh-dev-user-lucia-ferreira-audit` | Auditora | audit-compliance |

Aplicacoes simuladas:

| Role | Descricao | Padrao de acesso |
|------|-----------|------------------|
| `lfmesh-dev-app-quicksight-prod` | Dashboards QuickSight | Interactive |
| `lfmesh-dev-app-sagemaker-ml` | Pipeline ML SageMaker | Batch training |
| `lfmesh-dev-app-redshift-dwh` | Data Warehouse Redshift | Scheduled ETL |
| `lfmesh-dev-app-fraud-detection-api` | API deteccao de fraude | Real-time scoring |
| `lfmesh-dev-app-compliance-reporter` | Relatorios compliance | Monthly reports |

Todos usam `sts:AssumeRole` com `ExternalId` para simular o cross-account trust de forma segura dentro da mesma conta.

## Pre-requisitos

- Terraform `>= 1.6.0`
- AWS Provider `>= 6.32.0, < 7.0`
- AWS CLI autenticado
- Regiao `us-east-1`
- Permissoes para IAM, S3, Glue, Athena, Lake Formation, Lambda, CloudWatch, RDS, DMS e MSK
- Principal executor com permissao suficiente para atuar como administrador do Lake Formation

Observacoes operacionais:

- `contas`, `transacoes` e `riscos` dependem da VPC default da conta
- `envs/dev/network` deve ser aplicado antes de `contas`, `transacoes` e `riscos`
- `contas`, `transacoes` e `riscos` leem o state local `envs/dev/network/terraform.tfstate`
- alguns dominios mantem schedules e jobs ativos em background

## Ordem recomendada de deploy

### 1. Consumer roles

Etapa recomendada quando voce quer simular usuarios e aplicacoes consumidoras de forma mais realista:

```bash
cd envs/dev/consumer-roles
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
terraform output all_consumer_role_arns
```

### 2. Foundation

```bash
cd ../foundation
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Se quiser ligar a `foundation` as roles criadas em `consumer-roles`, preencha `trusted_principal_arns` no `terraform.tfvars`. Para um lab rapido, o arquivo exemplo tambem permite deixar esse valor vazio e usar o `root` da conta como principal confiavel.

### 3. Shared network

```bash
cd ../network
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Esse estado prepara a rede compartilhada do lab para os dominios conectados a VPC.

### 4. Dominios

Ordem alinhada com o estado atual do repositorio:

1. `clientes`
2. `parceiros`
3. `contas`
4. `transacoes`
5. `riscos`

### 5. Observabilidade

```bash
cd ../observability
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Cria alarmes, SNS topics e dashboard CloudWatch consolidado. Deve ser aplicada apos os dominios para que as metricas referenciadas existam. Detalhes em [docs/OBSERVABILIDADE.md](docs/OBSERVABILIDADE.md).

Exemplo:

```bash
cd ../domains/clientes
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Repita para os demais dominios. Para `contas`, `transacoes` e `riscos`, o `plan/apply` individual continua funcionando, desde que `envs/dev/network` ja tenha sido aplicado antes. Os comandos detalhados de deploy, validacao e destruicao estao em [docs/DEPLOY.md](docs/DEPLOY.md).

Nos dominios `clientes` e `parceiros`, o `terraform apply` agora tambem faz uma invocacao inicial da Lambda de ingestao/orquestracao para iniciar o primeiro `Glue Workflow` sem depender do schedule diario.

## Validacao no Athena

Depois de aplicar `foundation` e os dominios desejados:

1. Acesse Athena com o perfil admin do Lake Formation.
2. Escolha o workgroup correspondente a persona.
3. Consulte as tabelas gold.

Como varias tabelas usam `partition projection` com `pais = injected`, prefira consultas com `WHERE pais = 'BR'`.

Se a consulta retornar vazia logo apos o `apply`, aguarde alguns minutos para o workflow inicial terminar e valide os `Glue Job Runs` do dominio.

Exemplos:

```sql
SELECT * FROM dev_gold_clientes.cliente_360 WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_parceiros.parceiros_ativos WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_contas.contas_ativas WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_transacoes.transacoes_curated WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR' LIMIT 10;
```

Depois, valide a governanca assumindo as roles consumidoras e testando os workgroups correspondentes. Para detalhes completos dos testes, veja [docs/VALIDACAO-END-TO-END.md](docs/VALIDACAO-END-TO-END.md).

## Custos

O custo atual depende fortemente dos dominios ativos:

- `network` adiciona custo recorrente pequeno a moderado por causa dos `VPC Interface Endpoints` compartilhados
- `clientes` e `parceiros` sao os dominios mais baratos
- `contas` adiciona `RDS` e `DMS`
- `transacoes` adiciona `MSK Provisioned` e `MSK Connect`
- `riscos` adiciona `Glue Streaming`, que pode virar o maior custo recorrente enquanto houver run ativa

Use [docs/CUSTOS.md](docs/CUSTOS.md) como referencia principal de custo e desligamento. Nao considere mais este projeto como um lab de custo fixo minimo.

## Limpeza

Para remover tudo na ordem correta:

```bash
# Linux / Mac
./cleanup.sh

# Windows
cleanup.bat

# Ou via Makefile
make cleanup
```

> **Observacao sobre tempo de execucao:** O script de limpeza pode demorar bastante (30-60 minutos) devido a exclusao de recursos como RDS, MSK e buckets S3 com muitos arquivos. Se a etapa de exclusao de buckets S3 estiver demorando, voce pode acessar o console AWS (S3 > selecionar bucket > Empty > Delete) para esvaziar manualmente enquanto o script roda — isso acelera o processo. O script e idempotente: se cancelar e rodar novamente, ele continua de onde parou sem problemas.

Para destruir apenas um dominio:

```bash
make destroy-domain DOMAIN=clientes
```

No caso de `riscos`, o `Makefile` ja tenta pausar schedules e parar o Glue Streaming antes do `destroy`.

Se voce estiver fazendo limpeza completa do ambiente, destrua a camada `network` apenas depois de remover `contas`, `transacoes` e `riscos`.

## Estrutura do repositorio

```text
.
├── Makefile
├── cleanup.sh
├── cleanup.bat
├── docs
│   ├── CUSTOS.md
│   ├── DEPLOY.md
│   ├── EVIDENCIAS-OBSERVABILIDADE.md
│   ├── MODELO-MULTI-ACCOUNT-REAL.md
│   ├── OBSERVABILIDADE.md
│   ├── VALIDACAO-END-TO-END.md
│   └── evidencias
│       └── observabilidade
│           ├── 00_dashboard_completo.png
│           ├── 01_glue_duracao.png
│           ├── ... (snapshots dos paineis)
│           └── 11_data_volume.png
├── modules
│   ├── consumer-roles
│   ├── domain
│   ├── foundation
│   ├── observability-central
│   └── observability-domain
└── envs
    └── dev
        ├── consumer-roles
        ├── foundation
        ├── network
        ├── observability
        └── domains
            ├── clientes
            ├── parceiros
            ├── contas
            ├── transacoes
            └── riscos
```

## Limites do lab e evolucao para multi-account

Este projeto simula multi-account com:

- diretorios Terraform separados
- estados separados
- roles IAM distintas
- convencoes de naming
- governanca por persona com Lake Formation

Em uma implementacao enterprise real, a evolucao natural seria:

- AWS Organizations
- contas separadas por dominio
- conta central de governanca
- compartilhamento cross-account com AWS RAM
- Resource Links nas contas consumidoras
- conta de seguranca e conta de log archive
- IAM Identity Center como entrada padrao dos usuarios

Os detalhes dessa evolucao estao em [docs/MODELO-MULTI-ACCOUNT-REAL.md](docs/MODELO-MULTI-ACCOUNT-REAL.md).
