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

variable "lakeformation_admin_arns" {
  type    = list(string)
  default = []
}

variable "trusted_principal_arns" {
  type    = list(string)
  default = []
}

variable "manage_data_lake_settings" {
  type    = bool
  default = true
}
