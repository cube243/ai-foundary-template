locals {
  # AWS::BedrockAgentCore::Runtime requires the name to match
  # ^[a-zA-Z][a-zA-Z0-9_]{0,47}$ (letters/digits/underscore only, no
  # hyphens), unlike most other resources in this factory.
  agent_runtime_name = replace("${var.name_prefix}_${var.agent_name}", "-", "_")
}

resource "awscc_bedrockagentcore_runtime" "rename" {
  agent_runtime_name     = local.agent_runtime_name
  description            = "Suggests a tidied-up file name given a file's current name and its content."
  role_arn               = aws_iam_role.execution.arn
  protocol_configuration = "HTTP"

  agent_runtime_artifact = {
    container_configuration = {
      container_uri = "${aws_ecr_repository.rename.repository_url}:${var.image_tag}"
    }
  }

  network_configuration = {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    LOG_LEVEL = var.log_level
    MODEL_ID  = var.model_id
  }

  # Inbound auth: only bearer JWTs issued by the shared Cognito pool, to
  # this agent's own app client, for this agent's own scope, are accepted.
  authorizer_configuration = {
    custom_jwt_authorizer = {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.rename.id]
      allowed_scopes  = [local.cognito_scope]
    }
  }

  tags = {
    Agent   = var.agent_name
    Managed = "terraform"
  }
}

resource "awscc_bedrockagentcore_runtime_endpoint" "rename" {
  name             = "${local.agent_runtime_name}_default"
  description      = "Default endpoint for the ${var.agent_name} agent."
  agent_runtime_id = awscc_bedrockagentcore_runtime.rename.agent_runtime_id

  tags = {
    Agent   = var.agent_name
    Managed = "terraform"
  }
}
