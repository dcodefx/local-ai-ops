#!/usr/bin/env bash
# provision/40-litellm.sh — LiteLLM yapilandirmasi, yetkilendirme ve servis baslatma (FR-7, NFR-4)
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[4/6] LiteLLM Proxy yapilandiriliyor..."

target_exec "mkdir -p /opt/litellm"

# 1. Master key uretimi veya korunmasi
if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  # Var olan anahtari koruma kontrolu (--update senaryosu)
  existing_key="$(target_exec "grep -E '^[[:space:]]*master_key:' /opt/litellm/config.yaml 2>/dev/null | cut -d: -f2 | tr -d ' \"' || true")"
  if [ -n "$existing_key" ] && [ "$existing_key" != "{{LITELLM_MASTER_KEY}}" ]; then
    LITELLM_MASTER_KEY="$existing_key"
    log "  -> Mevcut LiteLLM master_key korundu"
  else
    LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16)"
    log "  -> Yeni LiteLLM master_key uretildi"
  fi
  export LITELLM_MASTER_KEY
fi

# 2. Config dosyasini hazirla ve chmod 600 ile aktar
tmp_cfg="$(mktemp)"
chmod 600 "$tmp_cfg"
sed "s|{{LITELLM_MASTER_KEY}}|${LITELLM_MASTER_KEY}|g" "$PAYLOAD_DIR_LOCAL/litellm-config.yml" > "$tmp_cfg"

target_push "$tmp_cfg" "/opt/litellm/config.yaml" 600
shred -u "$tmp_cfg" 2>/dev/null || rm -f "$tmp_cfg"
ok "LiteLLM konfigurasyonu /opt/litellm/config.yaml konumuna (chmod 600) aktarildi"

# 3. Service dosyasini hazirla ve enable --now yap
tmp_srv="$(mktemp)"
sed "s|{{LITELLM_BIN}}|/opt/litellm/venv/bin/litellm|g" "$PAYLOAD_DIR_LOCAL/litellm.service" > "$tmp_srv"

target_push "$tmp_srv" "/etc/systemd/system/litellm.service" 644
rm -f "$tmp_srv"

target_exec "
  systemctl daemon-reload
  systemctl enable --now litellm
"
ok "LiteLLM servisi baslatildi (enable --now)"

ok "[4/6] LiteLLM provision tamamlandi."
