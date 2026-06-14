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
  domain             = "transacoes"
  owner              = "equipe-transacoes"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]
  create_sample_data = false

  layers = {
    bronze = {
      tables = {
        transacoes_raw = {
          description    = "Transacoes brutas ingeridas via MSK S3 Sink Connector."
          format         = "json"
          classification = "confidential"
          pii            = "no"
          s3_prefix      = "transacoes_raw/txn.transacoes.raw"
          columns = [
            { name = "transacao_id",   type = "string" },
            { name = "conta_id",       type = "string" },
            { name = "cliente_id",     type = "string" },
            { name = "valor",          type = "double" },
            { name = "moeda",          type = "string" },
            { name = "categoria",      type = "string" },
            { name = "pais",           type = "string" },
            { name = "data_transacao", type = "string" }
          ]
          sample_csv = ""
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        transacoes = {
          description    = "Transacoes deduplicadas."
          format         = "parquet"
          classification = "confidential"
          pii            = "no"
          columns = [
            { name = "transacao_id",   type = "string" },
            { name = "conta_id",       type = "string" },
            { name = "cliente_id",     type = "string" },
            { name = "valor",          type = "double" },
            { name = "moeda",          type = "string" },
            { name = "categoria",      type = "string" },
            { name = "data_transacao", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-transacoes-silver-${data.aws_caller_identity.current.account_id}/transacoes/pais=$${pais}/"
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
        transacoes_curated = {
          description    = "Transacoes curadas para analytics."
          format         = "parquet"
          classification = "confidential"
          pii            = "no"
          data_product   = "transacoes_curated"
          columns = [
            { name = "transacao_id",   type = "string" },
            { name = "conta_id",       type = "string" },
            { name = "cliente_id",     type = "string" },
            { name = "valor",          type = "double" },
            { name = "moeda",          type = "string" },
            { name = "categoria",      type = "string" },
            { name = "data_transacao", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-transacoes-gold-${data.aws_caller_identity.current.account_id}/transacoes_curated/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }

      full_table_grants = {
        auditoria_transacoes = {
          table_name    = "transacoes_curated"
          principal_arn = data.aws_iam_role.consumer["auditoria"].arn
        }
      }

      data_filters = {
        bi_transacoes = {
          filter_name           = "bi_transacoes_br"
          table_name            = "transacoes_curated"
          principal_arn         = data.aws_iam_role.consumer["bi"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
        ds_transacoes = {
          filter_name           = "ds_transacoes_br"
          table_name            = "transacoes_curated"
          principal_arn         = data.aws_iam_role.consumer["data_science"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
        risco_transacoes = {
          filter_name           = "risco_transacoes_br"
          table_name            = "transacoes_curated"
          principal_arn         = data.aws_iam_role.consumer["risco_fraude"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
