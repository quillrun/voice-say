"""Loopback guard: a web page can't read the daemon via DNS rebinding (foreign
Host) or write to it cross-site (foreign Origin); local clients and same-origin
tailnet pages pass."""
from __future__ import annotations

import pytest
from aiohttp.test_utils import TestClient, TestServer

from voice_say._hostguard import host_allowed, refusal
from voice_say.http_server import STATE_KEY, build_app


@pytest.mark.parametrize("host", [
    "127.0.0.1:8890", "localhost:8890", "localhost", "[::1]:8890",
    "100.64.0.7:8890", "[fd7a:115c:a1e0::1]:8890", "box.tail0000.ts.net",
])
def test_local_and_tailnet_hosts_allowed(host):
    assert host_allowed(host)


@pytest.mark.parametrize("host", [
    "evil.example:8890", "192.168.1.5:8890", "8.8.8.8", "localhost.evil.example",
    "ts.net.evil.example", "", None,
])
def test_foreign_hosts_refused(host):
    assert not host_allowed(host)


def test_write_with_foreign_origin_refused_read_allowed():
    assert refusal("POST", "127.0.0.1:8890", "https://evil.example")
    assert refusal("POST", "127.0.0.1:8890", "null")
    assert refusal("GET", "127.0.0.1:8890", "https://evil.example") is None


@pytest.mark.parametrize("origin", [
    "https://evil.tail1234.ts.net", "http://100.64.0.9", "http://[fd7a:115c:a1e0::9]",
])
def test_write_from_another_tailnet_name_refused(origin):
    # Anyone can publish a *.ts.net page (Funnel): a tailnet Origin is not ours.
    assert refusal("POST", "127.0.0.1:8890", origin)
    assert refusal("POST", "box.tail0000.ts.net", origin)


def test_same_origin_write_through_the_tailnet_passes():
    assert refusal("POST", "box.tail0000.ts.net", "https://box.tail0000.ts.net") is None
    assert refusal("POST", "100.64.0.7:8890", "http://100.64.0.7:8890") is None


def test_clients_without_origin_and_configured_cors_pass():
    assert refusal("POST", "127.0.0.1:8890", None) is None
    assert refusal("POST", None, None) is None
    assert refusal("POST", "127.0.0.1:8890", "http://localhost:5173") is None
    assert refusal("POST", "127.0.0.1:8890", "http://app.test:5173",
                   cors_origin="http://app.test:5173") is None


@pytest.fixture
async def client(isolated_paths):
    async with TestClient(TestServer(build_app())) as cli:
        yield cli


async def test_rebound_host_gets_403(client):
    r = await client.get("/history?limit=1", headers={"Host": "evil.example:8890"})
    assert r.status == 403
    assert (await r.json())["error"] == "forbidden"


async def test_cross_site_text_plain_post_gets_403(client):
    r = await client.post("/overlays/2026-05-25T07:00:00Z", data='{"deleted": true}',
                          headers={"Origin": "https://evil.example",
                                   "Content-Type": "text/plain"})
    assert r.status == 403
    assert (await client.get("/overlays/2026-05-25T07:00:00Z")).status == 404


async def test_local_client_unaffected(client):
    assert (await client.get("/health")).status == 200
    client.server.app[STATE_KEY].record_history({"ts": "2026-05-25T07:00:00Z"})
    r = await client.post("/overlays/2026-05-25T07:00:00Z", json={"starred": True})
    assert r.status == 200
