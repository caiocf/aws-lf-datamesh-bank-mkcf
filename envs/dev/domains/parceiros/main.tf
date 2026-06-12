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
  domain             = "parceiros"
  owner              = "equipe-parceiros"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]

  layers = {
    bronze = {
      tables = {
        parceiros_raw = {
          description    = "Dados brutos de parceiros."
          classification = "internal"
          pii            = "no"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "pais",            type = "string" },
            { name = "contrato_status", type = "string" },
            { name = "dt_ingest",       type = "string" }
          ]
          sample_csv = <<EOT
parceiro_id,nome_parceiro,categoria,pais,contrato_status,dt_ingest
p001,Parceiro Pagamentos,pagamentos,BR,ativo,2026-01-10
p002,Parceiro Antifraude,risco,BR,ativo,2026-01-10
p003,Parceiro Global,dados,US,ativo,2026-01-10
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        parceiros = {
          description    = "Parceiros padronizados."
          classification = "internal"
          pii            = "no"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "pais",            type = "string" },
            { name = "contrato_status", type = "string" }
          ]
          sample_csv = <<EOT
parceiro_id,nome_parceiro,categoria,pais,contrato_status
p001,Parceiro Pagamentos,pagamentos,BR,ativo
p002,Parceiro Antifraude,risco,BR,ativo
p003,Parceiro Global,dados,US,ativo
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        parceiros_ativos = {
          description    = "Parceiros ativos e contratos para analytics."
          classification = "internal"
          pii            = "no"
          data_product   = "parceiros_ativos"
          columns = [
            { name = "parceiro_id",     type = "string" },
            { name = "nome_parceiro",   type = "string" },
            { name = "categoria",       type = "string" },
            { name = "pais",            type = "string" },
            { name = "contrato_status", type = "string" }
          ]
          sample_csv = <<EOT
parceiro_id,nome_parceiro,categoria,pais,contrato_status
p001,Parceiro Pagamentos,pagamentos,BR,ativo
p002,Parceiro Antifraude,risco,BR,ativo
p003,Parceiro Global,dados,US,ativo
EOT
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
