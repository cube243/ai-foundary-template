"""query_document: RAG retrieval, attached to an AgentCore Gateway as a tool.

Not fronted by API Gateway (see README) -- invoked directly by AgentCore
Gateway with the tool's raw arguments as `event`. Input/output contract is
fixed; do not add fields to either side without updating whatever attaches
this Lambda as a Gateway tool (its declared input schema must match).
"""

from __future__ import annotations

import os
from typing import Any

import boto3

from lambda_common.document_key import from_bedrock_document_id
from lambda_common.structured_logging import log_operation

_bedrock_agent_runtime = boto3.client("bedrock-agent-runtime")

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DEFAULT_TOP_K = 5


def _get_tenant_id(context: Any) -> str:
    """TODO (README "AgentCore Gateway integration" section): AgentCore
    Gateway does not, by default, propagate validated JWT claims down to a
    Lambda target's invocation -- doing so requires a separate Gateway
    request interceptor configured on the Gateway that attaches this tool,
    which is outside this template (it belongs to whatever wires this
    template's query_document into a Gateway, e.g. tool-agent).

    Until that interceptor is in place and populating
    context.client_context.custom['tenant_id'] with a value it has itself
    validated, this raises rather than guessing: silently querying with no
    tenant filter (or the wrong tenant) would be a cross-tenant data leak,
    which is worse than failing loudly.
    """
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    tenant_id = custom.get("tenant_id")
    if not tenant_id:
        raise RuntimeError(
            "No tenant_id available from the AgentCore Gateway invocation "
            "context. See this template's README ('AgentCore Gateway "
            "integration'): a Gateway request interceptor must inject a "
            "validated tenant_id before this tool can be attached safely."
        )
    return tenant_id


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    tenant_id = _get_tenant_id(context)
    query = event["query"]
    top_k = event.get("top_k", DEFAULT_TOP_K)

    with log_operation(operation="query", tenant_id=tenant_id, user_id="") as op:
        response = _bedrock_agent_runtime.retrieve(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {
                    "numberOfResults": top_k,
                    "filter": {"equals": {"key": "tenant_id", "value": tenant_id}},
                }
            },
        )

        results = []
        for item in response.get("retrievalResults", []):
            _, document_id = from_bedrock_document_id(item.get("documentId", ""))
            metadata = item.get("metadata", {})
            results.append(
                {
                    "text": item.get("content", {}).get("text", ""),
                    "score": item.get("score", 0.0),
                    "source_uri": metadata.get("source_uri", ""),
                    "document_id": document_id,
                }
            )
        op.result_count = len(results)

    return {"results": results}
