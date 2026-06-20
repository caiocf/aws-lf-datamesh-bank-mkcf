# ─── Ingestão: CSV → Glue Job (Python Shell) → Parquet ─────────────────────────
#
# Pipeline batch:
#   1. CSV é depositado no S3 landing zone
#   2. Glue Job (Python Shell) lê CSV, converte para Parquet
#   3. Output vai para o bucket bronze do domínio (criado pelo módulo domain)
#

locals {
  landing_bucket_name   = "${var.project_name}-${var.environment}-clientes-landing-${data.aws_caller_identity.current.account_id}"
  scripts_prefix        = "scripts"
  job_name              = "${var.project_name}-${var.environment}-clientes-csv-to-parquet"
  source_key            = "clientes/clientes_raw.csv"
  workflow_starter      = "${var.project_name}-${var.environment}-clientes-workflow-starter"
  log_retention_in_days = var.log_retention_in_days
}

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
  key          = local.source_key
  source       = "${path.module}/data/clientes_raw.csv"
  content_type = "text/csv"
  etag         = filemd5("${path.module}/data/clientes_raw.csv")
}

# Upload do script Python do Glue Job
resource "aws_s3_object" "glue_script" {
  bucket       = aws_s3_bucket.landing.id
  key          = "${local.scripts_prefix}/csv_to_parquet.py"
  source       = "${path.module}/scripts/csv_to_parquet.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/csv_to_parquet.py")
}

data "archive_file" "workflow_starter" {
  type        = "zip"
  source_file = "${path.module}/scripts/workflow_starter.py"
  output_path = "${path.module}/lambda/workflow_starter.zip"
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
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
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

resource "aws_iam_role" "lambda_workflow_starter" {
  name = local.workflow_starter

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Domain = "clientes"
    Layer  = "orchestration"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_workflow_starter_basic" {
  role       = aws_iam_role.lambda_workflow_starter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_workflow_starter_access" {
  name = "${local.workflow_starter}-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadLandingCsv"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.landing.arn,
          "${aws_s3_bucket.landing.arn}/${local.source_key}"
        ]
      },
      {
        Sid    = "StartGlueWorkflow"
        Effect = "Allow"
        Action = [
          "glue:GetWorkflowRuns",
          "glue:StartWorkflowRun"
        ]
        Resource = ["arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workflow/${aws_glue_workflow.clientes_pipeline.name}"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_workflow_starter_access" {
  role       = aws_iam_role.lambda_workflow_starter.name
  policy_arn = aws_iam_policy.lambda_workflow_starter_access.arn
}

resource "aws_cloudwatch_log_group" "lambda_workflow_starter" {
  name              = "/aws/lambda/${local.workflow_starter}"
  retention_in_days = local.log_retention_in_days
  tags = {
    Domain = "clientes"
    Layer  = "orchestration"
  }
}

resource "aws_lambda_function" "workflow_starter" {
  function_name    = local.workflow_starter
  role             = aws_iam_role.lambda_workflow_starter.arn
  handler          = "workflow_starter.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.workflow_starter.output_path
  source_code_hash = data.archive_file.workflow_starter.output_base64sha256

  environment {
    variables = {
      LANDING_BUCKET     = aws_s3_bucket.landing.id
      SOURCE_KEY         = local.source_key
      GLUE_WORKFLOW_NAME = aws_glue_workflow.clientes_pipeline.name
    }
  }

  tags = {
    Domain = "clientes"
    Layer  = "orchestration"
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_workflow_starter,
    aws_iam_role_policy_attachment.lambda_workflow_starter_basic,
    aws_iam_role_policy_attachment.lambda_workflow_starter_access
  ]
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
    "--source_key"                = local.source_key
    "--target_bucket"             = "${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"             = "clientes_raw"
    "--additional-python-modules" = "pyarrow==14.0.1,pandas==2.1.4"
  }

  max_capacity = 0.0625 # Mínimo para Python Shell (1/16 DPU)
  max_retries  = 0
  timeout      = 5 # minutos

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
  source       = "${path.module}/scripts/bronze_to_silver.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/bronze_to_silver.py")
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

  # Escrita no silver (PySpark overwrite precisa de DeleteObject)
  statement {
    sid     = "WriteSilverBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Leitura do script no landing
  statement {
    sid       = "ReadScript"
    actions   = ["s3:GetObject"]
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

# Glue Job: Bronze → Silver (PySpark + SHA256 hash com salt)
resource "aws_glue_job" "bronze_to_silver" {
  name         = local.silver_job_name
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.landing.id}/${local.scripts_prefix}/bronze_to_silver.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"              = local.silver_job_name
    "--source_bucket"         = "${var.project_name}-${var.environment}-clientes-bronze-${data.aws_caller_identity.current.account_id}"
    "--source_prefix"         = "clientes_raw"
    "--target_bucket"         = "${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"         = "clientes"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.landing.id}/spark-logs/"
  }

  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10

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

resource "aws_glue_trigger" "start_csv_to_parquet" {
  name          = "${local.job_name}-start"
  type          = "SCHEDULED"
  schedule      = "cron(0 * * * ? *)"
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

resource "aws_lambda_invocation" "seed_workflow" {
  function_name = aws_lambda_function.workflow_starter.function_name
  input         = jsonencode({})

  depends_on = [
    aws_lambda_function.workflow_starter,
    aws_s3_object.sample_csv,
    aws_glue_trigger.start_csv_to_parquet,
    aws_glue_trigger.bronze_to_silver_chain,
    aws_glue_trigger.silver_to_gold_chain
  ]
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
  source       = "${path.module}/scripts/silver_to_gold.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/silver_to_gold.py")
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

  # Escrita no gold (PySpark overwrite precisa de DeleteObject)
  statement {
    sid     = "WriteGoldBucket"
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # Leitura do script
  statement {
    sid       = "ReadScript"
    actions   = ["s3:GetObject"]
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

# Glue Job: Silver → Gold (PySpark + mascaramento PII com salt)
resource "aws_glue_job" "silver_to_gold" {
  name         = local.gold_job_name
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.landing.id}/${local.scripts_prefix}/silver_to_gold.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"              = local.gold_job_name
    "--source_bucket"         = "${var.project_name}-${var.environment}-clientes-silver-${data.aws_caller_identity.current.account_id}"
    "--source_prefix"         = "clientes"
    "--target_bucket"         = "${var.project_name}-${var.environment}-clientes-gold-${data.aws_caller_identity.current.account_id}"
    "--target_prefix"         = "cliente_360"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.landing.id}/spark-logs/"
  }

  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10

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
