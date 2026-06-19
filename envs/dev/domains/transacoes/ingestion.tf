# --- Ingestao: MSK Provisionado (SCRAM) -> S3 Sink Connector -> S3 bronze ---
#
# Pipeline real-time:
#   1. Lambda producer gera transacoes fake e publica no MSK (SCRAM auth)
#   2. MSK Connect S3 Sink Connector consome e grava Parquet no S3 bronze
#   3. Glue Workflow (horario) transforma bronze -> silver -> gold
#

locals {
  name_prefix           = "${var.project_name}-${var.environment}-transacoes"
  account_id            = data.aws_caller_identity.current.account_id
  bronze_bucket         = "${var.project_name}-${var.environment}-transacoes-bronze-${local.account_id}"
  silver_bucket         = "${var.project_name}-${var.environment}-transacoes-silver-${local.account_id}"
  gold_bucket           = "${var.project_name}-${var.environment}-transacoes-gold-${local.account_id}"
  topic_name            = "txn.transacoes.raw"
  msk_username          = "producer-user"
  log_retention_in_days = var.log_retention_in_days
}

# --- Networking (shared network baseline) ---

data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = "${path.module}/../../network/terraform.tfstate"
  }
}

resource "aws_security_group" "msk" {
  name        = "${local.name_prefix}-msk-sg"
  description = "SG para MSK e MSK Connect do dominio transacoes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    self        = true
    description = "Kafka PLAINTEXT"
  }

  ingress {
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "Kafka PLAINTEXT - Lambda"
  }

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    self        = true
    description = "Kafka TLS (mTLS)"
  }

  ingress {
    from_port       = 9094
    to_port         = 9094
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "Kafka TLS (mTLS) - Lambda"
  }

  ingress {
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    self        = true
    description = "Kafka SASL/SCRAM (TLS)"
  }

  ingress {
    from_port       = 9096
    to_port         = 9096
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "Kafka SASL/SCRAM (TLS) - Lambda"
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
    description     = "Kafka IAM auth - Lambda"
  }

  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    self        = true
    description = "Zookeeper"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "SG para Lambda producer do dominio transacoes"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

# --- Secrets Manager (credenciais SCRAM para MSK) ---

resource "random_password" "msk_scram" {
  length  = 24
  special = false
}

resource "aws_kms_key" "msk_scram" {
  description = "KMS key para secret SCRAM do MSK transacoes"
  tags        = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_secretsmanager_secret" "msk_scram" {
  name                    = "AmazonMSK_${local.name_prefix}-scram"
  kms_key_id              = aws_kms_key.msk_scram.key_id
  recovery_window_in_days = 0
  tags                    = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_secretsmanager_secret_version" "msk_scram" {
  secret_id = aws_secretsmanager_secret.msk_scram.id
  secret_string = jsonencode({
    username = local.msk_username
    password = random_password.msk_scram.result
  })
}

# --- MSK Provisionado (kafka.t3.small, 2 brokers) ---

resource "aws_msk_configuration" "transacoes" {
  name              = "${local.name_prefix}-config"
  kafka_versions    = ["3.6.0"]
  server_properties = <<-PROPS
    auto.create.topics.enable = true
    default.replication.factor = 2
    min.insync.replicas = 1
    num.partitions = 2
    log.retention.hours = 24
    allow.everyone.if.no.acl.found = true
  PROPS
}

resource "aws_msk_cluster" "transacoes" {
  cluster_name           = "${local.name_prefix}-msk"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = data.terraform_remote_state.network.outputs.msk_broker_subnet_ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 10
      }
    }

  }

  client_authentication {
    sasl {
      scram = true
      iam   = true
    }
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.msk_scram.arn
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.transacoes.arn
    revision = aws_msk_configuration.transacoes.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_broker.name
      }
    }
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_cloudwatch_log_group" "msk_broker" {
  name              = "/aws/msk/${local.name_prefix}"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "transacoes", Layer = "ingestion" }
}

# Cluster Policy (permite conexão e operações de tópico para lab)
resource "aws_msk_cluster_policy" "transacoes" {
  cluster_arn = aws_msk_cluster.transacoes.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ClusterConnectAndDescribe"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = [aws_msk_cluster.transacoes.arn]
      },
      {
        Sid       = "TopicOperations"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = [
          "arn:aws:kafka:${var.aws_region}:${local.account_id}:topic/${aws_msk_cluster.transacoes.cluster_name}/${aws_msk_cluster.transacoes.cluster_uuid}/*",
          "arn:aws:kafka:${var.aws_region}:${local.account_id}:group/${aws_msk_cluster.transacoes.cluster_name}/${aws_msk_cluster.transacoes.cluster_uuid}/*"
        ]
      }
    ]
  })
}

