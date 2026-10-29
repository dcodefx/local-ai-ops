#!/usr/bin/env bash
# provision/20-python.sh — Izole Python venv ortamlari ve paket sabitleme (FR-15, NFR-3)
#
# Kritik tasarim notu: target_exec() single-quote heredoc icinde python3 -c "..." kullanilamaz;
# uzak bash'ta quoting kiriliyor. Python kodu ayri dosya olarak push edilip calistirilir.
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[2/6] Python venv ortamlari hazirlaniyor..."

# 1. Constraints dosyasini hedefe aktar
log "  -> constraints.txt aktariliyor..."
target_push "$PAYLOAD_DIR_LOCAL/constraints.txt" "/etc/ai-brain/constraints.txt" 644

# 2. MCP dogrulama scriptini hedefe aktar (quoting sorununu onler)
log "  -> mcp_verify.py aktariliyor..."
target_push "$PAYLOAD_DIR_LOCAL/mcp_verify.py" "/tmp/mcp_verify.py" 644

# 3. MCP venv (/opt/ai_engine/venv)
# NOT: mcp 2.x SseServerTransport, types, Server modüllerini icerir.
#      web_search_mcp.py bu API'yi kullanir — surum degistirme.
log "  -> MCP icin ayri venv (/opt/ai_engine/venv) olusturuluyor..."
target_exec '
  set -e
  python3 -m venv /opt/ai_engine/venv
  /opt/ai_engine/venv/bin/pip install --upgrade pip setuptools wheel -q

  # Paketler tek satirda: quoting sorunu yok
  /opt/ai_engine/venv/bin/pip install -q \
    "mcp>=2.3.0,<3.0.0" \
    "fastapi>=0.110.0" \
    "uvicorn>=0.28.0" \
    "starlette>=0.36.0" \
    "pydantic>=2.0.0" \
    "ddgs>=7.0.0" \
    "cachetools>=5.3.0" \
    "beautifulsoup4>=4.12.0" \
    "requests>=2.31.0"

  # uvloop opsiyonel (yoksa asyncio ile devam eder)
  /opt/ai_engine/venv/bin/pip install -q "uvloop>=0.19.0" 2>/dev/null || true
'

# 4. mcp kurulumunu DOSYA uzerinden dogrula (heredoc quoting sorununu onler)
log "  -> MCP kurulumu dogrulaniyor..."
mcp_result="$(target_exec '/opt/ai_engine/venv/bin/python3 /tmp/mcp_verify.py 2>&1; echo "EXIT:$?"')"
mcp_exit="$(printf '%s' "$mcp_result" | grep -oE 'EXIT:[0-9]+' | tail -1 | cut -d: -f2)"
mcp_output="$(printf '%s' "$mcp_result" | grep -v 'EXIT:')"

if [ "${mcp_exit:-1}" = "0" ]; then
  ok "MCP dogrulandi: $mcp_output"
else
  err "MCP dogrulama ciktisi:"
  printf '%s\n' "$mcp_output" >&2
  die "mcp>=2.3.0 kurulamadi veya import edilemiyor. 'pip install mcp' sonrasi import deneyiniz."
fi

# Temp dosyayi temizle
target_exec 'rm -f /tmp/mcp_verify.py' || true

# 5. LiteLLM venv (/opt/litellm/venv)
# NOT: litellm[proxy] extras iceriyor. Extras'li paketler -c constraints.txt ile kullanilamaz;
#      pip yeni resolver'da "Constraints cannot have extras" hatasi verir.
log "  -> LiteLLM icin ayri venv (/opt/litellm/venv) olusturuluyor..."
target_exec '
  set -e
  python3 -m venv /opt/litellm/venv
  /opt/litellm/venv/bin/pip install --upgrade pip setuptools wheel -q

  # 1. Önce extras içeren litellm[proxy] paketini kuralım
  /opt/litellm/venv/bin/pip install -q "litellm[proxy]>=1.106.5"

  # # 2. huggingface-hub paketini, eğer constraints.txt içinde tanımlıysa ona uyarak,
  # #    değilse güncel ve native "hf" komutunu destekleyen bir sürümle (-c çakışmasına dikkat ederek ayrı satırda) kuralım.
  # if grep -q "huggingface-hub" /etc/ai-brain/constraints.txt 2>/dev/null; then
  #   /opt/litellm/venv/bin/pip install -q "huggingface-hub" -c /etc/ai-brain/constraints.txt
  # else
  #   /opt/litellm/venv/bin/pip install -q "huggingface-hub>=2.3.0"
  # fi
  # Sembbolik baglar: sistem PATH icin
  ln -sf /opt/litellm/venv/bin/hf /usr/local/bin/hf
'
ok "LiteLLM venv hazirlandi (/usr/local/bin/litellm baglandi)"

ok "[2/6] Python provision tamamlandi."
