#!/usr/bin/env bash
# tools/rotate-keys.sh — AI-Brain Guvenlik Anahtarlarini Yenileme Araci
# LiteLLM master_key ve MCP_SECRET_KEY anahtarlarini guvenli sekilde yeniden uretir,
# servisleri yeniden baslatir ve yerel keys dosyasini gunceller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/_common.sh"

PVE_IP="${AI_PVE_IP:-}"
TARGET_ID="${AI_CT_ID:-}"
TARGET_TYPE="${AI_TARGET_TYPE:-lxc}"

usage() {
  cat << 'EOF'
Kullanim: tools/rotate-keys.sh [secenekler]

  --host <ip>        Proxmox host adresi
  --id <id>          Container veya VM ID
  --type <lxc|vm>    Hedef turu (varsayilan: lxc)
  -h, --help         Bu yardim mesajini goster
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) PVE_IP="$2"; shift 2 ;;
    --id|--ctid) TARGET_ID="$2"; shift 2 ;;
    --type) TARGET_TYPE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Bilinmeyen secenek: $1" ;;
  esac
done

require_pve_ip "$PVE_IP"
[ -n "$TARGET_ID" ] || die "LXC veya VM ID belirtilmelidir (--id <id>)"

log "=== AI-Brain Anahtar Yenileme ($TARGET_TYPE #$TARGET_ID @ $PVE_IP) ==="

NEW_LITELLM_KEY="sk-$(openssl rand -hex 16)"
NEW_MCP_SECRET="$(openssl rand -hex 32)"

log "1. Yeni anahtarlar uretildi."

if [ "$TARGET_TYPE" = "lxc" ]; then
  # LXC icinde anahtarlari guncelle
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
    # LiteLLM anahtari guncelle
    if [ -f /opt/litellm/config.yaml ]; then
      sed -i 's|^[[:space:]]*master_key:.*|  master_key: \"$NEW_LITELLM_KEY\"|' /opt/litellm/config.yaml
      chmod 600 /opt/litellm/config.yaml
      systemctl restart litellm
    fi

    # MCP anahtari guncelle
    if [ -f /etc/ai-brain/mcp-web-search.env ]; then
      sed -i 's|^MCP_SECRET_KEY=.*|MCP_SECRET_KEY=$NEW_MCP_SECRET|' /etc/ai-brain/mcp-web-search.env
      chmod 600 /etc/ai-brain/mcp-web-search.env
      systemctl restart mcp-web-search
    fi
  "
else
  warn "VM hedefi uzerinde anahtar yenileme su an SSH uzerinden config guncellemesi gerektirir."
fi

# Yerel keys dosyasini guncelle
KEY_FILE="$SCRIPT_DIR/ai-brain-${TARGET_ID}-keys.txt"
if [ -f "$KEY_FILE" ]; then
  sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$NEW_LITELLM_KEY|" "$KEY_FILE"
  sed -i "s|^MCP_SECRET_KEY=.*|MCP_SECRET_KEY=$NEW_MCP_SECRET|" "$KEY_FILE"
else
  {
    echo "# AI-Brain ($TARGET_TYPE) - Rotated Keys"
    echo "# Tarih: $(date '+%Y-%m-%d %H:%M')"
    echo "LITELLM_MASTER_KEY=$NEW_LITELLM_KEY"
    echo "MCP_SECRET_KEY=$NEW_MCP_SECRET"
  } > "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"

ok "Anahtarlar basariyla yenilendi ve servisler yeniden baslatildi:"
echo "  -> LiteLLM Master Key: $NEW_LITELLM_KEY"
echo "  -> MCP Secret Key:     $NEW_MCP_SECRET"
echo "  -> Yerel Dosya:        $KEY_FILE"
warn "İstemci (Continue.dev, VSCode vb.) ayarlarınızdaki anahtarları güncellemeyi unutmayınız!"
