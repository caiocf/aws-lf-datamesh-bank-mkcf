data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  
  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "consumer-roles"
    },
    var.tags
  )
}

# Roles que simulam usuários reais de contas consumidoras
data "aws_iam_policy_document" "consumer_user_assume_role" {
  for_each = var.consumer_users

  statement {
    sid     = "AllowUserAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [each.value.external_id]
    }
  }
}

resource "aws_iam_role" "consumer_users" {
  for_each = var.consumer_users

  name               = "${local.name_prefix}-user-${each.key}"
  description        = "Simula usuário ${each.value.description} de conta consumidora"
  assume_role_policy = data.aws_iam_policy_document.consumer_user_assume_role[each.key].json
  max_session_duration = 3600

  tags = merge(local.default_tags, {
    Name         = "${local.name_prefix}-user-${each.key}"
    UserPersona  = each.key
    Department   = each.value.department
    AccessLevel  = each.value.access_level
  })
}

# Policy básica para interagir com serviços AWS
data "aws_iam_policy_document" "consumer_user_base_access" {
  statement {
    sid = "BasicAWSServicesAccess"
    
    actions = [
      "sts:GetCallerIdentity",
      "sts:AssumeRole"
    ]
    
    resources = ["*"]
  }
  
  statement {
    sid = "ConsoleAccess"
    
    actions = [
      "iam:GetUser",
      "iam:GetRole", 
      "iam:ListRoles"
    ]
    
    resources = ["*"]
  }
}

resource "aws_iam_policy" "consumer_user_base_access" {
  name        = "${local.name_prefix}-consumer-user-base-access"
  description = "Acesso básico para usuários simulados de contas consumidoras"
  policy      = data.aws_iam_policy_document.consumer_user_base_access.json

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "consumer_user_base_access" {
  for_each = aws_iam_role.consumer_users

  role       = each.value.name
  policy_arn = aws_iam_policy.consumer_user_base_access.arn
}

# Roles de aplicação que simulam aplicações de contas consumidoras
data "aws_iam_policy_document" "consumer_app_assume_role" {
  for_each = var.consumer_applications

  statement {
    sid     = "AllowApplicationAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId" 
      values   = [each.value.external_id]
    }
  }
}

resource "aws_iam_role" "consumer_applications" {
  for_each = var.consumer_applications

  name               = "${local.name_prefix}-app-${each.key}"
  description        = "Simula aplicação ${each.value.description}"
  assume_role_policy = data.aws_iam_policy_document.consumer_app_assume_role[each.key].json
  max_session_duration = 7200

  tags = merge(local.default_tags, {
    Name            = "${local.name_prefix}-app-${each.key}"
    ApplicationType = each.key
    AccessPattern   = each.value.access_pattern
  })
}

# Policy para aplicações
data "aws_iam_policy_document" "consumer_app_access" {
  for_each = var.consumer_applications

  statement {
    sid = "ApplicationBaseAccess"
    
    actions = [
      "sts:GetCallerIdentity"
    ]
    
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.value.additional_services
    
    content {
      sid = "Additional${statement.value}Access"
      
      actions = [
        "${lower(statement.value)}:*"
      ]
      
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "consumer_app_access" {
  for_each = var.consumer_applications

  name        = "${local.name_prefix}-app-${each.key}-access"
  description = "Política específica para aplicação ${each.key}"
  policy      = data.aws_iam_policy_document.consumer_app_access[each.key].json

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "consumer_app_access" {
  for_each = aws_iam_role.consumer_applications

  role       = each.value.name
  policy_arn = aws_iam_policy.consumer_app_access[each.key].arn
}