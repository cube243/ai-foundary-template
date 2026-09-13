# Detecting Bedrock throttling (3.8). Two distinct mechanisms are needed,
# not one, because Bedrock's own CloudWatch metrics only cover Retrieve:
#
# 1. Retrieve (query_document): Bedrock publishes a native `Throttles`
#    metric under the `AWS/Bedrock/KnowledgeBases` namespace, dimensioned by
#    Operation + KnowledgeBaseId. (This template's original brief mentioned
#    an `AWS/Bedrock` "InvocationThrottles" metric; that metric belongs to
#    direct model-invocation calls, not Knowledge Bases, and does not exist
#    under this namespace — verified against AWS's Knowledge Base
#    observability docs. `Throttles` is the real one.)
#
# 2. IngestKnowledgeBaseDocuments / DeleteKnowledgeBaseDocuments (add/update/
#    delete/purge_tenant): these do NOT publish a CloudWatch throttling
#    metric at all — hitting the account-wide 10-concurrent-call cap surfaces
#    only as a synchronous exception on the boto3 call, which this
#    template's structured logging already records as `"error": true`. So
#    throttling on this path is instead detected via a CloudWatch Logs
#    metric filter over each worker's own log group.

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"
}

# ---------------------------------------------------------------------------
# 1. Retrieve throttling (native Bedrock metric)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "retrieve_throttles" {
  alarm_name          = "${var.name_prefix}-retrieve-throttles"
  alarm_description   = "Bedrock is throttling Retrieve calls against this knowledge base (query_document) — a tenant may be running past this account's TPS quota."
  namespace           = "AWS/Bedrock/KnowledgeBases"
  metric_name         = "Throttles"
  dimensions = {
    Operation       = "Retrieve"
    KnowledgeBaseId = "knowledge-base/${aws_bedrockagent_knowledge_base.this.id}"
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# ---------------------------------------------------------------------------
# 2. Ingest/Delete errors (log-derived, since Bedrock has no metric for
#    these operations)
# ---------------------------------------------------------------------------

locals {
  worker_log_groups = {
    add    = aws_cloudwatch_log_group.ingest_worker["add"].name
    update = aws_cloudwatch_log_group.ingest_worker["update"].name
    delete = aws_cloudwatch_log_group.delete_worker.name
    purge  = aws_cloudwatch_log_group.purge_worker.name
  }
}

resource "aws_cloudwatch_log_metric_filter" "worker_errors" {
  for_each = local.worker_log_groups

  name           = "${var.name_prefix}-${each.key}-errors"
  log_group_name = each.value
  pattern        = "{ $.error = true }"

  metric_transformation {
    namespace     = "${var.name_prefix}/rag-vector-db"
    name          = "${each.key}WorkerErrors"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  for_each = local.worker_log_groups

  alarm_name          = "${var.name_prefix}-${each.key}-worker-errors"
  alarm_description   = "${each.key} worker is failing (likely the account-wide 10-concurrent-call Ingest/Delete cap, or a bad payload) — see its CloudWatch Logs."
  namespace           = "${var.name_prefix}/rag-vector-db"
  metric_name         = "${each.key}WorkerErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}
