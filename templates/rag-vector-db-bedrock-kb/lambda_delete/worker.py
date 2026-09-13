"""delete_document — SQS worker entrypoint. See lambda_common/delete.py."""

import os
from typing import Any

from lambda_common.delete import process_queue_event

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]


def handler(event: dict[str, Any], context: Any) -> None:
    process_queue_event(
        event,
        knowledge_base_id=KNOWLEDGE_BASE_ID,
        data_source_id=DATA_SOURCE_ID,
    )
