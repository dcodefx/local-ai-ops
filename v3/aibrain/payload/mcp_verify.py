#!/usr/bin/env python3
# payload/mcp_verify.py — Hedef VM/LXC icinde mcp kurulumunu dogrulayan kisa script.
# provision/20-python.sh tarafindan hedefe push edilip calistirilir; asla dogrudan calistirilmaz.
import sys

# --- mcp import ---
try:
    import mcp  # noqa: F401
except ImportError as e:
    print(f"FAIL: mcp import error: {e}", file=sys.stderr)
    sys.exit(1)

# --- Surum tespit ---
version_str = None
try:
    from importlib.metadata import version as _v
    version_str = _v("mcp")
except Exception:
    pass

if version_str is None:
    version_str = getattr(mcp, "__version__", "unknown")

print(f"mcp version: {version_str}")

# --- Minimum surum kontrol (major >= 1) ---
try:
    major = int(str(version_str).split(".")[0])
except (ValueError, IndexError):
    major = 1  # bilinmiyorsa gecerli say

if major < 1:
    print(f"FAIL: mcp version too old: {version_str}", file=sys.stderr)
    sys.exit(1)

# --- Kritik import'lar ---
try:
    from mcp import types  # noqa: F401
    from mcp.server import Server  # noqa: F401
    from mcp.server.sse import SseServerTransport  # noqa: F401
except ImportError as e:
    print(f"FAIL: mcp submodule import error: {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: mcp {version_str} - Server, types, sse importlari basarili")
sys.exit(0)
