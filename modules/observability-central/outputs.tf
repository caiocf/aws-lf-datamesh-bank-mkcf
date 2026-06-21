output "sns_topic_arn_critical" {
  description = "ARN do SNS topic para alarmes críticos."
  value       = aws_sns_topic.critical.arn
}

output "sns_topic_arn_warning" {
  description = "ARN do SNS topic para alarmes warning."
  value       = aws_sns_topic.warning.arn
}

output "sns_topic_arn_data_quality" {
  description = "ARN do SNS topic para alarmes de data quality."
  value       = aws_sns_topic.data_quality.arn
}

output "dashboard_name" {
  description = "Nome do CloudWatch Dashboard centralizado."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "oam_sink_arn" {
  description = "ARN do OAM Sink (vazio se não habilitado)."
  value       = var.enable_oam_sink ? aws_oam_sink.this[0].arn : ""
}
