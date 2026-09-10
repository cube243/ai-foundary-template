data "aws_caller_identity" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  state_bucket_name = "${var.name_prefix}-tfstate-${local.account_id}"
  lock_table_name   = "${var.name_prefix}-tfstate-lock"
  github_oidc_subs  = [for ref in var.github_oidc_allowed_refs : "repo:${var.github_repository}:${ref}"]
  deploy_role_name  = "${var.name_prefix}-github-actions-deploy"
}

# ---------------------------------------------------------------------------
# Terraform remote state backend (used by every other stack in this repo)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # State is the source of truth for every stack this factory manages;
  # accidental `terraform destroy` of the bucket itself would be very costly.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation + deploy role
# ---------------------------------------------------------------------------

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subs
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = local.deploy_role_name
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Deploy-time policy for the whole factory: Terraform backend access, plus
# create/update/delete rights over the AWS resources agent stacks manage
# (ECR, the agents' IAM execution roles, AgentCore runtimes, Cognito).
# Scoped by name/ARN prefix where AWS supports it; a few control-plane
# actions (Cognito, ECR auth token) are not resource-scopable and stay "*".
data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.tfstate_lock.arn]
  }

  statement {
    sid    = "EcrRepositoryManagement"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.name_prefix}-*"]
  }

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "AgentExecutionRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }

  statement {
    sid       = "PassAgentExecutionRoleToAgentCore"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["bedrock-agentcore.amazonaws.com"]
    }
  }

  statement {
    sid    = "AgentCoreRuntimeManagement"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateAgentRuntime",
      "bedrock-agentcore:UpdateAgentRuntime",
      "bedrock-agentcore:DeleteAgentRuntime",
      "bedrock-agentcore:GetAgentRuntime",
      "bedrock-agentcore:ListAgentRuntimes",
      "bedrock-agentcore:ListAgentRuntimeVersions",
      "bedrock-agentcore:TagResource",
      "bedrock-agentcore:UntagResource",
      "bedrock-agentcore:ListTagsForResource",
      "bedrock-agentcore:CreateAgentRuntimeEndpoint",
      "bedrock-agentcore:UpdateAgentRuntimeEndpoint",
      "bedrock-agentcore:DeleteAgentRuntimeEndpoint",
      "bedrock-agentcore:GetAgentRuntimeEndpoint",
      "bedrock-agentcore:ListAgentRuntimeEndpoints",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:runtime/*",
      "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:runtime-endpoint/*",
    ]
  }

  statement {
    sid       = "CognitoManagement"
    effect    = "Allow"
    actions   = ["cognito-idp:*"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadOnlySupport"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:ListOpenIDConnectProviders",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions_deploy" {
  name   = "${local.deploy_role_name}-policy"
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}
