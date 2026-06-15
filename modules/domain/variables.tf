variable "project_name" {
  description = "Nome curto do projeto."
  type        = string
  default     = "lfmesh"
}

variable "environment" {
  description = "Ambiente logico."
  type        = string
  default     = "dev"
}

variable "domain" {
  description = "Nome do dominio: clientes, contas, transacoes, parceiros ou riscos."
  type        = string
}

variable "owner" {
  description = "Owner logico do dominio."
  type        = string
}

variable "consumer_role_arns" {
  description = "Roles consumidoras que receberao DESCRIBE nos databases."
  type        = list(string)
  default     = []
}

variable "layers" {
  description = "Camadas do dominio (bronze, silver, gold) com suas tabelas, grants e filtros."
  type = map(object({
    tables = map(object({
      description = optional(string, "")
      s3_prefix   = optional(string)
      format      = optional(string, "csv")
      columns = list(object({
        name    = string
        type    = string
        comment = optional(string, "")
      }))
      partition_keys = optional(list(object({
        name = string
        type = string
      })), [])
      partition_projection = optional(object({
        enabled    = optional(bool, false)
        parameters = optional(map(string), {})
      }), { enabled = false, parameters = {} })
      sample_csv     = optional(string, "")
      classification = optional(string, "internal")
      pii            = optional(string, "no")
      data_product   = optional(string)
    }))

    full_table_grants = optional(map(object({
      table_name    = string
      principal_arn = string
    })), {})

    data_filters = optional(map(object({
      filter_name           = string
      table_name            = string
      principal_arn         = string
      column_names          = optional(list(string))
      excluded_column_names = optional(list(string), [])
      row_filter_expression = optional(string, "")
    })), {})
  }))
  default = {}
}

variable "create_sample_data" {
  description = "Cria objetos CSV pequenos no S3 para validacao com Athena."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}
