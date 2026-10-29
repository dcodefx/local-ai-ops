#!/usr/bin/env bash
# install_cpu_services.sh
#
# cpu_models.conf'u okuyup her model icin systemd servisi ve cpu-model-switch
# aracini uretir. LXC ICINDE calisir.
#
# OZELLIKLER VE IYILESTIRMELER:
#   - Standart Root Kontrolu: Auto-sudo yapmaz, root degilse net hata verip durur.
#   - Zorunlu ve Opsiyonel Alanlar: alias, model_adi, model_dosya, hf_repo zorunlu;
#     port opsiyoneldir (girilmezse varsayilan 8080 atanir).
#   - Akilli Duplicate Tespiti: Alias çakışmaları engellenir. Özel girilen portlar
#     çakışırsa uyarır; varsayılan port (8080) ortak kullanıma izin verir.
#   - xargs Temizligi: Yorum satırlarındaki tırnak/kesme işaretlerinden etkilenmemek
#     için xargs yerine sed kullanılmıştır.
#   - Eksik Model Indirme Uyarisi: Model dosyasi eksikse 'hf download' komutunu uretir.
#   - Gelismis cpu-model-switch: 'list', 'status', 'switch' ve 'stop' komutlarini barindirir.
#   - TimeoutStartSec 600: Buyuk modellerin --mlock ile RAM'e yüklenmesi icin guvenli pay.
#   - Modular Engine: llama-server binary yolu payload/engines/<isim>.sh profillerinden
#     okunur (bkz load_engine()). 'engine:' alani verilmezse "stock" kullanilir.
#   - mmproj / draft (speculative decoding) destegi: vision-language modeller icin
#     mmproj_dosya, speculative decoding icin draft_dosya alanlari - verilirse hem
#     indirme talimati uretilir hem de ExecStart'a --mmproj / -md flag'i otomatik eklenir.
#   - spec_type destegi (DFlash, MTP vb.): opsiyonel 'spec_type:' alani verilirse ExecStart'a
#     "--spec-type <deger>" eklenir. DFlash, draft_dosya ile ayni mantiktir - ayri alan yok:
#         draft_dosya:<dflash.gguf>   draft_repo:<repo>   spec_type:draft-dflash
#     (upstream llama.cpp: draft-dflash; bazi fork'lar: dflash). draft_dosya olmadan da
#     kullanilabilir (ör. spec_type:draft-mtp - harici draft dosyasi gerektirmeyen turler).
#   - extra_params temizligi: spec_type verilmisse extra_params icindeki elle yazilmis
#     --spec-type, draft_dosya verilmisse -md / --model-draft / --spec-draft-model
#     bayraklari UYARIYLA cikarilir (cift bayrak uretilmesin diye). spec_type/draft_dosya
#     verilmemisse extra_params'a dokunulmaz (geriye uyumluluk).


set -euo pipefail

# --- DEGISKENLER ---
CONFIG_FILE="${1:-/data/cpu_models.conf}"
ENGINES_DIR="${2:-/data/engines}"
MODEL_DIR="/data/models"
SWITCH_SCRIPT="/usr/local/bin/cpu-model-switch"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_PORT="8080"
DEFAULT_ENGINE="stock"

mkdir -p "$MODEL_DIR"
chmod 777 "$MODEL_DIR" 2>/dev/null || true

