#!/usr/bin/env bash
# provision/90-smoke.sh — Kurulum sonu duman testi ve dogrulama (FR-8, T3, T4, NFR-1)
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[6/6] Kurulum sonu duman testleri ve saglik kontrolleri yapiliyor..."

# 1. MCP /health kontrolu
log "  -> MCP Web Search (/health) testi yapiliyor..."
mcp_ready=0
for _ in $(seq 1 15); do
  resp="$(target_exec "curl -s -w '\n%{http_code}' http://127.0.0.1:8000/health || true")"
  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | head -n -1)"
  if [ "$http_code" = "200" ]; then
    mcp_ready=1
    log "     MCP Saglik Yaniti: $body"
    break
  fi
  sleep 1
done

if [ "$mcp_ready" -eq 1 ]; then
  ok "MCP Web Search /health: 200 OK"
else
  warn "MCP Web Search /health kontrolu basarisiz oldu. Servis loglari:"
  target_exec "journalctl -u mcp-web-search -n 20 --no-pager" || true
fi

# 2. MCP Kimlik Dogrulama Testi (T4)
log "  -> MCP Kimlik dogrulama testi (x-api-key)..."
auth_code="$(target_exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8000/sse || true")"
if [ "$auth_code" = "401" ]; then
  ok "Anahtarsiz erisim 401 Unauthorized ile engellendi (T4 Dogrulandi)"
else
  warn "Beklenmeyen yetkilendirme yaniti: $auth_code"
fi

# 3. LiteLLM Port ve Saglik Kontrolu
log "  -> LiteLLM Proxy (Port 4000) kontrol ediliyor..."
litellm_ready=0
for _ in $(seq 1 15); do
  litellm_code="$(target_exec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/health/liveliness || curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/ || true")"
  if [ "$litellm_code" = "200" ] || [ "$litellm_code" = "404" ] || [ "$litellm_code" = "401" ]; then
    litellm_ready=1
    break
  fi
  sleep 1
done

if [ "$litellm_ready" -eq 1 ]; then
  ok "LiteLLM servisi yanit veriyor (HTTP $litellm_code)"
else
  warn "LiteLLM servis yaniti alinamadi. Servis loglari:"
  target_exec "journalctl -u litellm -n 20 --no-pager" || true
fi

# 4. DNS Cozumleme Testi
log "  -> DNS ve dis ag erisimi dogrulaniyor..."
if target_exec "curl -sI --connect-timeout 5 https://huggingface.co >/dev/null 2>&1 || curl -sI --connect-timeout 5 https://github.com >/dev/null 2>&1"; then
  ok "DNS cozumleme ve HTTPS baglantisi basarili"
else
  warn "Hedef dis alan adlarini cozemiyor veya HTTPS erisimi yok."
fi

# 5. Bos kaynak kullanimi (NFR-1)
log "  -> Hedef bos kaynak durumu (RAM & CPU):"
target_exec "free -m | head -n 2" || true

ok "[6/6] Duman testi tamamlandi."
