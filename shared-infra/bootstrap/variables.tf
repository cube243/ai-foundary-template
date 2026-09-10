variable "region" {
  description = "AWS region this whole factory (agents + shared infra) lives in."
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Naming prefix shared by every resource this repository creates."
  type        = string
  default     = "agent-factory"
}

variable "github_repository" {
  description = <<-EOT
    GitHub repository allowed to assume the deploy role, in "org/repo" form
    (e.g. "my-org/ai-foundary-template"). Kept out of committed code on
    purpose: fill this in via terraform.tfvars (git-ignored), never edit the
    default here.
  EOT
  type        = string
}

variable "github_oidc_allowed_refs" {
  description = <<-EOT
    Suffixes appended to "repo:$${var.github_repository}:" and matched
    against the OIDC token's `sub` claim, i.e. what is allowed to assume the
    deploy role. Default allows pushes to main (apply) and any pull request
    (plan). Add "ref:refs/heads/<branch>" or "environment:<name>" entries as
    the branching / environments model evolves.
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main", "pull_request"]
}
