provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "lakeformation-datamesh-single-account"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}

# ─── Central: SNS + Dashboard + OAM Sink ─────────────────────────────────────

module "observability_central" {
  source = "../../../modules/observability-central"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  notification_email = var.notification_email
  enable_oam_sink    = var.enable_oam_sink

  domains = {
    clientes = {
      glue_job_names = [
        "${local.name_prefix}-clientes-csv-to-parquet",
        "${local.name_prefix}-clientes-bronze-to-silver",
        "${local.name_prefix}-clientes-silver-to-gold"
      ]
      lambda_function_names = [
        "${local.name_prefix}-clientes-workflow-starter"
      ]
      glue_workflow_name = "${local.name_prefix}-clientes-pipeline"
      gold_bucket_name   = "${local.name_prefix}-clientes-gold-${local.account_id}"
    }

    parceiros = {
      glue_job_names = [
        "${local.name_prefix}-parceiros-api-to-parquet",
        "${local.name_prefix}-parceiros-bronze-to-silver",
        "${local.name_prefix}-parceiros-silver-to-gold"
      ]
      lambda_function_names = [
        "${local.name_prefix}-parceiros-workflow-starter"
      ]
      glue_workflow_name = "${local.name_prefix}-parceiros-pipeline"
      gold_bucket_name   = "${local.name_prefix}-parceiros-gold-${local.account_id}"
    }

    contas = {
      glue_job_names = [
        "${local.name_prefix}-contas-bronze-to-silver",
        "${local.name_prefix}-contas-silver-to-gold"
      ]
      lambda_function_names = [
        "${local.name_prefix}-contas-db-seed"
      ]
      glue_workflow_name      = "${local.name_prefix}-contas-pipeline"
      gold_bucket_name        = "${local.name_prefix}-contas-gold-${local.account_id}"
      enable_dms              = true
      dms_replication_task_id = "${local.name_prefix}-contas-dms"
      rds_instance_id         = "${local.name_prefix}-contas-db"
      rds_allocated_storage_gb = 30
    }

    transacoes = {
      glue_job_names = [
        "${local.name_prefix}-transacoes-bronze-to-silver",
        "${local.name_prefix}-transacoes-silver-to-gold"
      ]
      lambda_function_names = [
        "${local.name_prefix}-transacoes-producer"
      ]
      glue_workflow_name = "${local.name_prefix}-transacoes-pipeline"
      enable_msk         = true
      msk_cluster_name   = "${local.name_prefix}-transacoes-msk"
      msk_consumer_group = "connect-${local.name_prefix}-transacoes-s3-sink"
      msk_topic          = "txn.transacoes.raw"
      enable_msk_connect = true
      msk_connector_name = "${local.name_prefix}-transacoes-s3-sink"
    }

    riscos = {
      glue_job_names = [
        "${local.name_prefix}-riscos-bronze-to-silver",
        "${local.name_prefix}-riscos-silver-to-gold"
      ]
      lambda_function_names = [
        "${local.name_prefix}-riscos-producer",
        "${local.name_prefix}-riscos-start-streaming-job"
      ]
      glue_workflow_name      = "${local.name_prefix}-riscos-pipeline"
      enable_msk              = true
      msk_cluster_name        = "${local.name_prefix}-riscos-msk"
      msk_consumer_group      = ""
      msk_topic               = "txn.riscos.raw"
      enable_glue_streaming   = true
      glue_streaming_job_name = "${local.name_prefix}-riscos-streaming-to-bronze"
    }
  }
}

# ─── Domain: Alarmes locais por domínio ───────────────────────────────────────

module "observability_clientes" {
  source = "../../../modules/observability-domain"

  project_name           = var.project_name
  environment            = var.environment
  domain                 = "clientes"
  aws_region             = var.aws_region
  sns_topic_arn_critical = module.observability_central.sns_topic_arn_critical
  sns_topic_arn_warning  = module.observability_central.sns_topic_arn_warning

  glue_job_names = [
    "${local.name_prefix}-clientes-csv-to-parquet",
    "${local.name_prefix}-clientes-bronze-to-silver",
    "${local.name_prefix}-clientes-silver-to-gold"
  ]

  lambda_function_names = [
    "${local.name_prefix}-clientes-workflow-starter"
  ]

