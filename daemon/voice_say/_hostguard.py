"""Loopback guard: refuse requests a web page could forge.

The daemon has no auth; binding to 127.0.0.1 keeps other machines out but not
the browser on this one. Two holes, two checks:

- DNS rebinding: a page on attacker.example re-points its name at 127.0.0.1
  and then reads responses as same-origin. The Host header still says
  attacker.example, so only loopback / Tailscale hosts are accepted.
- Cross-site writes: a page can POST a text/plain body (no CORS preflight) and
  the daemon parses it as JSON. Browsers always send Origin on a cross-site
  POST, so a write is refused unless its Origin is loopback, the request's own
  host (same-origin), or the configured cors_origins. A tailnet Origin on
  another name is refused: anyone can publish a *.ts.net page with Funnel.
  Non-browser clients (CLI, app) send no Origin.

Allowed hosts: localhost, loopback IP literals, Tailscale IP literals
(100.64.0.0/10, fd7a:115c:a1e0::/48) and MagicDNS names (*.ts.net). An IP
literal or a ts.net name can't be rebound by a third party.
"""
from __future__ import annotations

import ipaddress
from urllib.parse import urlsplit

_TAILNET = (ipaddress.ip_network("100.64.0.0/10"),
            ipaddress.ip_network("fd7a:115c:a1e0::/48"))
_WRITE_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})


def _hostname(host: str | None) -> str:
    return (urlsplit(f"//{host}").hostname or "") if host else ""


def _loopback(name: str) -> bool:
    if name == "localhost":
        return True
    try:
        return ipaddress.ip_address(name).is_loopback
    except ValueError:
        return False


def host_allowed(host: str | None) -> bool:
    """True for a Host hostname (port optional) on loopback or the tailnet."""
    name = _hostname(host)
    if not name:
        return False
    if _loopback(name) or name.endswith(".ts.net"):
        return True
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        return False
    return any(ip in net for net in _TAILNET)


def refusal(method: str, host: str | None, origin: str | None,
            cors_origin: str | None = None) -> str | None:
    """Why a request must be refused, or None to let it through.
    A missing Host (HTTP/1.0 tools) passes: browsers always send one."""
    if host is not None and not host_allowed(host):
        return f"host {host!r} not allowed"
    if method in _WRITE_METHODS and origin is not None and origin != cors_origin:
        name = _hostname(urlsplit(origin).netloc)
        if not name or not (_loopback(name) or name == _hostname(host)):
            return f"origin {origin!r} not allowed"
    return None