# Associar secret SCRAM ao cluster MSK
resource "aws_msk_scram_secret_association" "transacoes" {
  cluster_arn     = aws_msk_cluster.transacoes.arn
  secret_arn_list = [aws_secretsmanager_secret.msk_scram.arn]

  depends_on = [aws_secretsmanager_secret_version.msk_scram]
}

# --- Lambda Producer (SCRAM auth) ---

data "archive_file" "producer" {
  type        = "zip"
  source_file = "${path.module}/scripts/producer.py"
  output_path = "${path.module}/lambda/producer.zip"
}

resource "aws_lambda_layer_version" "kafka" {
  layer_name          = "${local.name_prefix}-kafka"
  description         = "kafka-python-ng (SCRAM/PLAINTEXT/IAM)"
  filename            = "${path.module}/layers/kafka_layer.zip"
  source_code_hash    = filebase64sha256("${path.module}/layers/kafka_layer.zip")
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

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "lambda_producer_basic" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_producer_vpc" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_producer_secrets" {
  name = "${local.name_prefix}-producer-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.msk_scram.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.msk_scram.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:StartWorkflowRun"]
        Resource = ["arn:aws:glue:${var.aws_region}:${local.account_id}:workflow/${aws_glue_workflow.transacoes_pipeline.name}"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_producer_secrets" {
  role       = aws_iam_role.lambda_producer.name
  policy_arn = aws_iam_policy.lambda_producer_secrets.arn
}

resource "aws_cloudwatch_log_group" "lambda_producer" {
  name              = "/aws/lambda/${local.name_prefix}-producer"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "transacoes", Layer = "ingestion" }
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

  layers = [aws_lambda_layer_version.kafka.arn]

  vpc_config {
    subnet_ids         = data.terraform_remote_state.network.outputs.platform_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      MSK_BOOTSTRAP_SERVERS = aws_msk_cluster.transacoes.bootstrap_brokers_sasl_scram
      TOPIC_NAME            = local.topic_name
      AUTH_METHOD           = "SCRAM"
      MSK_SECRET_ARN        = aws_secretsmanager_secret.msk_scram.arn
      NUM_TRANSACTIONS      = "100"
      GLUE_WORKFLOW_NAME    = aws_glue_workflow.transacoes_pipeline.name
    }
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }

  depends_on = [
    aws_msk_scram_secret_association.transacoes,
    aws_cloudwatch_log_group.lambda_producer,
    aws_iam_role_policy_attachment.lambda_producer_basic,
    aws_iam_role_policy_attachment.lambda_producer_vpc,
    aws_iam_role_policy_attachment.lambda_producer_secrets
  ]
}

# Invoca producer 1x para criar topico antes do Connector
resource "aws_lambda_invocation" "create_topic" {
  function_name = aws_lambda_function.producer.function_name
  input         = jsonencode({})

  depends_on = [aws_lambda_function.producer, aws_msk_cluster.transacoes, aws_msk_scram_secret_association.transacoes]
}

# --- EventBridge: Schedule para producer ---

resource "aws_cloudwatch_event_rule" "producer_schedule" {
  name                = "${local.name_prefix}-producer-5min"
  description         = "Dispara producer de transacoes a cada 5 min"
  schedule_expression = "rate(5 minutes)"

  tags = { Domain = "transacoes", Layer = "ingestion" }
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

# --- MSK Connect: Plugin + Worker Config + Connector ---

resource "aws_s3_bucket" "plugins" {
  bucket        = "${local.name_prefix}-plugins-${local.account_id}"
  force_destroy = true
  tags          = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_s3_object" "s3_sink_plugin" {
  bucket = aws_s3_bucket.plugins.id
  key    = "plugins/confluentinc-kafka-connect-s3-10.5.7.zip"
  source = "${path.module}/plugins/confluentinc-kafka-connect-s3-10.5.7.zip"
  etag   = filemd5("${path.module}/plugins/confluentinc-kafka-connect-s3-10.5.7.zip")
}

resource "aws_mskconnect_custom_plugin" "s3_sink" {
  name         = "${local.name_prefix}-s3-sink-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.plugins.arn
      file_key   = aws_s3_object.s3_sink_plugin.key
    }
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_mskconnect_worker_configuration" "s3_sink" {
  name                    = "${local.name_prefix}-worker-config-v3"
  properties_file_content = <<-EOT
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
value.converter.schemas.enable=false
EOT
}

resource "aws_cloudwatch_log_group" "msk_connect" {
  name              = "/aws/msk-connect/${local.name_prefix}"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_iam_role" "msk_connect" {
  name = "${local.name_prefix}-msk-connect"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "kafkaconnect.amazonaws.com" }
    }]
  })

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

