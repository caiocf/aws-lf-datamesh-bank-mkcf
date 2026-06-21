output "sns_topic_arn_critical" {
  value = module.observability_central.sns_topic_arn_critical
}

output "sns_topic_arn_warning" {
  value = module.observability_central.sns_topic_arn_warning
}

output "dashboard_name" {
  value = module.observability_central.dashboard_name
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.observability_central.dashboard_name}"
}
