output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "vpc_cidr_block" {
  value = data.aws_vpc.default.cidr_block
}

output "main_route_table_id" {
  value = data.aws_vpc.default.main_route_table_id
}

output "all_subnet_ids" {
  value = local.sorted_subnet_ids
}

output "platform_subnet_ids" {
  value = local.platform_subnet_ids
}

output "msk_broker_subnet_ids" {
  value = local.msk_broker_subnet_ids
}

output "glue_connection_subnet_id" {
  value = local.glue_connection_subnet_id
}

output "glue_connection_subnet_availability_zone" {
  value = data.aws_subnet.selected[local.glue_connection_subnet_id].availability_zone
}

output "interface_endpoint_security_group_id" {
  value = aws_security_group.interface_endpoints.id
}

output "shared_endpoint_ids" {
  value = {
    s3             = aws_vpc_endpoint.s3.id
    secretsmanager = aws_vpc_endpoint.secretsmanager.id
    glue           = aws_vpc_endpoint.glue.id
  }
}
