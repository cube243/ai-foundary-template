data "aws_caller_identity" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  user_pool_domain   = "${var.name_prefix}-${local.account_id}"
  resource_server_id = "agentcore"
}

# Shared identity foundation for every agent in the factory. Agents
# authenticate to AgentCore Runtime with OAuth2 client_credentials tokens
# issued by this pool (machine-to-machine, no end user involved); each agent
# owns its own app client (see agents/<name>/infra), scoped to one scope
# below via the shared "agentcore" resource server.
resource "aws_cognito_user_pool" "agentcore" {
  name = "${var.name_prefix}-agentcore"
}

resource "aws_cognito_user_pool_domain" "agentcore" {
  domain       = local.user_pool_domain
  user_pool_id = aws_cognito_user_pool.agentcore.id
}

resource "aws_cognito_resource_server" "agentcore" {
  identifier   = local.resource_server_id
  name         = "AgentCore agents"
  user_pool_id = aws_cognito_user_pool.agentcore.id

  dynamic "scope" {
    for_each = var.agent_scopes
    content {
      scope_name        = scope.value.name
      scope_description = scope.value.description
    }
  }
}
