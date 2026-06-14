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

variable "dms_serverless" {
  description = "Usar DMS Serverless (true) ou Provisionado (false). Provisionado e mais rapido para criar/destruir no lab."
  type        = bool
  default     = false
}
