#!/bin/bash
# ============================================================
# CPU Sunucusu (Proxmox LXC Debian) - Model Servisleri ve Switch Aracı
# Kullanım: ./install_cpu_services.sh
# Bu betik:
#   - /data/cpu_models.conf dosyasını okur
#   - Her model için systemd servis dosyasını oluşturur/günceller
#   - /usr/local/bin/cpu-model-switch aracını oluşturur/günceller
# ============================================================

set -e

# ---------- KONFİGÜRASYON ----------
CONFIG_FILE="/data/cpu_models.conf"
MODEL_DIR="/data/models"
LLAMA_BUILD="/opt/llama.cpp/build"
SERVICE_DIR="/etc/systemd/system"
DEFAULT_HOST="127.0.0.1"
DEFAULT_CTX_SIZE=8192
DEFAULT_THREADS=4
DEFAULT_THREADS_BATCH=4

# ---------- RENKLER ----------
info() { echo -e "\e[32m[INFO]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ---------- YARDIMCI FONKSİYONLAR ----------
# service_base = model_adı-sağlayıcı (sağlayıcı hf_repo'nun ilk bileşeni)
get_service_base() {
    local model_name="$1"
    local hf_repo_full="$2"
    local provider="${hf_repo_full%%/*}"
    echo "${model_name}-${provider}"
}

# ---------- SYSTEMD SERVİS DOSYASI OLUŞTUR/GÜNCELLE ----------
create_systemd_service() {
    local alias="$1"
    local model_name="$2"
    local model_file="$3"
    local port="$4"
    local host="$5"
    local ctx_size="$6"
    local threads="$7"
    local threads_batch="$8"
    local extra_params="$9"
    local hf_repo_full="${10}"

    local service_base=$(get_service_base "$model_name" "$hf_repo_full")
    local service_name="llama-cpu-${service_base}.service"
    local service_path="$SERVICE_DIR/$service_name"
    local full_model_path="$MODEL_DIR/$model_file"

    info "Servis dosyası oluşturuluyor/güncelleniyor: $service_name (alias: $alias)"
    tee "$service_path" > /dev/null << EOF
[Unit]
Description=llama.cpp CPU - $model_name ($alias)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$LLAMA_BUILD

# Proxmox Host'tan gelen mlock iznini sisteme geçirir
LimitMEMLOCK=infinity

# Tam kararlılık için her modelde zorunlu olan altyapı parametreleri
ExecStart=$LLAMA_BUILD/bin/llama-server \
  --model $full_model_path \
  --host $host \
  --port $port \
  --ctx-size $ctx_size \
  --threads $threads \
  --threads-batch $threads_batch \
  --parallel 1 \
  --batch-size 2048 \
  --ubatch-size 256 \
  --timeout 600 \
  --mlock \
  $extra_params

Restart=on-failure
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- MODEL DOSYASINI KONTROL ET (OPSİYONEL UYARI) ----------
check_model_file() {
    local model_file="$1"
    local hf_repo_full="$2"
    local full_path="$MODEL_DIR/$model_file"
    if [[ ! -f "$full_path" ]]; then
        warn "Model dosyası bulunamadı: $full_path"
        if [[ -n "$hf_repo_full" ]]; then
            warn "İndirmek için: hf download $hf_repo_full $model_file --local-dir $MODEL_DIR"
        else
            warn "İndirmek için: hf download <repo> $model_file --local-dir $MODEL_DIR"
        fi
    else
        info "Model dosyası mevcut: $full_path"
    fi
}

# ---------- ANA İŞLEM: KONFİGÜRASYONU OKU, SERVİSLERİ OLUŞTUR, SWITCH ARACINI YAZ ----------
main() {
    info "Konfigürasyon dosyası okunuyor: $CONFIG_FILE"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Konfigürasyon dosyası bulunamadı: $CONFIG_FILE"
    fi

    # Modelleri toplamak için diziler
    declare -a aliases
    declare -a service_bases
    declare -a model_names
    declare -a ports
    declare -a hosts
    declare -a ctx_sizes
    declare -a threads_arr
    declare -a threads_batch_arr
    declare -a extra_params_arr
    declare -a hf_repos
    declare -a model_files

    # Geçici değişkenler
    current_alias=""
    current_model_name=""
    current_model_file=""
    current_port=""
    current_host="$DEFAULT_HOST"
    current_ctx_size="$DEFAULT_CTX_SIZE"
    current_threads="$DEFAULT_THREADS"
    current_threads_batch="$DEFAULT_THREADS_BATCH"
    current_hf_repo=""
    current_extra_params=""

    while IFS=: read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            alias)
                # Önceki modeli kaydet (varsa)
                if [[ -n "$current_alias" ]]; then
                    aliases+=("$current_alias")
                    model_names+=("$current_model_name")
                    model_files+=("$current_model_file")
                    ports+=("$current_port")
                    hosts+=("$current_host")
                    ctx_sizes+=("$current_ctx_size")
                    threads_arr+=("$current_threads")
                    threads_batch_arr+=("$current_threads_batch")
                    hf_repos+=("$current_hf_repo")
                    extra_params_arr+=("$current_extra_params")
                    service_bases+=("$(get_service_base "$current_model_name" "$current_hf_repo")")
                fi
                # Yeni model başlat
                current_alias="$value"
                current_model_name=""
                current_model_file=""
                current_port=""
                current_host="$DEFAULT_HOST"
                current_ctx_size="$DEFAULT_CTX_SIZE"
                current_threads="$DEFAULT_THREADS"
                current_threads_batch="$DEFAULT_THREADS_BATCH"
                current_hf_repo=""
                current_extra_params=""
                ;;
            model_adı)
                current_model_name="$value"
                ;;
            model_dosya)
                current_model_file="$value"
                ;;
            port)
                current_port="$value"
                ;;
            host)
                current_host="$value"
                ;;
            ctx_size)
                current_ctx_size="$value"
                ;;
            threads)
                current_threads="$value"
                ;;
            threads_batch)
                current_threads_batch="$value"
                ;;
            hf_repo)
                current_hf_repo="$value"
                ;;
            extra_params)
                current_extra_params="$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    # Son modeli ekle
    if [[ -n "$current_alias" ]]; then
        aliases+=("$current_alias")
        model_names+=("$current_model_name")
        model_files+=("$current_model_file")
        ports+=("$current_port")
        hosts+=("$current_host")
        ctx_sizes+=("$current_ctx_size")
        threads_arr+=("$current_threads")
        threads_batch_arr+=("$current_threads_batch")
        hf_repos+=("$current_hf_repo")
        extra_params_arr+=("$current_extra_params")
        service_bases+=("$(get_service_base "$current_model_name" "$current_hf_repo")")
    fi

    # Her model için servis oluştur/güncelle ve model dosyasını kontrol et
    for idx in "${!aliases[@]}"; do
        create_systemd_service \
            "${aliases[$idx]}" \
            "${model_names[$idx]}" \
            "${model_files[$idx]}" \
            "${ports[$idx]}" \
            "${hosts[$idx]}" \
            "${ctx_sizes[$idx]}" \
            "${threads_arr[$idx]}" \
            "${threads_batch_arr[$idx]}" \
            "${extra_params_arr[$idx]}" \
            "${hf_repos[$idx]}"

        check_model_file "${model_files[$idx]}" "${hf_repos[$idx]}"
    done

    systemctl daemon-reload
    info "Tüm servis dosyaları oluşturuldu/güncellendi."

    # ---------- CPU-MODEL-SWITCH KOMUTUNU OLUŞTUR ----------
    SWITCH_SCRIPT="/usr/local/bin/cpu-model-switch"
    info "Oluşturuluyor: $SWITCH_SCRIPT"

    # Dinamik alias -> service_base ve port mapping
    local alias_map=""
    local base_map=""
    for idx in "${!aliases[@]}"; do
        local alias="${aliases[$idx]}"
        local base="${service_bases[$idx]}"
        local port="${ports[$idx]}"
        local name="${model_names[$idx]}"
        alias_map+="ALIAS_TO_BASE[\"$alias\"]=\"$base\"\n"
        alias_map+="ALIAS_TO_PORT[\"$alias\"]=\"$port\"\n"
        alias_map+="ALIAS_TO_NAME[\"$alias\"]=\"$name\"\n"
        base_map+="BASE_TO_ALIAS[\"$base\"]=\"$alias\"\n"
    done

    tee "$SWITCH_SCRIPT" > /dev/null << SWITCH_EOF
