#!/usr/bin/env bash
# ai-brain.sh — Birlesik AI-Brain Hedef Yonetimi ve Provision Giris Noktasi
#
# Desteklenen Hedefler:
#   - Proxmox LXC (--type lxc, varsayilan)
#   - Proxmox Cloud-Init VM (--type vm)
#
# Kullanim:
#   ./ai-brain.sh --type lxc --host 164.102.98.16
#   ./ai-brain.sh --type vm --host 164.102.98.16 --template-id 9000
#   ./ai-brain.sh --dry-run
#   ./ai-brain.sh --update
#
# Ayrintili secenekler icin: ./ai-brain.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"
PAYLOAD_DIR_LOCAL="$SCRIPT_DIR/payload"
PROVISION_DIR="$SCRIPT_DIR/provision"
TARGETS_DIR="$SCRIPT_DIR/targets"

# 1. Komut satirinda --type var mi onceden tespit et
CLI_TARGET_TYPE=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--type" ]; then
    next=$((i+1))
    CLI_TARGET_TYPE="${!next:-}"
    break
  fi
done

if [ -n "$CLI_TARGET_TYPE" ]; then
  AI_TARGET_TYPE="$CLI_TARGET_TYPE"
elif [ -f "$SCRIPT_DIR/.ai-brain.env" ]; then
  AI_TARGET_TYPE="$(grep -E '^[[:space:]]*AI_TARGET_TYPE=' "$SCRIPT_DIR/.ai-brain.env" 2>/dev/null | cut -d= -f2 | tr -d '\"' | tr -d "'" | tr -d ' ' || echo 'lxc')"
else
  AI_TARGET_TYPE="lxc"
fi
export AI_TARGET_TYPE

# 2. Ortak kutuphaneyi yukle (hedefe ozel .ai-brain-*.env dosyasini otomatik yukler)
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"
# Yol sozlesmesini yukle
# shellcheck source=./payload/paths.env
source "$PAYLOAD_DIR_LOCAL/paths.env"

# 3. Degisken Varsayilanlarini env'den yukle
TARGET_TYPE="${AI_TARGET_TYPE:-lxc}"
PVE_IP="${AI_PVE_IP:-}"
CT_ID="${AI_CT_ID:-}"
HOSTNAME_="${AI_HOSTNAME:-ai-brain}"
STORAGE="${AI_STORAGE:-local-lvm}"
BRIDGE="${AI_BRIDGE:-vmbr0}"
MAIN_MODE="${AI_MAIN_NET_MODE:-dhcp}"
MAIN_IP="${AI_MAIN_NET_IP:-}"
MAIN_GW="${AI_MAIN_NET_GW:-}"
VLAN_TAG="${AI_VLAN_TAG:-10}"
NET_IP="${AI_NET_IP:-10.10.10.2/24}"
AI_DNS="${AI_DNS:-1.1.1.1 9.9.9.9}"
CORES="${AI_CORES:-7}"
MEMORY_MB="${AI_MEMORY_MB:-28672}"
SWAP_MB="${AI_SWAP_MB:-2048}"
DISK_GB="${AI_DISK_GB:-100}"
ENGINES="stock"
SKIP_LLAMA_BUILD=false
SKIP_VLAN_CHECK=false
FORCE=false
DRY_RUN=false
UPDATE_MODE=false
DESTROY_MODE=false
CLEANUP_ON_FAIL=false       # D1: Hata olunca varsayilan koru, --cleanup-on-fail ile sil
WITH_MODELS=false
SETUP_ACCESS=false
ACCESS_USER="${AI_ACCESS_USER:-aibrain}"
ACCESS_PASSWORD=""
SSH_PUBKEY_FILE="${AI_SSH_PUBKEY_FILE:-}"

