output "user_pool_id" {
  description = "Shared Cognito User Pool ID. Agent infra stacks create their app client under this pool."
  value       = aws_cognito_user_pool.agentcore.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.agentcore.arn
}

output "discovery_url" {
  description = "OIDC discovery URL to hand to an AgentCore Runtime's custom_jwt_authorizer."
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.agentcore.id}/.well-known/openid-configuration"
}

output "token_endpoint" {
  description = "OAuth2 token endpoint agents' client_credentials calls should hit."
  value       = "https://${aws_cognito_user_pool_domain.agentcore.domain}.auth.${var.region}.amazoncognito.com/oauth2/token"
}

output "resource_server_identifier" {
  value = aws_cognito_resource_server.agentcore.identifier
}

output "region" {
  value = var.region
}
