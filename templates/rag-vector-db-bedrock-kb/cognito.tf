# Auth foundation for this template. Kept self-contained on purpose (see
# README "complete independence" note) — it does not reference any Cognito
# pool defined elsewhere in this repository (e.g. shared-infra/cognito
# belongs to a different, unrelated set of templates and must not be
# imported here).
#
# tenant_id lives on the `custom:tenant_id` custom attribute (set by
# whatever provisions each user — out of scope for this template) and roles
# come from the built-in `cognito:groups` claim; lambda_common/auth_context.py
# is the only place that reads these claim names (see ADR-0008).

resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-users"

  schema {
    name                = "tenant_id"
    attribute_data_type = "String"
    mutable             = false
    required            = false

    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "api" {
  name         = "${var.name_prefix}-api-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# Membership in this group is what lambda_common/auth_context.py treats as
# "admin" (required to call purge_tenant). Add users to it out-of-band
# (console/CLI/your own provisioning tooling) — this template does not
# manage user or group membership itself.
resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Members may call purge_tenant for any tenant."
}