# VM Ozel
AI_VM_TEMPLATE_ID="${AI_VM_TEMPLATE_ID:-}"
AI_VM_CPU_TYPE="${AI_VM_CPU_TYPE:-host}"
AI_VM_DISTRO="${AI_VM_DISTRO:-debian}"
AI_VM_VERSION="${AI_VM_VERSION:-13}"
AI_VM_USE_VIRT_CUSTOMIZE="${AI_VM_USE_VIRT_CUSTOMIZE:-false}"
AI_VM_AUTO_CREATE_TEMPLATE="${AI_VM_AUTO_CREATE_TEMPLATE:-true}"

usage() {
  cat << 'EOF'
Kullanim: ai-brain.sh [secenekler]

Genel & Hedef:
  --type <lxc|vm>              Hedef altyapi turu (varsayilan: lxc)
  --host <ip>                  Proxmox host adresi (.ai-brain-*.env dosyasindan okunur)
  --ctid <id>                  LXC CT ID veya VM ID (bos = cluster/nextid)
  --hostname <ad>              (varsayilan: ai-brain)
  --storage <ad>               (varsayilan: local-lvm)
  --bridge <ad>                (varsayilan: vmbr0)
  --vlan <tag>                 Izole ag VLAN tag'i (varsayilan: 10)
  --net-ip <ip/cidr>           Izole ag IP'si (varsayilan: 10.10.10.2/24)
  --dns <ip1 ip2...>           Hedef icin DNS sunuculari (varsayilan: 1.1.1.1 9.9.9.9)
  --main-mode <dhcp|static>    eth0 modu (varsayilan: dhcp)
  --main-ip <ip/cidr>          static secildiyse zorunlu
  --main-gw <ip>               static secildiyse zorunlu

VM Ozel & Template Yonetimi:
  --template-id <id>           Klonlanacak cloud-init VM template ID (bos ise otomatik bulunur/olusturulur)
  --cpu-type <tip>             VM CPU tipi (varsayilan: host)
  --virt-customize             create-vm-template.sh icin first-boot beklemeden diske gom modu
  --no-auto-template           Eksik template durumunda otomatik olusturmayi kapat

Kaynaklar:
  --cores <n>                  CPU cekirdek sayisi (varsayilan: 7)
  --memory <MB>                RAM miktari (varsayilan: 28672)
  --swap <MB>                  Swap miktari (varsayilan: 2048, VM'de 0)
  --disk <GB>                  Disk boyutu (varsayilan: 100)

Modeller ve Engine:
  --engines <ad1,ad2...>       payload/engines/ altindaki profiller (varsayilan: stock)
  --skip-llama-build           llama.cpp derlemesini atla
  --with-models                Kurulum sonrasi model indirme rehberini goster

Islem Modlari:
  --update                     Mevcut hedefi yeniden olusturmadan config, servis ve kodlari guncelle
  --destroy                    Hedefi durdur ve sil (--ctid veya AI_CT_ID gerekli)
  --force                      Mevcut hedef varsa sil ve uzerine kur
  --dry-run                    Hicbir islem yapmadan plani goster
  --cleanup-on-fail            Hata durumunda olusturulan hedefi sil (varsayilan: korur)
  --skip-vlan-check            vmbr0 VLAN-aware kontrolunu atla

Erisim & Guvenlik:
  --setup-access               Konsol ve SSH icin kullanici olustur
  --access-user <ad>           (varsayilan: aibrain)
  --ssh-pubkey-file <yol>      SSH public key dosyasi
  -h, --help                   Bu yardim mesajini goster
EOF
}

# --- Komut Satiri Parametrelerini Ayristir (Env degerlerinin uzerine yazar) ---
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TARGET_TYPE="$2"; shift 2 ;;
    --host) PVE_IP="$2"; shift 2 ;;
    --ctid) CT_ID="$2"; shift 2 ;;
    --hostname) HOSTNAME_="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --vlan) VLAN_TAG="$2"; shift 2 ;;
    --net-ip) NET_IP="$2"; shift 2 ;;
    --dns) AI_DNS="$2"; shift 2 ;;
    --main-mode) MAIN_MODE="$2"; shift 2 ;;
    --main-ip) MAIN_IP="$2"; shift 2 ;;
    --main-gw) MAIN_GW="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY_MB="$2"; shift 2 ;;
    --swap) SWAP_MB="$2"; shift 2 ;;
    --disk) DISK_GB="$2"; shift 2 ;;
    --template-id) AI_VM_TEMPLATE_ID="$2"; shift 2 ;;
    --cpu-type) AI_VM_CPU_TYPE="$2"; shift 2 ;;
    --virt-customize) AI_VM_USE_VIRT_CUSTOMIZE=true; shift ;;
    --no-auto-template) AI_VM_AUTO_CREATE_TEMPLATE=false; shift ;;
    --engines) ENGINES="$2"; shift 2 ;;
    --skip-llama-build) SKIP_LLAMA_BUILD=true; shift ;;
    --skip-vlan-check) SKIP_VLAN_CHECK=true; shift ;;
    --setup-access) SETUP_ACCESS=true; shift ;;
    --access-user) ACCESS_USER="$2"; shift 2 ;;
    --ssh-pubkey-file) SSH_PUBKEY_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --update) UPDATE_MODE=true; shift ;;
    --destroy) DESTROY_MODE=true; shift ;;
    --cleanup-on-fail) CLEANUP_ON_FAIL=true; shift ;;
    --with-models) WITH_MODELS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Bilinmeyen parametre: '$1' -- atlandi"; shift ;;
  esac
