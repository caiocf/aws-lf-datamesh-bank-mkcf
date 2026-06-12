provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "lakeformation-datamesh-single-account"
    }
  }
}

module "foundation" {
  source = "../../../modules/foundation"

  project_name              = var.project_name
  environment               = var.environment
  lakeformation_admin_arns  = var.lakeformation_admin_arns
  trusted_principal_arns    = var.trusted_principal_arns
  manage_data_lake_settings = var.manage_data_lake_settings
}
