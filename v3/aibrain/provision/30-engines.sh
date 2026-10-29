#!/usr/bin/env bash
# provision/30-engines.sh — Engine profilleri, llama.cpp derleme ve model servis araclari
set -euo pipefail
: "${C_BLUE:=\033[0;34m}"; : "${C_GREEN:=\033[0;32m}"; : "${C_YELLOW:=\033[1;33m}"; : "${C_RED:=\033[0;31m}"; : "${C_RESET:=\033[0m}"

log "[3/6] llama.cpp engine(leri) ve servis araclari hazirlaniyor..."

# 1. Tum engine profillerini /data/engines/ altina aktar
log "  -> Engine profilleri /data/engines/ dizinine aktariliyor..."
target_exec "mkdir -p /data/engines /data/models"

for pf in "$PAYLOAD_DIR_LOCAL"/engines/*.sh; do
  [ -f "$pf" ] || continue
  target_push "$pf" "/data/engines/$(basename "$pf")" 644
done
ok "Engine profilleri yerlestirildi"

# 2. llama.cpp derleme
if [ "${SKIP_LLAMA_BUILD:-false}" != "true" ]; then
  IFS=',' read -ra ENGINES_ARR <<< "${ENGINES:-stock}"
  for eng in "${ENGINES_ARR[@]}"; do
    eng="$(echo "$eng" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$eng" ] || continue
    
    profile="$PAYLOAD_DIR_LOCAL/engines/${eng}.sh"
    [ -f "$profile" ] || die "Engine profili bulunamadi: $profile"

    # Profile degiskenlerini oku
    unset ENGINE_NAME ENGINE_DESCRIPTION ENGINE_REPO_URL ENGINE_CLONE_DIR ENGINE_CMAKE_FLAGS ENGINE_LLAMA_BIN ENGINE_WORKDIR ENGINE_REF
    # shellcheck source=/dev/null
    source "$profile"
    [ -n "${ENGINE_REPO_URL:-}" ] && [ -n "${ENGINE_CLONE_DIR:-}" ] || die "Hatali profil: $profile"

    log "  -> Engine derleniyor: $eng ($ENGINE_REPO_URL -> $ENGINE_CLONE_DIR)..."
    ref_cmd=""
    if [ -n "${ENGINE_REF:-}" ]; then
      ref_cmd="git checkout '$ENGINE_REF'"
    fi

    target_exec "
      set -e
      mkdir -p \$(dirname '$ENGINE_CLONE_DIR')
      if [ ! -d '$ENGINE_CLONE_DIR/.git' ]; then
        git clone --depth 1 '$ENGINE_REPO_URL' '$ENGINE_CLONE_DIR'
      fi
      cd '$ENGINE_CLONE_DIR'
      $ref_cmd
      cmake -B build $ENGINE_CMAKE_FLAGS
      cmake --build build --config Release -j\$(nproc)
    "
    ok "Engine '$eng' basariyla derlendi"
  done
else
  warn "llama.cpp derlemesi atlandi (--skip-llama-build)"
fi

# 3. install_cpu_services.sh ve cpu_models.conf yerlestir
log "  -> install_cpu_services.sh ve cpu_models.conf aktariliyor..."
target_push "$PAYLOAD_DIR_LOCAL/install_cpu_services.sh" "/data/install_cpu_services.sh" 755

if target_exec "test -f /data/cpu_models.conf" >/dev/null 2>&1 && [ "${FORCE:-false}" != "true" ]; then
  warn "cpu_models.conf hedefte zaten mevcut, uzerine yazilmadi (--force ile yazilabilir)"
else
  target_push "$PAYLOAD_DIR_LOCAL/cpu_models.conf" "/data/cpu_models.conf" 644
  ok "cpu_models.conf yerlestirildi"
fi

target_exec "chmod 775 /data /data/models /data/engines"
ok "[3/6] Engine ve servis araclari tamamlandi."
