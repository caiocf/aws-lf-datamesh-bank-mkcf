data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Nomes dos buckets: lfmesh-dev-clientes-bronze / silver / gold
  bucket_names = {
    for layer in keys(var.layers) :
    layer => "${local.name_prefix}-${var.domain}-${layer}-${data.aws_caller_identity.current.account_id}"
  }

  # Nomes dos databases: dev_bronze_clientes / silver / gold
  database_names = {
    for layer in keys(var.layers) :
    layer => "${var.environment}_${layer}_${var.domain}"
  }

  # Flatten: { "bronze/transacoes_raw" => { layer, table_name, ...table } }
  all_tables = merge([
    for layer, layer_cfg in var.layers : {
      for table_name, table in layer_cfg.tables :
      "${layer}/${table_name}" => merge(table, { layer = layer, table_name = table_name })
    }
  ]...)

  all_full_grants = merge([
    for layer, layer_cfg in var.layers : {
      for grant_key, grant in layer_cfg.full_table_grants :
      "${layer}/${grant_key}" => merge(grant, { layer = layer })
    }
  ]...)

  all_data_filters = merge([
    for layer, layer_cfg in var.layers : {
      for filter_key, filter in layer_cfg.data_filters :
      "${layer}/${filter_key}" => merge(filter, { layer = layer })
    }
  ]...)

  default_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "lakeformation-domain"
      Domain      = var.domain
      Owner       = var.owner
    },
    var.tags
  )
}

# ─── S3: 1 bucket por camada ───────────────────────────────────────────────────

resource "aws_s3_bucket" "layer" {
  for_each = var.layers

  bucket        = local.bucket_names[each.key]
  force_destroy = true

  tags = merge(local.default_tags, {
    Name  = "${local.name_prefix}-${var.domain}-${each.key}"
    Layer = each.key
  })
}

