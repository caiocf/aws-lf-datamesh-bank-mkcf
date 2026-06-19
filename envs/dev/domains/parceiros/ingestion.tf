# ─── Ingestão: API Mock → Lambda ingestor → Parquet ────────────────────────────
#
# Pipeline:
#   1. EventBridge schedule dispara Lambda ingestor
#   2. Lambda ingestor chama API Gateway (mock) → recebe JSON
#   3. Lambda converte JSON → Parquet, grava no S3 bronze particionado
#   4. Lambda dispara Glue Workflow (bronze → silver → gold)
#

locals {
  name_prefix           = "${var.project_name}-${var.environment}-parceiros"
  account_id            = data.aws_caller_identity.current.account_id
  bronze_bucket         = "${var.project_name}-${var.environment}-parceiros-bronze-${local.account_id}"
  silver_bucket         = "${var.project_name}-${var.environment}-parceiros-silver-${local.account_id}"
  gold_bucket           = "${var.project_name}-${var.environment}-parceiros-gold-${local.account_id}"
  log_retention_in_days = var.log_retention_in_days
}

# ─── Lambda: API Mock ──────────────────────────────────────────────────────────

data "archive_file" "api_mock" {
  type        = "zip"
  source_file = "${path.module}/scripts/api_mock.py"
  output_path = "${path.module}/lambda/api_mock.zip"
}

resource "aws_iam_role" "lambda_api_mock" {
  name = "${local.name_prefix}-api-mock"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "lambda_api_mock_basic" {
  role       = aws_iam_role.lambda_api_mock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_api_mock" {
  name              = "/aws/lambda/${local.name_prefix}-api-mock"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_lambda_function" "api_mock" {
  function_name    = "${local.name_prefix}-api-mock"
  role             = aws_iam_role.lambda_api_mock.arn
  handler          = "api_mock.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.api_mock.output_path
  source_code_hash = data.archive_file.api_mock.output_base64sha256

  tags = { Domain = "parceiros", Layer = "ingestion" }

  depends_on = [
    aws_cloudwatch_log_group.lambda_api_mock,
    aws_iam_role_policy_attachment.lambda_api_mock_basic
  ]
}

# ─── API Gateway REST ──────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "parceiros_mock" {
  name        = "${local.name_prefix}-api"
  description = "API Mock para ingestão de parceiros"

  tags = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/apigateway/${local.name_prefix}-access"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${local.name_prefix}-apigw-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
    }]
  })

  tags = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "cloudwatch" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.api_gateway_cloudwatch]
}

resource "aws_api_gateway_resource" "parceiros" {
  rest_api_id = aws_api_gateway_rest_api.parceiros_mock.id
  parent_id   = aws_api_gateway_rest_api.parceiros_mock.root_resource_id
  path_part   = "parceiros"
}

