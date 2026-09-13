"""Normalizes Cognito JWT claims into this template's internal auth shape.

This is the ONLY file in this template that should know Cognito's specific
claim names (`custom:tenant_id`, `cognito:groups`). Every Lambda handler
calls get_auth_context(event) and works with its normalized output instead
-- if Cognito is ever replaced with a different IdP, this is the one file
that needs to change.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class MissingTenantIdError(Exception):
    """Raised when a validated JWT has no tenant_id claim."""


@dataclass(frozen=True)
class AuthContext:
    tenant_id: str
    user_id: str
    roles: frozenset[str]

    def is_admin(self) -> bool:
        return "admin" in self.roles


def get_auth_context(event: dict[str, Any]) -> AuthContext:
    """Extract the caller's identity from an API Gateway (REST API, Cognito
    User Pools authorizer) event.

    By the time this runs, API Gateway has already verified the JWT's
    signature/expiry/issuer -- these claims are trusted.
    """
    claims = event["requestContext"]["authorizer"]["claims"]

    tenant_id = claims.get("custom:tenant_id")
    if not tenant_id:
        raise MissingTenantIdError(
            "JWT is missing the custom:tenant_id claim; this user was not "
            "provisioned correctly."
        )

    groups_claim = claims.get("cognito:groups", "")
    # API Gateway's Cognito authorizer flattens multi-value claims into a
    # comma-separated string.
    roles = frozenset(g for g in groups_claim.split(",") if g)

    return AuthContext(
        tenant_id=tenant_id,
        user_id=claims["sub"],
        roles=roles,
    )
