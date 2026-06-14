# --- Ingestao: RDS PostgreSQL -> DMS Serverless (CDC) -> S3 bronze ---
#
# Pipeline CDC continua:
#   1. RDS PostgreSQL com tabela contas
#   2. DMS Serverless replica full load + CDC ongoing para S3
#   3. Glue Workflow transforma bronze -> silver -> gold
#

locals {
  name_prefix   = "${var.project_name}-${var.environment}-contas"
  account_id    = data.aws_caller_identity.current.account_id
  bronze_bucket = "${var.project_name}-${var.environment}-contas-bronze-${local.account_id}"
  silver_bucket = "${var.project_name}-${var.environment}-contas-silver-${local.account_id}"
  gold_bucket   = "${var.project_name}-${var.environment}-contas-gold-${local.account_id}"
  db_name       = "contasdb"
  db_username   = "admin_contas"
}

# --- Secrets Manager (secret unico para RDS, DMS e Lambda) ---

resource "random_password" "rds" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.name_prefix}-db-credentials"
  recovery_window_in_days = 0
  tags                    = { Domain = "contas", Layer = "ingestion" }
}
# referencia formato DMS que precisa https://docs.aws.amazon.com/dms/latest/userguide/security_iam_secretsmanager.html
resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    engine   = aws_db_instance.contas.engine
    host     = aws_db_instance.contas.address
    port     = aws_db_instance.contas.port
    username = local.db_username
    password = random_password.rds.result
    dbname   = local.db_name
  })
}

# --- Networking (default VPC) ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "SG para RDS PostgreSQL do dominio contas"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "PostgreSQL access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for VPC Endpoints (Secrets Manager)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Domain = "contas", Layer = "ingestion" }
}

# --- RDS PostgreSQL (db.t3.micro) ---

resource "aws_db_subnet_group" "contas" {
  name       = "${local.name_prefix}-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_db_parameter_group" "contas" {
  name   = "${local.name_prefix}-params"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "wal_sender_timeout"
    value        = "0"
    apply_method = "pending-reboot"
  }

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_db_instance" "contas" {
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = "16.9"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = local.db_name
  username = local.db_username
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.contas.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.contas.name

  publicly_accessible = true
  skip_final_snapshot = true
  deletion_protection = false

  backup_retention_period = 1

  tags = { Domain = "contas", Layer = "ingestion" }
}

# --- VPC Endpoints (necessarios para DMS com IP privado) ---

data "aws_route_table" "default" {
  vpc_id = data.aws_vpc.default.id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.us-east-1.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.rds.id]
  private_dns_enabled = true

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.default.id]

  tags = { Domain = "contas", Layer = "ingestion" }
}

# --- DMS: IAM Roles ---

resource "aws_iam_role" "dms_vpc_role" {
  name = "dms-vpc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "dms_vpc_management" {
  role       = aws_iam_role.dms_vpc_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_iam_role" "dms_cloudwatch_role" {
  name = "dms-cloudwatch-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch_logs" {
  role       = aws_iam_role.dms_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

resource "aws_iam_role" "dms_secrets_access" {
  name = "${local.name_prefix}-dms-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dms.us-east-1.amazonaws.com" }
    }]
  })

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_iam_policy" "dms_secrets_read" {
  name = "${local.name_prefix}-dms-secrets-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_credentials.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_secrets_read" {
  role       = aws_iam_role.dms_secrets_access.name
  policy_arn = aws_iam_policy.dms_secrets_read.arn
}

resource "aws_iam_role" "dms_s3_target" {
  name = "${local.name_prefix}-dms-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_iam_policy" "dms_s3_access" {
  name = "${local.name_prefix}-dms-s3-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject", "s3:GetBucketLocation"]
      Resource = ["arn:aws:s3:::${local.bronze_bucket}", "arn:aws:s3:::${local.bronze_bucket}/*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_s3_access" {
  role       = aws_iam_role.dms_s3_target.name
  policy_arn = aws_iam_policy.dms_s3_access.arn
}

# --- DMS: Endpoints ---

resource "aws_dms_endpoint" "source_postgres" {
  endpoint_id   = "${local.name_prefix}-source"
  endpoint_type = "source"
  engine_name   = "postgres"

  database_name = local.db_name
  ssl_mode      = "require"

  secrets_manager_access_role_arn = aws_iam_role.dms_secrets_access.arn
  secrets_manager_arn             = aws_secretsmanager_secret.db_credentials.arn

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_secretsmanager_secret_version.db_credentials, aws_iam_role_policy_attachment.dms_secrets_read]
}

resource "aws_dms_s3_endpoint" "target_s3" {
  endpoint_id   = "${local.name_prefix}-target"
  endpoint_type = "target"

  bucket_name              = local.bronze_bucket
  bucket_folder            = "contas_raw"
  service_access_role_arn  = aws_iam_role.dms_s3_target.arn
  data_format              = "parquet"
  parquet_version          = "parquet-2-0"
  include_op_for_full_load = true
  cdc_path                 = "cdc"
  timestamp_column_name    = "dms_timestamp"

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_iam_role_policy_attachment.dms_s3_access]
}

