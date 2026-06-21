locals {
  name_prefix = "${var.project_name}-${var.environment}"

  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "observability-central"
    },
    var.tags
  )
}

# ─── SNS Topics ───────────────────────────────────────────────────────────────

resource "aws_sns_topic" "critical" {
  name = "${local.name_prefix}-observability-critical"
  tags = local.default_tags
}

resource "aws_sns_topic" "warning" {
  name = "${local.name_prefix}-observability-warning"
  tags = local.default_tags
}

resource "aws_sns_topic" "data_quality" {
  name = "${local.name_prefix}-observability-data-quality"
  tags = local.default_tags
}

resource "aws_sns_topic_subscription" "critical_email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sns_topic_subscription" "warning_email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.warning.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ─── OAM Sink (multi-account real) ───────────────────────────────────────────

resource "aws_oam_sink" "this" {
  count = var.enable_oam_sink ? 1 : 0
  name  = "${local.name_prefix}-observability-sink"
  tags  = local.default_tags
}

resource "aws_oam_sink_policy" "this" {
  count           = var.enable_oam_sink ? 1 : 0
  sink_identifier = aws_oam_sink.this[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.oam_source_account_ids }
      Action    = ["oam:CreateLink", "oam:UpdateLink"]
      Resource  = "*"
      Condition = {
        "ForAllValues:StringEquals" = {
          "oam:ResourceTypes" = [
            "AWS::CloudWatch::Metric",
            "AWS::Logs::LogGroup",
            "AWS::XRay::Trace"
          ]
        }
      }
    }]
  })
}

# ─── EventBridge Rules: contadores de Glue Job success/failure ────────────────

resource "aws_cloudwatch_event_rule" "glue_job_succeeded" {
  name        = "${local.name_prefix}-glue-job-succeeded"
  description = "Conta execucoes de Glue Jobs com sucesso (todos os dominios)"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail        = { state = ["SUCCEEDED"] }
  })

  tags = local.default_tags
}

resource "aws_cloudwatch_event_rule" "glue_job_failed" {
  name        = "${local.name_prefix}-glue-job-failed"
  description = "Conta execucoes de Glue Jobs com falha (todos os dominios)"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail        = { state = ["FAILED", "TIMEOUT", "ERROR", "STOPPED"] }
  })

  tags = local.default_tags
}

# Log group para capturar eventos de falha dos Glue Jobs
resource "aws_cloudwatch_log_group" "glue_job_failed" {
  name              = "/aws/events/${local.name_prefix}-glue-job-failed"
  retention_in_days = 30
  tags              = local.default_tags
}

resource "aws_cloudwatch_event_target" "glue_job_failed_log" {
  rule      = aws_cloudwatch_event_rule.glue_job_failed.name
  target_id = "send-to-cloudwatch-logs"
  arn       = aws_cloudwatch_log_group.glue_job_failed.arn
}

# ─── S3 Bucket Metrics: habilita métricas de storage nos buckets gold ─────────

resource "aws_s3_bucket_metric" "gold" {
  for_each = { for k, v in var.domains : k => v if v.gold_bucket_name != "" }

  bucket = each.value.gold_bucket_name
  name   = "EntireBucket"
}

# ─── CloudWatch Dashboard ─────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-observability"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}

