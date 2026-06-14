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

locals {
  role_prefix = "${var.project_name}-${var.environment}"

  consumer_role_names = {
    bi             = "${local.role_prefix}-consumer-bi"
    data_science   = "${local.role_prefix}-consumer-data-science"
    data_warehouse = "${local.role_prefix}-consumer-data-warehouse"
    risco_fraude   = "${local.role_prefix}-consumer-risco-fraude"
    auditoria      = "${local.role_prefix}-consumer-auditoria"
  }
}

data "aws_iam_role" "consumer" {
  for_each = local.consumer_role_names
  name     = each.value
}

data "aws_caller_identity" "current" {}

module "domain" {
  source = "../../../../modules/domain"

  project_name       = var.project_name
  environment        = var.environment
  domain             = "contas"
  owner              = "equipe-contas"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]
  create_sample_data = false

  layers = {
    bronze = {
      tables = {
        contas_raw = {
          description    = "Dados CDC de contas replicados via DMS."
          format         = "parquet"
          classification = "confidential"
          pii            = "no"
          s3_prefix      = "contas_raw/public/contas"
          columns = [
            { name = "Op",            type = "string", comment = "CDC operation: I=Insert, U=Update, D=Delete" },
            { name = "conta_id",      type = "string" },
            { name = "cliente_id",    type = "string" },
            { name = "tipo_conta",    type = "string" },
            { name = "saldo",         type = "decimal(12,2)" },
            { name = "status",        type = "string" },
            { name = "pais",          type = "string" },
            { name = "dms_timestamp", type = "string", comment = "Timestamp DMS" }
          ]
          sample_csv = ""
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        contas = {
          description    = "Contas — estado atual após CDC merge."
          format         = "parquet"
          classification = "confidential"
          pii            = "no"
          columns = [
            { name = "conta_id",   type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "tipo_conta", type = "string" },
            { name = "saldo",      type = "decimal(12,2)" },
            { name = "status",     type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-contas-silver-${data.aws_caller_identity.current.account_id}/contas/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        contas_ativas = {
          description    = "Contas ativas para analytics."
          format         = "parquet"
          classification = "confidential"
          pii            = "no"
          data_product   = "contas_ativas"
          columns = [
            { name = "conta_id",   type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "tipo_conta", type = "string" },
            { name = "saldo",      type = "decimal(12,2)" },
            { name = "status",     type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-contas-gold-${data.aws_caller_identity.current.account_id}/contas_ativas/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }

      full_table_grants = {
        auditoria_contas_ativas = {
          table_name    = "contas_ativas"
          principal_arn = data.aws_iam_role.consumer["auditoria"].arn
        }
      }

      data_filters = {
        bi_contas_ativas = {
          filter_name           = "bi_contas_ativas_no_saldo_br"
          table_name            = "contas_ativas"
          principal_arn         = data.aws_iam_role.consumer["bi"].arn
          excluded_column_names = ["saldo"]
          row_filter_expression = "pais = 'BR'"
        }
        ds_contas_ativas = {
          filter_name           = "ds_contas_ativas_br"
          table_name            = "contas_ativas"
          principal_arn         = data.aws_iam_role.consumer["data_science"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
