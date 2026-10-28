#!/bin/bash
# ============================================================
# GPU Laptop - Tek Adımda Model Servisleri ve Switch Aracı Kurulumu/Güncellemesi
# Kullanım: sudo ./install_gpu_services.sh
# Bu betik:
#   - gpu_models.conf dosyasını okur
#   - Her model için systemd servis dosyasını oluşturur/günceller
#   - /usr/local/bin/gpu-model-switch aracını oluşturur/günceller
# ============================================================

set -e

# ---------- KONFİGÜRASYON ----------
CONFIG_FILE="/home/ai-gpu/gpu_models.conf"
MODEL_DIR="/home/ai-gpu/models"
LLAMA_BUILD="/home/ai-gpu/llama.cpp/build"
SERVICE_DIR="/etc/systemd/system"
USER="ai-gpu"
GROUP="ai-gpu"
CUDA_HOME="/opt/cuda-11.7"
DEFAULT_HOST="10.10.10.3"
DEFAULT_GPU_LAYERS=33
DEFAULT_CTX_SIZE=8192
DEFAULT_THREADS=4

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
    local model_name="$1"
    local model_file="$2"
    local port="$3"
    local host="$4"
    local gpu_layers="$5"
    local ctx_size="$6"
    local threads="$7"
    local extra_params="$8"
    local hf_repo_full="$9"

    local service_base=$(get_service_base "$model_name" "$hf_repo_full")
    local service_name="llama-gpu-${service_base}.service"
    local service_path="$SERVICE_DIR/$service_name"
    local full_model_path="$MODEL_DIR/$model_file"

    info "Servis dosyası oluşturuluyor/güncelleniyor: $service_name"
    sudo tee "$service_path" > /dev/null << EOF