resource "aws_s3_bucket_public_access_block" "layer" {
  for_each = var.layers

  bucket                  = aws_s3_bucket.layer[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "layer" {
  for_each = var.layers

  bucket = aws_s3_bucket.layer[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "layer" {
  for_each = var.layers

  bucket = aws_s3_bucket.layer[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "sample_data" {
  for_each = var.create_sample_data ? local.all_tables : {}

  bucket       = aws_s3_bucket.layer[each.value.layer].id
  key          = "${coalesce(each.value.s3_prefix, each.value.table_name)}/sample.csv"
  content      = try(each.value.sample_csv, "")
  content_type = "text/csv"

  tags = merge(local.default_tags, {
    Layer = each.value.layer
    Table = each.value.table_name
  })
}

# ─── IAM: producer + LF register (compartilhados pelo domínio) ─────────────────

data "aws_iam_policy_document" "producer_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "producer" {
  name               = "${local.name_prefix}-producer-${var.domain}"
  description        = "Role produtora do domínio ${var.domain}"
  assume_role_policy = data.aws_iam_policy_document.producer_assume_role.json
  tags               = merge(local.default_tags, { Layer = "producer" })
}

data "aws_iam_policy_document" "producer_access" {
  dynamic "statement" {
    for_each = var.layers
    content {
      sid     = "BucketAccess${title(statement.key)}"
      actions = ["s3:GetBucketLocation", "s3:ListBucket"]
      resources = [aws_s3_bucket.layer[statement.key].arn]
    }
  }

  dynamic "statement" {
    for_each = var.layers
    content {
      sid     = "ObjectAccess${title(statement.key)}"
      actions = ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:ListMultipartUploadParts", "s3:PutObject"]
      resources = ["${aws_s3_bucket.layer[statement.key].arn}/*"]
    }
  }

  statement {
    sid     = "GlueCatalogDomainAccess"
    actions = ["glue:CreateTable", "glue:DeleteTable", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:UpdateTable"]
    resources = ["*"]
  }

  statement {
    sid       = "LakeFormationDataAccess"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "producer_access" {
  name   = "${local.name_prefix}-producer-${var.domain}-access"
  policy = data.aws_iam_policy_document.producer_access.json
  tags   = local.default_tags
}

resource "aws_iam_role_policy_attachment" "producer_access" {
  role       = aws_iam_role.producer.name
  policy_arn = aws_iam_policy.producer_access.arn
}

data "aws_iam_policy_document" "lf_register_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:SetContext"]
    principals {
      type        = "Service"
      identifiers = ["lakeformation.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "lf_register" {
  for_each = var.layers

  name               = "${local.name_prefix}-lf-register-${var.domain}-${each.key}"
  description        = "Role Lake Formation para bucket ${var.domain}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lf_register_assume_role.json
  tags               = merge(local.default_tags, { Layer = each.key })
}

data "aws_iam_policy_document" "lf_register_access" {
  for_each = var.layers

  statement {
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.layer[each.key].arn]
  }

  statement {
    actions   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.layer[each.key].arn}/*"]
  }
}

resource "aws_iam_policy" "lf_register_access" {
  for_each = var.layers

  name   = "${local.name_prefix}-lf-register-${var.domain}-${each.key}-access"
  policy = data.aws_iam_policy_document.lf_register_access[each.key].json
  tags   = local.default_tags
}

resource "aws_iam_role_policy_attachment" "lf_register_access" {
  for_each = var.layers

  role       = aws_iam_role.lf_register[each.key].name
  policy_arn = aws_iam_policy.lf_register_access[each.key].arn
}

# ─── Glue: 1 database por camada ───────────────────────────────────────────────

resource "aws_glue_catalog_database" "layer" {
  for_each = var.layers

  name        = local.database_names[each.key]
  description = "Database ${each.key} do domínio ${var.domain}"
  tags        = merge(local.default_tags, { Layer = each.key })
}

resource "aws_glue_catalog_table" "layer" {
  for_each = local.all_tables

  name          = each.value.table_name
  database_name = aws_glue_catalog_database.layer[each.value.layer].name
  table_type    = "EXTERNAL_TABLE"
  description   = try(each.value.description, "")

  parameters = merge(
    {
      "classification"    = try(each.value.format, "csv")
      "EXTERNAL"          = "TRUE"
      "domain"            = var.domain
      "layer"             = each.value.layer
      "data_product"      = try(each.value.data_product, each.value.table_name)
      "classification_lf" = try(each.value.classification, "internal")
      "pii"               = try(each.value.pii, "no")
    },
    try(each.value.format, "csv") == "csv" ? { "skip.header.line.count" = "1" } : {},
    try(each.value.partition_projection.enabled, false) ? merge(
      { "projection.enabled" = "true" },
      try(each.value.partition_projection.parameters, {})
    ) : {}
  )

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.layer[each.value.layer].bucket}/${coalesce(each.value.s3_prefix, each.value.table_name)}/"
    input_format  = try(each.value.format, "csv") == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat" : "org.apache.hadoop.mapred.TextInputFormat"
    output_format = try(each.value.format, "csv") == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat" : "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "${each.value.table_name}_serde"
      serialization_library = (
        try(each.value.format, "csv") == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe" :
        try(each.value.format, "csv") == "json" ? "org.openx.data.jsonserde.JsonSerDe" :
        "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      )
      parameters = (
        try(each.value.format, "csv") == "parquet" ? { "serialization.format" = "1" } :
        try(each.value.format, "csv") == "json" ? { "serialization.format" = "1" } :
        {
          "separatorChar" = ","
          "quoteChar"     = "\""
          "escapeChar"    = "\\"
        }
      )
    }

    dynamic "columns" {
      for_each = each.value.columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = try(columns.value.comment, "")
      }
    }
  }

  dynamic "partition_keys" {
    for_each = try(each.value.partition_keys, [])
    content {
      name = partition_keys.value.name
      type = partition_keys.value.type
    }
  }

  depends_on = [aws_s3_object.sample_data]
}

# ─── Lake Formation: registro dos buckets ──────────────────────────────────────

resource "aws_lakeformation_resource" "layer" {
  for_each = var.layers

  arn      = aws_s3_bucket.layer[each.key].arn
  role_arn = aws_iam_role.lf_register[each.key].arn
}

resource "aws_lakeformation_permissions" "producer_data_location" {
  for_each = var.layers

  principal   = aws_iam_role.producer.arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = aws_lakeformation_resource.layer[each.key].arn
  }
}

resource "aws_lakeformation_permissions" "producer_database" {
  for_each = var.layers

  principal   = aws_iam_role.producer.arn
  permissions = ["ALTER", "CREATE_TABLE", "DESCRIBE", "DROP"]

  database {
    name = aws_glue_catalog_database.layer[each.key].name
  }
}

resource "aws_lakeformation_permissions" "producer_tables" {
  for_each = local.all_tables

  principal   = aws_iam_role.producer.arn
  permissions = ["ALTER", "DELETE", "DESCRIBE", "DROP", "INSERT", "SELECT"]

  table {
    database_name = aws_glue_catalog_database.layer[each.value.layer].name
    name          = aws_glue_catalog_table.layer[each.key].name
  }
}

# ─── Lake Formation: LF-Tags nos databases e tabelas ──────────────────────────

resource "aws_lakeformation_resource_lf_tags" "database" {
  for_each = var.layers

  database {
    name = aws_glue_catalog_database.layer[each.key].name
  }

  lf_tag {
    key   = "domain"
    value = var.domain
  }
  lf_tag {
    key   = "layer"
    value = each.key
  }
  lf_tag {
    key   = "environment"
    value = var.environment
  }
  lf_tag {
    key   = "owner"
    value = var.owner
  }

  depends_on = [aws_glue_catalog_database.layer]
}

resource "aws_lakeformation_resource_lf_tags" "table" {
  for_each = local.all_tables

  table {
    database_name = aws_glue_catalog_database.layer[each.value.layer].name
    name          = aws_glue_catalog_table.layer[each.key].name
  }

  lf_tag {
    key   = "domain"
    value = var.domain
  }
  lf_tag {
    key   = "layer"
    value = each.value.layer
  }
  lf_tag {
    key   = "environment"
    value = var.environment
  }
  lf_tag {
    key   = "owner"
    value = var.owner
  }
  lf_tag {
    key   = "classification"
    value = try(each.value.classification, "internal")
  }
  lf_tag {
    key   = "pii"
    value = try(each.value.pii, "no")
  }

  dynamic "lf_tag" {
    for_each = each.value.data_product != null ? [each.value.data_product] : []
    content {
      key   = "data_product"
      value = lf_tag.value
    }
  }

  depends_on = [aws_glue_catalog_table.layer]
}

# ─── Lake Formation: grants de DESCRIBE para consumidores ─────────────────────

resource "aws_lakeformation_permissions" "consumer_database_describe" {
  for_each = {
    for pair in setproduct(keys(var.layers), var.consumer_role_arns) :
    "${pair[0]}/${pair[1]}" => { layer = pair[0], principal = pair[1] }
  }

  principal   = each.value.principal
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.layer[each.value.layer].name
  }
}

# ─── Lake Formation: grants SELECT completos por tabela ───────────────────────

resource "aws_lakeformation_permissions" "full_table_select" {
  for_each = local.all_full_grants

  principal   = each.value.principal_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.layer[each.value.layer].name
    name          = aws_glue_catalog_table.layer["${each.value.layer}/${each.value.table_name}"].name
  }
}

# ─── Lake Formation: Data Cells Filters ───────────────────────────────────────

resource "aws_lakeformation_data_cells_filter" "this" {
  for_each = local.all_data_filters

  table_data {
    database_name    = aws_glue_catalog_database.layer[each.value.layer].name
    table_name       = aws_glue_catalog_table.layer["${each.value.layer}/${each.value.table_name}"].name
    table_catalog_id = data.aws_caller_identity.current.account_id
    name             = each.value.filter_name

    column_names = try(length(each.value.column_names), 0) > 0 ? each.value.column_names : null

    dynamic "column_wildcard" {
      for_each = try(length(each.value.column_names), 0) == 0 ? [1] : []
      content {
        excluded_column_names = try(each.value.excluded_column_names, [])
      }
    }

    row_filter {
      filter_expression = try(each.value.row_filter_expression, "") != "" ? each.value.row_filter_expression : null

      dynamic "all_rows_wildcard" {
        for_each = try(each.value.row_filter_expression, "") == "" ? [1] : []
        content {}
      }
    }
  }
}

resource "aws_lakeformation_permissions" "filtered_table_select" {
  for_each = local.all_data_filters

  principal   = each.value.principal_arn
  permissions = ["SELECT"]

  data_cells_filter {
    database_name    = aws_glue_catalog_database.layer[each.value.layer].name
    table_name       = aws_glue_catalog_table.layer["${each.value.layer}/${each.value.table_name}"].name
    table_catalog_id = data.aws_caller_identity.current.account_id
    name             = each.value.filter_name
  }

  depends_on = [aws_lakeformation_data_cells_filter.this]
}
