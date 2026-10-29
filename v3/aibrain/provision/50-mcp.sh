#!/usr/bin/env bash
# provision/50-mcp.sh — MCP Web Search yapilandirmasi ve servis baslatma (FR-5, FR-6)
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[5/6] MCP Web Search servisi yapilandiriliyor..."

target_exec "mkdir -p /etc/ai-brain /opt/ai_engine"

# 1. MCP Secret key uretimi veya korunmasi
if [ -z "${MCP_SECRET_KEY:-}" ]; then
  existing_secret="$(target_exec "grep -E '^MCP_SECRET_KEY=' /etc/ai-brain/mcp-web-search.env 2>/dev/null | cut -d= -f2 || true")"
  if [ -n "$existing_secret" ] && [ "$existing_secret" != "{{MCP_SECRET_KEY}}" ]; then
    MCP_SECRET_KEY="$existing_secret"
    log "  -> Mevcut MCP_SECRET_KEY korundu"
  else
    MCP_SECRET_KEY="$(openssl rand -hex 32)"
    log "  -> Yeni MCP_SECRET_KEY uretildi"
  fi
  export MCP_SECRET_KEY
fi

# 2. Env sablonunu hazirla ve chmod 600 ile yerlestir
tmp_env="$(mktemp)"
chmod 600 "$tmp_env"
sed -e "s|{{MCP_SECRET_KEY}}|${MCP_SECRET_KEY}|g" \
    -e "s|^MCP_TRANSPORT=.*|MCP_TRANSPORT=${MCP_TRANSPORT:-sse}|g" \
    "$PAYLOAD_DIR_LOCAL/mcp-web-search.env" > "$tmp_env"

target_push "$tmp_env" "/etc/ai-brain/mcp-web-search.env" 600
shred -u "$tmp_env" 2>/dev/null || rm -f "$tmp_env"
ok "MCP ortami /etc/ai-brain/mcp-web-search.env (chmod 600) konumuna aktarildi"

# 3. Python scriptini yerlestir
target_push "$PAYLOAD_DIR_LOCAL/web_search_mcp.py" "/opt/ai_engine/web_search_mcp.py" 755
ok "web_search_mcp.py aktarildi"

# 4. Service dosyasini hazirla ve enable --now yap
tmp_srv="$(mktemp)"
sed "s|{{PYTHON_BIN}}|/opt/ai_engine/venv/bin/python3|g" "$PAYLOAD_DIR_LOCAL/mcp-web-search.service" > "$tmp_srv"

target_push "$tmp_srv" "/etc/systemd/system/mcp-web-search.service" 644
rm -f "$tmp_srv"

target_exec "
  systemctl daemon-reload
  systemctl enable --now mcp-web-search
"
sleep 1

if target_exec "systemctl is-active --quiet mcp-web-search"; then
  ok "mcp-web-search servisi basariyla baslatildi ve aktif"
else
  warn "mcp-web-search servisi baslamamis gorunuyor, duman testi loglari inceleyecek."
fi

ok "[5/6] MCP Web Search provision tamamlandi."
