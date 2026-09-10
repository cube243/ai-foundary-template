data "aws_caller_identity" "current" {}

# Reads outputs from shared-infra/cognito (user pool, discovery URL,
# resource server) so this agent can create its own app client against the
# shared identity foundation without shared-infra needing to know this
# agent exists ahead of time.
data "terraform_remote_state" "cognito" {
  backend = "s3"

  config = {
    bucket = var.tf_state_bucket
    key    = "shared-infra/cognito.tfstate"
    region = var.tf_state_region
  }
}