done

# --- Hedef Arka Ucu Secimi ---
TARGET_DRIVER="$TARGETS_DIR/${TARGET_TYPE}.sh"
[ -f "$TARGET_DRIVER" ] || die "Gecersiz hedef turu: '$TARGET_TYPE' (beklenen: $TARGET_DRIVER)"

# shellcheck source=/dev/null
source "$TARGET_DRIVER"

TARGET_ID="${CT_ID:-}"

# Gerekli parametre kontrolleri
require_pve_ip "$PVE_IP"

# --destroy modu: erken cik
if [ "$DESTROY_MODE" = true ]; then
  [ -n "$TARGET_ID" ] || die "--destroy icin --ctid <id> belirtilmelidir"
  warn "Hedef $TARGET_ID ($TARGET_TYPE) siliniyor..."
  target_destroy
  ok "Hedef $TARGET_ID basariyla silindi."
  exit 0
fi

[ "$MAIN_MODE" = "dhcp" ] || [ "$MAIN_MODE" = "static" ] || die "--main-mode dhcp ya da static olmalidir"
if [ "$MAIN_MODE" = "static" ]; then
  [ -n "$MAIN_IP" ] && [ -n "$MAIN_GW" ] || die "--main-mode static icin --main-ip ve --main-gw zorunludur"
fi

if [ "$TARGET_TYPE" = "vm" ]; then
  if [ -z "$AI_VM_TEMPLATE_ID" ] && [ "${AI_VM_AUTO_CREATE_TEMPLATE:-true}" != "true" ]; then
    die "VM hedefi icin --template-id gereklidir (veya AI_VM_AUTO_CREATE_TEMPLATE=true olmalidir)"
  fi
fi

SSH_PUBKEY_CONTENT=""
if [ -n "$SSH_PUBKEY_FILE" ]; then
  [ -f "$SSH_PUBKEY_FILE" ] || die "SSH public key dosyasi bulunamadi: $SSH_PUBKEY_FILE"
  SSH_PUBKEY_CONTENT="$(cat "$SSH_PUBKEY_FILE")"
  SETUP_ACCESS=true
fi

