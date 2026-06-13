# ─── Ingestão: CSV → Glue Job (Python Shell) → Parquet ─────────────────────────
#
# Pipeline batch:
#   1. CSV é depositado no S3 landing zone
#   2. Glue Job (Python Shell) lê CSV, converte para Parquet
#   3. Output vai para o bucket bronze do domínio (criado pelo módulo domain)
#

locals {
  landing_bucket_name = "${var.project_name}-${var.environment}-clientes-landing-${data.aws_caller_identity.current.account_id}"
  scripts_prefix      = "scripts"
  job_name            = "${var.project_name}-${var.environment}-clientes-csv-to-parquet"
}

data "aws_caller_identity" "current" {}

# ─── S3: Landing Zone ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "landing" {
  bucket        = local.landing_bucket_name
  force_destroy = true

  tags = {
    Name   = local.landing_bucket_name
    Domain = "clientes"
    Layer  = "landing"
  }
}

resource "aws_s3_bucket_public_access_block" "landing" {
  bucket = aws_s3_bucket.landing.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload CSV de exemplo no landing zone (arquivo local)
resource "aws_s3_object" "sample_csv" {
  bucket       = aws_s3_bucket.landing.id
  key          = "clientes/clientes_raw.csv"
  source       = "${path.module}/data/clientes_raw.csv"
  content_type = "text/csv"
  etag         = filemd5("${path.module}/data/clientes_raw.csv")
}

# Upload do script Python do Glue Job
resource "aws_s3_object" "glue_script" {
  bucket       = aws_s3_bucket.landing.id
  key          = "${local.scripts_prefix}/csv_to_parquet.py"
  content_type = "text/x-python"
  content      = <<-PYTHON
import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import StringIO, BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_key', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lê CSV do landing zone
response = s3.get_object(Bucket=args['source_bucket'], Key=args['source_key'])
csv_content = response['Body'].read().decode('utf-8')

# Converte para DataFrame (todas colunas como string para compatibilidade com Glue)
df = pd.read_csv(StringIO(csv_content), dtype=str)

# Particiona por pais e dt_ingest, grava cada partição como Parquet
partition_cols = ['pais', 'dt_ingest']
for keys, partition_df in df.groupby(partition_cols):
    pais_val, dt_val = keys
    data_df = partition_df.drop(columns=partition_cols)
    
    table = pa.Table.from_pandas(data_df, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)
    
    target_key = f"{args['target_prefix']}/pais={pais_val}/dt_ingest={dt_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Partição pais={pais_val}/dt_ingest={dt_val}: {len(data_df)} registros")

print(f"Total: {len(df)} registros convertidos para Parquet particionado")
PYTHON
}

# ─── IAM: Role para Glue Job ──────────────────────────────────────────────────

data "aws_iam_policy_document" "glue_job_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  name               = "${var.project_name}-${var.environment}-clientes-glue-job"
  assume_role_policy = data.aws_iam_policy_document.glue_job_assume.json

  tags = {
    Domain = "clientes"
    Layer  = "ingestion"
  }
}

