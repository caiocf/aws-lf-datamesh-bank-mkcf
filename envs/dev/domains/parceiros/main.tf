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
  domain             = "parceiros"
  owner              = "equipe-parceiros"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]
  create_sample_data = false

  layers = {
    bronze = {
      tables = {
        parceiros_raw = {
          description    = "Dados brutos de parceiros ingeridos da API."
          format         = "parquet"
          classification = "internal"
          pii            = "no"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "contrato_status", type = "string" }
          ]
          partition_keys = [
            { name = "pais",      type = "string" },
            { name = "dt_ingest", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"              = "injected"
              "projection.dt_ingest.type"         = "date"
              "projection.dt_ingest.format"       = "yyyy-MM-dd"
              "projection.dt_ingest.range"        = "2026-01-01,NOW"
              "projection.dt_ingest.interval"     = "1"
              "projection.dt_ingest.interval.unit" = "DAYS"
              "storage.location.template"         = "s3://lfmesh-dev-parceiros-bronze-${data.aws_caller_identity.current.account_id}/parceiros_raw/pais=$${pais}/dt_ingest=$${dt_ingest}/"
            }
          }
          sample_csv = ""
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        parceiros = {
          description    = "Parceiros deduplicados — última versão por parceiro_id."
          format         = "parquet"
          classification = "internal"
          pii            = "no"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "contrato_status", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-parceiros-silver-${data.aws_caller_identity.current.account_id}/parceiros/pais=$${pais}/"
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
        parceiros_ativos = {
          description    = "Parceiros ativos para analytics."
          format         = "parquet"
          classification = "internal"
          pii            = "no"
          data_product   = "parceiros_ativos"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "contrato_status", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-parceiros-gold-${data.aws_caller_identity.current.account_id}/parceiros_ativos/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }

      full_table_grants = {
        auditoria_parceiros = {
          table_name    = "parceiros_ativos"
          principal_arn = data.aws_iam_role.consumer["auditoria"].arn
        }
      }

      data_filters = {
        bi_parceiros = {
          filter_name           = "bi_parceiros_br"
          table_name            = "parceiros_ativos"
          principal_arn         = data.aws_iam_role.consumer["bi"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
        ds_parceiros = {
          filter_name           = "ds_parceiros_br"
          table_name            = "parceiros_ativos"
          principal_arn         = data.aws_iam_role.consumer["data_science"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