  glue_workflow_name = "${local.name_prefix}-clientes-pipeline"
  gold_bucket_name   = "${local.name_prefix}-clientes-gold-${local.account_id}"
}

module "observability_parceiros" {
  source = "../../../modules/observability-domain"

  project_name           = var.project_name
  environment            = var.environment
  domain                 = "parceiros"
  aws_region             = var.aws_region
  sns_topic_arn_critical = module.observability_central.sns_topic_arn_critical
  sns_topic_arn_warning  = module.observability_central.sns_topic_arn_warning

  glue_job_names = [
    "${local.name_prefix}-parceiros-api-to-parquet",
    "${local.name_prefix}-parceiros-bronze-to-silver",
    "${local.name_prefix}-parceiros-silver-to-gold"
  ]

  lambda_function_names = [
    "${local.name_prefix}-parceiros-workflow-starter"
  ]

  glue_workflow_name = "${local.name_prefix}-parceiros-pipeline"
  gold_bucket_name   = "${local.name_prefix}-parceiros-gold-${local.account_id}"
}

module "observability_contas" {
  source = "../../../modules/observability-domain"

  project_name           = var.project_name
  environment            = var.environment
  domain                 = "contas"
  aws_region             = var.aws_region
  sns_topic_arn_critical = module.observability_central.sns_topic_arn_critical
  sns_topic_arn_warning  = module.observability_central.sns_topic_arn_warning

  glue_job_names = [
    "${local.name_prefix}-contas-bronze-to-silver",
    "${local.name_prefix}-contas-silver-to-gold"
  ]

  lambda_function_names = [
    "${local.name_prefix}-contas-db-seed"
  ]

  glue_workflow_name = "${local.name_prefix}-contas-pipeline"
  gold_bucket_name   = "${local.name_prefix}-contas-gold-${local.account_id}"

  enable_dms_alarms          = true
  dms_replication_task_id     = "${local.name_prefix}-contas-dms"
  dms_replication_task_cw_id  = "DD5O6HISLNABJFK7TJWYERVKRU"
}

module "observability_transacoes" {
  source = "../../../modules/observability-domain"

  project_name           = var.project_name
  environment            = var.environment
  domain                 = "transacoes"
  aws_region             = var.aws_region
  sns_topic_arn_critical = module.observability_central.sns_topic_arn_critical
  sns_topic_arn_warning  = module.observability_central.sns_topic_arn_warning

  glue_job_names = [
    "${local.name_prefix}-transacoes-bronze-to-silver",
    "${local.name_prefix}-transacoes-silver-to-gold"
  ]

  lambda_function_names = [
    "${local.name_prefix}-transacoes-producer"
  ]

  glue_workflow_name = "${local.name_prefix}-transacoes-pipeline"
  gold_bucket_name   = "${local.name_prefix}-transacoes-gold-${local.account_id}"

  enable_msk_alarms    = true
  msk_cluster_name     = "${local.name_prefix}-transacoes-msk"
  msk_consumer_group   = "connect-${local.name_prefix}-transacoes-s3-sink"
  msk_topic            = "txn.transacoes.raw"

  enable_msk_connect_alarms = true
  msk_connector_name        = "${local.name_prefix}-transacoes-s3-sink"
}

module "observability_riscos" {
  source = "../../../modules/observability-domain"

  project_name           = var.project_name
  environment            = var.environment
  domain                 = "riscos"
  aws_region             = var.aws_region
  sns_topic_arn_critical = module.observability_central.sns_topic_arn_critical
  sns_topic_arn_warning  = module.observability_central.sns_topic_arn_warning

  glue_job_names = [
    "${local.name_prefix}-riscos-bronze-to-silver",
    "${local.name_prefix}-riscos-silver-to-gold"
  ]

  lambda_function_names = [
    "${local.name_prefix}-riscos-producer",
    "${local.name_prefix}-riscos-start-streaming-job"
  ]

  glue_workflow_name = "${local.name_prefix}-riscos-pipeline"
  gold_bucket_name   = "${local.name_prefix}-riscos-gold-${local.account_id}"

  enable_msk_alarms    = true
  msk_cluster_name     = "${local.name_prefix}-riscos-msk"
  msk_consumer_group   = ""
  msk_topic            = "txn.riscos.raw"

  enable_glue_streaming_alarms = true
  glue_streaming_job_name      = "${local.name_prefix}-riscos-streaming-to-bronze"
}
