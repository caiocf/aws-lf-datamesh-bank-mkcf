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
  domain             = "clientes"
  owner              = "equipe-clientes"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]
  create_sample_data = false

  layers = {
    bronze = {
      tables = {
        clientes_raw = {
          description    = "Dados brutos de clientes ingeridos da fonte."
          format         = "parquet"
          classification = "restricted"
          pii            = "yes"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome", type = "string", comment = "PII" },
            { name = "cpf", type = "string", comment = "PII" },
            { name = "email", type = "string", comment = "PII" },
            { name = "segmento", type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" },
            { name = "dt_ingest", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"               = "injected"
              "projection.dt_ingest.type"          = "date"
              "projection.dt_ingest.format"        = "yyyy-MM-dd"
              "projection.dt_ingest.range"         = "2026-01-01,NOW"
              "projection.dt_ingest.interval"      = "1"
              "projection.dt_ingest.interval.unit" = "DAYS"
              "storage.location.template"          = "s3://lfmesh-dev-clientes-bronze-${data.aws_caller_identity.current.account_id}/clientes_raw/pais=$${pais}/dt_ingest=$${dt_ingest}/"
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
        clientes = {
          description    = "Clientes deduplicados - ultima versao por cliente_id."
          format         = "parquet"
          classification = "confidential"
          pii            = "yes"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome", type = "string", comment = "PII" },
            { name = "cpf", type = "string", comment = "PII" },
            { name = "email", type = "string", comment = "PII" },
            { name = "segmento", type = "string" },
            { name = "cpf_hash", type = "string", comment = "SHA256 do CPF" },
            { name = "email_hash", type = "string", comment = "SHA256 do email" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"      = "injected"
              "storage.location.template" = "s3://lfmesh-dev-clientes-silver-${data.aws_caller_identity.current.account_id}/clientes/pais=$${pais}/"
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
        cliente_360 = {
          description    = "Visao 360 analitica de clientes - enriquecida com dados de outros dominios. PII mascarada via SHA256 + partial mask."
          format         = "parquet"
          classification = "confidential"
          pii            = "yes"
          data_product   = "cliente_360"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome", type = "string", comment = "PII - nome completo" },
            { name = "cpf_masked", type = "string", comment = "CPF parcialmente mascarado (***.***.***-XX)" },
            { name = "cpf_hash", type = "string", comment = "SHA256 do CPF para joins tecnicos" },
            { name = "email_masked", type = "string", comment = "Email parcialmente mascarado (x***@dominio)" },
            { name = "email_hash", type = "string", comment = "SHA256 do email para joins tecnicos" },
            { name = "segmento", type = "string" },
            { name = "total_contas", type = "int", comment = "Qtd contas ativas - dominio contas" },
            { name = "volume_transacoes", type = "double", comment = "Soma valor transacoes - dominio transacoes" },
            { name = "ultima_transacao", type = "string", comment = "Data ultima transacao - dominio transacoes" },
            { name = "score_risco", type = "string", comment = "Score de risco - dominio riscos" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"      = "injected"
              "storage.location.template" = "s3://lfmesh-dev-clientes-gold-${data.aws_caller_identity.current.account_id}/cliente_360/pais=$${pais}/"
            }
          }
          sample_csv = ""
        }
      }

      full_table_grants = {
        auditoria_cliente_360 = {
          table_name    = "cliente_360"
          principal_arn = data.aws_iam_role.consumer["auditoria"].arn
        }
      }

      data_filters = {
        bi_cliente_360 = {
          filter_name           = "bi_cliente_360_no_pii_br"
          table_name            = "cliente_360"
          principal_arn         = data.aws_iam_role.consumer["bi"].arn
          excluded_column_names = ["nome", "cpf_hash", "email_hash"]
          row_filter_expression = "pais = 'BR'"
        }
        ds_cliente_360 = {
          filter_name           = "ds_cliente_360_masked"
          table_name            = "cliente_360"
          principal_arn         = data.aws_iam_role.consumer["data_science"].arn
          excluded_column_names = ["nome"]
          row_filter_expression = "pais = 'BR'"
        }
        risco_cliente_360 = {
          filter_name           = "risco_cliente_360_ops"
          table_name            = "cliente_360"
          principal_arn         = data.aws_iam_role.consumer["risco_fraude"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
