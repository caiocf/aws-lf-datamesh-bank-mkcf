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
  domain             = "alertas"
  owner              = "equipe-alertas"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]

  layers = {
    bronze = {
      tables = {
        alertas_raw = {
          description    = "Alertas brutos ingeridos."
          classification = "restricted"
          pii            = "no"
          columns = [
            { name = "alerta_id",  type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id",   type = "string" },
            { name = "severidade", type = "string" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" },
            { name = "motivo",     type = "string" },
            { name = "dt_ingest",  type = "string" }
          ]
          sample_csv = <<EOT
alerta_id,cliente_id,conta_id,severidade,status,pais,motivo,dt_ingest
al001,c001,a001,alta,aberto,BR,transacao_incomum,2026-01-10
al002,c002,a002,media,fechado,BR,limite_transacional,2026-01-10
al003,c003,a003,alta,aberto,US,login_suspeito,2026-01-10
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        alertas = {
          description    = "Alertas enriquecidos e classificados."
          classification = "restricted"
          pii            = "no"
          columns = [
            { name = "alerta_id",  type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id",   type = "string" },
            { name = "severidade", type = "string" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" },
            { name = "motivo",     type = "string" }
          ]
          sample_csv = <<EOT
alerta_id,cliente_id,conta_id,severidade,status,pais,motivo
al001,c001,a001,alta,aberto,BR,transacao_incomum
al002,c002,a002,media,fechado,BR,limite_transacional
al003,c003,a003,alta,aberto,US,login_suspeito
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        alertas_fraude = {
          description    = "Alertas de fraude consolidados para analytics."
          classification = "restricted"
          pii            = "no"
          data_product   = "alertas_fraude"
          columns = [
            { name = "alerta_id",  type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "conta_id",   type = "string" },
            { name = "severidade", type = "string" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" },
            { name = "motivo",     type = "string" }
          ]
          sample_csv = <<EOT
alerta_id,cliente_id,conta_id,severidade,status,pais,motivo
al001,c001,a001,alta,aberto,BR,transacao_incomum
al002,c002,a002,media,fechado,BR,limite_transacional
al003,c003,a003,alta,aberto,US,login_suspeito
EOT
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
          filter_name           = "risco_alertas_abertos_br"
          table_name            = "alertas_fraude"
          principal_arn         = data.aws_iam_role.consumer["risco_fraude"].arn
          excluded_column_names = []
          row_filter_expression = "pais = 'BR'"
        }
      }
    }
  }
}