# --- DMS Serverless: Replication Config ---

resource "aws_dms_replication_subnet_group" "contas" {
  replication_subnet_group_id          = "${local.name_prefix}-dms-subnet"
  replication_subnet_group_description = "Subnet group para DMS contas"
  subnet_ids                           = data.aws_subnets.default.ids

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_iam_role_policy_attachment.dms_vpc_management]
}

# --- DMS Provisionado (default para lab - mais rapido criar/destruir) ---

resource "aws_dms_replication_instance" "contas" {
  count = var.dms_serverless ? 0 : 1

  replication_instance_id    = "${local.name_prefix}-dms"
  replication_instance_class = "dms.t3.small"
  allocated_storage          = 20
  publicly_accessible        = false

  replication_subnet_group_id = aws_dms_replication_subnet_group.contas.replication_subnet_group_id
  vpc_security_group_ids      = [aws_security_group.rds.id]

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_iam_role_policy_attachment.dms_cloudwatch_logs, aws_vpc_endpoint.secretsmanager, aws_vpc_endpoint.s3]
}

resource "aws_dms_replication_task" "contas_cdc" {
  count = var.dms_serverless ? 0 : 1

  replication_task_id      = "${local.name_prefix}-cdc"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.contas[0].replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_postgres.endpoint_arn
  target_endpoint_arn      = aws_dms_s3_endpoint.target_s3.endpoint_arn

  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "select-contas"
      object-locator = {
        schema-name = "public"
        table-name  = "contas"
      }
      rule-action = "include"
    }]
  })

  replication_task_settings = jsonencode({
    TargetMetadata = {
      TargetSchema       = ""
      SupportLobs        = false
      FullLobMode        = false
      LimitedSizeLobMode = false
    }
    FullLoadSettings = {
      TargetTablePrepMode = "DO_NOTHING"
    }
    Logging = {
      EnableLogging = true
    }
  })

  start_replication_task = true

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_iam_role_policy_attachment.dms_s3_access, aws_lambda_invocation.db_seed]
}

# --- DMS Serverless (opcional - mais moderno, escala automaticamente) ---

resource "aws_dms_replication_config" "contas_cdc" {
  count = var.dms_serverless ? 1 : 0

  replication_config_identifier = "${local.name_prefix}-cdc"
  replication_type              = "full-load-and-cdc"
  source_endpoint_arn           = aws_dms_endpoint.source_postgres.endpoint_arn
  target_endpoint_arn           = aws_dms_s3_endpoint.target_s3.endpoint_arn

  compute_config {
    replication_subnet_group_id  = aws_dms_replication_subnet_group.contas.replication_subnet_group_id
    vpc_security_group_ids       = [aws_security_group.rds.id]
    min_capacity_units           = 1
    max_capacity_units           = 4
    preferred_maintenance_window = "sun:06:00-sun:07:00"
  }

  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "select-contas"
      object-locator = {
        schema-name = "public"
        table-name  = "contas"
      }
      rule-action = "include"
    }]
  })

  replication_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "SOURCE_UNLOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_CAPTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_APPLY", Severity = "LOGGER_SEVERITY_DEFAULT" }
      ]
    }
  })

  start_replication = true

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_iam_role_policy_attachment.dms_s3_access, aws_lambda_invocation.db_seed, aws_vpc_endpoint.secretsmanager, aws_vpc_endpoint.s3]
}


# --- Lambda: DB Seed (cria tabela + inserts via Secrets Manager) ---

data "archive_file" "db_seed" {
  type        = "zip"
  source_file = "${path.module}/scripts/db_seed.py"
  output_path = "${path.module}/lambda/db_seed.zip"
}

