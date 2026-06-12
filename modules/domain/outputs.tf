output "domain" {
  value = var.domain
}

output "database_names" {
  value = { for layer, db in aws_glue_catalog_database.layer : layer => db.name }
}

output "bucket_names" {
  value = { for layer, bucket in aws_s3_bucket.layer : layer => bucket.bucket }
}

output "producer_role_arn" {
  value = aws_iam_role.producer.arn
}

output "tables" {
  value = { for k, t in aws_glue_catalog_table.layer : k => t.name }
}

output "data_filters" {
  value = { for k in keys(aws_lakeformation_data_cells_filter.this) : k => k }
}
