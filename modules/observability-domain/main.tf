locals {
  name_prefix = "${var.project_name}-${var.environment}-${var.domain}"

  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "observability"
      Domain      = var.domain
    },
    var.tags
  )
}

# ─── Glue Job Alarms ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "glue_job_failed" {
  for_each = toset(var.glue_job_names)

  alarm_name          = "${local.name_prefix}-glue-${each.key}-failed"
  alarm_description   = "Glue Job ${each.key} falhou no domínio ${var.domain}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName  = each.key
    JobRunId = "ALL"
    Type     = "count"
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

resource "aws_cloudwatch_metric_alarm" "glue_job_duration" {
  for_each = toset(var.glue_job_names)

  alarm_name          = "${local.name_prefix}-glue-${each.key}-duration-high"
  alarm_description   = "Glue Job ${each.key} duração > 80% do timeout (${var.glue_job_timeout_minutes} min)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.elapsedTime"
  namespace           = "Glue"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.glue_job_timeout_minutes * 60 * 0.8 * 1000 # ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName  = each.key
    JobRunId = "ALL"
    Type     = "count"
  }

  alarm_actions = [var.sns_topic_arn_warning]

  tags = local.default_tags
}

# ─── Lambda Alarms ────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${local.name_prefix}-lambda-${each.key}-errors"
  alarm_description   = "Lambda ${each.key} com erros no domínio ${var.domain}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.key
  }

  alarm_actions = [var.sns_topic_arn_warning]
  ok_actions    = [var.sns_topic_arn_warning]

  tags = local.default_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${local.name_prefix}-lambda-${each.key}-throttles"
  alarm_description   = "Lambda ${each.key} throttled no domínio ${var.domain}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.key
  }

  alarm_actions = [var.sns_topic_arn_warning]

  tags = local.default_tags
}

# ─── DMS Alarms (contas) ──────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "dms_cdc_latency_source" {
  count = var.enable_dms_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-dms-cdc-latency-source"
  alarm_description   = "DMS CDC latency source > ${var.dms_cdc_latency_threshold_seconds}s no domínio ${var.domain}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CDCLatencySource"
  namespace           = "AWS/DMS"
  period              = 300
  statistic           = "Average"
  threshold           = var.dms_cdc_latency_threshold_seconds
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = var.dms_replication_task_id
    ReplicationTaskIdentifier     = var.dms_replication_task_cw_id
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

resource "aws_cloudwatch_metric_alarm" "dms_cdc_latency_target" {
  count = var.enable_dms_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-dms-cdc-latency-target"
  alarm_description   = "DMS CDC latency target > ${var.dms_cdc_latency_threshold_seconds}s no dom\u00ednio ${var.domain}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CDCLatencyTarget"
  namespace           = "AWS/DMS"
  period              = 300
  statistic           = "Average"
  threshold           = var.dms_cdc_latency_threshold_seconds
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = var.dms_replication_task_id
    ReplicationTaskIdentifier     = var.dms_replication_task_cw_id
  }

  alarm_actions = [var.sns_topic_arn_warning]

  tags = local.default_tags
}

resource "aws_cloudwatch_metric_alarm" "dms_task_stopped" {
  count = var.enable_dms_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-dms-task-stopped"
  alarm_description   = "DMS CDC task parou no dominio ${var.domain}! Sem metricas de latencia por 10 min."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CDCLatencySource"
  namespace           = "AWS/DMS"
  period              = 300
  statistic           = "SampleCount"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    ReplicationInstanceIdentifier = var.dms_replication_task_id
    ReplicationTaskIdentifier     = var.dms_replication_task_cw_id
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

# ─── MSK Alarms (transacoes, riscos) ─────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "msk_offset_lag" {
  count = var.enable_msk_alarms && var.msk_consumer_group != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-msk-offset-lag"
  alarm_description   = "MSK consumer lag > ${var.msk_offset_lag_threshold} no domínio ${var.domain}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MaxOffsetLag"
  namespace           = "AWS/Kafka"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.msk_offset_lag_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    "Cluster Name"   = var.msk_cluster_name
    "Consumer Group" = var.msk_consumer_group
    "Topic"          = var.msk_topic
  }

  alarm_actions = [var.sns_topic_arn_warning]

  tags = local.default_tags
}

resource "aws_cloudwatch_metric_alarm" "msk_time_lag" {
  count = var.enable_msk_alarms && var.msk_consumer_group != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-msk-time-lag"
  alarm_description   = "MSK consumer time lag > ${var.msk_time_lag_threshold_seconds}s no domínio ${var.domain}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "EstimatedMaxTimeLag"
  namespace           = "AWS/Kafka"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.msk_time_lag_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    "Cluster Name"   = var.msk_cluster_name
    "Consumer Group" = var.msk_consumer_group
    "Topic"          = var.msk_topic
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

# ─── MSK Connect Alarm (transacoes) ──────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "msk_connect_failed" {
  count = var.enable_msk_connect_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-msk-connect-failed"
  alarm_description   = "MSK Connect connector ${var.msk_connector_name} sem tasks rodando."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/KafkaConnect"
  period              = 300
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    ConnectorName = var.msk_connector_name
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

# ─── Glue Streaming Alarm (riscos) ───────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "glue_streaming_stopped" {
  count = var.enable_glue_streaming_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-glue-streaming-stopped"
  alarm_description   = "Glue Streaming job ${var.glue_streaming_job_name} sem atividade (0 tasks completadas em 10 min)."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "glue.driver.aggregate.numCompletedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    JobName  = var.glue_streaming_job_name
    JobRunId = "ALL"
    Type     = "count"
  }

  alarm_actions = [var.sns_topic_arn_critical]
  ok_actions    = [var.sns_topic_arn_critical]

  tags = local.default_tags
}

# ─── OAM Link (multi-account real) ───────────────────────────────────────────

resource "aws_oam_link" "this" {
  count = var.enable_oam_link ? 1 : 0

  label_template  = "$AccountName"
  sink_identifier = var.oam_sink_arn

  resource_types = [
    "AWS::CloudWatch::Metric",
    "AWS::Logs::LogGroup",
    "AWS::XRay::Trace"
  ]

  tags = local.default_tags
}
