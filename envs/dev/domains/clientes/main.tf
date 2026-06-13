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
            { name = "nome",       type = "string", comment = "PII" },
            { name = "cpf",        type = "string", comment = "PII" },
            { name = "email",      type = "string", comment = "PII" },
            { name = "segmento",   type = "string" }
          ]
          partition_keys = [
            { name = "pais",      type = "string" },
            { name = "dt_ingest", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"         = "injected"
              "projection.dt_ingest.type"    = "date"
              "projection.dt_ingest.format"  = "yyyy-MM-dd"
              "projection.dt_ingest.range"   = "2026-01-01,NOW"
              "projection.dt_ingest.interval" = "1"
              "projection.dt_ingest.interval.unit" = "DAYS"
              "storage.location.template"    = "s3://lfmesh-dev-clientes-bronze-978473717587/clientes_raw/pais=$${pais}/dt_ingest=$${dt_ingest}/"
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
          description    = "Clientes deduplicados — última versão por cliente_id."
          format         = "parquet"
          classification = "confidential"
          pii            = "yes"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome",       type = "string", comment = "PII" },
            { name = "cpf",        type = "string", comment = "PII" },
            { name = "email",      type = "string", comment = "PII" },
            { name = "segmento",   type = "string" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-clientes-silver-978473717587/clientes/pais=$${pais}/"
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
          description    = "Visão 360 analítica de clientes — enriquecida com dados de outros domínios."
          format         = "parquet"
          classification = "confidential"
          pii            = "yes"
          data_product   = "cliente_360"
          columns = [
            { name = "cliente_id",         type = "string" },
            { name = "nome",              type = "string", comment = "PII" },
            { name = "cpf",               type = "string", comment = "PII" },
            { name = "email",             type = "string", comment = "PII" },
            { name = "segmento",          type = "string" },
            { name = "total_contas",      type = "int",    comment = "Qtd contas ativas — domínio contas" },
            { name = "volume_transacoes", type = "double", comment = "Soma valor transações — domínio transacoes" },
            { name = "ultima_transacao",  type = "string", comment = "Data última transação — domínio transacoes" },
            { name = "score_risco",       type = "string", comment = "Score de risco — domínio alertas" }
          ]
          partition_keys = [
            { name = "pais", type = "string" }
          ]
          partition_projection = {
            enabled = true
            parameters = {
              "projection.pais.type"       = "injected"
              "storage.location.template" = "s3://lfmesh-dev-clientes-gold-978473717587/cliente_360/pais=$${pais}/"
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
          excluded_column_names = ["nome", "cpf", "email"]
          row_filter_expression = "pais = 'BR'"
        }
        ds_cliente_360 = {
          filter_name           = "ds_cliente_360_no_direct_pii"
          table_name            = "cliente_360"
          principal_arn         = data.aws_iam_role.consumer["data_science"].arn
          excluded_column_names = ["cpf", "email"]
          row_filter_expression = "pais = 'BR'"
        }
        risco_cliente_360 = {
          filter_name           = "risco_cliente_360_no_email"
          table_name            = "cliente_360"
          principal_arn         = data.aws_iam_role.consumer["risco_fraude"].arn
          excluded_column_names = ["email"]
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
