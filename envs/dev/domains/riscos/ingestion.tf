# --- Ingestao: MSK Serverless (IAM) -> Glue Streaming Job -> S3 bronze ---
#
# Pipeline real-time:
#   1. Lambda producer gera alertas fake e publica no MSK Serverless (IAM auth)
#   2. Glue Streaming Job consome MSK, converte JSON -> Parquet, grava S3 bronze
#   3. Glue Workflow (horario) transforma bronze -> silver -> gold
#
# Diferenciacao vs transacoes (fase 4):
#   - MSK Serverless (vs Provisionado) = zero custo parado
#   - Glue Streaming (vs S3 Sink Connector) = transformacao em tempo real
#   - IAM auth (vs SCRAM) = sem gerenciar credenciais
#

locals {
  name_prefix           = "${var.project_name}-${var.environment}-riscos"
  account_id            = data.aws_caller_identity.current.account_id
  bronze_bucket         = "${var.project_name}-${var.environment}-riscos-bronze-${local.account_id}"
  silver_bucket         = "${var.project_name}-${var.environment}-riscos-silver-${local.account_id}"
  gold_bucket           = "${var.project_name}-${var.environment}-riscos-gold-${local.account_id}"
  topic_name            = "txn.riscos.raw"
  log_retention_in_days = var.log_retention_in_days
}

# --- Networking (shared network baseline) ---

data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = "${path.module}/../../network/terraform.tfstate"
  }
}

resource "aws_security_group" "msk_serverless" {
  name        = "${local.name_prefix}-msk-sg"
  description = "SG para MSK Serverless e Glue Streaming do dominio riscos"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Glue executors intra-SG"
  }

  ingress {
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    self        = true
    description = "Kafka IAM auth"
  }

  ingress {
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "Kafka IAM - Lambda"
  }

  ingress {
    from_port   = 14001
    to_port     = 14100
    protocol    = "tcp"
    self        = true
    description = "MSK Serverless bootstrap (dynamic ports)"
  }

  ingress {
    from_port       = 14001
    to_port         = 14100
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "MSK Serverless bootstrap - Lambda"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "SG para Lambda producer do dominio riscos"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Domain = "riscos", Layer = "ingestion" }
}

# Shared endpoints are provisioned in envs/dev/network.
# In the single-account lab, this domain only consumes the shared network baseline.

# --- MSK Serverless ---

resource "aws_msk_serverless_cluster" "riscos" {
  cluster_name = "${local.name_prefix}-msk"

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  vpc_config {
    subnet_ids         = data.terraform_remote_state.network.outputs.platform_subnet_ids
    security_group_ids = [aws_security_group.msk_serverless.id]
  }

  tags = { Domain = "riscos", Layer = "ingestion" }
}

# MSK Serverless: acesso controlado via IAM policies nos principals (Lambda, Glue)
# Nao usa cluster policy (recurso apenas para MSK Provisionado)

# --- Lambda Producer (IAM auth) ---

data "archive_file" "producer" {
  type        = "zip"
  source_file = "${path.module}/scripts/producer.py"
  output_path = "${path.module}/lambda/producer.zip"
}

data "archive_file" "start_streaming_job" {
  type        = "zip"
  source_file = "${path.module}/scripts/start_streaming_job.py"
  output_path = "${path.module}/lambda/start_streaming_job.zip"
}

resource "aws_lambda_layer_version" "kafka_iam" {
  layer_name          = "${local.name_prefix}-kafka-iam"
  description         = "kafka-python-ng + aws-msk-iam-sasl-signer"
  filename            = "${path.module}/layers/kafka_iam_layer.zip"
  source_code_hash    = filebase64sha256("${path.module}/layers/kafka_iam_layer.zip")
  compatible_runtimes = ["python3.12"]
}

resource "aws_iam_role" "lambda_producer" {
  name = "${local.name_prefix}-producer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "lambda_producer_basic" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_producer_vpc" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_producer_msk" {
  name = "${local.name_prefix}-producer-msk"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKConnect"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = [
          aws_msk_serverless_cluster.riscos.arn,
          "arn:aws:kafka:${var.aws_region}:${local.account_id}:topic/${aws_msk_serverless_cluster.riscos.cluster_name}/*"
        ]
      },
      {
        Sid      = "MSKGetBootstrap"
        Effect   = "Allow"
        Action   = ["kafka:GetBootstrapBrokers"]
        Resource = [aws_msk_serverless_cluster.riscos.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_producer_msk" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = aws_iam_policy.lambda_producer_msk.arn
}

resource "aws_cloudwatch_log_group" "lambda_producer" {
  name              = "/aws/lambda/${local.name_prefix}-producer"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_lambda_function" "producer" {
  function_name    = "${local.name_prefix}-producer"
  role             = aws_iam_role.lambda_producer.arn
  handler          = "producer.handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.producer.output_path
  source_code_hash = data.archive_file.producer.output_base64sha256

  layers = [aws_lambda_layer_version.kafka_iam.arn]

  vpc_config {
    subnet_ids         = data.terraform_remote_state.network.outputs.platform_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      MSK_BOOTSTRAP_SERVERS = aws_msk_serverless_cluster.riscos.bootstrap_brokers_sasl_iam
      TOPIC_NAME            = local.topic_name
      NUM_ALERTS            = "50"
      AWS_REGION_MSK        = var.aws_region
    }
  }

  tags = { Domain = "riscos", Layer = "ingestion" }

  depends_on = [
    aws_cloudwatch_log_group.lambda_producer,
    aws_iam_role_policy_attachment.lambda_producer_basic,
    aws_iam_role_policy_attachment.lambda_producer_vpc,
    aws_iam_role_policy_attachment.lambda_producer_msk
  ]
}

