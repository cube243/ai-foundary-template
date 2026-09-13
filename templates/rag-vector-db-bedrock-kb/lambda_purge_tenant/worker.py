"""purge_tenant — SQS worker: naive list-then-batch-delete loop.

Reserved concurrency is 1 (see variables.tf) so this never runs more than
one DeleteKnowledgeBaseDocuments call at a time on its own -- combined with
add/update/delete's own budgets, the account-wide 10-concurrent-call cap on
Ingest+Delete combined is respected without any extra coordination.

Tenant enumeration is free of an extra Bedrock call per document: because
add/update namespace every document's Bedrock-side ID as
"{tenant_id}::{document_id}" (see lambda_common/document_key.py),
list_knowledge_base_documents's own id field is enough to find every
document belonging to a tenant by prefix -- no per-document metadata fetch
needed.
"""

from __future__ import annotations

import json
import os
from typing import Any, Iterator

import boto3

from lambda_common.structured_logging import log_operation

_bedrock_agent = boto3.client("bedrock-agent")

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]

# DeleteKnowledgeBaseDocuments accepts at most 10 documentIdentifiers per call.
_DELETE_BATCH_SIZE = 10


def handler(event: dict[str, Any], context: Any) -> None:
    for record in event["Records"]:
        _purge(json.loads(record["body"]))


def _purge(message: dict[str, Any]) -> None:
    tenant_id = message["tenant_id"]
    prefix = f"{tenant_id}::"

    with log_operation(operation="purge_tenant", tenant_id=tenant_id, user_id="") as op:
        document_ids = list(_tenant_document_ids(prefix))

        for batch in _chunks(document_ids, _DELETE_BATCH_SIZE):
            _bedrock_agent.delete_knowledge_base_documents(
                knowledgeBaseId=KNOWLEDGE_BASE_ID,
                dataSourceId=DATA_SOURCE_ID,
                documentIdentifiers=[
                    {"dataSourceType": "CUSTOM", "custom": {"id": doc_id}} for doc_id in batch
                ],
            )

        op.result_count = len(document_ids)


def _tenant_document_ids(prefix: str) -> Iterator[str]:
    next_token = None
    while True:
        kwargs: dict[str, Any] = {
            "knowledgeBaseId": KNOWLEDGE_BASE_ID,
            "dataSourceId": DATA_SOURCE_ID,
            "maxResults": 100,
        }
        if next_token:
            kwargs["nextToken"] = next_token

        response = _bedrock_agent.list_knowledge_base_documents(**kwargs)
        for detail in response.get("documentDetails", []):
            doc_id = detail.get("identifier", {}).get("custom", {}).get("id", "")
            if doc_id.startswith(prefix):
                yield doc_id

        next_token = response.get("nextToken")
        if not next_token:
            break


def _chunks(items: list[str], size: int) -> Iterator[list[str]]:
    for i in range(0, len(items), size):
        yield items[i : i + size]
