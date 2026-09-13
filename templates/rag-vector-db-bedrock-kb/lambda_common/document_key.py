"""Tenant-namespaced document identifiers.

add_document / update_document / delete_document / get_document_status all
address a document by ID directly against Bedrock's document-level APIs,
which -- unlike Retrieve -- have no metadata filter to enforce tenant
isolation. Namespacing the ID we actually send to Bedrock by tenant makes
cross-tenant access structurally impossible (a caller cannot address another
tenant's document even if they guess or brute-force its ID), without an
extra read-before-write call to Bedrock on every mutation.

Callers only ever see their own (un-prefixed) document_id; the composite key
below is an internal implementation detail of how we talk to Bedrock.
"""

from __future__ import annotations

_SEPARATOR = "::"


def to_bedrock_document_id(tenant_id: str, document_id: str) -> str:
    if _SEPARATOR in document_id:
        raise ValueError(f"document_id must not contain {_SEPARATOR!r}")
    return f"{tenant_id}{_SEPARATOR}{document_id}"


def from_bedrock_document_id(bedrock_document_id: str) -> tuple[str, str]:
    """Inverse of to_bedrock_document_id. Returns (tenant_id, document_id)."""
    tenant_id, _, document_id = bedrock_document_id.partition(_SEPARATOR)
    return tenant_id, document_id
