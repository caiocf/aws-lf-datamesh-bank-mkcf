provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "lakeformation-datamesh-consumer-roles"
    }
  }
}

module "consumer_roles" {
  source = "../../../modules/consumer-roles"

  project_name = var.project_name
  environment  = var.environment
}