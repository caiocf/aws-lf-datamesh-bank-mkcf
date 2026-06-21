variable "project_name" {
  type    = string
  default = "lfmesh"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "domain" {
  type        = string
  description = "Nome do domínio (clientes, parceiros, contas, transacoes, riscos)."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "sns_topic_arn_critical" {
  type        = string
  description = "ARN do SNS topic para alarmes críticos (criado na conta central)."
}

variable "sns_topic_arn_warning" {
  type        = string
  description = "ARN do SNS topic para alarmes warning."
}

# --- Glue ---

variable "glue_job_names" {
  type        = list(string)
  default     = []
  description = "Nomes dos Glue Jobs do domínio para monitorar."
}

variable "glue_job_timeout_minutes" {
  type        = number
  default     = 10
  description = "Timeout configurado nos Glue Jobs (usado para alarme de duração)."
}

variable "glue_workflow_name" {
  type        = string
  default     = ""
  description = "Nome do Glue Workflow do domínio."
}

# --- Lambda ---

variable "lambda_function_names" {
  type        = list(string)
  default     = []
  description = "Nomes das Lambda functions do domínio para monitorar."
}

# --- DMS (apenas contas) ---

variable "enable_dms_alarms" {
  type    = bool
  default = false
}

variable "dms_replication_task_id" {
  type        = string
  default     = ""
  description = "ID da replication instance DMS (ReplicationInstanceIdentifier)."
}

variable "dms_replication_task_cw_id" {
  type        = string
  default     = ""
  description = "ID interno da replication task no CloudWatch (ReplicationTaskIdentifier na dimensao de metricas)."
}

variable "dms_cdc_latency_threshold_seconds" {
  type    = number
  default = 300
}

# --- MSK (transacoes, riscos) ---

variable "enable_msk_alarms" {
  type    = bool
  default = false
}

variable "msk_cluster_name" {
  type    = string
  default = ""
}

variable "msk_consumer_group" {
  type    = string
  default = ""
}

variable "msk_topic" {
  type    = string
  default = ""
}

variable "msk_offset_lag_threshold" {
  type    = number
  default = 10000
}

variable "msk_time_lag_threshold_seconds" {
  type    = number
  default = 600
}

# --- MSK Connect (transacoes) ---

variable "enable_msk_connect_alarms" {
  type    = bool
  default = false
}

variable "msk_connector_name" {
  type    = string
  default = ""
}

# --- Glue Streaming (riscos) ---

variable "enable_glue_streaming_alarms" {
  type    = bool
  default = false
}

variable "glue_streaming_job_name" {
  type    = string
  default = ""
}

# --- Data Freshness ---

variable "gold_bucket_name" {
  type        = string
  description = "Nome do bucket gold do domínio para monitorar freshness."
}

variable "gold_freshness_threshold_seconds" {
  type    = number
  default = 7200
}

# --- OAM (multi-account real) ---

variable "enable_oam_link" {
  type        = bool
  default     = false
  description = "Habilita OAM Link para compartilhar métricas com conta central. Requer OAM Sink ARN."
}

variable "oam_sink_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
