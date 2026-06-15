variable "project_name" {
  description = "Nome curto do projeto."
  type        = string
  default     = "lfmesh"
}

variable "environment" {
  description = "Ambiente lógico."
  type        = string
  default     = "dev"
}

variable "manage_data_lake_settings" {
  description = "Se true, gerencia aws_lakeformation_data_lake_settings. Desative se sua conta já tiver Lake Formation configurado manualmente."
  type        = bool
  default     = true
}

variable "lakeformation_admin_arns" {
  description = "ARNs de IAM users/roles que serão Data Lake Administrators. Se vazio, tenta usar o ARN retornado por aws_caller_identity."
  type        = list(string)
  default     = []
}

variable "trusted_principal_arns" {
  description = "Principals autorizados a assumir as roles consumidoras. Se vazio, usa arn:aws:iam::<account-id>:root para facilitar o lab."
  type        = list(string)
  default     = []
}

variable "consumer_personas" {
  description = "Personas consumidoras simulando contas consumidoras."
  type = map(object({
    description = string
  }))

  default = {
    bi = {
      description = "Analistas BI com Athena e QuickSight conceitual"
    }
    data-science = {
      description = "Cientistas de dados com Athena e SageMaker conceitual"
    }
    data-warehouse = {
      description = "Data Warehouse com Athena/Redshift Spectrum conceitual"
    }
    risco-fraude = {
      description = "Time de risco e fraude"
    }
    auditoria = {
      description = "Auditoria e compliance"
    }
  }
}

variable "lf_tags" {
  description = "Taxonomia corporativa de LF-Tags."
  type        = map(list(string))

  default = {
    domain = [
      "clientes",
      "contas",
      "transacoes",
      "parceiros",
      "riscos"
    ]

    classification = [
      "public",
      "internal",
      "confidential",
      "restricted"
    ]

    pii = [
      "yes",
      "no"
    ]

    layer = [
      "bronze",
      "silver",
      "gold"
    ]

    environment = [
      "dev",
      "hml",
      "prod"
    ]

    data_product = [
      "cliente_360",
      "contas_ativas",
      "transacoes_curated",
      "parceiros_ativos",
      "alertas_fraude"
    ]

    owner = [
      "equipe-clientes",
      "equipe-contas",
      "equipe-transacoes",
      "equipe-parceiros",
      "equipe-riscos"
    ]
  }
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}