resource "aws_api_gateway_method" "get_parceiros" {
  rest_api_id   = aws_api_gateway_rest_api.parceiros_mock.id
  resource_id   = aws_api_gateway_resource.parceiros.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.parceiros_mock.id
  resource_id             = aws_api_gateway_resource.parceiros.id
  http_method             = aws_api_gateway_method.get_parceiros.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_mock.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_mock.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.parceiros_mock.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "parceiros_mock" {
  rest_api_id = aws_api_gateway_rest_api.parceiros_mock.id

  depends_on = [aws_api_gateway_integration.lambda_integration]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.parceiros_mock.id
  rest_api_id   = aws_api_gateway_rest_api.parceiros_mock.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      user           = "$context.identity.user"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = { Domain = "parceiros", Layer = "ingestion" }

  depends_on = [aws_api_gateway_account.cloudwatch]
}

# ─── Lambda: Ingestor ──────────────────────────────────────────────────────────

data "archive_file" "ingestor" {
  type        = "zip"
  source_file = "${path.module}/scripts/ingestor.py"
  output_path = "${path.module}/lambda/ingestor.zip"
}

resource "aws_iam_role" "lambda_ingestor" {
  name = "${local.name_prefix}-ingestor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_iam_role_policy_attachment" "lambda_ingestor_basic" {
  role       = aws_iam_role.lambda_ingestor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_ingestor" {
  name              = "/aws/lambda/${local.name_prefix}-ingestor"
  retention_in_days = local.log_retention_in_days
  tags              = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_iam_policy" "lambda_ingestor_access" {
  name = "${local.name_prefix}-ingestor-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteBronzeBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.bronze_bucket}", "arn:aws:s3:::${local.bronze_bucket}/*"]
      },
      {
        Sid    = "StartGlueWorkflow"
        Effect = "Allow"
        Action = [
          "glue:GetWorkflowRuns",
          "glue:StartWorkflowRun"
        ]
        Resource = ["arn:aws:glue:${var.aws_region}:${local.account_id}:workflow/${aws_glue_workflow.parceiros_pipeline.name}"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ingestor_access" {
  role       = aws_iam_role.lambda_ingestor.name
  policy_arn = aws_iam_policy.lambda_ingestor_access.arn
}

# Layer AWS SDK for pandas (awswrangler) — managed pela AWS
# https://aws-sdk-pandas.readthedocs.io/en/stable/layers.html
resource "aws_lambda_function" "ingestor" {
  function_name    = "${local.name_prefix}-ingestor"
  role             = aws_iam_role.lambda_ingestor.arn
  handler          = "ingestor.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.ingestor.output_path
  source_code_hash = data.archive_file.ingestor.output_base64sha256

  layers = ["arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python312:15"]

  environment {
    variables = {
      API_URL            = "${aws_api_gateway_stage.prod.invoke_url}/parceiros"
      TARGET_BUCKET      = local.bronze_bucket
      TARGET_PREFIX      = "parceiros_raw"
      GLUE_WORKFLOW_NAME = aws_glue_workflow.parceiros_pipeline.name
    }
  }

  tags = { Domain = "parceiros", Layer = "ingestion" }

  depends_on = [
    aws_cloudwatch_log_group.lambda_ingestor,
    aws_iam_role_policy_attachment.lambda_ingestor_basic,
    aws_iam_role_policy_attachment.lambda_ingestor_access
  ]
}

resource "aws_lambda_invocation" "seed_ingestion" {
  function_name = aws_lambda_function.ingestor.function_name
  input         = jsonencode({})

  depends_on = [
    aws_lambda_function.ingestor,
    aws_api_gateway_stage.prod,
    aws_glue_trigger.start_silver,
    aws_glue_trigger.silver_to_gold_chain
  ]
}

# Glue Workflow: Transformação bronze → silver → gold ───────────────────────

resource "aws_cloudwatch_event_rule" "ingestor_schedule" {
  name                = "${local.name_prefix}-ingestor-daily"
  description         = "Dispara ingestao diaria de parceiros"
  schedule_expression = "rate(1 hour)"

  tags = { Domain = "parceiros", Layer = "ingestion" }
}

resource "aws_cloudwatch_event_target" "ingestor" {
  rule = aws_cloudwatch_event_rule.ingestor_schedule.name
  arn  = aws_lambda_function.ingestor.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingestor_schedule.arn
}

resource "aws_glue_workflow" "parceiros_pipeline" {
  name = "${local.name_prefix}-pipeline"
  tags = { Domain = "parceiros", Layer = "orchestration" }
}

# IAM Role para Glue Jobs
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
  tags               = { Domain = "parceiros", Layer = "transformation" }
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

# S3 bucket para scripts Glue (reusa landing concept)
resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.name_prefix}-scripts-${local.account_id}"
  force_destroy = true
  tags          = { Domain = "parceiros", Layer = "ingestion" }
}

# Script bronze → silver (PySpark com Job Bookmark)
resource "aws_s3_object" "script_bronze_to_silver" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "scripts/bronze_to_silver.py"
  source       = "${path.module}/scripts/bronze_to_silver.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/bronze_to_silver.py")
}

# Script silver → gold (PySpark — filtra apenas ativos)
resource "aws_s3_object" "script_silver_to_gold" {
  bucket       = aws_s3_bucket.scripts.id
  key          = "scripts/silver_to_gold.py"
  source       = "${path.module}/scripts/silver_to_gold.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/scripts/silver_to_gold.py")
}

# Glue Jobs (PySpark)
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
    "--source_prefix"         = "parceiros_raw"
    "--target_bucket"         = local.silver_bucket
    "--target_prefix"         = "parceiros"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 5
  tags              = { Domain = "parceiros", Layer = "transformation" }
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
    "--source_bucket"         = local.silver_bucket
    "--source_prefix"         = "parceiros"
    "--target_bucket"         = local.gold_bucket
    "--target_prefix"         = "parceiros_ativos"
    "--enable-metrics"        = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.scripts.id}/spark-logs/"
  }
  number_of_workers = 2
  worker_type       = "G.1X"
  max_retries       = 0
  timeout           = 5
  tags              = { Domain = "parceiros", Layer = "transformation" }
}

# Triggers no Workflow (ON_DEMAND start -> bronze_to_silver -> silver_to_gold)
resource "aws_glue_trigger" "start_silver" {
  name          = "${local.name_prefix}-start-silver"
  type          = "ON_DEMAND"
  workflow_name = aws_glue_workflow.parceiros_pipeline.name
  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }
  tags = { Domain = "parceiros", Layer = "transformation" }
}

resource "aws_glue_trigger" "silver_to_gold_chain" {
  name          = "${local.name_prefix}-silver-to-gold-chain"
  type          = "CONDITIONAL"
  enabled       = true
  workflow_name = aws_glue_workflow.parceiros_pipeline.name
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
  tags = { Domain = "parceiros", Layer = "transformation" }
}