[Unit]
Description=Llama.cpp GPU - $model_name (${hf_repo_full%%/*})
After=network.target

[Service]
Type=simple
User=$USER
Group=$GROUP
WorkingDirectory=$LLAMA_BUILD
Environment="LD_LIBRARY_PATH=$CUDA_HOME/lib64:$CUDA_HOME/targets/x86_64-linux/lib"
Environment="PATH=$CUDA_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$LLAMA_BUILD/bin/llama-server \\
  --model $full_model_path \\
  --host $host \\
  --port $port \\
  --n-gpu-layers $gpu_layers \\
  --ctx-size $ctx_size \\
  --threads $threads \\
  --parallel 1 \\
  $extra_params

Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- MODEL DOSYASINI KONTROL ET VE İNDİR (OPSİYONEL) ----------
ensure_model_file() {
    local model_file="$1"
    local hf_repo_full="$2"
    local full_path="$MODEL_DIR/$model_file"
    if [[ ! -f "$full_path" ]]; then
        if [[ -n "$hf_repo_full" ]]; then
            info "Model dosyası eksik, indiriliyor: $hf_repo_full/$model_file"
            mkdir -p "$MODEL_DIR"
            if command -v hf &>/dev/null; then
                hf download "$hf_repo_full" "$model_file" --local-dir "$MODEL_DIR" --local-dir-use-symlinks False
            else
                warn "hf komutu bulunamadı. 'pipx install huggingface_hub[cli]' kurmayı deneyin."
            fi
        else
            warn "HF repo belirtilmemiş, model indirilemedi: $model_file"
        fi
    else
        info "Model dosyası mevcut: $full_path"
    fi
}

# ---------- ANA İŞLEM ----------
main() {
    info "Konfigürasyon dosyası okunuyor: $CONFIG_FILE"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Konfigürasyon dosyası bulunamadı: $CONFIG_FILE"
    fi

    # Modelleri toplamak için diziler
    declare -a service_bases
    declare -a model_names
    declare -a model_files
    declare -a ports
    declare -a hosts
    declare -a gpu_layers_arr
    declare -a ctx_sizes
    declare -a threads_arr
    declare -a hf_repos
    declare -a extra_params_arr

    # Geçici değişkenler
    current_model=""
    current_model_file=""
    current_port=""
    current_host="$DEFAULT_HOST"
    current_gpu_layers="$DEFAULT_GPU_LAYERS"
    current_ctx_size="$DEFAULT_CTX_SIZE"
    current_threads="$DEFAULT_THREADS"
    current_hf_repo=""
    current_extra_params=""

    while IFS=: read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            model_adı)
                # Önceki modeli kaydet (varsa)
                if [[ -n "$current_model" ]]; then
                    model_names+=("$current_model")
                    model_files+=("$current_model_file")
                    ports+=("$current_port")
                    hosts+=("$current_host")
                    gpu_layers_arr+=("$current_gpu_layers")
                    ctx_sizes+=("$current_ctx_size")
                    threads_arr+=("$current_threads")
                    hf_repos+=("$current_hf_repo")
                    extra_params_arr+=("$current_extra_params")
                    service_bases+=("$(get_service_base "$current_model" "$current_hf_repo")")
                fi
                # Yeni model başlat
                current_model="$value"
                current_model_file=""
                current_port=""
                current_host="$DEFAULT_HOST"
                current_gpu_layers="$DEFAULT_GPU_LAYERS"
                current_ctx_size="$DEFAULT_CTX_SIZE"
                current_threads="$DEFAULT_THREADS"
                current_hf_repo=""
                current_extra_params=""
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
            gpu_katman)
                current_gpu_layers="$value"
                ;;
            ctx_size)
                current_ctx_size="$value"
                ;;
            threads)
                current_threads="$value"
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
    if [[ -n "$current_model" ]]; then
        model_names+=("$current_model")
        model_files+=("$current_model_file")
        ports+=("$current_port")
        hosts+=("$current_host")
        gpu_layers_arr+=("$current_gpu_layers")
        ctx_sizes+=("$current_ctx_size")
        threads_arr+=("$current_threads")
        hf_repos+=("$current_hf_repo")
        extra_params_arr+=("$current_extra_params")
        service_bases+=("$(get_service_base "$current_model" "$current_hf_repo")")
    fi

    # Her model için servis oluştur/güncelle ve model dosyasını kontrol et
    for idx in "${!model_names[@]}"; do
        create_systemd_service \
            "${model_names[$idx]}" \
            "${model_files[$idx]}" \
            "${ports[$idx]}" \
            "${hosts[$idx]}" \
            "${gpu_layers_arr[$idx]}" \
            "${ctx_sizes[$idx]}" \
            "${threads_arr[$idx]}" \
            "${extra_params_arr[$idx]}" \
            "${hf_repos[$idx]}"

        ensure_model_file "${model_files[$idx]}" "${hf_repos[$idx]}"
    done

    sudo systemctl daemon-reload
    info "Tüm servis dosyaları oluşturuldu/güncellendi."

    # ---------- GPU-MODEL-SWITCH KOMUTUNU OLUŞTUR ----------
    SWITCH_SCRIPT="/usr/local/bin/gpu-model-switch"
    info "Oluşturuluyor: $SWITCH_SCRIPT"

    # Dinamik model listesi için bash kodu üret
    local dynamic_list=""
    for idx in "${!service_bases[@]}"; do
        local base="${service_bases[$idx]}"
        local port="${ports[$idx]}"
        local model="${model_names[$idx]}"
        local provider="${hf_repos[$idx]%%/*}"
        dynamic_list+="MODELS[\"$base\"]=\"$model ($provider)\"\n"
        dynamic_list+="MODEL_PORTS[\"$base\"]=\"$port\"\n"
    done

    sudo tee "$SWITCH_SCRIPT" > /dev/null << SWITCH_EOF
#!/bin/bash
# ============================================================
# GPU Model Switch - Otomatik oluşturulmuştur (gpu_models.conf tabanlı)
# Kullanım: gpu-model-switch {list|status|switch <service_base>}
# ============================================================

# Dinamik model listesi (otomatik oluşturuldu)
declare -A MODELS
declare -A MODEL_PORTS
$(echo -e "$dynamic_list")

# Renkler
info() { echo -e "\e[32m[INFO]\e[0m \$1"; }
warn() { echo -e "\e[33m[WARN]\e[0m \$1"; }
error() { echo -e "\e[31m[ERROR]\e[0m \$1"; exit 1; }

# Tüm GPU servislerini durdur (llama-gpu-*)
stop_all_gpu_services() {
    local any_stopped=false
    for svc in \$(systemctl list-unit-files --type=service | grep 'llama-gpu-' | awk '{print \$1}'); do
        if systemctl is-active --quiet "\$svc"; then
            sudo systemctl stop "\$svc"
            info "Durduruldu: \$svc"
            any_stopped=true
        fi
    done
    if [[ "\$any_stopped" == false ]]; then
        info "Zaten çalışan GPU servisi yok."
    fi
}

# Belirli bir servisi başlat (service_base ile)
start_service_by_base() {
    local base="\$1"
    local svc="llama-gpu-\${base}.service"
    if [[ ! -f "/etc/systemd/system/\$svc" ]]; then
        error "Servis dosyası bulunamadı: \$svc"
    fi
    sudo systemctl start "\$svc"
    info "Başlatıldı: \$svc (port \${MODEL_PORTS[\$base]})"
}

# Tüm servislerin durumunu göster
show_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   GPU Modelleri Durumu                               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    for base in "\${!MODELS[@]}"; do
        local svc="llama-gpu-\${base}.service"
        local state=\$(systemctl is-active "\$svc" 2>/dev/null || echo "inactive")
        local port="\${MODEL_PORTS[\$base]}"
        if [[ "\$state" == "active" ]]; then
            echo "  ✅ AKTIF   : \$base (\${MODELS[\$base]}) [port \$port]"
        else
            echo "  ❌ DURMUS  : \$base (\${MODELS[\$base]}) [port \$port]"
        fi
    done
    echo ""
}

# Modelleri listele
list_models() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Kullanılabilir GPU Modelleri                       ║"
    echo "╚══════════════════════════════════════════════════════╝"
    for base in "\${!MODELS[@]}"; do
        echo "  - \$base (\${MODELS[\$base]}) -> port \${MODEL_PORTS[\$base]}"
    done
    echo ""
}

# Geçiş yap: tümünü durdur, sadece seçileni başlat
switch_to() {
    local target="\$1"
    if [[ -z "\${MODELS[\$target]}" ]]; then
        error "Geçersiz model: \$target. Mevcut modeller: \${!MODELS[*]}"
    fi
    info "Tüm GPU servisleri durduruluyor..."
    stop_all_gpu_services
    sleep 1
    info "\${MODELS[\$target]} başlatılıyor..."
    start_service_by_base "\$target"
    echo ""
    show_status
}

# Kullanım
usage() {
    echo "Kullanım: gpu-model-switch {list|status|switch <model_base>}"
    echo ""
    echo "  list               : Tüm modelleri listele"
    echo "  status             : Tüm servislerin durumunu göster"
    echo "  switch <model>     : Belirtilen modele geç (diğerlerini durdur)"
    echo ""
    echo "Örnek: gpu-model-switch switch qwen3.5-4b-jackrong"
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
            error "switch komutu için model adı gerekli."
        fi
        switch_to "\$2"
        ;;
    *)
        usage
        ;;
esac
SWITCH_EOF

    sudo chmod +x "$SWITCH_SCRIPT"
    info "Model switch komutu oluşturuldu: $SWITCH_SCRIPT"
    info "Kullanım: 'gpu-model-switch list', 'status', 'switch <service_base>'"
}

# ---------- SADECE DOĞRUDAN ÇALIŞTIRMA ----------
if [[ $EUID -ne 0 ]]; then
    error "Root yetkisi gerekli. 'sudo' ile çalıştırın."
fi

# Argümansız çalıştırıldığını varsay
main