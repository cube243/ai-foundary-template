# One IAM role per Lambda, each scoped to only the Bedrock action it needs
# plus write access to its own CloudWatch log group (see 3.10). This file
# grows by one role/policy per function as each is implemented.

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# query_document — bedrock:Retrieve only
# ---------------------------------------------------------------------------

resource "aws_iam_role" "query" {
  name               = "${var.name_prefix}-query-document-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "query" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.query.arn}:*"]
  }

  statement {
    sid       = "Retrieve"
    effect    = "Allow"
    actions   = ["bedrock:Retrieve"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role_policy" "query" {
  name   = "${var.name_prefix}-query-document-policy"
  role   = aws_iam_role.query.id
  policy = data.aws_iam_policy_document.query.json
}

# ---------------------------------------------------------------------------
# add_document / update_document — dispatch (enqueue) + worker (ingest)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ingest_dispatch" {
  for_each = toset(["add", "update"])

  name               = "${var.name_prefix}-${each.key}-document-dispatch-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "ingest_dispatch" {
  for_each = toset(["add", "update"])

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest_dispatch[each.key].arn}:*"]
  }

  statement {
    sid       = "Enqueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this[each.key].arn]
  }
}

resource "aws_iam_role_policy" "ingest_dispatch" {
  for_each = toset(["add", "update"])

  name   = "${var.name_prefix}-${each.key}-document-dispatch-policy"
  role   = aws_iam_role.ingest_dispatch[each.key].id
  policy = data.aws_iam_policy_document.ingest_dispatch[each.key].json
}

resource "aws_iam_role" "ingest_worker" {
  for_each = toset(["add", "update"])

  name               = "${var.name_prefix}-${each.key}-document-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "ingest_worker" {
  for_each = toset(["add", "update"])

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest_worker[each.key].arn}:*"]
  }

  statement {
    sid       = "ConsumeQueue"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.this[each.key].arn]
  }

  statement {
    sid       = "WriteDocumentContent"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]
  }

  statement {
    sid       = "Ingest"
    effect    = "Allow"
    actions   = ["bedrock:IngestKnowledgeBaseDocuments"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role_policy" "ingest_worker" {
  for_each = toset(["add", "update"])

  name   = "${var.name_prefix}-${each.key}-document-worker-policy"
  role   = aws_iam_role.ingest_worker[each.key].id
  policy = data.aws_iam_policy_document.ingest_worker[each.key].json
}

# ---------------------------------------------------------------------------
# delete_document — dispatch (enqueue) + worker (delete)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "delete_dispatch" {
  name               = "${var.name_prefix}-delete-document-dispatch-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "delete_dispatch" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.delete_dispatch.arn}:*"]
  }

  statement {
    sid       = "Enqueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this["delete"].arn]
  }
}

resource "aws_iam_role_policy" "delete_dispatch" {
  name   = "${var.name_prefix}-delete-document-dispatch-policy"
  role   = aws_iam_role.delete_dispatch.id
  policy = data.aws_iam_policy_document.delete_dispatch.json
}

resource "aws_iam_role" "delete_worker" {
  name               = "${var.name_prefix}-delete-document-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "delete_worker" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.delete_worker.arn}:*"]
  }

  statement {
    sid       = "ConsumeQueue"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.this["delete"].arn]
  }

  statement {
    sid       = "Delete"
    effect    = "Allow"
    actions   = ["bedrock:DeleteKnowledgeBaseDocuments"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role_policy" "delete_worker" {
  name   = "${var.name_prefix}-delete-document-worker-policy"
  role   = aws_iam_role.delete_worker.id
  policy = data.aws_iam_policy_document.delete_worker.json
}

# ---------------------------------------------------------------------------
# get_document_status — bedrock:GetKnowledgeBaseDocuments only
# ---------------------------------------------------------------------------

resource "aws_iam_role" "get_status" {
  name               = "${var.name_prefix}-get-document-status-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "get_status" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.get_status.arn}:*"]
  }

  statement {
    sid       = "GetStatus"
    effect    = "Allow"
    actions   = ["bedrock:GetKnowledgeBaseDocuments"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role_policy" "get_status" {
  name   = "${var.name_prefix}-get-document-status-policy"
  role   = aws_iam_role.get_status.id
  policy = data.aws_iam_policy_document.get_status.json
}

# ---------------------------------------------------------------------------
# purge_tenant — dispatch (admin-gated enqueue) + worker (list + batch delete)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "purge_dispatch" {
  name               = "${var.name_prefix}-purge-tenant-dispatch-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "purge_dispatch" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.purge_dispatch.arn}:*"]
  }

  statement {
    sid       = "Enqueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this["purge"].arn]
  }
}

resource "aws_iam_role_policy" "purge_dispatch" {
  name   = "${var.name_prefix}-purge-tenant-dispatch-policy"
  role   = aws_iam_role.purge_dispatch.id
  policy = data.aws_iam_policy_document.purge_dispatch.json
}

resource "aws_iam_role" "purge_worker" {
  name               = "${var.name_prefix}-purge-tenant-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "purge_worker" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.purge_worker.arn}:*"]
  }

  statement {
    sid       = "ConsumeQueue"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.this["purge"].arn]
  }

  statement {
    sid       = "ListAndDelete"
    effect    = "Allow"
    actions   = ["bedrock:ListKnowledgeBaseDocuments", "bedrock:DeleteKnowledgeBaseDocuments"]
    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }
}

resource "aws_iam_role_policy" "purge_worker" {
  name   = "${var.name_prefix}-purge-tenant-worker-policy"
  role   = aws_iam_role.purge_worker.id
  policy = data.aws_iam_policy_document.purge_worker.json
}
