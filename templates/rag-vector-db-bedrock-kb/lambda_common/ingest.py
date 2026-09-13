"""Shared implementation behind add_document and update_document.

Both ultimately call the same Bedrock API (IngestKnowledgeBaseDocuments,
which is an upsert keyed on customDocumentIdentifier) -- they exist as
separate Lambdas/queues/IAM roles purely so each operation's logs and
concurrency budget are independently observable and tunable (see README),
not because the business logic differs. If add and update ever need to
actually behave differently (e.g. add_document rejecting an id that already
exists), fork this rather than adding an `if operation == "add"` branch here.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import boto3

from .auth_context import get_auth_context
from .document_key import to_bedrock_document_id
from .structured_logging import log_operation

_sqs = boto3.client("sqs")
_bedrock_agent = boto3.client("bedrock-agent")
_s3 = boto3.client("s3")


def dispatch(event: dict[str, Any], *, operation: str, queue_url: str) -> dict[str, Any]:
    """API Gateway-facing handler body: validate+enqueue, respond immediately."""
    ctx = get_auth_context(event)
    body = json.loads(event.get("body") or "{}")
    document_id = body["document_id"]

    with log_operation(operation=operation, tenant_id=ctx.tenant_id, user_id=ctx.user_id):
        _sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(
                {
                    "tenant_id": ctx.tenant_id,
                    "document_id": document_id,
                    "content": body["content"],
                    "source_uri": body.get("source_uri", ""),
                }
            ),
        )

    return {
        "statusCode": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"document_id": document_id, "status": "QUEUED"}),
    }


def process_queue_event(
    event: dict[str, Any],
    *,
    operation: str,
    knowledge_base_id: str,
    data_source_id: str,
    document_bucket: str,
) -> None:
    """SQS-facing handler body (batch_size=1: one message per invocation)."""
    for record in event["Records"]:
        _ingest_one(
            json.loads(record["body"]),
            operation=operation,
            knowledge_base_id=knowledge_base_id,
            data_source_id=data_source_id,
            document_bucket=document_bucket,
        )


def _ingest_one(
    message: dict[str, Any],
    *,
    operation: str,
    knowledge_base_id: str,
    data_source_id: str,
    document_bucket: str,
) -> None:
    tenant_id = message["tenant_id"]
    document_id = message["document_id"]
    source_uri = message.get("source_uri", "")

    with log_operation(operation=operation, tenant_id=tenant_id, user_id=""):
        # Content goes to S3 first (S3_LOCATION, not inline) so the document
        # bucket's versioning is the backup/DR story for this document body
        # -- see main.tf's "Backup/DR" comment.
        s3_key = f"{tenant_id}/{document_id}.txt"
        _s3.put_object(
            Bucket=document_bucket,
            Key=s3_key,
            Body=message["content"].encode("utf-8"),
        )

        _bedrock_agent.ingest_knowledge_base_documents(
            knowledgeBaseId=knowledge_base_id,
            dataSourceId=data_source_id,
            documents=[
                {
                    "content": {
                        "dataSourceType": "CUSTOM",
                        "custom": {
                            "customDocumentIdentifier": {
                                "id": to_bedrock_document_id(tenant_id, document_id)
                            },
                            "sourceType": "S3_LOCATION",
                            "s3Location": {"uri": f"s3://{document_bucket}/{s3_key}"},
                        },
                    },
                    "metadata": {
                        "type": "IN_LINE_ATTRIBUTE",
                        "inlineAttributes": [
                            {
                                "key": "tenant_id",
                                "value": {"type": "STRING", "stringValue": tenant_id},
                            },
                            {
                                "key": "access_tags",
                                "value": {
                                    "type": "STRING_LIST",
                                    "stringListValue": ["public"],
                                },
                            },
                            {
                                "key": "document_id",
                                "value": {"type": "STRING", "stringValue": document_id},
                            },
                            {
                                "key": "source_uri",
                                "value": {"type": "STRING", "stringValue": source_uri},
                            },
                            {
                                "key": "updated_at",
                                "value": {
                                    "type": "STRING",
                                    "stringValue": datetime.now(timezone.utc).isoformat(),
                                },
                            },
                        ],
                    },
                }
            ],
        )
