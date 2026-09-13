# Lambda functions + the shared lambda_common layer. Grows by one
# archive/function block per handler as each is implemented (see this
# template's README for the build order).

data "archive_file" "lambda_common_layer" {
  type        = "zip"
  output_path = "${path.module}/.build/lambda_common_layer.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/lambda_common", "**/*.py")
    content {
      content  = file("${path.module}/lambda_common/${source.value}")
      filename = "python/lambda_common/${source.value}"
    }
  }
}

resource "aws_lambda_layer_version" "common" {
  layer_name          = "${var.name_prefix}-lambda-common"
  filename            = data.archive_file.lambda_common_layer.output_path
  source_code_hash    = data.archive_file.lambda_common_layer.output_base64sha256
  compatible_runtimes = [var.lambda_runtime]
}

# ---------------------------------------------------------------------------
# query_document
# ---------------------------------------------------------------------------

data "archive_file" "query" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_query"
  output_path = "${path.module}/.build/lambda_query.zip"
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${var.name_prefix}-query-document"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "query" {
  function_name    = "${var.name_prefix}-query-document"
  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256
  handler          = "handler.handler"
  runtime          = var.lambda_runtime
  role             = aws_iam_role.query.arn
  layers           = [aws_lambda_layer_version.common.arn]
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.query]
}

# ---------------------------------------------------------------------------
# add_document / update_document (dispatch + worker share one archive per
# operation — lambda_add/{dispatch,worker}.py, lambda_update/{dispatch,worker}.py)
# ---------------------------------------------------------------------------

data "archive_file" "ingest" {
  for_each = toset(["add", "update"])

  type        = "zip"
  source_dir  = "${path.module}/lambda_${each.key}"
  output_path = "${path.module}/.build/lambda_${each.key}.zip"
}

resource "aws_cloudwatch_log_group" "ingest_dispatch" {
  for_each = toset(["add", "update"])

  name              = "/aws/lambda/${var.name_prefix}-${each.key}-document-dispatch"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "ingest_worker" {
  for_each = toset(["add", "update"])

  name              = "/aws/lambda/${var.name_prefix}-${each.key}-document-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "ingest_dispatch" {
  for_each = toset(["add", "update"])

  function_name    = "${var.name_prefix}-${each.key}-document-dispatch"
  filename         = data.archive_file.ingest[each.key].output_path
  source_code_hash = data.archive_file.ingest[each.key].output_base64sha256
  handler          = "dispatch.handler"
  runtime          = var.lambda_runtime
  role             = aws_iam_role.ingest_dispatch[each.key].arn
  layers           = [aws_lambda_layer_version.common.arn]
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.this[each.key].url
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest_dispatch]
}

resource "aws_lambda_function" "ingest_worker" {
  for_each = toset(["add", "update"])

  function_name                   = "${var.name_prefix}-${each.key}-document-worker"
  filename                        = data.archive_file.ingest[each.key].output_path
  source_code_hash                = data.archive_file.ingest[each.key].output_base64sha256
  handler                         = "worker.handler"
  runtime                         = var.lambda_runtime
  role                            = aws_iam_role.ingest_worker[each.key].arn
  layers                          = [aws_lambda_layer_version.common.arn]
  timeout                         = 60
  memory_size                     = 256
  reserved_concurrent_executions  = each.key == "add" ? var.add_reserved_concurrency : var.update_reserved_concurrency

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.custom.data_source_id
      DOCUMENT_BUCKET   = aws_s3_bucket.documents.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest_worker]
}

resource "aws_lambda_event_source_mapping" "ingest_worker" {
  for_each = toset(["add", "update"])

  event_source_arn = aws_sqs_queue.this[each.key].arn
  function_name    = aws_lambda_function.ingest_worker[each.key].arn
  batch_size       = 1 # 1 in-flight Bedrock call per concurrent worker invocation
}

# ---------------------------------------------------------------------------
# delete_document (dispatch + worker share lambda_delete/{dispatch,worker}.py)
# ---------------------------------------------------------------------------

data "archive_file" "delete" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_delete"
  output_path = "${path.module}/.build/lambda_delete.zip"
}

