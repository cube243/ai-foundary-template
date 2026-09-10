output "ecr_repository_url" {
  value = aws_ecr_repository.rename.repository_url
}

output "agent_runtime_id" {
  value = awscc_bedrockagentcore_runtime.rename.agent_runtime_id
}

output "agent_runtime_arn" {
  value = awscc_bedrockagentcore_runtime.rename.agent_runtime_arn
}

output "agent_runtime_endpoint_arn" {
  value = awscc_bedrockagentcore_runtime_endpoint.rename.agent_runtime_endpoint_arn
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.rename.id
}

output "cognito_client_secret" {
  value     = aws_cognito_user_pool_client.rename.client_secret
  sensitive = true
}

output "token_endpoint" {
  description = "Where callers run the client_credentials grant to get a bearer token for this agent."
  value       = data.terraform_remote_state.cognito.outputs.token_endpoint
}

output "oauth_scope" {
  value = local.cognito_scope
}
