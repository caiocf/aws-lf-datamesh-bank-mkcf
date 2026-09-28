output "database_names" {
  value = module.domain.database_names
}

output "bucket_names" {
  value = module.domain.bucket_names
}

output "producer_role_arn" {
  value = module.domain.producer_role_arn
}

output "tables" {
  value = module.domain.tables
}

output "dms_monitoring" {
  description = "CloudWatch dimensions for provisioned DMS; null in serverless mode."
  value = var.dms_serverless ? null : {
    instance_id = aws_dms_replication_instance.contas[0].replication_instance_id
    task_cw_id  = reverse(split(":", aws_dms_replication_task.contas_cdc[0].replication_task_arn))[0]
  }
}
