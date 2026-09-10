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

variable "agent_scopes" {
  description = <<-EOT
    Central registry of OAuth2 scopes, one per agent, exposed on the shared
    "agentcore" resource server. Each agent's own infra (agents/<name>/infra)
    creates its own Cognito app client and requests exactly one of these
    scopes — add an entry here whenever a new agent is onboarded.
  EOT
  type = list(object({
    name        = string
    description = string
  }))
  default = [
    {
      name        = "rename.invoke"
      description = "Invoke the rename agent"
    },
  ]
}