#!/bin/bash
# ============================================================
# CPU Model Switch - Otomatik oluşturulmuştur (cpu_models.conf tabanlı)
# Kullanım: cpu-model-switch {list|status|switch <alias>}
# ============================================================

# Dinamik veriler
declare -A ALIAS_TO_BASE
declare -A ALIAS_TO_PORT
declare -A ALIAS_TO_NAME
declare -A BASE_TO_ALIAS
$(echo -e "$alias_map")
$(echo -e "$base_map")

# Renkler
info() { echo -e "\e[32m[INFO]\e[0m \$1"; }
warn() { echo -e "\e[33m[WARN]\e[0m \$1"; }
error() { echo -e "\e[31m[ERROR]\e[0m \$1"; exit 1; }

# Tüm CPU servislerini durdur (llama-cpu-*)
stop_all_cpu_services() {
    local any_stopped=false
    for svc in \$(systemctl list-unit-files --type=service | grep 'llama-cpu-' | awk '{print \$1}'); do
        if systemctl is-active --quiet "\$svc"; then
            systemctl stop "\$svc"
            info "Durduruldu: \$svc"
            any_stopped=true
        fi
    done
    if [[ "\$any_stopped" == false ]]; then
        info "Zaten çalışan CPU servisi yok."
    fi
}

