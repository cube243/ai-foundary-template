"""purge_tenant — API Gateway entrypoint (admin-only, async contract).

There is no native Bedrock "delete everything for tenant X" API, and the
work involved (list every document, delete in batches) can run long, so
this never blocks the caller -- it validates the admin role, enqueues one
job, and returns immediately.

Unlike every other operation in this template, tenant_id is a caller-
supplied parameter here on purpose: purge_tenant is an admin action that by
definition operates across tenants (an admin retiring a departing
customer's data), not a tenant-scoped operation. The blanket "tenant_id must
come from auth context, never a parameter" rule protects tenant-scoped
operations (query/add/update/delete/get_status) from cross-tenant access;
it does not apply to this admin-gated exception.
"""

from __future__ import annotations

import json
import os
import uuid
from typing import Any

import boto3

from lambda_common.auth_context import get_auth_context
from lambda_common.structured_logging import log_operation

_sqs = boto3.client("sqs")

QUEUE_URL = os.environ["QUEUE_URL"]


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    ctx = get_auth_context(event)
    if not ctx.is_admin():
        return {
            "statusCode": 403,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "purge_tenant requires the admin role"}),
        }

    body = json.loads(event.get("body") or "{}")
    target_tenant_id = body["tenant_id"]
    job_id = str(uuid.uuid4())

    with log_operation(operation="purge_tenant", tenant_id=target_tenant_id, user_id=ctx.user_id):
        _sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({"tenant_id": target_tenant_id, "job_id": job_id}),
        )

    return {
        "statusCode": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"status": "PURGE_QUEUED", "job_id": job_id}),
    }
