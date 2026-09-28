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

Cada role consumidora pode executar consultas e acessar historico/resultados somente no workgroup `lfmesh-dev-<persona>`. A politica especifica da persona permite listar, ler e gravar somente seu prefixo `<persona>/` no bucket `lfmesh-dev-athena-results-<ACCOUNT_ID>`. A politica compartilhada mantem descoberta de catalogos e workgroups; por isso nomes de outros workgroups podem aparecer no console, mas seu uso e bloqueado. O Lake Formation continua controlando o acesso aos dados de origem.

O isolamento depende de nao conceder permissoes adicionais amplas a essas roles ou ao bucket. Consulte o teste reproduzivel em [docs/VALIDACAO-END-TO-END.md](docs/VALIDACAO-END-TO-END.md#isolamento-de-workgroups-e-resultados-athena).

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

Depois de `consumer-roles`, `foundation` e `network`, aplique os dominios nesta ordem:

1. `parceiros`
2. `contas`
3. `transacoes`
4. `riscos`
5. `clientes`

`clientes` fica por ultimo porque concede permissoes Lake Formation sobre `dev_gold_contas.contas_ativas`, `dev_gold_transacoes.transacoes_curated` e `dev_gold_riscos.alertas_fraude`. Esses databases e tabelas precisam existir no Glue Data Catalog antes dos grants; nao precisam conter dados. Aplicar `clientes` antes desses catalogos causa `Table not found`.

Na raiz do repositorio, depois de preparar o `terraform.tfvars` de cada dominio a partir do respectivo exemplo (sem sobrescrever configuracoes existentes), use:

```bash
make init-domains
make plan-domains
make apply-domains
```

O Makefile executa os dominios sequencialmente na ordem acima, interrompe no primeiro erro e por padrao mantem a confirmacao interativa de cada `terraform apply`. Os alvos `init-domain`, `plan-domain` e `apply-domain` sem `DOMAIN` tambem executam todos os dominios. Esses comandos nao criam as camadas previas nem a observabilidade.

Para aplicar os dominios sem confirmacao interativa, habilite explicitamente a opcao:

```bash
make apply-domains AUTO_APPROVE=true
```

`AUTO_APPROVE` e `false` por padrao. Com `true`, dispensa a confirmacao do Terraform em `apply-domains` e `apply-domain`, por exemplo `make apply-domain DOMAIN=clientes AUTO_APPROVE=true`. Nesses alvos, aprova todas as acoes do plano, incluindo eventuais alteracoes e exclusoes, e nao reutiliza o plano exibido anteriormente por `make plan-domains`.

A mesma opcao dispensa a confirmacao `DESTRUIR` do script em `cleanup`, `cleanup-windows` e `destroy-domain`, autorizando a limpeza completa ou do dominio selecionado. Os demais alvos do Makefile nao usam `AUTO_APPROVE`.

Para operar apenas um dominio, informe `DOMAIN` explicitamente:

```bash
make plan-domain DOMAIN=clientes
make apply-domain DOMAIN=clientes
```

Se `clientes` ja foi parcialmente criado e faltaram apenas os grants, crie os dominios dependidos e execute novamente seu `plan/apply`; nao e necessario destruir os recursos existentes.

Para deploy manual, partindo de `envs/dev/network`:

```bash
cd ../domains/parceiros
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Repita nos demais dominios seguindo a ordem acima. Os comandos detalhados de deploy, validacao e destruicao estao em [docs/DEPLOY.md](docs/DEPLOY.md).

Nos dominios `clientes` e `parceiros`, o `terraform apply` tambem faz uma invocacao inicial da Lambda de ingestao/orquestracao para iniciar o primeiro `Glue Workflow` sem depender do schedule diario.

### 5. Observabilidade

Depois do ultimo dominio, partindo de `envs/dev/domains/clientes`:

```bash
cd ../../observability
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Cria alarmes, SNS topics e dashboard CloudWatch consolidado. Deve ser aplicada apos os dominios para que as metricas referenciadas existam. Detalhes em [docs/OBSERVABILIDADE.md](docs/OBSERVABILIDADE.md).

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

Para remover tudo na ordem correta (requer Python 3.9+, AWS CLI e Terraform):

```bash
# Linux / Mac
./cleanup.sh

# Windows
cleanup.bat

# Ou via Makefile
make cleanup
```

O fluxo comum em `scripts/cleanup-lab.py` para agendamentos, aguarda Glue/DMS/MSK Connect encerrarem e remove objetos, versoes antigas e delete markers em lotes de ate 1.000. A exclusao dos buckets fica com o Terraform. Erros de acesso, exclusoes parciais e timeout interrompem a limpeza com erro; o script nao anuncia sucesso sem verificar. Nao execute dois destroys simultaneos nem remova locks de um Terraform ativo.

RDS e MSK ainda podem levar varios minutos para serem excluidos. Para automacao ja autorizada, use `make cleanup AUTO_APPROVE=true`. Em destruicao parcial, execute novamente depois de confirmar que a execucao anterior terminou.

Para destruir apenas um dominio:

```bash
make destroy-domain DOMAIN=clientes
```

`destroy-domain` usa o mesmo fluxo, limitado aos nomes do dominio e da conta autenticada. A limpeza nao forca detach de interfaces de rede; o Terraform remove primeiro os servicos proprietarios.

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