# --- RENKLER VE LOG FONKSIYONLARI ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
info()  { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[UYARI]${C_RESET} $*" >&2; }
error() { echo -e "${C_RED}[HATA]${C_RESET} $*" >&2; exit 1; }

# --- STANDART ROOT KONTROLU (Auto-sudo yok) ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  error "Bu script root yetkisi gerektirir. Lutfen 'sudo ./install_cpu_services.sh' seklinde calistirin."
fi

[ -f "$CONFIG_FILE" ] || error "Config dosyasi bulunamadi: $CONFIG_FILE"
[ -d "$ENGINES_DIR" ] || error "Engine profil dizini bulunamadi: $ENGINES_DIR (ai-brain-lxc.sh payload/engines/'i yerlestirmis olmali)"

# --- ENGINE PROFILI YUKLEME (cache'li - ayni engine birden fazla blokta kullanilsa da tek sefer source edilir) ---
declare -A ENGINE_BIN_CACHE
declare -A ENGINE_WORKDIR_CACHE

load_engine() {
  local engine="$1"
  local profile="$ENGINES_DIR/${engine}.sh"

  if [ -n "${ENGINE_BIN_CACHE[$engine]:-}" ]; then
    return 0   # zaten yuklenmis
  fi

  [ -f "$profile" ] || error "Bilinmeyen engine '$engine': $profile bulunamadi (payload/engines/ altina bak)"

  # profil dosyasi sadece degisken tanimlar (ENGINE_LLAMA_BIN, ENGINE_WORKDIR, ...), guvenle source edilir
  # shellcheck source=/dev/null
  source "$profile"

  [ -n "${ENGINE_LLAMA_BIN:-}" ] || error "Engine profili hatali ($profile): ENGINE_LLAMA_BIN tanimli degil"

  ENGINE_BIN_CACHE["$engine"]="$ENGINE_LLAMA_BIN"
  ENGINE_WORKDIR_CACHE["$engine"]="${ENGINE_WORKDIR:-$(dirname "$ENGINE_LLAMA_BIN")}"

  if [ ! -x "$ENGINE_LLAMA_BIN" ]; then
    warn "llama-server bulunamadi ($engine): $ENGINE_LLAMA_BIN (once bu engine derlenmeli, servis yine de uretilecek)"
  fi

  # her sonraki cagrida ayni degiskenlerin baska bir profilden sizmasini onlemek icin temizle
  unset ENGINE_NAME ENGINE_DESCRIPTION ENGINE_REPO_URL ENGINE_CLONE_DIR ENGINE_CMAKE_FLAGS ENGINE_LLAMA_BIN ENGINE_WORKDIR
}

# --- MODEL DOSYASI KONTROLU VE INDIRME TALIMATI ---
check_model_file() {
  local model_file="$1"
  local hf_repo="$2"
  local path="$MODEL_DIR/$model_file"
  if [ ! -f "$path" ]; then
    warn "Model dosyasi henuz yok: $path"
    if [ -n "$hf_repo" ]; then
      warn "Indirmek icin: hf download $hf_repo $model_file --local-dir $MODEL_DIR"
    else
      warn "Indirmek icin: hf download <repo> $model_file --local-dir $MODEL_DIR"
    fi
  else
    info "Model dosyasi mevcut: $path"
  fi
}

get_service_base() {
  local model_name="$1" hf_repo_full="$2"
  local provider="${hf_repo_full%%/*}"
  echo "${model_name}-${provider}"
}

# --- extra_params ICINDEKI BELIRLI BAYRAKLAR ---
# has_flag  <string> <bayrak-regex>  -> bayrak string'de "bayrak deger" ya da "bayrak=deger" olarak geciyorsa 0 doner
# strip_flag <string> <bayrak-regex> -> o bayragi ve degerini string'den cikarip kalani yazar
FLAG_BOUNDARY='(^|[[:space:]])'
has_flag() {
  local str="$1" flags="$2"
  [[ "$str" =~ ${FLAG_BOUNDARY}(${flags})([[:space:]=]|$) ]]
}
strip_flag() {
  local str="$1" flags="$2"
  echo "$str" \
    | sed -E "s/(^|[[:space:]])(${flags})([[:space:]]+|=)[^[:space:]]+//g" \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

SPEC_FLAGS='--spec-type'
DRAFT_FLAGS='-md|--model-draft|--spec-draft-model'

# --- ZORUNLU VE OPSIYONEL ALAN DOGRULAMA ---
validate_block() {
  local ctx="$1" alias="$2" model_name="$3" model_file="$4" port="$5" hf_repo="$6"
  local missing=()
  [ -n "$alias" ]      || missing+=("alias")
  [ -n "$model_name" ] || missing+=("model_adı")
  [ -n "$model_file" ] || missing+=("model_dosya")
  [ -n "$hf_repo" ]    || missing+=("hf_repo")

  if [ ${#missing[@]} -gt 0 ]; then
    error "Config hatasi ($ctx): eksik zorunlu alan(lar): ${missing[*]}"
  fi

  # Port elle girilmis ise sayisal kontrol yapilir
  if [ -n "$port" ] && ! [[ "$port" =~ ^[0-9]+$ ]]; then
    error "Config hatasi ($ctx, alias=$alias): port sayisal olmali, gelen deger: '$port'"
  fi
}

declare -A ALIAS_TO_BASE
declare -A ALIAS_TO_MODEL
declare -A ALIAS_TO_PORT
declare -A SEEN_ALIASES
declare -A SEEN_CUSTOM_PORTS
SERVICES_CREATED=()

current_alias=""; current_model_name=""; current_model_file=""; current_port=""
current_ctx_size="4096"; current_threads="4"; current_threads_batch="4"
current_hf_repo=""; current_extra_params=""; current_engine=""
current_mmproj_dosya=""; current_mmproj_repo=""
current_draft_dosya=""; current_draft_repo=""
current_spec_type=""
block_index=0

process_block() {
  [ -z "$current_alias" ] && return
  block_index=$((block_index + 1))
  local ctx="blok #$block_index"

  validate_block "$ctx" "$current_alias" "$current_model_name" "$current_model_file" "$current_port" "$current_hf_repo"

  # --- Duplicate alias kontrolu ---
  if [ -n "${SEEN_ALIASES[$current_alias]:-}" ]; then
    error "Config hatasi ($ctx): alias '$current_alias' zaten kullanildi (once ${SEEN_ALIASES[$current_alias]} blogunda)"
  fi
  SEEN_ALIASES["$current_alias"]="$ctx"

  # --- Akilli duplicate port kontrolu ---
  if [ -n "$current_port" ]; then
    if [ -n "${SEEN_CUSTOM_PORTS[$current_port]:-}" ]; then
      error "Config hatasi ($ctx): '$current_port' portu elle tekrar kullanilmis! (once ${SEEN_CUSTOM_PORTS[$current_port]} blogunda)"
    fi
    SEEN_CUSTOM_PORTS["$current_port"]="$ctx (alias: $current_alias)"
  fi

  # --- spec_type / draft_dosya ile extra_params'taki elle yazilmis bayraklarin cakismasi ---
  # Config alani oncelikli; extra_params'taki es bayrak uyariyla cikarilir (cift bayrak uretilmesin).
  local extra_params="$current_extra_params"
  if [ -n "$current_spec_type" ] && has_flag "$extra_params" "$SPEC_FLAGS"; then
    warn "($ctx, alias=$current_alias) hem spec_type:$current_spec_type hem extra_params icinde --spec-type var; extra_params'taki cikarildi, spec_type kullanilacak."
    extra_params="$(strip_flag "$extra_params" "$SPEC_FLAGS")"
  fi
  if [ -n "$current_draft_dosya" ] && has_flag "$extra_params" "$DRAFT_FLAGS"; then
    warn "($ctx, alias=$current_alias) hem draft_dosya hem extra_params icinde -md/--model-draft var; extra_params'taki cikarildi, draft_dosya kullanilacak."
    extra_params="$(strip_flag "$extra_params" "$DRAFT_FLAGS")"
  fi

  # --- spec_type + mmproj uyumluluk uyarisi ---
  if [ -n "$current_mmproj_dosya" ] && { [ -n "$current_draft_dosya" ] || [ -n "$current_spec_type" ]; }; then
    warn "($ctx, alias=$current_alias) mmproj_dosya ile draft/spec_type birlikte: bazi llama.cpp build'leri multimodal varken speculative decoding'i kapatir ya da 'speculative decoding is not supported with multimodal' hatasiyla servis kalkmaz. Servis uretilecek; calismazsa mmproj_dosya satirini kaldir."
  fi

  local actual_port="${current_port:-$DEFAULT_PORT}"
  local actual_engine="${current_engine:-$DEFAULT_ENGINE}"

  check_model_file "$current_model_file" "$current_hf_repo"
  [ -z "$current_mmproj_dosya" ] || check_model_file "$current_mmproj_dosya" "${current_mmproj_repo:-$current_hf_repo}"
  [ -z "$current_draft_dosya" ] || check_model_file "$current_draft_dosya" "${current_draft_repo:-$current_hf_repo}"
  load_engine "$actual_engine"
  local engine_bin="${ENGINE_BIN_CACHE[$actual_engine]}"
  local engine_workdir="${ENGINE_WORKDIR_CACHE[$actual_engine]}"

  # mmproj (vision) / draft (speculative decoding) / spec_type verilmisse ExecStart'a otomatik eklenir
  local extra_model_flags=""
  [ -z "$current_mmproj_dosya" ] || extra_model_flags="${extra_model_flags} --mmproj ${MODEL_DIR}/${current_mmproj_dosya}"
  [ -z "$current_draft_dosya" ] || extra_model_flags="${extra_model_flags} -md ${MODEL_DIR}/${current_draft_dosya}"
  [ -z "$current_spec_type" ] || extra_model_flags="${extra_model_flags} --spec-type ${current_spec_type}"

  local base
  base="$(get_service_base "$current_model_name" "$current_hf_repo")"
  local service_name="llama-cpu-${base}"

  cat > "${SYSTEMD_DIR}/${service_name}.service" << EOF
[Unit]
Description=llama.cpp CPU server - ${current_alias} (engine: ${actual_engine})
After=network.target

[Service]
Type=simple
User=root
LimitMEMLOCK=infinity
WorkingDirectory=${engine_workdir}
ExecStart=${engine_bin} \\
  -m ${MODEL_DIR}/${current_model_file} \\
  --port ${actual_port} \\
  -c ${current_ctx_size} \\
  -t ${current_threads} -tb ${current_threads_batch} \\
  --load-mode mlock --timeout 600 \\
  ${extra_model_flags} \\
  ${extra_params}
Restart=on-failure
RestartSec=10
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

  ALIAS_TO_BASE["$current_alias"]="$base"
  ALIAS_TO_MODEL["$current_alias"]="$current_model_name"
  ALIAS_TO_PORT["$current_alias"]="$actual_port"
  SERVICES_CREATED+=("$current_alias")
  info "Servis uretildi: ${service_name}.service (alias: $current_alias, port: $actual_port, engine: $actual_engine)"
}

# --- CONFIG OKUMA (sed ile tırnak bug'ı önlenmiştir) ---
while IFS=: read -r key value || [ -n "$key" ]; do
  [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

  key="$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "$key" in
    alias)
      process_block
      current_alias="$value"; current_model_name=""; current_model_file=""; current_port=""
      current_ctx_size="4096"; current_threads="4"; current_threads_batch="4"
      current_hf_repo=""; current_extra_params=""; current_engine=""
      current_mmproj_dosya=""; current_mmproj_repo=""
      current_draft_dosya=""; current_draft_repo=""
      current_spec_type=""
      ;;
    model_adı|model_adi) current_model_name="$value" ;;
    model_dosya)         current_model_file="$value" ;;
    port)                current_port="$value" ;;
    ctx_size)             current_ctx_size="$value" ;;
    threads)              current_threads="$value" ;;
    threads_batch)        current_threads_batch="$value" ;;
    hf_repo)              current_hf_repo="$value" ;;
    extra_params)         current_extra_params="$value" ;;
    engine)               current_engine="$value" ;;         # opsiyonel; bos ise DEFAULT_ENGINE ("stock") kullanilir
    mmproj_dosya)          current_mmproj_dosya="$value" ;;   # opsiyonel; vision-language modeller icin (--mmproj)
    mmproj_repo)           current_mmproj_repo="$value" ;;    # opsiyonel; bos ise hf_repo ile ayni repo varsayilir
    draft_dosya)           current_draft_dosya="$value" ;;    # opsiyonel; draft model - klasik ya da DFlash (-md)
    draft_repo)            current_draft_repo="$value" ;;     # opsiyonel; bos ise hf_repo ile ayni repo varsayilir
    spec_type)             current_spec_type="$value" ;;      # opsiyonel; --spec-type degeri (draft-dflash, dflash, draft-mtp ...)
  esac
