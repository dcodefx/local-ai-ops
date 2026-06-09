import asyncio
import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List

import uvicorn
import uvloop
from cachetools import TTLCache
from ddgs import DDGS
from mcp import types
from mcp.server import Server
from mcp.server.sse import SseServerTransport
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Mount, Route

# =========================================================
# LOGGING
# =========================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("mcp-web-search")

# =========================================================
# MCP SERVER & SSE TRANSPORT
# =========================================================
mcp_server = Server("web-search-homelab")
sse_transport = SseServerTransport("/messages")

# =========================================================
# CONFIG
# =========================================================
MCP_SECRET_KEY = "your mcp random string key"

MAX_RESULTS        = 3
MAX_SNIPPET_LENGTH = 300
SEARCH_TIMEOUT     = 8
CACHE_TTL_SECONDS  = 600
CACHE_MAX_SIZE     = 128

executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ddg-search")
search_cache = TTLCache(maxsize=CACHE_MAX_SIZE, ttl=CACHE_TTL_SECONDS)

DOMAIN_SCORES: Dict[str, int] = {
    "github.com":            100,
    "docs.python.org":        95,
    "developer.mozilla.org":  90,
    "numpy.org":              85,
    "pytorch.org":            85,
    "stackoverflow.com":      80,
    "docs.rs":                75,
    "pypi.org":               70,
    "pkg.go.dev":             70,
    "npmjs.com":              60,
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
    body  = trim_text(result.get("body",  ""), snippet_limit)
    url   = result.get("href", "")
    return f"[{index}]\nTITLE: {title}\nURL: {url}\nCONTENT: {body}"

# =========================================================
# SEARCH ENGINE
# =========================================================
def run_search(query: str) -> List[Dict]:
    cached = search_cache.get(query)
    if cached is not None:
        logger.info("Cache hit | query='%s'", query)
        return cached

    with DDGS(timeout=SEARCH_TIMEOUT) as ddgs:
        raw = list(ddgs.text(query, region="wt-wt", safesearch="moderate", max_results=MAX_RESULTS))

    results = prioritize_results(deduplicate_results(raw))[:MAX_RESULTS]
    search_cache[query] = results
    logger.info("Cache store | query='%s' | hits=%d", query, len(results))
    return results

# =========================================================
# MCP TOOLS
# =========================================================
@mcp_server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
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

@mcp_server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name != "web_search":
        raise ValueError(f"Unknown tool: {name}")

    query = normalize_text(arguments.get("query", "")).lower()
    if not query:
        return [types.TextContent(type="text", text="Search query is empty.")]

    try:
        logger.info("Search started | query='%s'", query)
        loop = asyncio.get_running_loop()
        results = await loop.run_in_executor(executor, run_search, query)

        if not results:
            return [types.TextContent(type="text", text="No search results found.")]

        snippet_limit = 180 if len(results) >= 3 else MAX_SNIPPET_LENGTH
        context = "\n\n".join(compact_result(i + 1, r, snippet_limit) for i, r in enumerate(results))
        logger.info("Search done | query='%s' | results=%d", query, len(results))
        return [types.TextContent(type="text", text=context)]

    except Exception:
        logger.exception("Search failed | query='%s'", query)
        return [types.TextContent(type="text", text="Search temporarily unavailable.")]

# =========================================================
# AUTH MIDDLEWARE
# =========================================================
class PureASGIAuthMiddleware:
    """
    Saf ASGI auth — SSE stream ile uyumlu.
    BaseHTTPMiddleware response'u tamponlar, SSE frame'lerini reddeder.
    Bu sınıf doğrudan ASGI (scope,receive,send) üzerinde çalışır.
    """
    _UNAUTHORIZED = json.dumps({"error": "Unauthorized"}).encode()

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        client_key = headers.get(b"x-api-key", b"").decode()
        if not client_key:
            for part in scope.get("query_string", b"").decode().split("&"):
                if part.startswith("api_key="):
                    client_key = part[len("api_key="):]
                    break

        if client_key != MCP_SECRET_KEY:
            body = self._UNAUTHORIZED
            await send({"type": "http.response.start", "status": 401,
                        "headers": [(b"content-type", b"application/json"),
                                    (b"content-length", str(len(body)).encode())]})
            await send({"type": "http.response.body", "body": body})
            return

        await self.app(scope, receive, send)

# =========================================================
# SSE ASGI APP
# =========================================================
# SORUN: Starlette Route bir fonksiyon alınca request_response() ile sarar.
# request_response() endpoint'ten Response nesnesi bekler.
# connect_sse() zaten EventSourceResponse ile send'e yazıyor.
# Fonksiyon bitince request_response() tekrar response göndermeye çalışır → ÇAKIŞMA.
#
# ÇÖZÜM: Route bir SINIF alınca onu saf ASGI callable olarak kullanır,
# request_response() sarmalaması yapmaz.
# SSEApp sınıfı __call__(scope,receive,send) ile saf ASGI davranır.

class SSEApp:
    """
    Saf ASGI SSE uygulaması.
    Starlette Route'a sınıf verilince request_response() sarması yapılmaz,
    __call__(scope,receive,send) doğrudan çağrılır.
    """
    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        async with sse_transport.connect_sse(scope, receive, send) as streams:
            await mcp_server.run(
                streams[0],
                streams[1],
                mcp_server.create_initialization_options(),
            )


async def health_endpoint(request: Request) -> Response:
    data = json.dumps({
        "status": "ok",
        "cache_size": len(search_cache),
        "cache_maxsize": search_cache.maxsize,
    }).encode()
    return Response(content=data, media_type="application/json")


# =========================================================
# APP
# =========================================================
routes = [
    Route("/sse",    endpoint=SSEApp(),        methods=["GET"]),
    Route("/health", endpoint=health_endpoint, methods=["GET"]),
    Mount("/messages", app=sse_transport.handle_post_message),
]

app = Starlette(
    routes=routes,
    middleware=[Middleware(PureASGIAuthMiddleware)],
)

# =========================================================
# ENTRYPOINT
# =========================================================
if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        workers=1,
        loop="uvloop",
        timeout_keep_alive=30,
        access_log=False,
        log_level="warning",
    )