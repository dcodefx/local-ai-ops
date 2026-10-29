#!/usr/bin/env bash
# targets/vm.sh — Proxmox VM (Cloud-Init KVM) Hedef Arka Ucu
# Bu modül Proxmox VE üzerindeki VM şablonundan klonlama, cloud-init ve SSH erişimini sağlar.
#
# DEGISIKLIK (SSH baglanti firtinasi duzeltmesi):
#   Onceki surumde her target_exec/target_push cagrisi, host uzerinden VM'e
#   -o ProxyJump="root@${PVE_IP}" ile YENI bir SSH baglantisi aciyordu. Kurulum
#   onlarca kucuk komut/dosya aktarimi yaptigi icin (ozellikle MCP adiminda,
#   kisa surede art arda) host'un sshd'si kisa surede cok sayida yeni baglanti
#   goruyor ve bir noktada "Connection timed out" ile host'a baglanti
#   kurulamaz hale geliyordu.
#
#   Cozum: host'a giden atlama (jump hop), _common.sh'nin zaten actigi
#   paylasimli ControlMaster soketini (SSH_MASTER_PATH) -o ProxyCommand ile
#   yeniden kullaniyor. Boylece kurulum boyunca host'a kac kez VM'e komut
#   gonderirsek gonderelim, host SADECE TEK bir gercek SSH oturumu goruyor;
#   geri kalan tum trafik bu tek baglanti uzerinden multiplekslenen
#   yonlendirilmis kanallar (direct-tcpip) olarak gidiyor. VM tarafina giden
#   son atlama icin de ayrica kendi ControlMaster'i eklendi.

set -euo pipefail

target_type_name() {
  echo "Proxmox VM (Cloud-Init KVM, CPU: ${AI_VM_CPU_TYPE:-host})"
}

# --- VM'e giden SSH baglantilari icin paylasimli/coklanan secenekler ---
# Her cagrida fonksiyon olarak yeniden kurulur ki PVE_IP/TARGET_ID gibi
# degiskenler henuz atanmamisken kaynak alinsa bile (source sirasinda) sorun
# cikmasin; degerler yalnizca cagri ANINDA okunur.
_vm_control_path() {
  # TARGET_ID henuz atanmamis olabilir (target_resolve_id'den once); PID ile
  # tekil bir yol uretip ayni calismanin tum cagrilarinda tutarli kalmasini
  # sagliyoruz.
  echo "/tmp/ai-brain-ssh-vm-${TARGET_ID:-pid$$}-%r@%h:%p"
}

_vm_ssh_opts() {
  local vm_control_path
  vm_control_path="$(_vm_control_path)"
  cat <<EOF_MARKER_NOT_USED
EOF_MARKER_NOT_USED
  # (Yukaridaki heredoc kullanilmiyor; bash'ta dizi donus degeri olmadigi
  # icin asagida global bir dizi doldurularak kullaniliyor.)
}

# _vm_build_ssh_opts: VM_SSH_OPTS global dizisini doldurur.
# Her cagrida taze kurulur (PVE_IP/ACCESS_USER degismis olabilir diye).
_vm_build_ssh_opts() {
  local vm_control_path jump_control_path proxy_cmd
  vm_control_path="$(_vm_control_path)"
  jump_control_path="${SSH_MASTER_PATH:-/tmp/ai-brain-ssh-%r@%h:%p}"

  # Jump hop (host'a), _common.sh'nin actigi ana soketi paylasir. ControlMaster=auto
  # eklenmesi, eger ana soket herhangi bir nedenle henuz acik degilse bu cagrinin
  # kendisinin onu acmasini saglar (hic baglanti kurulamamasindansa).
  proxy_cmd="ssh -o ControlMaster=auto -o ControlPath=${jump_control_path} -o ControlPersist=300 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %h:%p root@${PVE_IP}"

  VM_SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=15
    -o ControlMaster=auto
    -o "ControlPath=${vm_control_path}"
    -o ControlPersist=300
    -o "ProxyCommand=${proxy_cmd}"
  )
}

# vm_ssh_close_master: VM'e giden paylasimli soketi kapatir (temizlik icin).
# ai-brain.sh'nin genel cleanup() trap'i bunu cagirmasa da ControlPersist=300
# soketi kendiliginden sonlandirir; bu fonksiyon istege bagli erken kapatma icindir.
vm_ssh_close_master() {
  [ -n "${TARGET_ID:-}" ] || return 0
  local vm_control_path="${TARGET_ID}-%r@%h:%p"
  ssh -O exit -o "ControlPath=/tmp/ai-brain-ssh-vm-${vm_control_path}" \
    "${ACCESS_USER:-aibrain}@${VM_TARGET_IP:-127.0.0.1}" 2>/dev/null || true
}