done < "$CONFIG_FILE"
process_block   # son blok

[ ${#SERVICES_CREATED[@]} -gt 0 ] || error "Config'te gecerli hicbir model blogu bulunamadi: $CONFIG_FILE"

# --- CPU-MODEL-SWITCH ARACI URET ---
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'declare -A ALIAS_TO_BASE'
  echo 'declare -A ALIAS_TO_MODEL'
  echo 'declare -A ALIAS_TO_PORT'

  for a in "${!ALIAS_TO_BASE[@]}"; do
    echo "ALIAS_TO_BASE[\"$a\"]=\"${ALIAS_TO_BASE[$a]}\""
    echo "ALIAS_TO_MODEL[\"$a\"]=\"${ALIAS_TO_MODEL[$a]}\""
    echo "ALIAS_TO_PORT[\"$a\"]=\"${ALIAS_TO_PORT[$a]}\""
  done
  echo ''
  cat << 'SWITCHEOF'
usage() {
  echo "Kullanım: cpu-model-switch {list|status|switch <alias>|stop}"
  echo ""
  echo "  list           : Tüm modelleri ve portlarını listele"
  echo "  status         : Tüm servislerin çalışma durumunu göster"
  echo "  switch <alias> : Belirtilen modele geç (diğerlerini durdurur)"
  echo "  stop           : Çalışan tüm CPU servislerini durdur"
  exit 1
}

stop_all_cpu_services() {
  local unit any_stopped=false
  for unit in $(systemctl list-unit-files --type=service 2>/dev/null | grep '^llama-cpu-' | awk '{print $1}'); do
    if systemctl is-active --quiet "$unit"; then
      systemctl stop "$unit"
      echo -e "\e[32m[OK]\e[0m Durduruldu: $unit"
      any_stopped=true
    fi
  done
  if [ "$any_stopped" = false ]; then
    echo -e "\e[33m[UYARI]\e[0m Zaten calisan aktif CPU servisi yok."
  fi
}

list_models() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  Kullanilabilir CPU Modelleri                                    ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  for alias in "${!ALIAS_TO_BASE[@]}"; do
    echo "  - $alias -> ${ALIAS_TO_MODEL[$alias]} (Port: ${ALIAS_TO_PORT[$alias]})"
  done
  echo ""
}

show_status() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  CPU Model Servisleri Durumu                                      ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  for alias in "${!ALIAS_TO_BASE[@]}"; do
    local base="${ALIAS_TO_BASE[$alias]}"
    local svc="llama-cpu-${base}.service"
    local port="${ALIAS_TO_PORT[$alias]}"
    local model="${ALIAS_TO_MODEL[$alias]}"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo -e "  \e[32m✅ AKTIF\e[0m   : $alias ($model) [Port: $port]"
    else
      echo -e "  \e[31m❌ DURMUS\e[0m  : $alias ($model) [Port: $port]"
    fi
  done
  echo ""
}

