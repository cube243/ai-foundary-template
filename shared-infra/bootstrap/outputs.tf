output "state_bucket_name" {
  description = "S3 bucket every other stack should use as its Terraform backend."
  value       = aws_s3_bucket.tfstate.id
}

output "state_lock_table_name" {
  description = "DynamoDB table every other stack should use for state locking."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "github_actions_role_arn" {
  description = "Role ARN GitHub Actions assumes (via OIDC) to deploy this factory. Register this as the AWS_DEPLOY_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions_deploy.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
