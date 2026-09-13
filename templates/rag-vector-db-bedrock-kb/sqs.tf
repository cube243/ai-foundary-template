# Async pipeline for add/update/delete (mandatory — see 3.6 and the
# concurrency variables in variables.tf): API Gateway -> dispatch Lambda ->
# SQS -> worker Lambda (reserved-concurrency-limited) -> Bedrock. purge_tenant
# follows the same shape on its own queue.

locals {
  queues = {
    add    = { visibility_timeout = 60 }
    update = { visibility_timeout = 60 }
    delete = { visibility_timeout = 60 }
    purge  = { visibility_timeout = 900 } # must be >= the purge worker Lambda's own timeout (lambda.tf)
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum — give humans time to notice and replay
}

resource "aws_sqs_queue" "this" {
  for_each = local.queues

  name                       = "${var.name_prefix}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}