resource "aws_cloudwatch_log_group" "delete_dispatch" {
  name              = "/aws/lambda/${var.name_prefix}-delete-document-dispatch"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "delete_worker" {
  name              = "/aws/lambda/${var.name_prefix}-delete-document-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "delete_dispatch" {
  function_name    = "${var.name_prefix}-delete-document-dispatch"
  filename         = data.archive_file.delete.output_path
  source_code_hash = data.archive_file.delete.output_base64sha256
  handler          = "dispatch.handler"
  runtime          = var.lambda_runtime
  role             = aws_iam_role.delete_dispatch.arn
  layers           = [aws_lambda_layer_version.common.arn]
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.this["delete"].url
    }
  }

  depends_on = [aws_cloudwatch_log_group.delete_dispatch]
}

resource "aws_lambda_function" "delete_worker" {
  function_name                  = "${var.name_prefix}-delete-document-worker"
  filename                       = data.archive_file.delete.output_path
  source_code_hash               = data.archive_file.delete.output_base64sha256
  handler                        = "worker.handler"
  runtime                        = var.lambda_runtime
  role                           = aws_iam_role.delete_worker.arn
  layers                         = [aws_lambda_layer_version.common.arn]
  timeout                        = 60
  memory_size                    = 256
  reserved_concurrent_executions = var.delete_reserved_concurrency

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.custom.data_source_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.delete_worker]
}

resource "aws_lambda_event_source_mapping" "delete_worker" {
  event_source_arn = aws_sqs_queue.this["delete"].arn
  function_name    = aws_lambda_function.delete_worker.arn
  batch_size       = 1
}

# ---------------------------------------------------------------------------
# get_document_status (synchronous)
# ---------------------------------------------------------------------------

data "archive_file" "get_status" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_get_status"
  output_path = "${path.module}/.build/lambda_get_status.zip"
}

resource "aws_cloudwatch_log_group" "get_status" {
  name              = "/aws/lambda/${var.name_prefix}-get-document-status"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "get_status" {
  function_name    = "${var.name_prefix}-get-document-status"
  filename         = data.archive_file.get_status.output_path
  source_code_hash = data.archive_file.get_status.output_base64sha256
  handler          = "handler.handler"
  runtime          = var.lambda_runtime
  role             = aws_iam_role.get_status.arn
  layers           = [aws_lambda_layer_version.common.arn]
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.custom.data_source_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.get_status]
}

# ---------------------------------------------------------------------------
# purge_tenant (dispatch + worker share lambda_purge_tenant/{dispatch,worker}.py)
# ---------------------------------------------------------------------------

data "archive_file" "purge" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_purge_tenant"
  output_path = "${path.module}/.build/lambda_purge_tenant.zip"
}

resource "aws_cloudwatch_log_group" "purge_dispatch" {
  name              = "/aws/lambda/${var.name_prefix}-purge-tenant-dispatch"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "purge_worker" {
  name              = "/aws/lambda/${var.name_prefix}-purge-tenant-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "purge_dispatch" {
  function_name    = "${var.name_prefix}-purge-tenant-dispatch"
  filename         = data.archive_file.purge.output_path
  source_code_hash = data.archive_file.purge.output_base64sha256
  handler          = "dispatch.handler"
  runtime          = var.lambda_runtime
  role             = aws_iam_role.purge_dispatch.arn
  layers           = [aws_lambda_layer_version.common.arn]
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.this["purge"].url
    }
  }

  depends_on = [aws_cloudwatch_log_group.purge_dispatch]
}

resource "aws_lambda_function" "purge_worker" {
  function_name                  = "${var.name_prefix}-purge-tenant-worker"
  filename                        = data.archive_file.purge.output_path
  source_code_hash                = data.archive_file.purge.output_base64sha256
  handler                         = "worker.handler"
  runtime                         = var.lambda_runtime
  role                            = aws_iam_role.purge_worker.arn
  layers                          = [aws_lambda_layer_version.common.arn]
  timeout                         = 900 # 15 min: pagination + batched deletes over potentially many documents
  memory_size                     = 256
  reserved_concurrent_executions  = var.purge_reserved_concurrency

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.custom.data_source_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.purge_worker]
}

resource "aws_lambda_event_source_mapping" "purge_worker" {
  event_source_arn = aws_sqs_queue.this["purge"].arn
  function_name    = aws_lambda_function.purge_worker.arn
  batch_size       = 1
}
