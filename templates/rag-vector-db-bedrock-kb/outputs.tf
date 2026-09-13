output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  value = aws_bedrockagent_knowledge_base.this.arn
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.custom.data_source_id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.api.id
}

output "alarms_sns_topic_arn" {
  description = "Subscribe an email/Slack/PagerDuty integration to this to receive throttling alarms (see monitoring.tf)."
  value       = aws_sns_topic.alarms.arn
}

output "document_bucket_name" {
  description = "Where raw ingested document content is stored/versioned (see main.tf's backup/DR note)."
  value       = aws_s3_bucket.documents.id
}

output "api_base_url" {
  description = "Base URL for POST /documents/{add,update,delete,status} and POST /admin/purge-tenant. Every call needs an Authorization: Bearer <Cognito JWT> header."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "query_document_lambda_arn" {
  description = "Attach this to an AgentCore Gateway as a tool target. See README for the required input schema and the Gateway-side identity-propagation prerequisite (tenant_id)."
  value       = aws_lambda_function.query.arn
}
