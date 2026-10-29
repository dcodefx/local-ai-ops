#!/usr/bin/env bash
# engines/prism-cpu.sh — PrismML-Eng/llama.cpp fork engine profili.
# Ternary/dusuk-bit (Bonsai ailesi vb.) GGUF paketleri icin. Stock (mainline)
# llama.cpp bu paketleri (Q1_0_g128 / deneysel PQ2_0 vb.) tanimiyor ya da
# sessizce yanlis sonuc uretiyor - bu yuzden ayri bir engine olarak tanimli.
#
# NOT (dogrulanmasi gereken acik noktalar - kurulumdan once bakilmali):
#   - PrismML fork'unun ust dal (upstream) ile senkron durumu ve ternary format
#     adlandirmasi (Q1_0 / Q2_0 / Q2_0_g64 / PQ2_0) zaman icinde degisiyor;
#     Bonsai-demo reposundaki (github.com/PrismML-Eng/Bonsai-demo) guncel
#     runtime/format tablosu KAYNAK OLARAK ESAS ALINMALI, bu dosyadaki
#     degerler degil.
#   - Fork'un CPU/AVX2 cekirdeklerinin olgunluk durumu (CUDA/Metal'e kiyasla)
#     teyit edilmeden performans/dogruluk varsayimi yapilmamali.
#   - Asagidaki cmake bayraklari mevcut stock profilinden birebir kopyalandi;
#     fork icin CPU-ozel bir build talimati/bayragi varsa ("Additional Apple
#     Platforms" disindaki CPU notlari) build'den once guncellenmeli.

ENGINE_NAME="prism-cpu"
ENGINE_DESCRIPTION="PrismML-Eng/llama.cpp fork - ternary/dusuk-bit GGUF (Bonsai ailesi) icin CPU build"

ENGINE_REPO_URL="https://github.com/PrismML-Eng/llama.cpp"
ENGINE_CLONE_DIR="/opt/llama.cpp-prism"

# TODO: build oncesi Bonsai-demo repo'sundaki setup.sh / runtime tablosuna gore dogrula
ENGINE_CMAKE_FLAGS="-DGGML_AVX2=ON -DGGML_F16C=ON -DGGML_FMA=ON -DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-march=native -DCMAKE_CXX_FLAGS=-march=native"

ENGINE_LLAMA_BIN="${ENGINE_CLONE_DIR}/build/bin/llama-server"
ENGINE_WORKDIR="${ENGINE_CLONE_DIR}/build"
