"""Shared implementation behind delete_document."""

from __future__ import annotations

import json
from typing import Any

import boto3

from .auth_context import get_auth_context
from .document_key import to_bedrock_document_id
from .structured_logging import log_operation

_sqs = boto3.client("sqs")
_bedrock_agent = boto3.client("bedrock-agent")


def dispatch(event: dict[str, Any], *, queue_url: str) -> dict[str, Any]:
    ctx = get_auth_context(event)
    body = json.loads(event.get("body") or "{}")
    document_id = body["document_id"]

    with log_operation(operation="delete", tenant_id=ctx.tenant_id, user_id=ctx.user_id):
        _sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps({"tenant_id": ctx.tenant_id, "document_id": document_id}),
        )

    return {
        "statusCode": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"document_id": document_id, "status": "QUEUED"}),
    }


def process_queue_event(event: dict[str, Any], *, knowledge_base_id: str, data_source_id: str) -> None:
    for record in event["Records"]:
        _delete_one(json.loads(record["body"]), knowledge_base_id=knowledge_base_id, data_source_id=data_source_id)


def _delete_one(message: dict[str, Any], *, knowledge_base_id: str, data_source_id: str) -> None:
    tenant_id = message["tenant_id"]
    document_id = message["document_id"]

    with log_operation(operation="delete", tenant_id=tenant_id, user_id=""):
        _bedrock_agent.delete_knowledge_base_documents(
            knowledgeBaseId=knowledge_base_id,
            dataSourceId=data_source_id,
            documentIdentifiers=[
                {
                    "dataSourceType": "CUSTOM",
                    "custom": {"id": to_bedrock_document_id(tenant_id, document_id)},
                }
            ],
        )