target_resolve_template() {
  local tmpl_id="${AI_VM_TEMPLATE_ID:-}"
  local exists="no"

  if [ -n "$tmpl_id" ]; then
    exists="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "qm status '$tmpl_id' >/dev/null 2>&1 && echo yes || echo no")"
  fi

  if [ "$exists" = "yes" ]; then
    ok "VM Template dogrulandi (ID: $tmpl_id)"
    return 0
  fi

  # Eger ID verilmediyse veya bulunamadiysa, mevcut bir debian-13 template ara
  local discovered_id
  discovered_id="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" \
    "qm list 2>/dev/null | awk 'NR>1 && /template/ && /debian.*13/ {print \$1; exit}' || true")"
  if [ -n "$discovered_id" ]; then
    AI_VM_TEMPLATE_ID="$discovered_id"
    export AI_VM_TEMPLATE_ID
    ok "Proxmox uzerinde hazir Debian 13 template kesfedildi (ID: $AI_VM_TEMPLATE_ID)"
    return 0
  fi

  # Sablon yoksa ve otomatik olusturma aktifse create-vm-template.sh ile olustur
  if [ "${AI_VM_AUTO_CREATE_TEMPLATE:-true}" = "true" ]; then
    warn "Debian 13 Cloud-Init sablonu Proxmox uzerinde bulunamadi."
    log "create-vm-template.sh ile sablon otomatik olusturuluyor..."

    local target_tmpl_vmid="${AI_VM_TEMPLATE_ID:-9000}"
    local tmpl_cmd=("$SCRIPT_DIR/tools/create-vm-template.sh"
      --host "$PVE_IP"
      --distro "${AI_VM_DISTRO:-debian}"
      --version "${AI_VM_VERSION:-13}"
      --vmid "$target_tmpl_vmid"
      --storage "$STORAGE"
      --bridge "$BRIDGE"
      --cpu-type "${AI_VM_CPU_TYPE:-host}"
    )

    if [ -n "${AI_DNS:-}" ]; then
      tmpl_cmd+=(--nameserver "${AI_DNS%% *}")
    fi
    if [ -n "${VLAN_TAG:-}" ]; then
      tmpl_cmd+=(--vlan "$VLAN_TAG")
    fi
    if [ -n "${SSH_PUBKEY_FILE:-}" ] && [ -f "$SSH_PUBKEY_FILE" ]; then
      tmpl_cmd+=(--ssh-pubkey-file "$SSH_PUBKEY_FILE")
    fi
    if [ -n "${ACCESS_USER:-}" ]; then
      tmpl_cmd+=(--ciuser "$ACCESS_USER")
    fi
    if [ "${AI_VM_USE_VIRT_CUSTOMIZE:-false}" = "true" ]; then
      tmpl_cmd+=(--use-virt-customize)
    fi

    log "  -> Komut calistiriliyor: ${tmpl_cmd[*]}"
    "${tmpl_cmd[@]}"

    AI_VM_TEMPLATE_ID="$target_tmpl_vmid"
    export AI_VM_TEMPLATE_ID
    ok "Debian 13 Cloud-Init sablonu olusturuldu (ID: $AI_VM_TEMPLATE_ID)"
  else
    die "VM template bulunamadi ve otomatik olusturma devre disi (AI_VM_AUTO_CREATE_TEMPLATE=false)."
  fi
}

target_check_prereqs() {
  require_pve_ip "$PVE_IP"
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "echo ok" >/dev/null 2>&1 || die "SSH baglantisi kurulamadi: $PVE_IP"

  if [ "${SKIP_VLAN_CHECK:-false}" != "true" ]; then
    local vlan_state
    vlan_state="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" \
      "ip -d link show '$BRIDGE' 2>/dev/null | grep -oE 'vlan_filtering [0-9]' | awk '{print \$2}' || true")"
    if [ "$vlan_state" != "1" ]; then
      die "Bridge '$BRIDGE' VLAN-aware degil (vlan_filtering=${vlan_state:-bulunamadi}).
      Proxmox GUI: Datacenter -> Node -> System -> Network -> $BRIDGE -> 'VLAN aware' isaretle.
      Atlamak icin: --skip-vlan-check"
    fi
  fi

  target_resolve_template
}

target_resolve_id() {
  if [ -z "${CT_ID:-}" ]; then
    CT_ID="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pvesh get /cluster/nextid")"
    log "Otomatik VM ID atandi: $CT_ID"
  fi
  TARGET_ID="$CT_ID"
  export TARGET_ID
}