resource "aws_iam_policy" "msk_connect_access" {
  name = "${local.name_prefix}-msk-connect-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Access"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = ["arn:aws:s3:::${local.bronze_bucket}", "arn:aws:s3:::${local.bronze_bucket}/*"]
      },
      {
        Sid    = "MSKConnect"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = ["*"]
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.msk_scram.arn]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "msk_connect_access" {
  role       = aws_iam_role.msk_connect.name
  policy_arn = aws_iam_policy.msk_connect_access.arn
}

resource "aws_mskconnect_connector" "s3_sink" {
  name = "${local.name_prefix}-s3-sink"

  kafkaconnect_version = "3.7.x"

  depends_on = [aws_lambda_invocation.create_topic]

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                = "io.confluent.connect.s3.S3SinkConnector"
    "tasks.max"                      = "1"
    "topics"                         = local.topic_name
    "s3.bucket.name"                 = local.bronze_bucket
    "s3.region"                      = var.aws_region
    "storage.class"                  = "io.confluent.connect.s3.storage.S3Storage"
    "format.class"                   = "io.confluent.connect.s3.format.json.JsonFormat"
    "flush.size"                     = "100"
    "rotate.interval.ms"             = "60000"
    "partition.duration.ms"          = "3600000"
    "topics.dir"                     = "transacoes_raw"
    "path.format"                    = "'year='YYYY/'month='MM/'day='dd/'hour='HH"
    "locale"                         = "pt-BR"
    "timezone"                       = "America/Sao_Paulo"
    "partitioner.class"              = "io.confluent.connect.storage.partitioner.TimeBasedPartitioner"
    "timestamp.extractor"            = "Wallclock"
    "key.converter"                  = "org.apache.kafka.connect.storage.StringConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"
    "schema.compatibility"           = "NONE"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.transacoes.bootstrap_brokers_sasl_iam
      vpc {
        security_groups = [aws_security_group.msk.id]
        subnets         = data.terraform_remote_state.network.outputs.platform_subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.s3_sink.arn
      revision = aws_mskconnect_custom_plugin.s3_sink.latest_revision
    }
  }

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.s3_sink.arn
    revision = aws_mskconnect_worker_configuration.s3_sink.latest_revision
  }

  service_execution_role_arn = aws_iam_role.msk_connect.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_connect.name
      }
    }
  }

  tags = { Domain = "transacoes", Layer = "ingestion" }
}

# --- Glue: Scripts + Workflow ---

resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.name_prefix}-scripts-${local.account_id}"
  force_destroy = true
  tags          = { Domain = "transacoes", Layer = "ingestion" }
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
  tags               = { Domain = "transacoes", Layer = "transformation" }
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
        Sid      = "GlueCatalog"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartition", "glue:GetPartitions"]
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
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_job_access" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_job_access.arn
}

# Lake Formation: grants para Glue Job acessar tabela bronze e gravar no silver/gold
resource "aws_lakeformation_permissions" "glue_job_bronze_table" {
  principal   = aws_iam_role.glue_job.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = "dev_bronze_transacoes"
    name          = "transacoes_raw"
  }

  depends_on = [module.domain]
}

resource "aws_lakeformation_permissions" "glue_job_silver_location" {
  principal   = aws_iam_role.glue_job.arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = "arn:aws:s3:::${local.silver_bucket}"
  }

  depends_on = [module.domain]
}

resource "aws_lakeformation_permissions" "glue_job_gold_location" {
  principal   = aws_iam_role.glue_job.arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = "arn:aws:s3:::${local.gold_bucket}"
  }

  depends_on = [module.domain]
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
    "--source_prefix"         = "transacoes_raw/txn.transacoes.raw"
    "--target_bucket"         = local.silver_bucket
    "--target_prefix"         = "transacoes"
    "--job-bookmark-option"   = "job-bookmark-enable"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "transacoes", Layer = "transformation" }
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
    "--source_prefix"         = "transacoes"
    "--target_bucket"         = local.gold_bucket
    "--target_prefix"         = "transacoes_curated"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 10
  tags              = { Domain = "transacoes", Layer = "transformation" }
}

resource "aws_glue_workflow" "transacoes_pipeline" {
  name = "${local.name_prefix}-pipeline"
  tags = { Domain = "transacoes", Layer = "orchestration" }
}

resource "aws_glue_trigger" "scheduled_start" {
  name          = "${local.name_prefix}-hourly"
  type          = "SCHEDULED"
  schedule      = "cron(0 * * * ? *)"
  enabled       = true
  workflow_name = aws_glue_workflow.transacoes_pipeline.name
  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }
  tags = { Domain = "transacoes", Layer = "transformation" }
}

resource "aws_glue_trigger" "silver_to_gold_chain" {
  name          = "${local.name_prefix}-silver-to-gold-chain"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.transacoes_pipeline.name
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
  tags = { Domain = "transacoes", Layer = "transformation" }
}