# Invoca 1x para criar topico
resource "aws_lambda_invocation" "create_topic" {
  function_name = aws_lambda_function.producer.function_name
  input         = jsonencode({})

  depends_on = [aws_lambda_function.producer, aws_msk_serverless_cluster.riscos]
}

# --- EventBridge: Schedule para producer ---

resource "aws_cloudwatch_event_rule" "producer_schedule" {
  name                = "${local.name_prefix}-producer-5min"
  description         = "Dispara producer de riscos a cada 5 min"
  schedule_expression = "rate(5 minutes)"

  tags = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_cloudwatch_event_target" "producer" {
  rule = aws_cloudwatch_event_rule.producer_schedule.name
  arn  = aws_lambda_function.producer.arn
}

resource "aws_lambda_permission" "eventbridge_producer" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.producer_schedule.arn
}

# --- Glue Streaming Job: MSK -> S3 bronze ---

resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.name_prefix}-scripts-${local.account_id}"
  force_destroy = true
  tags          = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_s3_object" "script_streaming" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "scripts/streaming_to_bronze.py"
  source       = "${path.module}/scripts/streaming_to_bronze.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/streaming_to_bronze.py")
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

# --- IAM: Glue Job role ---

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
  tags               = { Domain = "riscos", Layer = "transformation" }
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
        Sid    = "MSKAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = [
          aws_msk_serverless_cluster.riscos.arn,
          "arn:aws:kafka:${var.aws_region}:${local.account_id}:topic/${aws_msk_serverless_cluster.riscos.cluster_name}/*",
          "arn:aws:kafka:${var.aws_region}:${local.account_id}:group/${aws_msk_serverless_cluster.riscos.cluster_name}/*"
        ]
      },
      {
        Sid      = "MSKGetBootstrap"
        Effect   = "Allow"
        Action   = ["kafka:GetBootstrapBrokers", "kafka:DescribeCluster", "kafka:DescribeClusterV2"]
        Resource = [aws_msk_serverless_cluster.riscos.arn]
      },
      {
        Sid      = "GlueCatalog"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartition", "glue:GetPartitions", "glue:GetConnection"]
        Resource = ["*"]
      },
      {
        Sid      = "LakeFormation"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = ["*"]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:/aws-glue/*"]
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
      },
      {
        Sid    = "EC2NetworkForConnection"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = ["*"]
      },
      {
        Sid      = "EC2CreateTagsForENI"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:network-interface/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_job_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_access.arn
}

# --- Glue Connection (Network para MSK Serverless) ---

resource "aws_glue_connection" "msk_serverless" {
  name            = "${local.name_prefix}-msk-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = data.terraform_remote_state.network.outputs.glue_connection_subnet_availability_zone
    subnet_id              = data.terraform_remote_state.network.outputs.glue_connection_subnet_id
    security_group_id_list = [aws_security_group.msk_serverless.id]
  }

  tags = { Domain = "riscos", Layer = "ingestion" }
}

# --- Glue Streaming Job ---

resource "aws_cloudwatch_log_group" "glue_streaming" {
  name              = "/aws-glue/jobs/${local.name_prefix}-streaming"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "riscos", Layer = "ingestion" }
}

resource "aws_glue_job" "streaming_to_bronze" {
  name         = "${local.name_prefix}-streaming-to-bronze"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "gluestreaming"
    script_location = "s3://${aws_s3_bucket.scripts.id}/scripts/streaming_to_bronze.py"
    python_version  = "3"
  }

  default_arguments = {
    "--JOB_NAME"                         = "${local.name_prefix}-streaming-to-bronze"
    "--target_bucket"                    = local.bronze_bucket
    "--target_prefix"                    = "riscos_raw"
    "--msk_bootstrap_servers"            = aws_msk_serverless_cluster.riscos.bootstrap_brokers_sasl_iam
    "--topic_name"                       = local.topic_name
    "--msk_connection_name"              = aws_glue_connection.msk_serverless.name
    "--window_size"                      = "60 seconds"
    "--consumer_group_prefix"            = "${local.name_prefix}-streaming-to-bronze"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue_streaming.name
  }

  connections = [aws_glue_connection.msk_serverless.name]

  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 0

  tags = { Domain = "riscos", Layer = "ingestion" }

  depends_on = [aws_lambda_invocation.create_topic]
}

# Start the streaming job once after the infra is in place. The Lambda is
# idempotent and avoids opening a duplicate run if the job is already active.
resource "aws_iam_role" "lambda_start_streaming_job" {
  name = "${local.name_prefix}-start-streaming-job"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Domain = "riscos", Layer = "orchestration" }
}

resource "aws_iam_role_policy_attachment" "lambda_start_streaming_job_basic" {
  role       = aws_iam_role.lambda_start_streaming_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_start_streaming_job_access" {
  name = "${local.name_prefix}-start-streaming-job-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartStreamingGlueJob"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRuns"]
        Resource = ["arn:aws:glue:${var.aws_region}:${local.account_id}:job/${aws_glue_job.streaming_to_bronze.name}"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_start_streaming_job_access" {
  role       = aws_iam_role.lambda_start_streaming_job.name
  policy_arn = aws_iam_policy.lambda_start_streaming_job_access.arn
}

resource "aws_cloudwatch_log_group" "lambda_start_streaming_job" {
  name              = "/aws/lambda/${local.name_prefix}-start-streaming-job"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "riscos", Layer = "orchestration" }
}

resource "aws_lambda_function" "start_streaming_job" {
  function_name    = "${local.name_prefix}-start-streaming-job"
  role             = aws_iam_role.lambda_start_streaming_job.arn
  handler          = "start_streaming_job.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.start_streaming_job.output_path
  source_code_hash = data.archive_file.start_streaming_job.output_base64sha256

  environment {
    variables = {
      JOB_NAME = aws_glue_job.streaming_to_bronze.name
    }
  }

  tags = { Domain = "riscos", Layer = "orchestration" }

  depends_on = [
    aws_cloudwatch_log_group.lambda_start_streaming_job,
    aws_iam_role_policy_attachment.lambda_start_streaming_job_basic,
    aws_iam_role_policy_attachment.lambda_start_streaming_job_access
  ]
}

resource "aws_lambda_invocation" "start_streaming_job" {
  function_name = aws_lambda_function.start_streaming_job.function_name
  input         = jsonencode({})

  depends_on = [
    aws_glue_job.streaming_to_bronze,
    aws_lambda_invocation.create_topic
  ]
}

# Watchdog: garante que o job de streaming volte a subir caso tenha parado.
resource "aws_cloudwatch_event_rule" "start_streaming_job_watchdog" {
  name                = "${local.name_prefix}-start-streaming-job-15min"
  description         = "Verifica a cada 15 min se o Glue Streaming de riscos esta ativo"
  schedule_expression = "rate(15 minutes)"

  tags = { Domain = "riscos", Layer = "orchestration" }
}

resource "aws_cloudwatch_event_target" "start_streaming_job_watchdog" {
  rule = aws_cloudwatch_event_rule.start_streaming_job_watchdog.name
  arn  = aws_lambda_function.start_streaming_job.arn
}

resource "aws_lambda_permission" "eventbridge_start_streaming_job" {
  statement_id  = "AllowEventBridgeInvokeStartStreamingJob"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_streaming_job.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start_streaming_job_watchdog.arn
}

# --- Glue Batch: Workflow bronze -> silver -> gold ---

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
    "--source_prefix"         = "riscos_raw"
    "--target_bucket"         = local.silver_bucket
    "--target_prefix"         = "riscos"
    "--job-bookmark-option"   = "job-bookmark-disable"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "riscos", Layer = "transformation" }
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
    "--source_prefix"         = "riscos"
    "--target_bucket"         = local.gold_bucket
    "--target_prefix"         = "alertas_fraude"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "riscos", Layer = "transformation" }
}

resource "aws_glue_workflow" "riscos_pipeline" {
  name = "${local.name_prefix}-pipeline"
  tags = { Domain = "riscos", Layer = "orchestration" }
}

resource "aws_glue_trigger" "scheduled_start" {
  name          = "${local.name_prefix}-hourly"
  type          = "SCHEDULED"
  schedule      = "cron(0 * * * ? *)"
  enabled       = true
  workflow_name = aws_glue_workflow.riscos_pipeline.name
  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }
  tags = { Domain = "riscos", Layer = "transformation" }
}

resource "aws_glue_trigger" "silver_to_gold_chain" {
  name          = "${local.name_prefix}-silver-to-gold-chain"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.riscos_pipeline.name
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
  tags = { Domain = "riscos", Layer = "transformation" }
}
