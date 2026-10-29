#!/usr/bin/env bash
# tools/status.sh — AI-Brain Sistem, Servis ve Saglik Durumu Goruntuleyici
# Hedefin (LXC veya VM) durumunu, servis sagligini, RAM ve disk kullanimini tek ekranda gosterir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/_common.sh"

PVE_IP="${AI_PVE_IP:-}"
TARGET_ID="${AI_CT_ID:-}"
TARGET_TYPE="${AI_TARGET_TYPE:-lxc}"

usage() {
  cat << 'EOF'
Kullanim: tools/status.sh [secenekler]

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
[ -n "$TARGET_ID" ] || die "LXC veya VM ID belirtilmelidir (--id <id> veya .ai-brain-lxc.env)"

log "=== AI-Brain Durum Raporu ($TARGET_TYPE #$TARGET_ID @ $PVE_IP) ==="

run_cmd() {
  if [ "$TARGET_TYPE" = "lxc" ]; then
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec '$TARGET_ID' -- bash -c '$*'"
  else
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "qm guest exec '$TARGET_ID' -- bash -c '$*'" 2>/dev/null || \
      warn "VM guest agent komut calistiramadi"
  fi
}

echo ""
log "--- [1] Servis Durumlari ---"
run_cmd "systemctl is-active mcp-web-search litellm 2>/dev/null | paste <(echo -e 'mcp-web-search:\nlitellm:') - || true"

echo ""
log "--- [2] MCP /health Yaniti ---"
run_cmd "curl -s http://127.0.0.1:8000/health || echo 'MCP servisine ulasilamiyor'"

echo ""
log "--- [3] LiteLLM Durumu ---"
run_cmd "curl -s -o /dev/null -w 'HTTP Code: %{http_code}\n' http://127.0.0.1:4000/health/liveliness || echo 'LiteLLM servisine ulasilamiyor'"

echo ""
log "--- [4] Aktif Model (cpu-model-switch) ---"
run_cmd "cpu-model-switch status 2>/dev/null || echo 'cpu-model-switch tanimli degil veya model calismiyor'"

echo ""
log "--- [5] Bellek (RAM) ve Disk Durumu ---"
run_cmd "free -h"
echo ""
run_cmd "df -h /data"

echo ""
log "--- [6] DNS Cozumleme Kontrolu ---"
run_cmd "getent hosts huggingface.co || echo 'DNS cozumleme basarisiz!'"

ok "Durum raporu tamamlandi."
