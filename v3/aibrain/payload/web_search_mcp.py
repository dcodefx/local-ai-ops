import asyncio
import hmac
import json
import logging
import os
import re
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List

import uvicorn
from cachetools import TTLCache
from ddgs import DDGS
from mcp import types
from mcp.server import Server
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Mount, Route

try:
    import uvloop  # noqa: F401
    LOOP = "uvloop"
except ImportError:  # uvloop yoksa standart asyncio'ya dus
    LOOP = "asyncio"

# =========================================================
# LOGGING
# =========================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("mcp-web-search")

# =========================================================
# CONFIG (hepsi ortam degiskeniyle ayarlanabilir)
# =========================================================
MCP_SECRET_KEY = os.environ.get("MCP_SECRET_KEY", "")
if not MCP_SECRET_KEY:
    raise RuntimeError(
        "MCP_SECRET_KEY ortam degiskeni tanimli degil. "
        "Systemd unit'inde EnvironmentFile= ile set edilmeli "
        "(bkz: /etc/ai-brain/mcp-web-search.env)."
    )
_SECRET_BYTES = MCP_SECRET_KEY.encode()


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


# Tasima modu: sse (varsayilan) | streamable | both
MCP_TRANSPORT = os.environ.get("MCP_TRANSPORT", "sse").strip().lower()
if MCP_TRANSPORT not in ("sse", "streamable", "both"):
    raise RuntimeError("MCP_TRANSPORT 'sse', 'streamable' veya 'both' olmali.")

MAX_SSE_CONNECTIONS = _env_int("MCP_MAX_SSE_CONNECTIONS", 8)   # esanli SSE baglanti ust siniri
SSE_MAX_LIFETIME = _env_int("MCP_SSE_MAX_LIFETIME", 0)         # sn; 0 = kapali (istemci yeniden baglanmazsa kopar)
MAX_BODY_BYTES = _env_int("MCP_MAX_BODY_BYTES", 64 * 1024)     # POST govde siniri (Content-Length)

MAX_RESULTS = 3
MAX_SNIPPET_LENGTH = 300
SEARCH_TIMEOUT = 8            # ddgs ic zaman asimi (sn)
SEARCH_HARD_TIMEOUT = 12      # istek basina ust sinir (sn)
CACHE_TTL_SECONDS = 600
CACHE_MAX_SIZE = 128

# Tek worker: ayni anda tek arama -> dusuk RAM, DDG rate-limit'ine nazik
executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ddg-search")
search_cache: TTLCache = TTLCache(maxsize=CACHE_MAX_SIZE, ttl=CACHE_TTL_SECONDS)

DOMAIN_SCORES: Dict[str, int] = {
    "github.com": 100,
    "docs.python.org": 95,
    "developer.mozilla.org": 90,
    "numpy.org": 85,
    "pytorch.org": 85,
    "stackoverflow.com": 80,
    "docs.rs": 75,
    "pypi.org": 70,
    "pkg.go.dev": 70,
    "npmjs.com": 60,
}

BAD_SNIPPET_PATTERNS = (
    "accept cookies", "cookie policy", "enable javascript",
    "javascript required", "privacy policy",
    "subscribe to read", "sign in to continue",
)

# =========================================================
# HELPERS
# =========================================================
_WHITESPACE_RE = re.compile(r"\s+")


def normalize_text(text: str) -> str:
    if not text:
        return ""
    return _WHITESPACE_RE.sub(" ", text).strip()


def trim_text(text: str, limit: int) -> str:
    text = normalize_text(text)
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "…"


def is_bad_snippet(text: str) -> bool:
    return any(p in text.lower() for p in BAD_SNIPPET_PATTERNS)


def deduplicate_results(results: List[Dict]) -> List[Dict]:
    seen: set = set()
    out = []
    for r in results:
        url = r.get("href", "").strip()
        if not url or url in seen or is_bad_snippet(r.get("body", "")):
            continue
        seen.add(url)
        out.append(r)
    return out


def prioritize_results(results: List[Dict]) -> List[Dict]:
    def score(r: Dict) -> int:
        url = r.get("href", "").lower()
        return sum(w for d, w in DOMAIN_SCORES.items() if d in url)
    return sorted(results, key=score, reverse=True)


def compact_result(index: int, result: Dict, snippet_limit: int) -> str:
    title = trim_text(result.get("title", ""), 120)
    body = trim_text(result.get("body", ""), snippet_limit)
    url = result.get("href", "")
    return f"[{index}]\nTITLE: {title}\nURL: {url}\nCONTENT: {body}"


