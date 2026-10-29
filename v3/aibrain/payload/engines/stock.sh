#!/usr/bin/env bash
# engines/stock.sh — mainline (ggml-org) llama.cpp engine profili.
# Tek basina calistirilmaz; ai-brain-lxc.sh (build sirasinda) ve
# install_cpu_services.sh (servis uretirken) tarafindan source edilir.
#
# Bu dosya SADECE degisken tanimlar - hicbir komut calistirmaz.
# Yeni bir engine eklemek icin bu dosyayi kopyalayip degerleri degistirmek yeterli;
# ai-brain-lxc.sh ve install_cpu_services.sh'a DOKUNMAYA GEREK YOK.

ENGINE_NAME="stock"
ENGINE_DESCRIPTION="Mainline ggml-org/llama.cpp - standart GGUF quant formatlari (Q4_K_M, Q8_0, IQ*, vb.)"

# git clone edilecek repo ve hedef dizin (LXC icinde, mutlak yol)
ENGINE_REPO_URL="https://github.com/ggml-org/llama.cpp"
ENGINE_CLONE_DIR="/opt/llama.cpp"

# cmake yapilandirma bayraklari - bu makinedeki CPU'ya gore (AVX2/FMA, cpu=host -march=native)
ENGINE_CMAKE_FLAGS="-DGGML_AVX2=ON -DGGML_F16C=ON -DGGML_FMA=ON -DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-march=native -DCMAKE_CXX_FLAGS=-march=native"

# systemd ExecStart icin kullanilacak gercek binary yolu
ENGINE_LLAMA_BIN="${ENGINE_CLONE_DIR}/build/bin/llama-server"

# systemd WorkingDirectory icin
ENGINE_WORKDIR="${ENGINE_CLONE_DIR}/build"
