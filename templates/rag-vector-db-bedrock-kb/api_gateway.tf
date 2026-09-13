# REST API for add/update/delete/get_status/purge_tenant. query_document is
# deliberately NOT here (see README — it is attached to an AgentCore Gateway
# as a tool instead, via the query_document_lambda_arn output).
#
# Auth is API Gateway's built-in COGNITO_USER_POOLS authorizer (no Lambda
# Authorizer — see ADR-0008): it only proves "this is a valid, unexpired
# token for a user in this pool." purge_tenant's extra "is this user an
# admin" check happens inside its own dispatch Lambda (lambda_purge_tenant/
# dispatch.py), since scope-based authorization would additionally require
# an OAuth resource-server/scopes setup this template does not otherwise need.

locals {
  api_operations = {
    add = {
      path_part     = "add"
      invoke_arn    = aws_lambda_function.ingest_dispatch["add"].invoke_arn
      function_name = aws_lambda_function.ingest_dispatch["add"].function_name
    }
    update = {
      path_part     = "update"
      invoke_arn    = aws_lambda_function.ingest_dispatch["update"].invoke_arn
      function_name = aws_lambda_function.ingest_dispatch["update"].function_name
    }
    delete = {
      path_part     = "delete"
      invoke_arn    = aws_lambda_function.delete_dispatch.invoke_arn
      function_name = aws_lambda_function.delete_dispatch.function_name
    }
    status = {
      path_part     = "status"
      invoke_arn    = aws_lambda_function.get_status.invoke_arn
      function_name = aws_lambda_function.get_status.function_name
    }
  }
}

resource "aws_api_gateway_rest_api" "this" {
  name = "${var.name_prefix}-api"
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${var.name_prefix}-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.this.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.this.arn]
  identity_source = "method.request.header.Authorization"
}

# ---------------------------------------------------------------------------
# /documents/{add,update,delete,status}
# ---------------------------------------------------------------------------

resource "aws_api_gateway_resource" "documents" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "documents"
}

resource "aws_api_gateway_resource" "operation" {
  for_each = local.api_operations

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.documents.id
  path_part   = each.value.path_part
}

resource "aws_api_gateway_method" "operation" {
  for_each = local.api_operations

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.operation[each.key].id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "operation" {
  for_each = local.api_operations

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.operation[each.key].id
  http_method             = aws_api_gateway_method.operation[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = each.value.invoke_arn
}

resource "aws_lambda_permission" "operation" {
  for_each = local.api_operations

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/documents/${each.value.path_part}"
}

# ---------------------------------------------------------------------------
# /admin/purge-tenant
# ---------------------------------------------------------------------------

resource "aws_api_gateway_resource" "admin" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "admin"
}

resource "aws_api_gateway_resource" "purge" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.admin.id
  path_part   = "purge-tenant"
}

resource "aws_api_gateway_method" "purge" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.purge.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "purge" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.purge.id
  http_method             = aws_api_gateway_method.purge.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.purge_dispatch.invoke_arn
}

resource "aws_lambda_permission" "purge" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purge_dispatch.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/admin/purge-tenant"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.operation,
      aws_api_gateway_method.operation,
      aws_api_gateway_integration.operation,
      aws_api_gateway_resource.purge,
      aws_api_gateway_method.purge,
      aws_api_gateway_integration.purge,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.api_stage_name
}
