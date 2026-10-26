"""Typed aiohttp app keys — keeps NotAppKeyWarning silent and gives
route modules a single import for the shared app slots."""
from __future__ import annotations

from aiohttp import web
import httpx

from .state import State


HTTPX_KEY: web.AppKey[httpx.AsyncClient] = web.AppKey("httpx", httpx.AsyncClient)
STATE_KEY: web.AppKey[State] = web.AppKey("state", State)