target_create() {
  target_resolve_id
  log "VM $TARGET_ID klonlama hazirligi (Template: $AI_VM_TEMPLATE_ID)..."

  local exists
  exists="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "qm status '$TARGET_ID' >/dev/null 2>&1 && echo yes || echo no")"
  if [ "$exists" = "yes" ]; then
    if [ "${FORCE:-false}" = "true" ]; then
      warn "VM $TARGET_ID zaten mevcut, --force ile temizleniyor..."
      target_destroy
    else
      die "VM $TARGET_ID zaten mevcut. (--force ile silinebilir veya ID bos birakilabilir)"
    fi
  fi

  local ipconfig0 ipconfig1
  if [ "$MAIN_MODE" = "static" ]; then
    ipconfig0="ip=${MAIN_IP},gw=${MAIN_GW}"
  else
    ipconfig0="ip=dhcp"
  fi
  ipconfig1="ip=${NET_IP}"

  # SSH pubkey'i Proxmox host'a aktar (sshkeys komutu icin gerekli)
  local pubkey_remote=""
  if [ -n "${SSH_PUBKEY_FILE:-}" ] && [ -f "$SSH_PUBKEY_FILE" ]; then
    pubkey_remote="/tmp/ai-pubkey-$$-$RANDOM.pub"
    scp "${SSH_OPTS[@]}" "$SSH_PUBKEY_FILE" "root@${PVE_IP}:${pubkey_remote}" >/dev/null
  elif [ -n "${SSH_PUBKEY_CONTENT:-}" ]; then
    # Pubkey icerik dogrudan verilmis (--ssh-pubkey-file yerine)
    pubkey_remote="/tmp/ai-pubkey-$$-$RANDOM.pub"
    printf '%s\n' "$SSH_PUBKEY_CONTENT" | ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "cat > '$pubkey_remote'"
  fi

  log "VM $TARGET_ID klonlaniyor (Template: $AI_VM_TEMPLATE_ID -> VM: $TARGET_ID, tam klon)..."
  log "  NOT: qm clone --full tam disk kopyasi yapar (~template boyutu kadar veri transfer edilir)"

  # Tum qm komutlarini tek SSH oturumunda calistir
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
    set -e

    echo '[*] qm clone basliyor...'
    qm clone '${AI_VM_TEMPLATE_ID}' '${TARGET_ID}' --name '${HOSTNAME_}' --full 1

    echo '[*] VM ayarlari yapiliyor...'
    qm set '${TARGET_ID}' \
      --cpu '${AI_VM_CPU_TYPE:-host}' \
      --cores '${CORES}' \
      --memory '${MEMORY_MB}' \
      --net0 'virtio,bridge=${BRIDGE}' \
      --net1 'virtio,bridge=${BRIDGE},tag=${VLAN_TAG}' \
      --ipconfig0 '${ipconfig0}' \
      --ipconfig1 '${ipconfig1}' \
      --nameserver '${AI_DNS}' \
      --ciuser '${ACCESS_USER:-aibrain}'

    if [ -n '${pubkey_remote}' ]; then
      qm set '${TARGET_ID}' --sshkeys '${pubkey_remote}'
      rm -f '${pubkey_remote}'
    fi

    # Disk buyutme: template boyutundan daha buyukse resize
    disk_entry=\$(qm config '${TARGET_ID}' 2>/dev/null | grep -E '^(scsi|virtio|ide|sata)0:' | head -1 || true)
    disk_name=\$(echo \"\$disk_entry\" | cut -d: -f1)
    disk_size=\$(echo \"\$disk_entry\" | grep -oE 'size=[0-9]+G' | tr -dc '0-9' || echo 0)
    target_gb='${DISK_GB}'
    if [ -n \"\$target_gb\" ] && [ \"\$target_gb\" != '0' ] && [ -n \"\$disk_name\" ] && [ \"\${disk_size:-0}\" -lt \"\$target_gb\" ] 2>/dev/null; then
      echo '[*] Disk boyutu '\${disk_size}'G -> '\${target_gb}'G olarak buyutuluyor ('\$disk_name')...'
      qm disk resize '${TARGET_ID}' \"\$disk_name\" \"\${target_gb}G\" 2>/dev/null || qm resize '${TARGET_ID}' \"\$disk_name\" \"\${target_gb}G\" 2>/dev/null || true
    fi

    echo '[*] VM baslatiliyor...'
    qm start '${TARGET_ID}'
  "
  ok "VM $TARGET_ID baslatildi"
}

target_get_ip() {
  if [ "$MAIN_MODE" = "static" ]; then
    echo "${MAIN_IP%%/*}"
  else
    # qemu-guest-agent ile IP coz
    local vm_ip=""
    for _ in $(seq 1 15); do
      vm_ip="$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" \
        "qm guest cmd '${TARGET_ID}' network-get-interfaces 2>/dev/null" | \
        grep -oE '"ip-address":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        grep -v '^127\.' | grep -v '^10\.10\.' | head -1 || true)"
      [ -n "$vm_ip" ] && break
      sleep 3
    done
    echo "$vm_ip"
  fi
}

target_wait_ready() {
  log "VM hazir olmasi bekleniyor (SSH ve cloud-init bitisi)..."
  local ip
  ip="$(target_get_ip)"
  [ -n "$ip" ] || die "VM ana ag IP adresi alinamadi (qemu-guest-agent kurulu ve calisiyor mu?)"
  VM_TARGET_IP="$ip"
  export VM_TARGET_IP
  ok "VM IP: $VM_TARGET_IP"

  _vm_build_ssh_opts

  local user="${ACCESS_USER:-aibrain}"
  local ready=0
  log "  -> SSH hazirligini bekleniyor (kullanici: $user, IP: $VM_TARGET_IP, paylasimli baglanti ile)..."
  for _ in $(seq 1 60); do
    if ssh "${VM_SSH_OPTS[@]}" \
        "${user}@${VM_TARGET_IP}" \
        "cloud-init status --wait 2>/dev/null || true; echo ready" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 3
  done
  [ "$ready" -eq 1 ] || die "VM 180 saniye icinde SSH/cloud-init tarafindan hazir edilmedi"
  ok "VM $TARGET_ID SSH erisimine ve komutlara hazir (paylasimli SSH baglantisi kuruldu)"
}

# target_exec: VM'e paylasimli SSH baglantisi uzerinden komut gonder, sudo bash -s ile calistir.
# NOT: ACCESS_USER'in NOPASSWD sudo yetkisi olmalidir (10-base.sh tarafindan ayarlanir).
target_exec() {
  local user="${ACCESS_USER:-aibrain}"
  local ip="${VM_TARGET_IP:-$(target_get_ip)}"
  _vm_build_ssh_opts

  # Kullanici root ise dogrudan calistir, degilse sudo bash -s ile
  local sudo_prefix="sudo"
  if [ "$user" = "root" ]; then
    sudo_prefix=""
  fi

  if [ $# -gt 0 ]; then
    printf '%s\n' "$*" | ssh "${VM_SSH_OPTS[@]}" \
      "${user}@${ip}" \
      "${sudo_prefix:+$sudo_prefix }bash -s"
  else
    ssh "${VM_SSH_OPTS[@]}" \
      "${user}@${ip}" \
      "${sudo_prefix:+$sudo_prefix }bash -s"
  fi
}

target_push() {
  local local_file="$1"
  local remote_path="$2"
  local mode="${3:-644}"
  local user="${ACCESS_USER:-aibrain}"
  local ip="${VM_TARGET_IP:-$(target_get_ip)}"
  local tmp_remote="/tmp/ai-vmpush-$(basename "$local_file")-$$-$RANDOM"
  _vm_build_ssh_opts

  scp "${VM_SSH_OPTS[@]}" \
    "$local_file" "${user}@${ip}:${tmp_remote}" >/dev/null

  ssh "${VM_SSH_OPTS[@]}" \
    "${user}@${ip}" "
      sudo mkdir -p \"\$(dirname '${remote_path}')\"
      sudo mv '${tmp_remote}' '${remote_path}'
      sudo chmod '${mode}' '${remote_path}'
    " >/dev/null
}

target_destroy() {
  if [ -n "${TARGET_ID:-}" ]; then
    warn "VM $TARGET_ID durduruluyor ve siliniyor..."
    vm_ssh_close_master
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "
      qm stop '$TARGET_ID' 2>/dev/null || true
      sleep 2
      qm destroy '$TARGET_ID' --purge 2>/dev/null || true
    " || true
    ok "VM $TARGET_ID temizlendi"
  fi
}

target_snapshot() {
  local snap_name="${1:-ai-brain-installed}"
  log "VM $TARGET_ID icin snapshot aliniyor: $snap_name..."
  ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" \
    "qm snapshot '$TARGET_ID' '$snap_name' --description 'AI-Brain basarili kurulum' 2>/dev/null" \
    || warn "Snapshot alinamadi (disk driver desteklemiyor olabilir)."
}