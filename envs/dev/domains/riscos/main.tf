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
  domain             = "riscos"
  owner              = "equipe-riscos"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]
  create_sample_data = false

  layers = {
    bronze = {
      tables = {
        riscos_raw = {
          description    = "Eventos de risco brutos ingeridos via Glue Streaming do MSK Serverless."
          format         = "parquet"
          classification = "restricted"
          pii            = "no"
          columns = [
            { name = "alerta_id", type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id", type = "string" },
            { name = "severidade", type = "string" },
            { name = "status", type = "string" },
            { name = "motivo", type = "string" },
            { name = "score_risco", type = "double" },
            { name = "data_alerta", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-riscos-bronze-${data.aws_caller_identity.current.account_id}/riscos_raw/pais=$${pais}/"
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
        riscos = {
          description    = "Eventos de risco deduplicados por alerta_id."
          format         = "parquet"
          classification = "restricted"
          pii            = "no"
          columns = [
            { name = "alerta_id", type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id", type = "string" },
            { name = "severidade", type = "string" },
            { name = "status", type = "string" },
            { name = "motivo", type = "string" },
            { name = "score_risco", type = "double" },
            { name = "data_alerta", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-riscos-silver-${data.aws_caller_identity.current.account_id}/riscos/pais=$${pais}/"
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
        alertas_fraude = {
          description    = "Alertas de fraude ativos (aberto + em_analise) para analytics."
          format         = "parquet"
          classification = "restricted"
          pii            = "no"
          data_product   = "alertas_fraude"
          columns = [
            { name = "alerta_id", type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id", type = "string" },
            { name = "severidade", type = "string" },
            { name = "status", type = "string" },
            { name = "motivo", type = "string" },
            { name = "score_risco", type = "double" },
            { name = "data_alerta", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-riscos-gold-${data.aws_caller_identity.current.account_id}/alertas_fraude/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }

      full_table_grants = {
        auditoria_alertas = {
          table_name    = "alertas_fraude"
          principal_arn = data.aws_iam_role.consumer["auditoria"].arn
        }
      }

      data_filters = {
        risco_alertas = {
          filter_name           = "risco_alertas_fraude_br"
          table_name            = "alertas_fraude"
          principal_arn         = data.aws_iam_role.consumer["risco_fraude"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
        bi_alertas = {
          filter_name           = "bi_alertas_fraude_br"
          table_name            = "alertas_fraude"
          principal_arn         = data.aws_iam_role.consumer["bi"].arn
          excluded_column_names = ["score_risco"]
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