# --- Plan Goruntuleme ---
log "=== AI-Brain Kurulum & Provision Plani ==="
echo "  Hedef Turu:    $(target_type_name)"
echo "  Host:          $PVE_IP"
echo "  Hedef ID:      ${TARGET_ID:-<otomatik atama>}"
echo "  Hostname:      $HOSTNAME_"
echo "  Storage:       $STORAGE"
echo "  eth0 (ana ag): $MAIN_MODE $([ "$MAIN_MODE" = static ] && echo "$MAIN_IP gw=$MAIN_GW" || true)"
echo "  eth1 (izole):  vlan=$VLAN_TAG ip=$NET_IP (gateway yok)"
echo "  DNS:           $AI_DNS"
echo "  Kaynak:        ${CORES} core, ${MEMORY_MB}MB RAM, ${SWAP_MB}MB swap, ${DISK_GB}GB disk"
echo "  llama.cpp:     $([ "$SKIP_LLAMA_BUILD" = true ] && echo "atlanacak" || echo "yapilacak (engine(ler): $ENGINES)")"
echo "  Islem Modu:    $([ "$UPDATE_MODE" = true ] && echo "GUNCELLEME (--update)" || echo "YENI KURULUM")"
echo "  Hata Temizligi: $([ "$CLEANUP_ON_FAIL" = true ] && echo "Hata aninda hedef silinecek" || echo "Hata aninda hedef korunacak (varsayilan)")"
if [ "$SETUP_ACCESS" = true ]; then
  echo "  Erisim:        kullanici '$ACCESS_USER' $([ -n "$SSH_PUBKEY_CONTENT" ] && echo "(SSH pubkey)" || echo "(parola)")"
fi
if [ "$TARGET_TYPE" = "vm" ]; then
  echo "  VM Template:   ${AI_VM_TEMPLATE_ID:-<otomatik olusturulacak (ID: 9000)>}"
  echo "  VM CPU Tipi:   ${AI_VM_CPU_TYPE:-host}"
  echo "  virt-customize:$([ "${AI_VM_USE_VIRT_CUSTOMIZE:-false}" = true ] && echo ' aktif' || echo ' devre disi')"
fi

if [ "$DRY_RUN" = true ]; then
  warn "--dry-run: Hicbir islem yapilmadi, plan dogrulandi."
  exit 0
fi

# --- Trap ve Hata Yonetimi ---
cleanup() {
  local ec=$?
  ssh_close_master "$PVE_IP"
  if [ $ec -ne 0 ] && [ "$UPDATE_MODE" = false ]; then
    if [ "$CLEANUP_ON_FAIL" = true ] && [ -n "${TARGET_ID:-}" ]; then
      warn "Kurulum basarisiz oldu. --cleanup-on-fail bayragi aktif oldugu icin hedef $TARGET_ID temizleniyor..."
      target_destroy 2>/dev/null || true
    else
      warn "Kurulum basarisiz oldu. Hedef ($TARGET_ID) hata teshisi icin KORUNDU."
      warn "Silmek icin: ./ai-brain.sh --type $TARGET_TYPE --host $PVE_IP --ctid $TARGET_ID --force"
    fi
  fi
  exit $ec
}
trap cleanup EXIT

# Baglanti ve on kosullari kontrol et
log "Hedef arka uc on kosullari kontrol ediliyor..."
target_check_prereqs

# Hedefi olustur veya hazirla
if [ "$UPDATE_MODE" = false ]; then
  target_create
else
  log "--update modu: Hedef yeniden olusturulmuyor, mevcut hedef yapilandiriliyor..."
  [ -n "$TARGET_ID" ] || die "--update modu icin --ctid verilmelidir"
fi

target_wait_ready

