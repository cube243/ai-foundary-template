variable "region" {
  description = "AWS region this factory lives in."
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Naming prefix shared by every resource this repository creates."
  type        = string
  default     = "agent-factory"
}

variable "agent_name" {
  description = "Short name of this agent, used to derive resource names."
  type        = string
  default     = "rename"
}

variable "image_tag" {
  description = <<-EOT
    Tag of the container image (already pushed to the ECR repo this stack
    creates) that the AgentCore Runtime should run. The deploy workflow
    pushes an image tagged with the git SHA and passes it here — plan/apply
    with the default "latest" only works once such a tag actually exists.
  EOT
  type    = string
  default = "latest"
}

variable "model_id" {
  description = "Bedrock model (or inference profile) ID the agent calls to suggest file names."
  type        = string
  default     = "apac.anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "log_level" {
  type    = string
  default = "INFO"
}

# --- Cross-stack reference to shared-infra/cognito's remote state ---------
# Externalized rather than hardcoded so this stack doesn't need to know
# shared-infra's bucket/table names at edit time; the deploy workflow passes
# these with -var from the same repository variables used for its own
# backend config.

variable "tf_state_bucket" {
  description = "S3 bucket holding this repo's Terraform state (same bucket as this stack's own backend)."
  type        = string
}

variable "tf_state_region" {
  description = "Region of the Terraform state bucket."
  type        = string
  default     = "ap-northeast-1"
}
