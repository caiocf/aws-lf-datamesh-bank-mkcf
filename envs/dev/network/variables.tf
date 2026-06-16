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

variable "availability_zones" {
  description = "Lista de AZs candidatas dentro da VPC default do lab."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
}
