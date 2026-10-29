#!/usr/bin/env bash
# _common.sh — scripts/ai-brain/ altındaki script'lerin source ettigi ortak kutuphane.
# Tek basina calistirilmaz.

export C_RED='\033[0;31m'
export C_GREEN='\033[0;32m'
export C_YELLOW='\033[1;33m'
export C_BLUE='\033[0;34m'
export C_RESET='\033[0m'
log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()  { echo -e "${C_RED}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

: "${COMMON_DIR:?_common.sh: kullanmadan once COMMON_DIR degiskenini set et}"

load_target_env() {
  local target="${1:-${AI_TARGET_TYPE:-lxc}}"
  if [ -f "$COMMON_DIR/.ai-brain-${target}.env" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_DIR/.ai-brain-${target}.env"
  elif [ -f "$COMMON_DIR/.ai-brain.env" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_DIR/.ai-brain.env"
  elif [ -f "$COMMON_DIR/.ai-brain-lxc.env" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_DIR/.ai-brain-lxc.env"
  fi
}

# Ilk yukleme (varsayilan hedef veya mevcut tanim)
load_target_env "${AI_TARGET_TYPE:-lxc}"

: "${AI_PVE_IP:=}"
: "${AI_CT_ID:=}"
: "${AI_STORAGE:=local-lvm}"
: "${AI_BRIDGE:=vmbr0}"
: "${AI_VLAN_TAG:=10}"
: "${AI_NET_IP:=10.10.10.2/24}"
: "${AI_HOSTNAME:=ai-brain}"
: "${AI_CORES:=7}"
: "${AI_MEMORY_MB:=28672}"
: "${AI_SWAP_MB:=2048}"
: "${AI_DISK_GB:=100}"
: "${AI_MAIN_NET_MODE:=dhcp}"   # dhcp | static
: "${AI_MAIN_NET_IP:=}"          # static secilirse: 192.168.1.50/24
: "${AI_MAIN_NET_GW:=}"
: "${AI_DNS:=1.1.1.1 9.9.9.9}"

# Hedef ve VM ayarlari
: "${AI_TARGET_TYPE:=lxc}"              # lxc | vm
: "${AI_VM_TEMPLATE_ID:=}"              # vm modu icin qm clone template ID (bos ise otomatik olusturulur/bulunur)
: "${AI_VM_CPU_TYPE:=host}"
: "${AI_VM_DISTRO:=debian}"
: "${AI_VM_VERSION:=13}"
: "${AI_VM_USE_VIRT_CUSTOMIZE:=false}"  # Host'ta libguestfs-tools varsa first-boot beklemeden diske gom
: "${AI_VM_AUTO_CREATE_TEMPLATE:=true}" # Template bulunamazsa create-vm-template.sh'i otomatik calistir

# MCP ayarlari
: "${MCP_TRANSPORT:=sse}"
: "${MCP_MAX_SSE_CONNECTIONS:=8}"
: "${MCP_SSE_MAX_LIFETIME:=0}"
: "${MCP_MAX_BODY_BYTES:=65536}"

SSH_MASTER_PATH="${SSH_MASTER_PATH:-/tmp/ai-brain-ssh-%r@%h:%p}"
SSH_OPTS=(
  -o ControlMaster=auto
  -o "ControlPath=${SSH_MASTER_PATH}"
  -o ControlPersist=300
  -o BatchMode=yes
  -o ConnectTimeout=10
)

ssh_close_master() {
  local host="$1"
  ssh -O exit -o ControlPath="$SSH_MASTER_PATH" "root@${host}" 2>/dev/null || true
}

secure_chmod() {
  local f="$1"
  [ -f "$f" ] || return 0
  chmod 600 "$f"
}

require_pve_ip() {
  if [ -z "${AI_PVE_IP:-}" ] && [ -z "${1:-}" ]; then
    die "Proxmox host IP'si belirtilmedi. --host ile ver, ya da $COMMON_DIR/.ai-brain-lxc.env" \
        "dosyasinda AI_PVE_IP=... tanimla (ornek icin .ai-brain-lxc.env.example'a bak)."
  fi
}