# Belirli bir servisi başlat (alias ile)
start_service_by_alias() {
    local alias="\$1"
    local base="\${ALIAS_TO_BASE[\$alias]}"
    if [[ -z "\$base" ]]; then
        error "Geçersiz alias: \$alias"
    fi
    local svc="llama-cpu-\${base}.service"
    if [[ ! -f "/etc/systemd/system/\$svc" ]]; then
        error "Servis dosyası bulunamadı: \$svc"
    fi
    systemctl start "\$svc"
    info "Başlatıldı: \$alias (\${ALIAS_TO_NAME[\$alias]}) [port \${ALIAS_TO_PORT[\$alias]}]"
}

# Tüm servislerin durumunu göster (alias bazlı)
show_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  CPU Model Servisleri Durumu                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    for alias in "\${!ALIAS_TO_BASE[@]}"; do
        local base="\${ALIAS_TO_BASE[\$alias]}"
        local svc="llama-cpu-\${base}.service"
        local state=\$(systemctl is-active "\$svc" 2>/dev/null || echo "inactive")
        local port="\${ALIAS_TO_PORT[\$alias]}"
        if [[ "\$state" == "active" ]]; then
            echo "  ✅ AKTIF   : \$alias (\${ALIAS_TO_NAME[\$alias]}) [port \$port]"
        else
            echo "  ❌ DURMUS  : \$alias (\${ALIAS_TO_NAME[\$alias]}) [port \$port]"
        fi
    done
    echo ""
}

# Modelleri listele
list_models() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  Kullanılabilir CPU Modelleri (alias -> port)                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    for alias in "\${!ALIAS_TO_BASE[@]}"; do
        echo "  - \$alias -> \${ALIAS_TO_NAME[\$alias]} (port \${ALIAS_TO_PORT[\$alias]})"
    done
    echo ""
}

# Geçiş yap: tümünü durdur, sadece seçileni başlat
switch_to() {
    local target="\$1"
    if [[ -z "\${ALIAS_TO_BASE[\$target]}" ]]; then
        error "Geçersiz alias: \$target. Mevcut alias'lar: \${!ALIAS_TO_BASE[*]}"
    fi
    info "Tüm CPU servisleri durduruluyor..."
    stop_all_cpu_services
    sleep 1
    info "\${ALIAS_TO_NAME[\$target]} başlatılıyor..."
    start_service_by_alias "\$target"
    echo ""
    show_status
}

# Kullanım
usage() {
    echo "Kullanım: cpu-model-switch {list|status|switch <alias>}"
    echo ""
    echo "  list               : Tüm modelleri listele"
    echo "  status             : Tüm servislerin durumunu göster"
    echo "  switch <alias>     : Belirtilen modele geç (diğerlerini durdur)"
    echo ""
    echo "Örnek: cpu-model-switch switch qwen3-30b"
    exit 1
}

# Ana komut işleme
case "\$1" in
    list)
        list_models
        ;;
    status)
        show_status
        ;;
    switch)
        if [[ -z "\$2" ]]; then
            error "switch komutu için alias gerekli."
        fi
        switch_to "\$2"
        ;;
    *)
        usage
        ;;
esac
SWITCH_EOF

    chmod +x "$SWITCH_SCRIPT"
    info "CPU model switch komutu oluşturuldu: $SWITCH_SCRIPT"
    info "Kullanım: 'cpu-model-switch list', 'status', 'switch <alias>'"
}

# ---------- SADECE DOĞRUDAN ÇALIŞTIRMA ----------
if [[ $EUID -ne 0 ]]; then
    error "Root yetkisi gerekli. 'sudo' ile çalıştırın."
fi

main

