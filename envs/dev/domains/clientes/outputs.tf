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
