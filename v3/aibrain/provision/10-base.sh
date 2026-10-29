#!/usr/bin/env bash
# provision/10-base.sh — Temel isletim sistemi paketleri, DNS ve erisim
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[1/6] Temel paketler, DNS ve yerel ayarlar yapilandiriliyor..."

# 1. DNS dogrulamasi (FR-9)
log "  -> DNS ve internet erisimi dogrulaniyor..."
if ! target_exec "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1"; then
  warn "Target dis ag gecidine ulasamiyor olabilir. Ag yapilandirmasini kontrol ediniz."
fi

# 2. apt guncelleme, disk genisletme ve paket kurulumu
log "  -> apt paketleri guncelleniyor ve disk genisletiliyor..."
target_exec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # 1. Disk ve bolum genisletme (VM/LXC disk buyutuldugunde kok dosya sistemine yansit)
  if ! command -v growpart >/dev/null 2>&1; then
    apt-get install -y -qq cloud-guest-utils >/dev/null 2>&1 || true
  fi

  ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [ -b "$ROOT_SRC" ]; then
    DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
    PART_NUM="$(lsblk -no PARTN "$ROOT_SRC" 2>/dev/null || true)"
    FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || echo ext4)"

    if [ -n "$DISK_NAME" ] && [ -n "$PART_NUM" ]; then
      growpart "/dev/$DISK_NAME" "$PART_NUM" 2>/dev/null || true
    fi

    if [ "$FSTYPE" = "xfs" ]; then
      xfs_growfs / 2>/dev/null || true
    else
      resize2fs "$ROOT_SRC" 2>/dev/null || true
    fi
  fi

  # 2. Temel paketlerin kurulumu
  apt-get -o Dpkg::Options::=--force-confold upgrade -y -qq
  apt-get install -y -qq \
    build-essential cmake git curl wget \
    python3 python3-pip python3-venv \
    htop tmux net-tools locales sudo openssh-server \
    cloud-guest-utils

  # LC_* uyarilarini onlemek icin en_US.UTF-8
  sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
  update-locale LANG=en_US.UTF-8
'
disk_info="$(target_exec "df -h / | awk 'NR==2{print \$2 \" (Kullanilabilir: \" \$4 \")\"}'")"
ok "Disk ve dosya sistemi genisletildi: $disk_info"
ok "Temel paketler ve locale kuruldu"

# 3. /data dizin sozlesmesi (NFR-7)
log "  -> /data ve model dizinleri olusturuluyor (chmod 775)..."
target_exec '
  mkdir -p /data/models /data/engines /etc/ai-brain /opt/ai_engine /opt/litellm
  chmod 775 /data /data/models /data/engines
'
ok "Dizinler hazirlandi"

# 4. Erisim kullanicisi (SETUP_ACCESS)
if [ "${SETUP_ACCESS:-false}" = "true" ]; then
  local_user="${ACCESS_USER:-aibrain}"
  log "  -> Erisim kullanicisi yapilandiriliyor: $local_user"

  target_exec "
    if ! id '$local_user' >/dev/null 2>&1; then
      useradd -m -s /bin/bash -G sudo '$local_user'
    fi
    # NOPASSWD sudo - provision sirasinda gerekli (VM hedefi icin ozellikle)
    echo '${local_user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ai-brain-provision
    chmod 440 /etc/sudoers.d/ai-brain-provision
  "

  if [ -z "${ACCESS_PASSWORD:-}" ]; then
    ACCESS_PASSWORD="$(openssl rand -base64 18)"
    export ACCESS_PASSWORD
  fi

  # Parola: ozel karakter guvenli olmasi icin heredoc ile aktar
  # sed yerine chpasswd'yi dogrudan stdin'den besle; ozel karakterler shell expansion'dan korumak icin printf kullan
  printf '%s:%s\n' "$local_user" "$ACCESS_PASSWORD" | target_exec "chpasswd"
  ok "Kullanici '$local_user' sifresi ayarlandi"

  if [ -n "${SSH_PUBKEY_CONTENT:-}" ]; then
    target_exec "
      mkdir -p /home/${local_user}/.ssh
      chmod 700 /home/${local_user}/.ssh
    "
    tmp_key="$(mktemp)"
    chmod 600 "$tmp_key"
    printf '%s\n' "$SSH_PUBKEY_CONTENT" > "$tmp_key"
    target_push "$tmp_key" "/home/${local_user}/.ssh/authorized_keys" 600
    rm -f "$tmp_key"

    target_exec "
      chown -R ${local_user}:${local_user} /home/${local_user}/.ssh

      # sshd_config: PasswordAuthentication no
      if grep -q '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      else
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
      fi

      # sshd_config: PermitRootLogin
      if grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
      else
        echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
      fi

      systemctl reload-or-restart ssh >/dev/null 2>&1 || systemctl reload-or-restart sshd >/dev/null 2>&1 || true
    "
    ok "SSH pubkey yetkilendirildi (parola ile SSH kapali)"
  fi
fi

ok "[1/6] Base provision tamamlandi."
