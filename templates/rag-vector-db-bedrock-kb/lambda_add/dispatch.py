"""add_document — API Gateway entrypoint. See lambda_common/ingest.py."""

import os
from typing import Any

from lambda_common.ingest import dispatch

QUEUE_URL = os.environ["QUEUE_URL"]


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    return dispatch(event, operation="add", queue_url=QUEUE_URL)