async def send_json(send: Any, status: int, payload: dict) -> None:
    body = json.dumps(payload).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"),
                            (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


# =========================================================
# SEARCH ENGINE
# =========================================================
def run_search(query: str) -> List[Dict]:
    cached = search_cache.get(query)
    if cached is not None:
        logger.info("Cache hit | query='%s'", query)
        return cached

    with DDGS(timeout=SEARCH_TIMEOUT) as ddgs:
        raw = list(ddgs.text(query, region="us-en", safesearch="moderate", max_results=MAX_RESULTS))

    results = prioritize_results(deduplicate_results(raw))[:MAX_RESULTS]
    search_cache[query] = results
    logger.info("Cache store | query='%s' | hits=%d", query, len(results))
    return results


def _result(text: str, is_error: bool = False) -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=text)],
        isError=is_error,
    )


# =========================================================
# MCP TOOL HANDLERS (mcp 2.x: constructor callback'leri)
# =========================================================
async def handle_list_tools(ctx: Any, params: Any) -> types.ListToolsResult:
    return types.ListToolsResult(
        tools=[
            types.Tool(
                name="web_search",
                description=(
                    "Searches the web for current information. "
                    "Optimized for coding agents, Continue.dev, "
                    "LiteLLM pipelines and homelab coder models."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {"query": {"type": "string", "description": "Search query"}},
                    "required": ["query"],
                },
            )
        ]
    )


async def handle_call_tool(ctx: Any, params: types.CallToolRequestParams) -> types.CallToolResult:
    if params.name != "web_search":
        return _result(f"Unknown tool: {params.name}", is_error=True)

    arguments = params.arguments or {}
    query = normalize_text(str(arguments.get("query", ""))).lower()
    if not query:
        return _result("Search query is empty.", is_error=True)

    try:
        logger.info("Search started | query='%s'", query)
        loop = asyncio.get_running_loop()
        results = await asyncio.wait_for(
            loop.run_in_executor(executor, run_search, query),
            timeout=SEARCH_HARD_TIMEOUT,
        )

        if not results:
            return _result("No search results found.")

        snippet_limit = 180 if len(results) >= 3 else MAX_SNIPPET_LENGTH
        context = "\n\n".join(
            compact_result(i + 1, r, snippet_limit) for i, r in enumerate(results)
        )
        logger.info("Search done | query='%s' | results=%d", query, len(results))
        return _result(context)

    except asyncio.TimeoutError:
        logger.warning("Search timeout | query='%s'", query)
        return _result("Search timed out.", is_error=True)
    except Exception:
        logger.exception("Search failed | query='%s'", query)
        return _result("Search temporarily unavailable.", is_error=True)


mcp_server = Server(
    "web-search-homelab",
    version="2.0.0",
    on_list_tools=handle_list_tools,
    on_call_tool=handle_call_tool,
)

# =========================================================
# MIDDLEWARE (saf ASGI - SSE akisini tamponlamaz)
# =========================================================
class PureASGIAuthMiddleware:
    """
    - /health muaf
    - x-api-key header'i, Authorization: Bearer <key>, veya ?api_key= query parametresi
    - Sabit-zamanli bayt karsilastirmasi
    - http disi scope'lar (lifespan vb.) oldugu gibi gecer
    """

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        path = scope.get("path", "")
        if scope["type"] != "http" or path == "/health" or path.startswith("/.well-known/"):       
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))

        client_key = headers.get(b"x-api-key", b"")

        if not client_key:
            auth_header = headers.get(b"authorization", b"")
            if auth_header.startswith(b"Bearer "):
                client_key = auth_header[len(b"Bearer "):]

        if not client_key:
            for part in scope.get("query_string", b"").split(b"&"):
                if part.startswith(b"api_key="):
                    client_key = part[len(b"api_key="):]
                    break

        if not hmac.compare_digest(client_key, _SECRET_BYTES):
            await send_json(send, 401, {"error": "Unauthorized"})
            return

        await self.app(scope, receive, send)

class BodyLimitMiddleware:
    """Content-Length'i MAX_BODY_BYTES'i asan POST isteklerini 413 ile reddeder.
    (Chunked govdeler bu kontrolden gecmez; JSON-RPC istemcileri normalde Content-Length gonderir.)"""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] == "http" and scope.get("method") == "POST":
            headers = dict(scope.get("headers", []))
            try:
                length = int(headers.get(b"content-length", b"0"))
            except ValueError:
                length = 0
            if length > MAX_BODY_BYTES:
                await send_json(send, 413, {"error": "Request body too large"})
                return
        await self.app(scope, receive, send)


