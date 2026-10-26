"""Request-shape helpers shared across route modules.

Centralizes the four patterns every handler needs:
  - `json_error(stage, message, status)` — error envelope builder
  - `parse_json(request)` — JSON body parse with a typed error response
  - `stage_to_status(stage)` — RenderError stage → HTTP status mapping
  - typed-list / typed-number coercion guards

Keep this file tiny — it's helpers, not policy.
"""
from __future__ import annotations

import json
from typing import Any

from aiohttp import web


def json_error(stage: str, message: str, status: int = 500) -> web.Response:
    """Canonical `{error, message}` envelope for Response-returning handlers.
    The raise-path coercion guards (parse_json / typed_list_of_str /
    typed_number) build the same envelope inline."""
    return web.json_response({"error": stage, "message": message}, status=status)


async def parse_json(request: web.Request) -> dict[str, Any]:
    """Parse a JSON request body. Raises web.HTTPBadRequest with our
    standard error envelope on parse failure or non-object body."""
    try:
        body = await request.json()
    except Exception as exc:  # noqa: BLE001
        raise web.HTTPBadRequest(
            text=json.dumps({"error": "request", "message": f"bad JSON: {exc}"}),
            content_type="application/json",
        ) from exc
    if not isinstance(body, dict):
        raise web.HTTPBadRequest(
            text='{"error":"request","message":"body must be a JSON object"}',
            content_type="application/json",
        )
    return body


def typed_of(value: Any, field: str, kind: type, what: str) -> Any:
    """Validate an optional body slot's JSON type: None passes through, any
    other mismatch is a 400 (a string `deleted: "false"` must not read as
    true, an int `text` must not reach str methods)."""
    if value is None or isinstance(value, kind):
        return value
    raise web.HTTPBadRequest(
        text=json.dumps({"error": "request", "message": f"{field} must be {what}"}),
        content_type="application/json",
    )


def stage_to_status(stage: str) -> int:
    """Map an `engine.RenderError` stage to its HTTP status.
    tts        = upstream backend failure  → 502 Bad Gateway
    request    = caller passed bad input    → 400 Bad Request
    conflict   = duplicate of an in-flight op → 409 Conflict
    archive/db = local fs / sqlite store    → 500 Internal Server Error
    """
    return {"tts": 502, "request": 400, "conflict": 409}.get(stage, 500)


def typed_list_of_str(value: Any, field: str) -> list[str] | None:
    """Validate a `field: [str]` body slot. Returns the list (possibly
    empty) on success, raises HTTPBadRequest on shape mismatch, returns
    None when the field is absent.
    """
    if value is None:
        return None
    if not isinstance(value, list):
        raise web.HTTPBadRequest(
            text=f'{{"error":"request","message":"\\u0027{field}\\u0027 must be a list of strings"}}',
            content_type="application/json",
        )
    if not all(isinstance(t, str) for t in value):
        raise web.HTTPBadRequest(
            text=f'{{"error":"request","message":"every element of \\u0027{field}\\u0027 must be a string"}}',
            content_type="application/json",
        )
    return value


def typed_number(value: Any, field: str, default: float | None = None) -> float | None:
    """Validate a `field: number` slot. Booleans are rejected (Python's
    bool is an int subclass, so `isinstance(True, int)` is True — without
    the explicit check, `{"speed": true}` would coerce to 1.0)."""
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise web.HTTPBadRequest(
            text=f'{{"error":"request","message":"{field} must be a number"}}',
            content_type="application/json",
        )
    return float(value)
