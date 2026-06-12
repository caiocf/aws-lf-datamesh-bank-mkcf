data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "lakeformation-foundation"
    },
    var.tags
  )

  lakeformation_admin_arns = length(var.lakeformation_admin_arns) > 0 ? var.lakeformation_admin_arns : [
    data.aws_caller_identity.current.arn
  ]

  trusted_principal_arns = length(var.trusted_principal_arns) > 0 ? var.trusted_principal_arns : [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]
}

resource "aws_lakeformation_data_lake_settings" "this" {
  count = var.manage_data_lake_settings ? 1 : 0

  admins = local.lakeformation_admin_arns
}

resource "aws_lakeformation_lf_tag" "this" {
  for_each = var.lf_tags

  key    = each.key
  values = each.value
}

resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name_prefix}-athena-results-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.default_tags, {
    Name      = "${local.name_prefix}-athena-results"
    Component = "athena-results"
  })
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "consumer_assume_role" {
  for_each = var.consumer_personas

  statement {
    sid     = "AllowTrustedPrincipalsToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "consumer" {
  for_each = var.consumer_personas

  name               = "${local.name_prefix}-consumer-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.consumer_assume_role[each.key].json

  tags = merge(local.default_tags, {
    Name    = "${local.name_prefix}-consumer-${each.key}"
    Persona = each.key
    Layer   = "consumer"
  })
}

data "aws_iam_policy_document" "consumer_access" {
  statement {
    sid = "AthenaQueryAccess"

    actions = [
      "athena:BatchGetQueryExecution",
      "athena:GetDatabase",
      "athena:GetDataCatalog",
      "athena:GetNamedQuery",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetTableMetadata",
      "athena:GetWorkGroup",
      "athena:ListDataCatalogs",
      "athena:ListDatabases",
      "athena:ListEngineVersions",
      "athena:ListNamedQueries",
      "athena:ListQueryExecutions",
      "athena:ListTableMetadata",
      "athena:ListWorkGroups",
      "athena:StartQueryExecution",
      "athena:StopQueryExecution"
    ]

    resources = ["*"]
  }

  statement {
    sid = "GlueCatalogReadAccess"

    actions = [
      "glue:BatchGetPartition",
      "glue:GetCatalog",
      "glue:GetCatalogs",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetTableVersion",
      "glue:GetTableVersions"
    ]

    resources = ["*"]
  }

  statement {
    sid = "LakeFormationDataAccess"

    actions = [
      "lakeformation:GetDataAccess"
    ]

    resources = ["*"]
  }

  statement {
    sid = "AthenaResultsBucketAccess"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [aws_s3_bucket.athena_results.arn]
  }

  statement {
    sid = "AthenaResultsObjectAccess"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]

    resources = ["${aws_s3_bucket.athena_results.arn}/*"]
  }
}

resource "aws_iam_policy" "consumer_access" {
  name        = "${local.name_prefix}-consumer-lakeformation-athena"
  description = "Acesso base para consumidores consultarem dados governados via Lake Formation e Athena."
  policy      = data.aws_iam_policy_document.consumer_access.json

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "consumer_access" {
  for_each = aws_iam_role.consumer

  role       = each.value.name
  policy_arn = aws_iam_policy.consumer_access.arn
}

resource "aws_athena_workgroup" "consumer" {
  for_each = var.consumer_personas

  name        = "${local.name_prefix}-${each.key}"
  description = "Workgroup Athena para persona ${each.key}"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/${each.key}/"
    }
  }

  tags = merge(local.default_tags, {
    Persona = each.key
    Layer   = "consumer"
  })
}
