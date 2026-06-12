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
  domain             = "transacoes"
  owner              = "equipe-transacoes"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]

  layers = {
    bronze = {
      tables = {
        transacoes_raw = {
          description    = "Transações brutas ingeridas da fonte."
          classification = "confidential"
          pii            = "no"
          columns = [
            { name = "transacao_id",   type = "string" },
            { name = "conta_id",       type = "string" },
            { name = "cliente_id",     type = "string" },
            { name = "valor",          type = "double" },
            { name = "moeda",          type = "string" },
            { name = "categoria",      type = "string" },
            { name = "pais",           type = "string" },
            { name = "data_transacao", type = "string" },
            { name = "dt_ingest",      type = "string" }
          ]
          sample_csv = <<EOT
transacao_id,conta_id,cliente_id,valor,moeda,categoria,pais,data_transacao,dt_ingest
t001,a001,c001,220.50,BRL,mercado,BR,2026-01-10,2026-01-10
t002,a002,c002,5000.00,BRL,transferencia,BR,2026-01-11,2026-01-11
t003,a003,c003,90.00,USD,servicos,US,2026-01-11,2026-01-11
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        transacoes = {
          description    = "Transações limpas e enriquecidas."
          classification = "confidential"
          pii            = "no"
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
          sample_csv = <<EOT
transacao_id,conta_id,cliente_id,valor,moeda,categoria,pais,data_transacao
t001,a001,c001,220.50,BRL,mercado,BR,2026-01-10
t002,a002,c002,5000.00,BRL,transferencia,BR,2026-01-11
t003,a003,c003,90.00,USD,servicos,US,2026-01-11
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        transacoes_curated = {
          description    = "Transações curadas para analytics e detecção de fraude."
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
            { name = "pais",           type = "string" },
            { name = "data_transacao", type = "string" }
          ]
          sample_csv = <<EOT
transacao_id,conta_id,cliente_id,valor,moeda,categoria,pais,data_transacao
t001,a001,c001,220.50,BRL,mercado,BR,2026-01-10
t002,a002,c002,5000.00,BRL,transferencia,BR,2026-01-11
t003,a003,c003,90.00,USD,servicos,US,2026-01-11
EOT
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
