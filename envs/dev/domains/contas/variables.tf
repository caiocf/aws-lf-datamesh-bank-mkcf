variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "lfmesh"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "log_retention_in_days" {
  description = "Dias de retencao dos logs no CloudWatch."
  type        = number
  default     = 3
}

variable "dms_serverless" {
  description = "Usar DMS Serverless (true) ou Provisionado (false). Provisionado e mais rapido para criar/destruir no lab."
  type        = bool
  default     = false
}

# --- RDS ---

variable "rds_engine" {
  description = "Engine do RDS."
  type        = string
  default     = "postgres"
}

variable "rds_engine_version" {
  description = "Versao do engine RDS."
  type        = string
  default     = "16.9"
}

variable "rds_instance_class" {
  description = "Classe da instancia RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "Storage inicial em GB."
  type        = number
  default     = 30
}

variable "rds_max_allocated_storage" {
  description = "Limite maximo para autoscaling de storage em GB. Se null, autoscaling desabilitado."
  type        = number
  default     = 50
}

variable "rds_storage_type" {
  description = "Tipo de storage do RDS."
  type        = string
  default     = "gp3"
}

variable "rds_db_name" {
  description = "Nome do database PostgreSQL."
  type        = string
  default     = "contasdb"
}

variable "rds_db_username" {
  description = "Usuario admin do PostgreSQL."
  type        = string
  default     = "admin_contas"
}
