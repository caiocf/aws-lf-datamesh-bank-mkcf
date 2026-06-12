output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "consumer_role_arns" {
  value = {
    for k, v in aws_iam_role.consumer : k => v.arn
  }
}

output "consumer_role_names" {
  value = {
    for k, v in aws_iam_role.consumer : k => v.name
  }
}

output "athena_workgroups" {
  value = {
    for k, v in aws_athena_workgroup.consumer : k => v.name
  }
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}

output "lf_tag_keys" {
  value = keys(aws_lakeformation_lf_tag.this)
}