# =========================================================
# SSE KATMANI (sadece sse / both modunda kullanilir)
# =========================================================
class SSEApp:
    """
    Saf ASGI SSE uygulamasi (Route'a sinif ornegi verilince request_response sarmasi yapilmaz).
    Koruma: esanli baglanti ust siniri + opsiyonel maksimum baglanti omru.
    """

    def __init__(self, transport: Any) -> None:
        self.transport = transport
        self.active = 0

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if self.active >= MAX_SSE_CONNECTIONS:
            logger.warning("SSE limit reached (%d), baglanti reddedildi", MAX_SSE_CONNECTIONS)
            await send_json(send, 503, {"error": "Too many SSE connections"})
            return

        self.active += 1
        logger.info("SSE connected | active=%d", self.active)
        try:
            async with self.transport.connect_sse(scope, receive, send) as streams:
                run = mcp_server.run(
                    streams[0],
                    streams[1],
                    mcp_server.create_initialization_options(),
                )
                if SSE_MAX_LIFETIME > 0:
                    try:
                        await asyncio.wait_for(run, timeout=SSE_MAX_LIFETIME)
                    except asyncio.TimeoutError:
                        logger.info("SSE max omur doldu, baglanti kapatiliyor")
                else:
                    await run
        finally:
            self.active -= 1
            logger.info("SSE closed | active=%d", self.active)


def _make_sse_transport() -> Any:
    from mcp.server.sse import SseServerTransport

    # Kimlik dogrulama API key ile yapildigi icin LAN'dan gelen Host header'lari
    # DNS-rebinding korumasina takilmasin. Imza farkli ise sade kurucuya duser.
    try:
        from mcp.server.transport_security import TransportSecuritySettings
        return SseServerTransport(
            "/messages/",
            security_settings=TransportSecuritySettings(enable_dns_rebinding_protection=False),
        )
    except (ImportError, TypeError):
        logger.warning("security_settings desteklenmedi, varsayilan SseServerTransport kullaniliyor")
        return SseServerTransport("/messages/")


sse_app: SSEApp | None = None


async def health_endpoint(request: Request) -> Response:
    data = json.dumps({
        "status": "ok",
        "transport": MCP_TRANSPORT,
        "sse_active": sse_app.active if sse_app else 0,
        "sse_max": MAX_SSE_CONNECTIONS if sse_app else 0,
        "cache_size": len(search_cache),
        "cache_maxsize": search_cache.maxsize,
    }).encode()
    return Response(content=data, media_type="application/json")


# =========================================================
# APP INSA
# =========================================================
def build_app() -> Any:
    global sse_app

    health_route = Route("/health", endpoint=health_endpoint, methods=["GET"])
    sse_routes: list = []

    if MCP_TRANSPORT in ("sse", "both"):
        transport = _make_sse_transport()
        sse_app = SSEApp(transport)
        sse_routes = [
            Route("/sse", endpoint=sse_app, methods=["GET"]),
            Mount("/messages/", app=transport.handle_post_message),
        ]

    if MCP_TRANSPORT == "sse":
        inner = Starlette(routes=[health_route, *sse_routes])
    else:
        # streamable veya both: /mcp (stateless + JSON). both ise /sse ve /messages/ da eklenir.
        inner = mcp_server.streamable_http_app(
            streamable_http_path="/mcp",
            stateless_http=True,
            json_response=True,
            max_request_body_size=MAX_BODY_BYTES,
            host="0.0.0.0",  # localhost-only DNS-rebinding korumasini devre disi birakir
            custom_starlette_routes=[health_route, *sse_routes],
        )

    return PureASGIAuthMiddleware(BodyLimitMiddleware(inner))


app = build_app()

# =========================================================
# ENTRYPOINT
# =========================================================
if __name__ == "__main__":
    logger.info("Baslatiliyor | transport=%s | max_sse=%d | sse_lifetime=%ds",
                MCP_TRANSPORT, MAX_SSE_CONNECTIONS, SSE_MAX_LIFETIME)
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        workers=1,
        loop=LOOP,
        timeout_keep_alive=30,
        access_log=False,
        log_level="warning",
    )
