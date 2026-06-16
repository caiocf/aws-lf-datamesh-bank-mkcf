provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Lab         = "lakeformation-datamesh-shared-network"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Mantemos slices deterministicas para todos os dominios consumirem o mesmo contrato.
  sorted_subnet_ids          = sort(data.aws_subnets.default.ids)
  platform_subnet_ids        = slice(local.sorted_subnet_ids, 0, min(3, length(local.sorted_subnet_ids)))
  msk_broker_subnet_ids      = slice(local.sorted_subnet_ids, 0, min(2, length(local.sorted_subnet_ids)))
  interface_endpoint_subnets = slice(local.sorted_subnet_ids, 0, min(1, length(local.sorted_subnet_ids)))
  glue_connection_subnet_id  = local.platform_subnet_ids[0]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = var.availability_zones
  }
}

data "aws_subnet" "selected" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

resource "aws_security_group" "interface_endpoints" {
  name        = "${local.name_prefix}-shared-endpoints-sg"
  description = "Security group compartilhado para VPC Interface Endpoints do lab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
    description = "HTTPS a partir de qualquer recurso dentro da VPC do lab"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "${local.name_prefix}-shared-endpoints-sg"
    Component = "shared-network"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_vpc.default.main_route_table_id]

  tags = {
    Name      = "${local.name_prefix}-s3-gateway-endpoint"
    Component = "shared-network"
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.interface_endpoint_subnets
  security_group_ids  = [aws_security_group.interface_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name      = "${local.name_prefix}-secretsmanager-endpoint"
    Component = "shared-network"
  }
}

resource "aws_vpc_endpoint" "glue" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.glue"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.interface_endpoint_subnets
  security_group_ids  = [aws_security_group.interface_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name      = "${local.name_prefix}-glue-endpoint"
    Component = "shared-network"
  }
}
