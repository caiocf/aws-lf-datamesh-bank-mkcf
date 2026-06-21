output "alarm_arns" {
  description = "ARNs de todos os alarmes criados para este domínio."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.glue_job_failed : a.arn],
    [for a in aws_cloudwatch_metric_alarm.glue_job_duration : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dms_cdc_latency_source : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dms_cdc_latency_target : a.arn],
    [for a in aws_cloudwatch_metric_alarm.msk_offset_lag : a.arn],
    [for a in aws_cloudwatch_metric_alarm.msk_time_lag : a.arn],
    [for a in aws_cloudwatch_metric_alarm.msk_connect_failed : a.arn],
    [for a in aws_cloudwatch_metric_alarm.glue_streaming_stopped : a.arn],
    [for a in aws_cloudwatch_metric_alarm.dms_task_stopped : a.arn]
  )
}

output "oam_link_arn" {
  description = "ARN do OAM Link (vazio se não habilitado)."
  value       = var.enable_oam_link ? aws_oam_link.this[0].arn : ""
}
