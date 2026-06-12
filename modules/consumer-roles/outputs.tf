output "consumer_user_role_arns" {
  description = "ARNs das roles de usuários consumidores"
  value = {
    for key, role in aws_iam_role.consumer_users :
    key => role.arn
  }
}

output "consumer_user_role_names" {
  description = "Nomes das roles de usuários consumidores"
  value = {
    for key, role in aws_iam_role.consumer_users :
    key => role.name
  }
}

output "consumer_application_role_arns" {
  description = "ARNs das roles de aplicações consumidoras"
  value = {
    for key, role in aws_iam_role.consumer_applications :
    key => role.arn
  }
}

output "consumer_application_role_names" {
  description = "Nomes das roles de aplicações consumidoras"
  value = {
    for key, role in aws_iam_role.consumer_applications :
    key => role.name
  }
}

output "all_consumer_role_arns" {
  description = "Todos os ARNs de roles consumidoras (usuários + aplicações)"
  value = concat(
    values(aws_iam_role.consumer_users)[*].arn,
    values(aws_iam_role.consumer_applications)[*].arn
  )
}

output "assume_role_commands" {
  description = "Comandos para assumir as roles via AWS CLI"
  value = {
    for key, role in aws_iam_role.consumer_users :
    key => "aws sts assume-role --role-arn ${role.arn} --role-session-name ${key}-session --external-id ${var.consumer_users[key].external_id}"
  }
}