resource "aws_iam_role" "lambda_seed" {
  name = "${local.name_prefix}-db-seed"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "lambda_seed_basic" {
  role       = aws_iam_role.lambda_seed.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_seed_access" {
  name = "${local.name_prefix}-db-seed-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_credentials.arn]
      },
      {
        Sid      = "S3ReadSQL"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.scripts.arn}/sql/*"]
      },
      {
        Sid      = "GlueStartWorkflow"
        Effect   = "Allow"
        Action   = ["glue:StartWorkflowRun"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_seed_access" {
  role       = aws_iam_role.lambda_seed.name
  policy_arn = aws_iam_policy.lambda_seed_access.arn
}

resource "aws_lambda_function" "db_seed" {
  function_name    = "${local.name_prefix}-db-seed"
  role             = aws_iam_role.lambda_seed.arn
  handler          = "db_seed.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.db_seed.output_path
  source_code_hash = data.archive_file.db_seed.output_base64sha256

  layers = ["arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python312:15"]

  environment {
    variables = {
      DB_SECRET_ARN        = aws_secretsmanager_secret.db_credentials.arn
      DB_HOST              = aws_db_instance.contas.address
      DB_PORT              = "5432"
      DB_NAME              = local.db_name
      SQL_BUCKET           = aws_s3_bucket.scripts.id
      SQL_CREATE_TABLE_KEY = "sql/create_table.sql"
      SQL_SEED_INSERTS_KEY = "sql/seed_inserts.sql"
      WORKFLOW_NAME        = aws_glue_workflow.contas_pipeline.name
    }
  }

  tags = { Domain = "contas", Layer = "ingestion" }

  depends_on = [aws_db_instance.contas]
}

resource "aws_lambda_invocation" "db_seed" {
  function_name = aws_lambda_function.db_seed.function_name
  input         = jsonencode({})

  depends_on = [
    aws_lambda_function.db_seed,
    aws_s3_object.sql_create_table,
    aws_s3_object.sql_seed_inserts,
    aws_secretsmanager_secret_version.db_credentials
  ]
}

# --- S3: Scripts + SQL ---

resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.name_prefix}-scripts-${local.account_id}"
  force_destroy = true
  tags          = { Domain = "contas", Layer = "ingestion" }
}

resource "aws_s3_object" "sql_create_table" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "sql/create_table.sql"
  source       = "${path.module}/data/create_table.sql"
  content_type = "text/plain"
  etag         = filemd5("${path.module}/data/create_table.sql")
}

resource "aws_s3_object" "sql_seed_inserts" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "sql/seed_inserts.sql"
  source       = "${path.module}/data/seed_inserts.sql"
  content_type = "text/plain"
  etag         = filemd5("${path.module}/data/seed_inserts.sql")
}

resource "aws_s3_object" "script_bronze_to_silver" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "scripts/bronze_to_silver.py"
  source       = "${path.module}/scripts/bronze_to_silver.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/bronze_to_silver.py")
}

resource "aws_s3_object" "script_silver_to_gold" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "scripts/silver_to_gold.py"
  source       = "${path.module}/scripts/silver_to_gold.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/silver_to_gold.py")
}

# --- Glue: Jobs + Workflow ---

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
  name               = "${local.name_prefix}-glue-job"
  assume_role_policy = data.aws_iam_policy_document.glue_job_assume.json
  tags               = { Domain = "contas", Layer = "transformation" }
}

resource "aws_iam_policy" "glue_job_access" {
  name = "${local.name_prefix}-glue-job-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::${local.bronze_bucket}", "arn:aws:s3:::${local.bronze_bucket}/*",
          "arn:aws:s3:::${local.silver_bucket}", "arn:aws:s3:::${local.silver_bucket}/*",
          "arn:aws:s3:::${local.gold_bucket}", "arn:aws:s3:::${local.gold_bucket}/*",
          aws_s3_bucket.scripts.arn, "${aws_s3_bucket.scripts.arn}/*"
        ]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:/aws-glue/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_job_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_access.arn
}

resource "aws_glue_job" "bronze_to_silver" {
  name         = "${local.name_prefix}-bronze-to-silver"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.id}/scripts/bronze_to_silver.py"
    python_version  = "3"
  }
  default_arguments = {
    "--JOB_NAME"              = "${local.name_prefix}-bronze-to-silver"
    "--source_bucket"         = local.bronze_bucket
    "--source_prefix"         = "contas_raw"
    "--target_bucket"         = local.silver_bucket
    "--target_prefix"         = "contas"
    "--job-bookmark-option"   = "job-bookmark-enable"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "contas", Layer = "transformation" }
}

resource "aws_glue_job" "silver_to_gold" {
  name         = "${local.name_prefix}-silver-to-gold"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.id}/scripts/silver_to_gold.py"
    python_version  = "3"
  }
  default_arguments = {
    "--JOB_NAME"              = "${local.name_prefix}-silver-to-gold"
    "--source_bucket"         = local.silver_bucket
    "--source_prefix"         = "contas"
    "--target_bucket"         = local.gold_bucket
    "--target_prefix"         = "contas_ativas"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "contas", Layer = "transformation" }
}

resource "aws_glue_workflow" "contas_pipeline" {
  name = "${local.name_prefix}-pipeline"
  tags = { Domain = "contas", Layer = "orchestration" }
}

resource "aws_glue_trigger" "scheduled_start" {
  name          = "${local.name_prefix}-hourly"
  type          = "SCHEDULED"
  schedule      = "cron(0 * * * ? *)"
  enabled       = true
  workflow_name = aws_glue_workflow.contas_pipeline.name
  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }
  tags = { Domain = "contas", Layer = "transformation" }
}

resource "aws_glue_trigger" "silver_to_gold_chain" {
  name          = "${local.name_prefix}-silver-to-gold-chain"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.contas_pipeline.name
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
  tags = { Domain = "contas", Layer = "transformation" }
}

# Execucao inicial do Workflow apos DMS completar full load
resource "aws_lambda_invocation" "start_workflow" {
  function_name = aws_lambda_function.db_seed.function_name
  input         = jsonencode({ action = "start_workflow" })

  depends_on = [
    aws_dms_replication_task.contas_cdc,
    aws_glue_workflow.contas_pipeline,
    aws_glue_trigger.scheduled_start
  ]
}


