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