case "${1:-}" in
  list)
    list_models
    ;;
  status)
    show_status
    ;;
  switch)
    [ -n "${2:-}" ] || { echo "Hata: Alias belirtilmedi!"; usage; }
    target="$2"
    base="${ALIAS_TO_BASE[$target]:-}"
    [ -n "$base" ] || { echo "Hata: Bilinmeyen alias '$target'. Mevcutlar: ${!ALIAS_TO_BASE[*]}"; exit 1; }

    echo "Tum CPU servisleri durduruluyor..."
    stop_all_cpu_services
    sleep 1
    echo "Baslatiliyor: llama-cpu-${base}.service ($target)"
    systemctl start "llama-cpu-${base}.service"
    show_status
    ;;
  stop)
    stop_all_cpu_services
    ;;
  *)
    usage
    ;;
esac
SWITCHEOF
} > "$SWITCH_SCRIPT"
chmod +x "$SWITCH_SCRIPT"
info "cpu-model-switch araci uretildi: $SWITCH_SCRIPT"

systemctl daemon-reload
info "systemd daemon-reload tamamlandi"

echo ""
echo "Uretilen ${#SERVICES_CREATED[@]} servis: ${SERVICES_CREATED[*]}"
echo ""
echo "Kullanim:"
echo "  cpu-model-switch list              # Tum modelleri ve portlari listele"
echo "  cpu-model-switch status            # Servis durumlarini goster"
echo "  cpu-model-switch switch <alias>   # Bir modeli baslat, digerlerini durdur"
echo "  cpu-model-switch stop              # Hepsini durdur"
