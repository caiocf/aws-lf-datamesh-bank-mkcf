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

  layers = {
    bronze = {
      tables = {
        clientes_raw = {
          description    = "Dados brutos de clientes ingeridos da fonte."
          classification = "restricted"
          pii            = "yes"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome",       type = "string", comment = "PII" },
            { name = "cpf",        type = "string", comment = "PII" },
            { name = "email",      type = "string", comment = "PII" },
            { name = "segmento",   type = "string" },
            { name = "pais",       type = "string" },
            { name = "dt_ingest",  type = "string" }
          ]
          sample_csv = <<EOT
cliente_id,nome,cpf,email,segmento,pais,dt_ingest
c001,Ana Silva,11111111111,ana@example.com,alta_renda,BR,2026-01-10
c002,Bruno Souza,22222222222,bruno@example.com,varejo,BR,2026-01-10
c003,Carla Lima,33333333333,carla@example.com,internacional,US,2026-01-10
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    silver = {
      tables = {
        clientes = {
          description    = "Clientes limpos e padronizados."
          classification = "confidential"
          pii            = "yes"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome",       type = "string", comment = "PII" },
            { name = "cpf",        type = "string", comment = "PII" },
            { name = "email",      type = "string", comment = "PII" },
            { name = "segmento",   type = "string" },
            { name = "pais",       type = "string" }
          ]
          sample_csv = <<EOT
cliente_id,nome,cpf,email,segmento,pais
c001,Ana Silva,11111111111,ana@example.com,alta_renda,BR
c002,Bruno Souza,22222222222,bruno@example.com,varejo,BR
c003,Carla Lima,33333333333,carla@example.com,internacional,US
EOT
        }
      }
      full_table_grants = {}
      data_filters      = {}
    }

    gold = {
      tables = {
        cliente_360 = {
          description    = "Visão 360 analítica de clientes."
          classification = "confidential"
          pii            = "yes"
          data_product   = "cliente_360"
          columns = [
            { name = "cliente_id", type = "string" },
            { name = "nome",       type = "string", comment = "PII" },
            { name = "cpf",        type = "string", comment = "PII" },
            { name = "email",      type = "string", comment = "PII" },
            { name = "segmento",   type = "string" },
            { name = "pais",       type = "string" }
          ]
          sample_csv = <<EOT
cliente_id,nome,cpf,email,segmento,pais
c001,Ana Silva,11111111111,ana@example.com,alta_renda,BR
c002,Bruno Souza,22222222222,bruno@example.com,varejo,BR
c003,Carla Lima,33333333333,carla@example.com,internacional,US
EOT
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
