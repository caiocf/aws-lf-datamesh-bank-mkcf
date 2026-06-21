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
  description = "Email para receber notificações. Precisa ser confirmado manualmente no SNS após o apply."
}

variable "enable_oam_sink" {
  type        = bool
  default     = false
  description = "Habilita OAM Sink. No lab single-account, deixar false."
}
