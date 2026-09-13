data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  kb_name         = "${var.name_prefix}-kb"
  vector_bucket   = "${var.name_prefix}-vectors-${local.account_id}"
  vector_index    = "${var.name_prefix}-index"
  document_bucket = "${var.name_prefix}-documents-${local.account_id}"
}

# ---------------------------------------------------------------------------
# Backup/DR (required — see variables.tf's backup_retention_days)
#
# S3 Vectors indexes have S3-grade (11 9s) storage durability but, as of
# this writing, no point-in-time-recovery/versioning of their own — they
# protect against infrastructure failure, not against an accidental
# DeleteKnowledgeBaseDocuments call or a purge_tenant bug. So the thing this
# template actually backs up is the raw ingested content: every add/update
# writes the document body here (versioned) before calling
# IngestKnowledgeBaseDocuments with an S3_LOCATION pointer at what it just
# wrote (see lambda_add/lambda_update). The Knowledge Base + S3 Vectors index
# are treated as regenerable state that can always be rebuilt from this
# bucket; this bucket is the thing with retention.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "documents" {
  bucket = local.document_bucket
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket                  = aws_s3_bucket.documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.documents]
}

# ---------------------------------------------------------------------------
# Vector store: S3 Vectors (see variables.tf for why this is the default)
# ---------------------------------------------------------------------------

resource "aws_s3vectors_vector_bucket" "kb" {
  vector_bucket_name = local.vector_bucket
}

resource "aws_s3vectors_index" "kb" {
  vector_bucket_name = aws_s3vectors_vector_bucket.kb.vector_bucket_name
  index_name         = local.vector_index

  data_type       = "float32"
  dimension       = var.embedding_dimension
  distance_metric = "cosine"

  # tenant_id / access_tags / document_id / source_uri / updated_at (see the
  # metadata schema in README) are all filterable metadata: none are listed
  # here as non-filterable, on purpose.
}

# ---------------------------------------------------------------------------
# Knowledge Base service role
# (trust policy + permissions verbatim from AWS's documented contract:
# https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kb_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${local.account_id}:knowledge-base/*"]
    }
  }
}

data "aws_iam_policy_document" "kb_permissions" {
  statement {
    sid       = "InvokeEmbeddingModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = [var.embedding_model_arn]
  }

  statement {
    sid    = "S3VectorsReadWrite"
    effect = "Allow"
    actions = [
      "s3vectors:PutVectors",
      "s3vectors:GetVectors",
      "s3vectors:DeleteVectors",
      "s3vectors:QueryVectors",
      "s3vectors:GetIndex",
    ]
    resources = [aws_s3vectors_index.kb.index_arn]
  }

  statement {
    sid       = "ReadIngestedDocumentContent"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }

  # Bedrock publishes the Retrieve operation's runtime metrics (including
  # Throttles — see monitoring.tf) to CloudWatch using THIS role's
  # credentials, not the caller's. Without this, Retrieve metrics are
  # silently never published (best-effort, per AWS's docs) and the
  # throttling alarm can never fire.
  statement {
    sid       = "PublishKnowledgeBaseMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["AWS/Bedrock/KnowledgeBases"]
    }
  }
}

resource "aws_iam_role" "kb_service" {
  name               = "${var.name_prefix}-kb-service-role"
  assume_role_policy = data.aws_iam_policy_document.kb_trust.json
}

resource "aws_iam_role_policy" "kb_service" {
  name   = "${var.name_prefix}-kb-service-policy"
  role   = aws_iam_role.kb_service.id
  policy = data.aws_iam_policy_document.kb_permissions.json
}

# ---------------------------------------------------------------------------
# Knowledge Base + CUSTOM data source (Direct Ingestion API)
# ---------------------------------------------------------------------------

resource "aws_bedrockagent_knowledge_base" "this" {
  name     = local.kb_name
  role_arn = aws_iam_role.kb_service.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = var.embedding_model_arn
      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions          = var.embedding_dimension
          embedding_data_type = "FLOAT32"
        }
      }
    }
  }

  storage_configuration {
    type = "S3_VECTORS"
    s3_vectors_configuration {
      index_arn = aws_s3vectors_index.kb.index_arn
    }
  }

  depends_on = [aws_iam_role_policy.kb_service]
}

# type = "CUSTOM" takes no nested configuration block: every document is
# pushed in directly via IngestKnowledgeBaseDocuments/DeleteKnowledgeBase
# Documents from this template's Lambdas, there is nothing for Bedrock to
# crawl.
resource "aws_bedrockagent_data_source" "custom" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${var.name_prefix}-custom-source"

  data_source_configuration {
    type = "CUSTOM"
  }
}
