variable "project_name" {
  type    = string
  default = "lfmesh"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Email para receber notificações de alarmes. Deixe vazio para não criar subscription."
}

# --- Domínios ativos (controla widgets do dashboard) ---

variable "domains" {
  type = map(object({
    glue_job_names          = list(string)
    lambda_function_names   = list(string)
    glue_workflow_name      = string
    gold_bucket_name        = optional(string, "")
    enable_dms              = optional(bool, false)
    dms_replication_task_id = optional(string, "")
    rds_instance_id         = optional(string, "")
    rds_allocated_storage_gb = optional(number, 0)
    enable_msk              = optional(bool, false)
    msk_cluster_name        = optional(string, "")
    msk_consumer_group      = optional(string, "")
    msk_topic               = optional(string, "")
    enable_msk_connect      = optional(bool, false)
    msk_connector_name      = optional(string, "")
    enable_glue_streaming   = optional(bool, false)
    glue_streaming_job_name = optional(string, "")
  }))
  description = "Configuração de cada domínio para o dashboard central."
}

# --- OAM (multi-account real) ---

variable "enable_oam_sink" {
  type        = bool
  default     = false
  description = "Habilita OAM Sink para receber métricas de contas produtoras."
}

variable "oam_source_account_ids" {
  type        = list(string)
  default     = []
  description = "IDs das contas produtoras autorizadas a enviar métricas via OAM."
}

variable "tags" {
  type    = map(string)
  default = {}
}
