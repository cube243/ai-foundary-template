"""One-line-per-request structured JSON logging, shared by every handler.

Emits exactly the fields required by this template's monitoring contract:
tenant_id, user_id, operation, latency_ms, error, result_count (query only),
timestamp. CloudWatch Logs Insights queries against these field names; do
not rename them without updating any saved Insights queries/dashboards.
"""

from __future__ import annotations

import json
import logging
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Iterator

logger = logging.getLogger("rag-vector-db-bedrock-kb")
logger.setLevel(logging.INFO)


class OperationHandle:
    """Mutable handle yielded by log_operation so the caller can attach
    fields (currently just result_count) known only after the operation
    body runs."""

    def __init__(self) -> None:
        self.result_count: int | None = None


@contextmanager
def log_operation(*, operation: str, tenant_id: str, user_id: str) -> Iterator[OperationHandle]:
    """Wrap a handler's business logic, always emitting exactly one
    structured log line -- on success or on exception.

    Usage:
        with log_operation(operation="query", tenant_id=ctx.tenant_id, user_id=ctx.user_id) as op:
            results = do_the_work()
            op.result_count = len(results)
    """
    handle = OperationHandle()
    start = time.perf_counter()
    error = False
    try:
        yield handle
    except Exception:
        error = True
        raise
    finally:
        latency_ms = (time.perf_counter() - start) * 1000
        record = {
            "tenant_id": tenant_id,
            "user_id": user_id,
            "operation": operation,
            "latency_ms": round(latency_ms, 2),
            "error": error,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if handle.result_count is not None:
            record["result_count"] = handle.result_count
        logger.info(json.dumps(record))
