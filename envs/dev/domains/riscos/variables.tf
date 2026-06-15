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

variable "create_vpc_endpoints" {
  description = <<-EOT
    Criar VPC Endpoints (S3 Gateway + Glue Interface).
    
    Em producao real (multi-account), cada conta tem sua VPC e seus endpoints.
    No lab (conta unica, VPC compartilhada), apenas o PRIMEIRO dominio deployado deve criar.
    
    Se transacoes ou contas ja estao deployados na mesma VPC, setar false.
    Verificar: aws ec2 describe-vpc-endpoints --filters Name=vpc-endpoint-state,Values=available --query "VpcEndpoints[].ServiceName" --output text
  EOT
  type        = bool
  default     = true
}
