locals {
  account_id     = data.aws_caller_identity.current.account_id
  execution_role = "${var.name_prefix}-${var.agent_name}-agentcore-execution"
}

# Trust policy per AWS's documented AgentCore Runtime execution role
# contract: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html
data "aws_iam_policy_document" "execution_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:*"]
    }
  }
}

data "aws_iam_policy_document" "execution_permissions" {
  statement {
    sid       = "EcrImageAccess"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.rename.arn]
  }

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "LogGroupCreation"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
  }

  statement {
    sid       = "LogGroupPolicy"
    effect    = "Allow"
    actions   = ["logs:PutResourcePolicy"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/${var.name_prefix}-${var.agent_name}-*"]
  }

  statement {
    sid       = "LogGroupDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:*"]
  }

  statement {
    sid       = "LogStreamWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
  }

  statement {
    sid       = "Tracing"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }

  statement {
    sid       = "Metrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  # JWT-authenticated calls only: no caller-supplied user id path, so only
  # the JWT-based workload token action is granted (least privilege — see
  # the "production deployments" note in AWS's runtime-permissions docs).
  statement {
    sid    = "WorkloadAccessToken"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
      "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${var.name_prefix}-${var.agent_name}-*",
    ]
  }

  statement {
    sid       = "BedrockModelInvocation"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["arn:aws:bedrock:*::foundation-model/*", "arn:aws:bedrock:${var.region}:${local.account_id}:*"]
  }
}

resource "aws_iam_role" "execution" {
  name               = local.execution_role
  assume_role_policy = data.aws_iam_policy_document.execution_trust.json
}

resource "aws_iam_role_policy" "execution" {
  name   = "${local.execution_role}-policy"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_permissions.json
}