locals {
  # --- Header Widget (overview) ---
  alarm_status_widget = {
    type   = "text"
    x      = 0
    y      = 0
    width  = 24
    height = 3
    properties = {
      markdown = <<-EOT
# Data Mesh Observability

**Domínios monitorados:** clientes | parceiros | contas | transacoes | riscos

| Widget | O que mostra |
|--------|-------------|
| Duração por Job (ms) | Tempo de execução de cada Glue Job. Se o valor cresce, indica degradação. |
| Succeeded vs Failed | **Contagem real** de execuções de jobs (via EventBridge). Detecta qualquer falha incluindo S3 not found, timeout, permissão. |
| Lambda Errors/Invocations | Erros e invocações das Lambdas de orquestração e produção. |
| DMS CDC Latency | Atraso da replicação CDC. Mostra dados apenas quando há changes no PostgreSQL. |
| MSK Consumer Lag | Offset lag (transacoes) e bytes/s (riscos). Indica se consumers estão acompanhando producers. |
| MSK Connect | Tasks rodando e records processados pelo S3 Sink Connector. |
| Glue Streaming | Tasks completadas pelo job de streaming. Se zerar, o job parou. |
| Data Volume | Total de objetos nos buckets gold (métrica S3 diária). |
EOT
    }
  }

  # --- Glue: Duração por Job ---
  glue_metrics = flatten([
    for domain, cfg in var.domains : [
      for idx, job in cfg.glue_job_names : {
        id     = "raw_${domain}_${idx}"
        metric = ["Glue", "glue.driver.aggregate.elapsedTime", "JobName", job, "JobRunId", "ALL", "Type", "count"]
        label  = "${domain}/${job}"
      }
    ]
  ])

  glue_metrics_expressions = [
    for m in local.glue_metrics : {
      expression = "${m.id}/1000"
      id         = "s_${m.id}"
      label      = m.label
    }
  ]

  glue_metrics_widget = {
    type   = "metric"
    x      = 0
    y      = 3
    width  = 24
    height = 5
    properties = {
      title   = "Glue Jobs — Duração por Job (segundos)"
      region  = var.aws_region
      period  = 300
      stat    = "Maximum"
      metrics = concat(
        [for m in local.glue_metrics : concat(m.metric, [{ id = m.id, visible = false }])],
        [for e in local.glue_metrics_expressions : [{ expression = e.expression, id = e.id, label = e.label }]]
      )
    }
  }

  # --- Glue: Jobs Succeeded vs Failed (totais + detalhamento por job) ---
  glue_job_status_widget = {
    type   = "metric"
    x      = 0
    y      = 8
    width  = 12
    height = 5
    properties = {
      title   = "Glue Jobs — Total Succeeded vs Failed"
      region  = var.aws_region
      period  = 300
      stat    = "Sum"
      metrics = [
        ["AWS/Events", "MatchedEvents", "RuleName", "${local.name_prefix}-glue-job-succeeded", { label = "Succeeded", color = "#2ca02c" }],
        ["AWS/Events", "MatchedEvents", "RuleName", "${local.name_prefix}-glue-job-failed", { label = "Failed", color = "#d62728" }]
      ]
    }
  }

  # --- Glue: Falhas por Job (Log Insights — mostra SOMENTE jobs que falharam) ---
  glue_failed_per_job_widget = {
    type   = "log"
    x      = 12
    y      = 8
    width  = 12
    height = 5
    properties = {
      title   = "Glue Jobs — SOMENTE os que falharam (nome + estado + horário)"
      region  = var.aws_region
      query   = "SOURCE '/aws/events/${local.name_prefix}-glue-job-failed' | fields detail.jobName as job, detail.state as estado, @timestamp as horario | sort @timestamp desc | limit 50"
    }
  }

  # --- Lambda Widgets ---
  lambda_error_metrics = flatten([
    for domain, cfg in var.domains : [
      for fn in cfg.lambda_function_names : {
        metric = ["AWS/Lambda", "Errors", "FunctionName", fn]
        label  = "${domain}/${fn}"
      }
    ]
  ])

  lambda_errors_widget = {
    type   = "metric"
    x      = 0
    y      = 10
    width  = 12
    height = 6
    properties = {
      title   = "Lambda — Errors"
      region  = var.aws_region
      period  = 300
      stat    = "Sum"
      metrics = [for m in local.lambda_error_metrics : concat(m.metric, [{ label = m.label }])]
    }
  }

  lambda_invocation_metrics = flatten([
    for domain, cfg in var.domains : [
      for fn in cfg.lambda_function_names : {
        metric = ["AWS/Lambda", "Invocations", "FunctionName", fn]
        label  = "${domain}/${fn}"
      }
    ]
  ])

  lambda_invocations_widget = {
    type   = "metric"
    x      = 12
    y      = 10
    width  = 12
    height = 6
    properties = {
      title   = "Lambda — Invocations"
      region  = var.aws_region
      period  = 300
      stat    = "Sum"
      metrics = [for m in local.lambda_invocation_metrics : concat(m.metric, [{ label = m.label }])]
    }
  }

  # --- DMS Widgets (uses metric math SEARCH to auto-discover task identifiers) ---
  dms_domains = { for k, v in var.domains : k => v if v.enable_dms }

  dms_search_expressions = flatten([
    for domain, cfg in local.dms_domains : [
      { expression = "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} CDCLatencySource ReplicationInstanceIdentifier=\"${cfg.dms_replication_task_id}\"', 'Average', 300)", id = "dms_src_${domain}", label = "${domain} latency-source" },
      { expression = "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} CDCLatencyTarget ReplicationInstanceIdentifier=\"${cfg.dms_replication_task_id}\"', 'Average', 300)", id = "dms_tgt_${domain}", label = "${domain} latency-target" },
      { expression = "SEARCH('{AWS/DMS,ReplicationInstanceIdentifier,ReplicationTaskIdentifier} CDCIncomingChanges ReplicationInstanceIdentifier=\"${cfg.dms_replication_task_id}\"', 'Sum', 300)", id = "dms_incoming_${domain}", label = "${domain} incoming-changes (0 = parado!)" }
    ]
  ])

  dms_widget = length(local.dms_domains) > 0 ? [{
    type   = "metric"
    x      = 0
    y      = 16
    width  = 24
    height = 6
    properties = {
      title   = "DMS — CDC Latency + Incoming Changes (0 por muito tempo = task parou!)"
      region  = var.aws_region
      view    = "timeSeries"
      metrics = [for expr in local.dms_search_expressions : [expr]]
    }
  }] : []

  # --- MSK Widgets ---
  msk_domains = { for k, v in var.domains : k => v if v.enable_msk }

  # Consumer lag by consumer group + topic (actual CW dimension structure)
  msk_lag_metrics = [
    for domain, cfg in local.msk_domains : {
      metric = ["AWS/Kafka", "MaxOffsetLag", "Consumer Group", cfg.msk_consumer_group, "Cluster Name", cfg.msk_cluster_name, "Topic", cfg.msk_topic]
      label  = "${domain} offset-lag"
    } if cfg.msk_consumer_group != "" && cfg.msk_topic != ""
  ]

  # Fallback: BytesInPerSec per cluster for domains without consumer group
  msk_bytes_metrics = [
    for domain, cfg in local.msk_domains : {
      metric = ["AWS/Kafka", "BytesInPerSec", "Cluster Name", cfg.msk_cluster_name, "Topic", cfg.msk_topic]
      label  = "${domain} bytes-in"
    } if cfg.msk_topic != "" && cfg.msk_consumer_group == ""
  ]

  msk_widget = length(local.msk_domains) > 0 ? [{
    type   = "metric"
    x      = 0
    y      = 22
    width  = 12
    height = 6
    properties = {
      title   = "MSK — transacoes: offset-lag (< 100 ok) | riscos: bytes/s (> 0 = producer ativo)"
      region  = var.aws_region
      period  = 300
      stat    = "Maximum"
      metrics = concat(
        [for m in local.msk_lag_metrics : concat(m.metric, [{ label = m.label }])],
        [for m in local.msk_bytes_metrics : concat(m.metric, [{ label = m.label }])]
      )
    }
  }] : []

  # --- MSK Connect Widget ---
  msk_connect_domains = { for k, v in var.domains : k => v if v.enable_msk_connect }

  msk_connect_metrics = flatten([
    for domain, cfg in local.msk_connect_domains : [
      { metric = ["AWS/KafkaConnect", "RunningTaskCount", "ConnectorName", cfg.msk_connector_name], label = "${domain} running-tasks" },
      { metric = ["AWS/KafkaConnect", "ErroredTaskCount", "ConnectorName", cfg.msk_connector_name], label = "${domain} errored-tasks" },
      { metric = ["AWS/KafkaConnect", "SinkRecordReadRate", "ConnectorName", cfg.msk_connector_name], label = "${domain} records/s" }
    ]
  ])

  msk_connect_widget = length(local.msk_connect_domains) > 0 ? [{
    type   = "metric"
    x      = 12
    y      = 22
    width  = 12
    height = 6
    properties = {
      title   = "MSK Connect — S3 Sink (running=1 ok, errored=0 ok, records/s = throughput)"
      region  = var.aws_region
      period  = 300
      stat    = "Average"
      metrics = [for m in local.msk_connect_metrics : concat(m.metric, [{ label = m.label }])]
    }
  }] : []

  # --- Glue Streaming Widget ---
  streaming_domains = { for k, v in var.domains : k => v if v.enable_glue_streaming }

  streaming_metrics = [
    for domain, cfg in local.streaming_domains : {
      metric = ["Glue", "glue.driver.aggregate.numCompletedTasks", "JobName", cfg.glue_streaming_job_name, "JobRunId", "ALL", "Type", "count"]
      label  = domain
    }
  ]

  streaming_widget = length(local.streaming_domains) > 0 ? [{
    type   = "metric"
    x      = 0
    y      = 28
    width  = 12
    height = 6
    properties = {
      title   = "Glue Streaming — Micro-batches Processados (2 = saudável, 0 = sem dados ou parado)"
      region  = var.aws_region
      period  = 60
      stat    = "Sum"
      metrics = [for m in local.streaming_metrics : concat(m.metric, [{ label = m.label }])]
    }
  }] : []

  # --- Data Volume Widget (S3 NumberOfObjects on gold buckets) ---
  # Usa FilterId=EntireBucket (request metrics) para dados em tempo real
  freshness_metrics = [
    for domain, cfg in var.domains : {
      metric = ["AWS/S3", "NumberOfObjects", "BucketName", cfg.gold_bucket_name, "StorageType", "AllStorageTypes"]
      label  = "${domain} (daily)"
    } if cfg.gold_bucket_name != ""
  ]

  freshness_request_metrics = [
    for domain, cfg in var.domains : {
      metric = ["AWS/S3", "AllRequests", "BucketName", cfg.gold_bucket_name, "FilterId", "EntireBucket"]
      label  = "${domain} (requests)"
    } if cfg.gold_bucket_name != ""
  ]

  freshness_widget = {
    type   = "metric"
    x      = 12
    y      = 28
    width  = 12
    height = 6
    properties = {
      title   = "Data Volume — Objetos no Gold (daily) + Requests (real-time)"
      region  = var.aws_region
      period  = 86400
      stat    = "Average"
      metrics = concat(
        [for m in local.freshness_metrics : concat(m.metric, [{ label = m.label }])],
        [for m in local.freshness_request_metrics : concat(m.metric, [{ label = m.label, yAxis = "right", stat = "Sum", period = 300 }])]
      )
    }
  }

  # --- RDS Widget (contas) ---
  rds_domains = { for k, v in var.domains : k => v if v.enable_dms }
  rds_instance_id = try([for k, v in local.rds_domains : v.rds_instance_id if v.rds_instance_id != ""][0], "${local.name_prefix}-contas-db")
  rds_storage_gb  = try([for k, v in local.rds_domains : v.rds_allocated_storage_gb if v.rds_allocated_storage_gb > 0][0], 30)

  rds_widget = length(local.rds_domains) > 0 ? [{
    type   = "metric"
    x      = 0
    y      = 34
    width  = 24
    height = 6
    properties = {
      title   = "RDS PostgreSQL — CPU (%) | Conexões | Storage Total vs Livre (GB) | IOPS | Memória Livre (MB)"
      region  = var.aws_region
      period  = 300
      stat    = "Average"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.rds_instance_id, { label = "CPU %", color = "#d62728" }],
        ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.rds_instance_id, { label = "Conexões", yAxis = "right" }],
        ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.rds_instance_id, { label = "raw_storage", visible = false, id = "raw_storage" }],
        [{ expression = "raw_storage/1024/1024/1024", id = "storage_free_gb", label = "Storage Livre (GB)", color = "#2ca02c" }],
        [{ expression = "raw_storage/raw_storage*${local.rds_storage_gb}", id = "storage_total_gb", label = "Storage Total (${local.rds_storage_gb} GB)", color = "#9467bd" }],
        ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.rds_instance_id, { label = "raw_mem", visible = false, id = "raw_mem" }],
        [{ expression = "raw_mem/1024/1024", id = "mem_mb", label = "Memória Livre (MB)" }],
        ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", local.rds_instance_id, { label = "Read IOPS", yAxis = "right" }],
        ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", local.rds_instance_id, { label = "Write IOPS", yAxis = "right" }]
      ]
      annotations = {
        horizontal = [
          { label = "Storage Total (30 GB)", value = 30, color = "#9467bd", fill = "none" }
        ]
      }
    }
  }] : []

  # --- Compose all widgets ---
  dashboard_widgets = concat(
    [local.alarm_status_widget],
    [local.glue_metrics_widget],
    [local.glue_job_status_widget],
    [local.glue_failed_per_job_widget],
    [local.lambda_errors_widget],
    [local.lambda_invocations_widget],
    local.dms_widget,
    local.rds_widget,
    local.msk_widget,
    local.msk_connect_widget,
    local.streaming_widget,
    [local.freshness_widget]
  )
}
