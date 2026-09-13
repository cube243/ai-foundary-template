"""get_document_status — synchronous status lookup (API Gateway, Cognito-authenticated).

Not part of the async pipeline (3.6 only calls out add/update/delete): a
single GetKnowledgeBaseDocuments call is cheap and fast enough to answer
inline, and it is itself how a caller checks on a QUEUED add/update/delete.
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3

from lambda_common.auth_context import get_auth_context
from lambda_common.document_key import to_bedrock_document_id
from lambda_common.structured_logging import log_operation

_bedrock_agent = boto3.client("bedrock-agent")

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    ctx = get_auth_context(event)
    body = json.loads(event.get("body") or "{}")
    document_id = body["document_id"]

    with log_operation(operation="get_status", tenant_id=ctx.tenant_id, user_id=ctx.user_id):
        response = _bedrock_agent.get_knowledge_base_documents(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            dataSourceId=DATA_SOURCE_ID,
            documentIdentifiers=[
                {
                    "dataSourceType": "CUSTOM",
                    "custom": {"id": to_bedrock_document_id(ctx.tenant_id, document_id)},
                }
            ],
        )
        details = response.get("documentDetails", [])
        status = details[0]["status"] if details else "NOT_FOUND"

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"document_id": document_id, "status": status}),
    }
