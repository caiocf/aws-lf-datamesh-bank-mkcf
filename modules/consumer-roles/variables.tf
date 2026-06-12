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

variable "consumer_users" {
  description = "Usuários simulados de contas consumidoras."
  type = map(object({
    description  = string
    department   = string
    access_level = string
    external_id  = string
  }))
  
  default = {
    "ana-silva-bi" = {
      description  = "Analista BI Ana Silva"
      department   = "business-intelligence"
      access_level = "analyst"
      external_id  = "bi-ana-2024"
    }
    
    "carlos-santos-ds" = {
      description  = "Cientista de Dados Carlos Santos"
      department   = "data-science"
      access_level = "scientist"
      external_id  = "ds-carlos-2024"
    }
    
    "maria-costa-dw" = {
      description  = "Engenheira DW Maria Costa"
      department   = "data-warehouse"
      access_level = "engineer"
      external_id  = "dw-maria-2024"
    }
    
    "pedro-oliveira-risk" = {
      description  = "Analista de Risco Pedro Oliveira"
      department   = "risk-management"
      access_level = "senior-analyst"
      external_id  = "risk-pedro-2024"
    }
    
    "lucia-ferreira-audit" = {
      description  = "Auditora Lucia Ferreira"
      department   = "audit-compliance"
      access_level = "auditor"
      external_id  = "audit-lucia-2024"
    }
  }
}

variable "consumer_applications" {
  description = "Aplicações simuladas de contas consumidoras."
  type = map(object({
    description         = string
    access_pattern      = string
    external_id         = string
    additional_services = list(string)
  }))
  
  default = {
    "quicksight-prod" = {
      description         = "QuickSight Production Dashboards"
      access_pattern      = "interactive-dashboards"
      external_id         = "qs-prod-2024"
      additional_services = ["quicksight"]
    }
    
    "sagemaker-ml" = {
      description         = "SageMaker ML Pipeline"
      access_pattern      = "batch-training"
      external_id         = "sg-ml-2024"
      additional_services = ["sagemaker", "s3"]
    }
    
    "redshift-dwh" = {
      description         = "Redshift Data Warehouse"
      access_pattern      = "scheduled-etl"
      external_id         = "rs-dwh-2024"
      additional_services = ["redshift"]
    }
    
    "fraud-detection-api" = {
      description         = "Real-time Fraud Detection API"
      access_pattern      = "real-time-scoring"
      external_id         = "fraud-api-2024"
      additional_services = ["lambda", "apigateway"]
    }
    
    "compliance-reporter" = {
      description         = "Compliance Reporting System"
      access_pattern      = "monthly-reports"
      external_id         = "compliance-2024"
      additional_services = ["ses", "s3"]
    }
  }
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}