# Fonksiyonlari ve degiskenleri alt islemlere aktar
export -f target_exec target_push target_destroy target_get_ip target_snapshot log ok warn err die
export PAYLOAD_DIR_LOCAL SCRIPT_DIR COMMON_DIR PROVISION_DIR TARGET_TYPE PVE_IP TARGET_ID \
       HOSTNAME_ STORAGE BRIDGE VLAN_TAG NET_IP MAIN_MODE MAIN_IP MAIN_GW AI_DNS \
       CORES MEMORY_MB SWAP_MB DISK_GB ENGINES SKIP_LLAMA_BUILD SKIP_VLAN_CHECK FORCE \
       DRY_RUN UPDATE_MODE SETUP_ACCESS ACCESS_USER ACCESS_PASSWORD SSH_PUBKEY_CONTENT \
       MCP_TRANSPORT C_RED C_GREEN C_YELLOW C_BLUE C_RESET \
       AI_VM_TEMPLATE_ID AI_VM_CPU_TYPE AI_VM_DISTRO AI_VM_VERSION \
       AI_VM_USE_VIRT_CUSTOMIZE AI_VM_AUTO_CREATE_TEMPLATE \
       VM_TARGET_IP SSH_MASTER_PATH

# --- Provision Adimlarini Sirayla Calistir ---
# NOT: 'source' kullaniliyor (bash alt-shell degil) cunku SSH_OPTS gibi
#      bash dizileri alt-shell'e export edilemez.
log "=== Provision Modulleri Calistiriliyor ==="
# shellcheck source=/dev/null
source "$PROVISION_DIR/10-base.sh"
# shellcheck source=/dev/null
source "$PROVISION_DIR/20-python.sh"
# shellcheck source=/dev/null
source "$PROVISION_DIR/30-engines.sh"
# shellcheck source=/dev/null
source "$PROVISION_DIR/40-litellm.sh"
# shellcheck source=/dev/null
source "$PROVISION_DIR/50-mcp.sh"
# shellcheck source=/dev/null
source "$PROVISION_DIR/90-smoke.sh"

# Basarili kurulum sonrasi snapshot al
target_snapshot "ai-brain-ready"

# --- Anahtarlari Kaydet ---
ACTUAL_IP="$(target_get_ip)"
KEY_FILE="$SCRIPT_DIR/ai-brain-${TARGET_ID}-keys.txt"
{
  echo "# AI-Brain ($TARGET_TYPE) - Keys & Access Credentials"
  echo "# Olusturulma: $(date '+%Y-%m-%d %H:%M')"
  echo "# Hedef Turu: $TARGET_TYPE"
  echo "# PVE Host: $PVE_IP"
  echo "# Hedef IP: $ACTUAL_IP"
  echo "# Hedef ID: $TARGET_ID"
  echo ""
  echo "LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY:-}"
  echo "MCP_SECRET_KEY=${MCP_SECRET_KEY:-}"
  if [ "$SETUP_ACCESS" = true ]; then
    echo "ACCESS_USER=${ACCESS_USER}"
    echo "ACCESS_PASSWORD=${ACCESS_PASSWORD:-<ssh-key-only>}"
  fi
} > "$KEY_FILE"
chmod 600 "$KEY_FILE"

echo ""
ok "=== KURULUM VE PROVISION TAMAMLANDI ==="
echo "  Hedef Turu:    $TARGET_TYPE"
echo "  Hedef ID:      $TARGET_ID"
echo "  Hedef IP:      $ACTUAL_IP"
echo "  MCP Uç Noktası: http://${ACTUAL_IP}:8000/sse"
echo "  LiteLLM Proxy:  http://${ACTUAL_IP}:4000"
echo "  Anahtarlar:    $KEY_FILE (chmod 600)"
echo ""

if [ "$WITH_MODELS" = true ]; then
  log "Model Kurulum Talimati:"
  echo "  1) Hedefe baglanin veya komut calistirin:"
  echo "     ./tools/status.sh --host $PVE_IP --id $TARGET_ID"
  echo "  2) Model indirmek ve switch etmek icin:"
  echo "     /data/install_cpu_services.sh"
  echo "     cpu-model-switch switch <alias>"
fi
