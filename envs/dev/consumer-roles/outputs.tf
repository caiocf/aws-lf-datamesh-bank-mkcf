output "consumer_user_role_arns" {
  description = "ARNs das roles de usuários consumidores"
  value       = module.consumer_roles.consumer_user_role_arns
}

output "consumer_application_role_arns" {
  description = "ARNs das roles de aplicações consumidoras"
  value       = module.consumer_roles.consumer_application_role_arns
}

output "all_consumer_role_arns" {
  description = "Todos os ARNs de roles consumidoras"
  value       = module.consumer_roles.all_consumer_role_arns
}

output "assume_role_commands" {
  description = "Comandos para assumir as roles"
  value       = module.consumer_roles.assume_role_commands
}