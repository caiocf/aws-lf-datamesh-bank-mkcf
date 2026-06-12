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
  domain             = "contas"
  owner              = "equipe-contas"
  consumer_role_arns = [for role in data.aws_iam_role.consumer : role.arn]

  layers = {
    bronze = {
      tables = {
        contas_raw = {
          description    = "Dados brutos de contas."
          classification = "confidential"
          pii            = "no"
          columns = [
            { name = "conta_id",   type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "tipo_conta", type = "string" },
            { name = "saldo",      type = "double" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" },
            { name = "dt_ingest",  type = "string" }
          ]
          sample_csv = <<EOT
conta_id,cliente_id,tipo_conta,saldo,status,pais,dt_ingest
a001,c001,corrente,15000.50,ativa,BR,2026-01-10
a002,c002,poupanca,2500.00,ativa,BR,2026-01-10
a003,c003,corrente,8000.00,ativa,US,2026-01-10
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        contas = {
          description    = "Contas padronizadas e validadas."
          classification = "confidential"
          pii            = "no"
          columns = [
            { name = "conta_id",   type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "tipo_conta", type = "string" },
            { name = "saldo",      type = "double" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" }
          ]
          sample_csv = <<EOT
conta_id,cliente_id,tipo_conta,saldo,status,pais
a001,c001,corrente,15000.50,ativa,BR
a002,c002,poupanca,2500.00,ativa,BR
a003,c003,corrente,8000.00,ativa,US
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        contas_ativas = {
          description    = "Contas ativas para analytics."
          classification = "confidential"
          pii            = "no"
          data_product   = "contas_ativas"
          columns = [
            { name = "conta_id",   type = "string" },
            { name = "cliente_id", type = "string" },
            { name = "tipo_conta", type = "string" },
            { name = "saldo",      type = "double" },
            { name = "status",     type = "string" },
            { name = "pais",       type = "string" }
          ]
          sample_csv = <<EOT
conta_id,cliente_id,tipo_conta,saldo,status,pais
a001,c001,corrente,15000.50,ativa,BR
a002,c002,poupanca,2500.00,ativa,BR
a003,c003,corrente,8000.00,ativa,US
EOT
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
