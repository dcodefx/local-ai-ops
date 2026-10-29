#!/usr/bin/env bash
# targets/lxc.sh — Proxmox LXC Hedef Arka Ucu
# Bu modül Proxmox VE üzerindeki LXC container yönetimini ve komut/dosya aktarımını sağlar.

set -euo pipefail

target_type_name() {
  echo "Proxmox LXC (Debian 13)"
}

target_check_prereqs() {
  require_pve_ip "$PVE_IP"
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "echo ok" >/dev/null 2>&1 || die "SSH baglantisi kurulamadi: $PVE_IP"

  if [ "${SKIP_VLAN_CHECK:-false}" != "true" ]; then
    local vlan_state
    vlan_state="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "ip -d link show '$BRIDGE' 2>/dev/null | grep -oE 'vlan_filtering [0-9]' | awk '{print \$2}' || true")"
    if [ "$vlan_state" != "1" ]; then
      die "Bridge '$BRIDGE' VLAN-aware degil (vlan_filtering=${vlan_state:-bulunamadi}).
      Proxmox GUI: Datacenter -> Node -> System -> Network -> $BRIDGE -> 'VLAN aware' isaretle.
      Atlamak icin: --skip-vlan-check"
    fi
  fi
}

target_resolve_id() {
  if [ -z "${CT_ID:-}" ]; then
    CT_ID="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pvesh get /cluster/nextid")"
    log "Otomatik CT ID atandi: $CT_ID"
  fi
  TARGET_ID="$CT_ID"
}

target_create() {
  target_resolve_id
  log "LXC $TARGET_ID olusturma hazirligi..."

  local exists
  exists="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct status '$TARGET_ID' >/dev/null 2>&1 && echo yes || echo no")"
  if [ "$exists" = "yes" ]; then
    if [ "${FORCE:-false}" = "true" ]; then
      warn "CT $TARGET_ID zaten mevcut, --force ile temizleniyor..."
      target_destroy
    else
      die "CT $TARGET_ID zaten mevcut. (--force ile uzerine yazilabilir veya --ctid bos birakilabilir)"
    fi
  fi

  # Debian 13 template cozumu
  log "Debian 13 container template kontrol ediliyor..."
  local tmpl
  tmpl="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
    TMPL=\$(pveam list local 2>/dev/null | grep -oE 'debian-13-standard[^[:space:]]*\.tar\.[a-z]+' | head -1 || true)
    if [ -z \"\$TMPL\" ]; then
      pveam update >/dev/null 2>&1 || true
      TMPL=\$(pveam available 2>/dev/null | grep -oE 'debian-13-standard[^[:space:]]*\.tar\.[a-z]+' | head -1 || true)
      if [ -n \"\$TMPL\" ]; then
        pveam download local \"\$TMPL\" >/dev/null
      fi
    fi
    echo \"\$TMPL\"
  ")"
  [ -n "$tmpl" ] || die "Debian 13 template bulunamadi (pveam available ciktisinda yok)"
  ok "Template: $tmpl"

  # Ag ayarlari
  local net0 net1
  if [ "$MAIN_MODE" = "static" ]; then
    net0="name=eth0,bridge=${BRIDGE},ip=${MAIN_IP},gw=${MAIN_GW}"
  else
    net0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  fi
  net1="name=eth1,bridge=${BRIDGE},tag=${VLAN_TAG},ip=${NET_IP}"

  log "LXC $TARGET_ID olusturuluyor..."
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
    pct create '$TARGET_ID' 'local:vztmpl/${tmpl}' \
      --hostname '$HOSTNAME_' \
      --unprivileged 1 \
      --cores '$CORES' \
      --memory '$MEMORY_MB' \
      --swap '$SWAP_MB' \
      --rootfs '${STORAGE}:${DISK_GB}' \
      --net0 '$net0' \
      --net1 '$net1' \
      --ostype debian

    # DNS ayari (FR-9)
    if [ -n '${AI_DNS:-}' ]; then
      pct set '$TARGET_ID' --nameserver '$AI_DNS'
    fi

    # Host-side mlock prlimit
    CONF='/etc/pve/lxc/${TARGET_ID}.conf'
    if ! grep -q '^lxc.prlimit.memlock' \"\$CONF\" 2>/dev/null; then
      echo 'lxc.prlimit.memlock: unlimited' >> \"\$CONF\"
    fi

    pct start '$TARGET_ID'
  "
  ok "LXC $TARGET_ID baslatildi"
}

target_wait_ready() {
  log "LXC hazir olmasi bekleniyor (komut kabul etme)..."
  local ready=0
  for _ in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec '$TARGET_ID' -- true" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [ "$ready" -eq 1 ] || die "LXC 60 saniye icinde hazir duruma gelmedi"
  ok "LXC $TARGET_ID calisiyor ve komut kabul ediyor"
}

target_exec() {
  if [ $# -gt 0 ]; then
    printf '%s\n' "$*" | ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec '$TARGET_ID' -- bash -s"
  else
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec '$TARGET_ID' -- bash -s"
  fi
}

target_push() {
  local local_file="$1"
  local remote_path="$2"
  local mode="${3:-644}"
  local tmp_remote="/tmp/ai-push-$(basename "$local_file")-$$-$RANDOM"

  scp "${SSH_OPTS[@]}" "$local_file" "root@${PVE_IP}:${tmp_remote}" >/dev/null
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
    pct exec '$TARGET_ID' -- mkdir -p \"\$(dirname '$remote_path')\"
    pct push '$TARGET_ID' '$tmp_remote' '$remote_path'
    pct exec '$TARGET_ID' -- chmod '$mode' '$remote_path'
    rm -f '$tmp_remote'
  " >/dev/null
}

target_destroy() {
  if [ -n "${TARGET_ID:-}" ]; then
    warn "LXC $TARGET_ID durduruluyor ve siliniyor..."
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
      pct stop '$TARGET_ID' 2>/dev/null || true
      pct destroy '$TARGET_ID' --purge 2>/dev/null || true
    " || true
    ok "LXC $TARGET_ID temizlendi"
  fi
}

target_get_ip() {
  if [ "$MAIN_MODE" = "static" ]; then
    echo "${MAIN_IP%%/*}"
  else
    # Dinamik IP'yi pct exec ile ogren
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec '$TARGET_ID' -- ip -4 addr show eth0 | awk '/inet /{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo ""
  fi
}

target_snapshot() {
  local snap_name="${1:-ai-brain-installed}"
  log "LXC $TARGET_ID icin snapshot aliniyor: $snap_name..."
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct snapshot '$TARGET_ID' '$snap_name' --description 'AI-Brain basarili kurulum' 2>/dev/null" || warn "Snapshot alinamadi."
}
