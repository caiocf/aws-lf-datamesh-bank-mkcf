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

## Matriz de dominios

| Dominio | Fonte principal | Modo de ingestao | Servicos principais | Data product gold |
| --- | --- | --- | --- | --- |
| `clientes` | CSV local | Batch diario | S3 landing, Glue Python Shell, Glue Workflow | `dev_gold_clientes.cliente_360` |
| `parceiros` | API mock JSON | Batch diario | API Gateway, Lambda, Glue Workflow | `dev_gold_parceiros.parceiros_ativos` |
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

## Governanca e seguranca

O projeto usa Lake Formation como plano central de autorizacao:

- `bronze` e `silver` sao camadas internas do produtor
- `gold` e a camada exposta como data product
- consumidores recebem `DESCRIBE` nos databases e `SELECT` apenas no que for permitido
- controles finos por linha e coluna sao aplicados com `Data Cells Filters`
- buckets S3 usam `public access block` e criptografia server-side

Exemplos de governanca implementada:

- `auditoria` recebe acesso completo aos data products gold definidos para a persona
- `bi` recebe filtros por pais e remocao de colunas sensiveis em varios dominios
- `risco-fraude` recebe acesso ampliado ao dominio `riscos`

## Pre-requisitos

- Terraform `>= 1.6.0`
- AWS Provider `>= 6.32.0, < 7.0`
- AWS CLI autenticado
- Regiao `us-east-1`
- Permissoes para IAM, S3, Glue, Athena, Lake Formation, Lambda, CloudWatch, RDS, DMS e MSK
- Principal executor com permissao suficiente para atuar como administrador do Lake Formation

Observacoes operacionais:

- `contas`, `transacoes` e `riscos` dependem da VPC default da conta
- `riscos` pode precisar de `create_vpc_endpoints = false` se outros dominios ja tiverem criado endpoints na mesma VPC
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

### 3. Dominios

Ordem alinhada com o estado atual do repositorio:

1. `clientes`
2. `parceiros`
3. `contas`
4. `transacoes`
5. `riscos`

Exemplo:

```bash
cd ../domains/clientes
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Repita para os demais dominios. Os comandos detalhados de deploy, validacao e destruicao estao em [docs/DEPLOY.md](docs/DEPLOY.md).

## Validacao no Athena

Depois de aplicar `foundation` e os dominios desejados:

1. Acesse Athena com o perfil admin do Lake Formation.
2. Escolha o workgroup correspondente a persona.
3. Consulte as tabelas gold.

Como varias tabelas usam `partition projection` com `pais = injected`, prefira consultas com `WHERE pais = 'BR'`.

Exemplos:

```sql
SELECT * FROM dev_gold_clientes.cliente_360 WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_parceiros.parceiros_ativos WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_contas.contas_ativas WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_transacoes.transacoes_curated WHERE pais = 'BR' LIMIT 10;
SELECT * FROM dev_gold_riscos.alertas_fraude WHERE pais = 'BR' LIMIT 10;
```

Depois, valide a governanca assumindo as roles consumidoras e testando os workgroups correspondentes.

## Custos

O custo atual depende fortemente dos dominios ativos:

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

Para destruir apenas um dominio:

```bash
make destroy-domain DOMAIN=clientes
```

No caso de `riscos`, o `Makefile` ja tenta pausar schedules e parar o Glue Streaming antes do `destroy`.

## Estrutura do repositorio

```text
.
├── Makefile
├── cleanup.sh
├── cleanup.bat
├── docs
│   ├── CUSTOS.md
│   ├── DEPLOY.md
│   └── MODELO-MULTI-ACCOUNT-REAL.md
├── modules
│   ├── consumer-roles
│   ├── foundation
│   └── domain
└── envs
    └── dev
        ├── consumer-roles
        ├── foundation
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