data "aws_iam_policy_document" "glue_job_access" {
  # Acesso ao landing zone (leitura)
  statement {
    sid     = "ReadLandingBucket"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/*"
    ]
  }

  # Acesso ao bucket bronze (escrita)
  statement {
    sid     = "WriteBronzeBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Logs do Glue
  statement {
    sid     = "CloudWatchLogs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:/aws-glue/*"]
  }
}

resource "aws_iam_policy" "glue_job_access" {
  name   = "${var.project_name}-${var.environment}-clientes-glue-job-access"
  policy = data.aws_iam_policy_document.glue_job_access.json
}

resource "aws_iam_role_policy_attachment" "glue_job_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_access.arn
}

# ─── Glue Job: Python Shell ───────────────────────────────────────────────────

resource "aws_glue_job" "csv_to_parquet" {
  name     = local.job_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.landing.id}/${local.scripts_prefix}/csv_to_parquet.py"
  }

  default_arguments = {
    "--source_bucket"             = aws_s3_bucket.landing.id
    "--source_key"                = "clientes/clientes_raw.csv"
    "--target_bucket"             = "${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"             = "clientes_raw"
    "--additional-python-modules" = "pyarrow==14.0.1,pandas==2.1.4"
  }

  max_capacity = 0.0625  # Mínimo para Python Shell (1/16 DPU)
  max_retries  = 0
  timeout      = 5  # minutos

  tags = {
    Domain = "clientes"
    Layer  = "ingestion"
  }
}

# ─── Glue Trigger: Schedule removido — agora está no Workflow abaixo ──────────


# ─── Transformação: Bronze → Silver (deduplicação) ─────────────────────────────
#
# Pipeline:
#   1. Lê todas as partições do bronze (Parquet particionado por pais/dt_ingest)
#   2. Deduplica por cliente_id (última dt_ingest vence)
#   3. Grava no silver particionado por pais (1 registro por cliente)
#

locals {
  silver_job_name = "${var.project_name}-${var.environment}-clientes-bronze-to-silver"
}

# Upload do script Python do Job bronze→silver
resource "aws_s3_object" "glue_script_silver" {
  bucket       = aws_s3_bucket.landing.id
  key          = "${local.scripts_prefix}/bronze_to_silver.py"
  content_type = "text/x-python"
  content      = <<-PYTHON
import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lista todos os Parquets no bronze (todas as partições)
paginator = s3.get_paginator('list_objects_v2')
pages = paginator.paginate(Bucket=args['source_bucket'], Prefix=args['source_prefix'])

frames = []
for page in pages:
    for obj in page.get('Contents', []):
        key = obj['Key']
        if not key.endswith('.parquet'):
            continue
        
        # Extrai pais e dt_ingest do path Hive-style
        parts = key.split('/')
        pais_val = None
        dt_val = None
        for part in parts:
            if part.startswith('pais='):
                pais_val = part.split('=')[1]
            elif part.startswith('dt_ingest='):
                dt_val = part.split('=')[1]
        
        # Lê Parquet
        response = s3.get_object(Bucket=args['source_bucket'], Key=key)
        df = pd.read_parquet(BytesIO(response['Body'].read()))
        df['pais'] = pais_val
        df['dt_ingest'] = dt_val
        frames.append(df)

if not frames:
    print("Nenhum dado encontrado no bronze")
    sys.exit(0)

# Concatena tudo
df_all = pd.concat(frames, ignore_index=True)
print(f"Bronze: {len(df_all)} registros lidos")

# Deduplica: última dt_ingest vence por cliente_id
df_dedup = (
    df_all.sort_values('dt_ingest', ascending=False)
          .drop_duplicates(subset=['cliente_id'], keep='first')
          .drop(columns=['dt_ingest'])
)
print(f"Silver: {len(df_dedup)} registros após deduplicação")

# Grava particionado por pais no silver
for pais_val, pais_df in df_dedup.groupby('pais'):
    data_df = pais_df.drop(columns=['pais'])
    
    table = pa.Table.from_pandas(data_df, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)
    
    target_key = f"{args['target_prefix']}/pais={pais_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Silver partição pais={pais_val}: {len(data_df)} registros")

print("Transformação bronze → silver concluída")
PYTHON
}

# IAM: acesso adicional ao bucket silver
data "aws_iam_policy_document" "glue_job_silver_access" {
  # Leitura no bronze
  statement {
    sid     = "ReadBronzeBucket"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Escrita no silver
  statement {
    sid     = "WriteSilverBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Leitura do script no landing
  statement {
    sid     = "ReadScript"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.landing.arn}/*"]
  }

  # Logs
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:/aws-glue/*"]
  }
}

resource "aws_iam_policy" "glue_job_silver_access" {
  name   = "${var.project_name}-${var.environment}-clientes-glue-job-silver-access"
  policy = data.aws_iam_policy_document.glue_job_silver_access.json
}

resource "aws_iam_role_policy_attachment" "glue_job_silver_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_silver_access.arn
}

# Glue Job: Bronze → Silver
resource "aws_glue_job" "bronze_to_silver" {
  name     = local.silver_job_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.landing.id}/${local.scripts_prefix}/bronze_to_silver.py"
  }

  default_arguments = {
    "--source_bucket"             = "${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}"
    "--source_prefix"             = "clientes_raw/"
    "--target_bucket"             = "${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"             = "clientes"
    "--additional-python-modules" = "pyarrow==14.0.1,pandas==2.1.4"
  }

  max_capacity = 0.0625
  max_retries  = 0
  timeout      = 5

  tags = {
    Domain = "clientes"
    Layer  = "transformation"
  }
}

# Glue Trigger: Chain — dispara silver após bronze suceder (via Workflow)
resource "aws_glue_workflow" "clientes_pipeline" {
  name = "${var.project_name}-${var.environment}-clientes-pipeline"

  tags = {
    Domain = "clientes"
    Layer  = "orchestration"
  }
}

resource "aws_glue_trigger" "bronze_start" {
  name          = "${local.job_name}-start"
  type          = "SCHEDULED"
  schedule      = "cron(0 6 * * ? *)"
  enabled       = true
  workflow_name = aws_glue_workflow.clientes_pipeline.name

  actions {
    job_name = aws_glue_job.csv_to_parquet.name
  }

  tags = {
    Domain = "clientes"
    Layer  = "ingestion"
  }
}

resource "aws_glue_trigger" "bronze_to_silver_chain" {
  name          = "${local.silver_job_name}-after-bronze"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.clientes_pipeline.name

  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }

  predicate {
    conditions {
      job_name         = aws_glue_job.csv_to_parquet.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = {
    Domain = "clientes"
    Layer  = "transformation"
  }
}


# ─── Transformação: Silver → Gold (enriquecimento visão 360) ───────────────────
#
# Pipeline:
#   1. Lê silver (clientes deduplicados por pais)
#   2. Adiciona colunas de enriquecimento (NULL por agora, futuro: joins com outros domínios)
#   3. Grava no gold particionado por pais
#

locals {
  gold_job_name = "${var.project_name}-${var.environment}-clientes-silver-to-gold"
}

resource "aws_s3_object" "glue_script_gold" {
  bucket       = aws_s3_bucket.landing.id
  key          = "${local.scripts_prefix}/silver_to_gold.py"
  content_type = "text/x-python"
  content      = <<-PYTHON
import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lista todos os Parquets no silver
paginator = s3.get_paginator('list_objects_v2')
pages = paginator.paginate(Bucket=args['source_bucket'], Prefix=args['source_prefix'])

frames = []
for page in pages:
    for obj in page.get('Contents', []):
        key = obj['Key']
        if not key.endswith('.parquet'):
            continue
        
        # Extrai pais do path
        parts = key.split('/')
        pais_val = None
        for part in parts:
            if part.startswith('pais='):
                pais_val = part.split('=')[1]
        
        response = s3.get_object(Bucket=args['source_bucket'], Key=key)
        df = pd.read_parquet(BytesIO(response['Body'].read()))
        df['pais'] = pais_val
        frames.append(df)

if not frames:
    print("Nenhum dado encontrado no silver")
    sys.exit(0)

df_all = pd.concat(frames, ignore_index=True)
print(f"Silver: {len(df_all)} registros lidos")

# Enriquecimento: adiciona colunas de outros domínios (NULL por agora)
# Futuro: joins com dev_silver_contas, dev_silver_transacoes, dev_gold_alertas
df_all['total_contas'] = None
df_all['volume_transacoes'] = None
df_all['ultima_transacao'] = None
df_all['score_risco'] = None

print(f"Gold: {len(df_all)} registros enriquecidos (colunas extras: NULL até domínios disponíveis)")

# Grava particionado por pais no gold
for pais_val, pais_df in df_all.groupby('pais'):
    data_df = pais_df.drop(columns=['pais'])
    
    # Define schema explícito para manter tipos corretos
    schema = pa.schema([
        ('cliente_id', pa.string()),
        ('nome', pa.string()),
        ('cpf', pa.string()),
        ('email', pa.string()),
        ('segmento', pa.string()),
        ('total_contas', pa.int32()),
        ('volume_transacoes', pa.float64()),
        ('ultima_transacao', pa.string()),
        ('score_risco', pa.string()),
    ])
    
    table = pa.Table.from_pandas(data_df, schema=schema, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)
    
    target_key = f"{args['target_prefix']}/pais={pais_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Gold partição pais={pais_val}: {len(data_df)} registros")

print("Transformação silver → gold concluída")
PYTHON
}

# IAM: acesso ao bucket gold
data "aws_iam_policy_document" "glue_job_gold_access" {
  # Leitura no silver
  statement {
    sid     = "ReadSilverBucket"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Escrita no gold
  statement {
    sid     = "WriteGoldBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Leitura do script
  statement {
    sid     = "ReadScript"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.landing.arn}/*"]
  }

  # Logs
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:/aws-glue/*"]
  }
}

resource "aws_iam_policy" "glue_job_gold_access" {
  name   = "${var.project_name}-${var.environment}-clientes-glue-job-gold-access"
  policy = data.aws_iam_policy_document.glue_job_gold_access.json
}

resource "aws_iam_role_policy_attachment" "glue_job_gold_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_gold_access.arn
}

# Glue Job: Silver → Gold
resource "aws_glue_job" "silver_to_gold" {
  name     = local.gold_job_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.landing.id}/${local.scripts_prefix}/silver_to_gold.py"
  }

  default_arguments = {
    "--source_bucket"             = "${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}"
    "--source_prefix"             = "clientes/"
    "--target_bucket"             = "${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"             = "cliente_360"
    "--additional-python-modules" = "pyarrow==14.0.1,pandas==2.1.4"
  }

  max_capacity = 0.0625
  max_retries  = 0
  timeout      = 5

  tags = {
    Domain = "clientes"
    Layer  = "transformation"
  }
}

# Glue Trigger: Chain — dispara gold após silver suceder (dentro do Workflow)
resource "aws_glue_trigger" "silver_to_gold_chain" {
  name          = "${local.gold_job_name}-after-silver"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.clientes_pipeline.name

  actions {
    job_name = aws_glue_job.silver_to_gold.name
  }

  predicate {
    conditions {
      job_name         = aws_glue_job.bronze_to_silver.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = {
    Domain = "clientes"
    Layer  = "transformation"
  }
}
