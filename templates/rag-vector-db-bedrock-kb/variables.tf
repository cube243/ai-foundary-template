variable "region" {
  description = "AWS region to deploy this stack into."
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Naming prefix for every resource this template creates. Change this if you copy the template out more than once into the same account/region."
  type        = string
  default     = "rag-kb"
}

# ---------------------------------------------------------------------------
# Vector store backend
# ---------------------------------------------------------------------------

variable "vector_store_backend" {
  description = <<-EOT
    Which vector store backs the Knowledge Base. Only "S3_VECTORS" is wired
    up today: it needs no cluster (2 resources total: a vector bucket + an
    index) and has no idle/minimum cost, which is why it is this template's
    default. Other Bedrock-supported stores (OPENSEARCH_SERVERLESS,
    OPENSEARCH_MANAGED_CLUSTER, RDS/Aurora pgvector, PINECONE, ...) each need
    their own cluster/collection plus network & access policies, which is
    real additional implementation this template does not include. If you
    need one of those (e.g. a large customer contractually requires a silo'd
    OpenSearch collection, or you need faster query latency than S3 Vectors
    gives you), add it as a sibling storage_configuration block in main.tf —
    do not repurpose this variable to silently mean something else.
  EOT
  type    = string
  default = "S3_VECTORS"

  validation {
    condition     = var.vector_store_backend == "S3_VECTORS"
    error_message = "Only \"S3_VECTORS\" is implemented by this template today; see the variable description for how to add another backend."
  }
}

variable "embedding_model_arn" {
  description = "Foundation model ARN used to embed ingested documents and queries."
  type        = string
  default     = "arn:aws:bedrock:ap-northeast-1::foundation-model/amazon.titan-embed-text-v2:0"
}

variable "embedding_dimension" {
  description = "Output vector dimension of embedding_model_arn. Must match the model's configuration (Titan Embed v2 supports 256, 512, or 1024)."
  type        = number
  default     = 1024
}

# ---------------------------------------------------------------------------
# Tenancy
# ---------------------------------------------------------------------------
# Default is pool-based isolation: one shared Knowledge Base, every document
# tagged with a tenant_id metadata attribute, every query/mutation forced to
# that tenant via lambda_common (never a caller-supplied value). This keeps
# infrastructure (and its cost) O(1) in the number of tenants.
#
# Consider switching to one Knowledge Base per tenant ("silo") instead only
# when a contract requires physical data separation, or when one tenant's
# query/ingestion volume is large enough to need performance isolation from
# the others (a single S3 Vectors index / OpenSearch collection is shared by
# everyone in the pool model). That is a bigger change (per-tenant KB
# provisioning, routing) this template does not implement.

variable "log_retention_days" {
  description = "CloudWatch Logs retention for every Lambda function's log group."
  type        = number
  default     = 30
}

variable "api_stage_name" {
  description = "API Gateway deployment stage name."
  type        = string
  default     = "v1"
}

variable "lambda_runtime" {
  description = "Python runtime shared by every Lambda function and the lambda_common layer."
  type        = string
  default     = "python3.13"
}

variable "backup_retention_days" {
  description = "Retention (days) for the S3 Vectors bucket's versioned object history. Backups cannot be disabled; only this number is configurable."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "backup_retention_days must be at least 1."
  }
}

# ---------------------------------------------------------------------------
# Ingest/delete concurrency (mandatory — see README on why this exists)
# ---------------------------------------------------------------------------
# IngestKnowledgeBaseDocuments and DeleteKnowledgeBaseDocuments share one
# account-wide cap of 10 concurrent calls. add_document/update_document
# (Ingest) and delete_document (Delete) each get their own SQS queue +
# reserved-concurrency-limited consumer Lambda so no single operation (or
# tenant) can exhaust that shared budget; purge_tenant gets its own tiny
# budget too since it also calls Delete. Keep the sum at or below your
# account's actual quota (check Service Quotas — 10 is the documented
# default, but you may have requested an increase).

variable "add_reserved_concurrency" {
  type    = number
  default = 3
}

variable "update_reserved_concurrency" {
  type    = number
  default = 3
}

variable "delete_reserved_concurrency" {
  type    = number
  default = 2
}

variable "purge_reserved_concurrency" {
  description = "Kept at 1 (serial) since purge_tenant batches many documents per DeleteKnowledgeBaseDocuments call already; it does not need parallelism."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Rate limiting (NOT implemented in this pass — see README)
# ---------------------------------------------------------------------------
# A per-tenant rate limit is intentionally not implemented yet even though it
# is desirable (Bedrock's IngestKnowledgeBaseDocuments/DeleteKnowledgeBase
# Documents share a 10-concurrent-execution cap for the whole account, and
# retrieval APIs have their own account/region TPS quota — one noisy tenant
# can still degrade every other tenant today). If/when this is built, prefer
# a DynamoDB-backed per-tenant counter checked from lambda_common at the top
# of every handler over API Gateway Usage Plans: Usage Plans throttle by API
# Key, and this template authenticates with Cognito JWTs, not API keys.
