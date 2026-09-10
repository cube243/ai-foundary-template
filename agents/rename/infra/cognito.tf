locals {
  cognito_user_pool_id       = data.terraform_remote_state.cognito.outputs.user_pool_id
  cognito_discovery_url      = data.terraform_remote_state.cognito.outputs.discovery_url
  cognito_resource_server_id = data.terraform_remote_state.cognito.outputs.resource_server_identifier
  cognito_scope              = "${local.cognito_resource_server_id}/rename.invoke"
}

# Machine-to-machine client for callers invoking this agent. Callers run the
# OAuth2 client_credentials grant against shared-infra/cognito's token
# endpoint to get a JWT access token, then call the AgentCore Runtime with
# `Authorization: Bearer <token>` — validated by this stack's
# authorizer_configuration in main.tf.
resource "aws_cognito_user_pool_client" "rename" {
  name         = "${var.name_prefix}-${var.agent_name}-client"
  user_pool_id = local.cognito_user_pool_id

  generate_secret                     = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [local.cognito_scope]
  supported_identity_providers         = ["COGNITO"]
}
