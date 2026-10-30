# AI-Brain: LXC ve VM Destekli AI Çıkarım Altyapısı

Proxmox VE üzerinde CPU tabanlı LLM çıkarımı (`llama.cpp`), LiteLLM Proxy ve MCP (`mcp-web-search`) servislerini tek bir komutla hem LXC Container hem de Cloud-Init VM hedeflerinde kuran modüler otomasyon altyapısı.

---

## 🚀 Hızlı Başlangıç (Gerçekten Quick Start)

> Çalışma dizini: `v3/aibrain/` (tüm komutlar bu dizinden çalıştırılır).

### 0. Pre-flight Kontroller (Çalıştırmadan Önce)

Tüm env/config dosyalarının mevcut ve dolu olduğunu doğrula:

```bash
# 1) Çalışma dizini
pwd   # .../v3/aibrain olmalı

# 2) Env dosyaları mevcut mu?
ls -la .ai-brain-lxc.env .ai-brain-vm.env paths.env payload/cpu_models.conf payload/mcp-web-search.env payload/paths.env 2>&1

# 3) Zorunlu alanlar dolu mu? (LXC örneği)
grep -E '^(AI_PVE_IP|AI_CTID|AI_CORES|AI_RAM|AI_STORAGE)=' .ai-brain-lxc.env

# 4) paths.env / yol sözleşmesi
cat payload/paths.env

# 5) cpu_models.conf — port çakışması kontrolü (tüm modeller varsayılan 8080'i paylaşıyor; switch ile tek aktif)
grep -n 'port\|alias:' payload/cpu_models.conf

# 6) CONFIG_FILE / ENGINES_DIR (install_cpu_services.sh için)
echo "CONFIG_FILE=${CONFIG_FILE:-payload/cpu_models.conf}"
echo "ENGINES_DIR=${ENGINES_DIR:-payload/engines}"

# 7) VM template bayrakları (isteğe bağlı)
# --no-auto-template   : şablon oluşturma adımını atla (hazır şablon varsa)
# --template-id <id>   : kullanılacak şablon ID'sini belirt
# --virt-customize     : şablonu virt-customize ile özelleştir
```

> [!NOTE]
> `paths.env` env alanlarının nasıl doldurulacağı için B.2.2 tablosuna bakın; Quick_start sadece kontrol adımlarını içerir.

### 1. Ayarları Yapılandırma

Hedefinize göre ilgili ayar dosyasını kopyalayın:

* **LXC Hedefi için:**
  ```bash
  cp .ai-brain-lxc.env.example .ai-brain-lxc.env
  nano .ai-brain-lxc.env
  ```
* **VM Hedefi için:**
  ```bash
  cp .ai-brain-vm.env.example .ai-brain-vm.env
  nano .ai-brain-vm.env
  ```

Env dosya öncelik sırası: CLI argümanları > `.ai-brain.env` > `.ai-brain-<type>.env` > varsayılanlar.

### 2. Planı Kontrol Etme (Dry-Run)

Hiçbir değişiklik yapmadan parametreleri ve planı doğrulamak için:

```bash
./ai-brain.sh --dry-run
# veya VM için:
./ai-brain.sh --type vm --dry-run
```

### 3. Kurulumu Başlatma

#### A) Proxmox LXC Hedefi (Varsayılan):
```bash
./ai-brain.sh --type lxc
```

#### B) Proxmox VM Hedefi (Cloud-Init KVM):
```bash
./ai-brain.sh --type vm
# VM template seçenekleri:
./ai-brain.sh --type vm --no-auto-template
./ai-brain.sh --type vm --template-id 9000
./ai-brain.sh --type vm --virt-customize
```

> [!NOTE]
> Proxmox üzerinde hazır bir Debian 13 Cloud-Init şablonu yoksa, `ai-brain.sh` arka planda `create-vm-template.sh`'ı otomatik olarak tetikler, şablonu oluşturur ve ardından VM'i ayağa kaldırıp kurulumu tamamlar. Elle ayrı bir script çalıştırmanıza gerek yoktur.

### 4. Kurulum Sonrası: Model İndirme + Servis Kurulumu

Hedefe bağlanıp model servislerini kurun:

```bash
# Hedefte (LXC/VM içinde):
sudo /data/install_cpu_services.sh
# Opsiyonel argümanlar:
sudo CONFIG_FILE=/data/cpu_models.conf ENGINES_DIR=/data/engines /data/install_cpu_services.sh
```

> **Not:** İlk kurulumda hiçbir model diskte olmayacaktır. `install_cpu_services.sh` bu durumu tespit eder ve `cpu_models.conf`'taki bilgilere göre her eksik model için `hf download <hf_repo> <model_dosya> --local-dir /data/models` komutunu **otomatik üretir** (indirmeyi kendisi yapmaz). Üretilen komutları kopyala-yapıştır ile hızlıca çalıştırabilirsiniz. Path'lerde değişiklik yapmadıysanız indirme `/data/models` altına yapılır ve systemd servis dosyaları da aynı yere bakar; dolayısıyla ekstra yol ayarı gerekmez.
>
> **`cpu_models.conf` değişikliği:** Model listesini (ekleme/çıkarma/parametre değişikliği) sonradan değiştirirseniz sıkıntı çıkmaz. Aynı `install_cpu_services.sh` komutunu tekrar çalıştırmanız yeterlidir; script yeni hale göre tüm dosyaları ve systemd servislerini yeniden üretir. Alt klasör gerekiyorsa `model_dosya` alanına `MTP/dosya-adı.gguf` biçiminde yol yazmanız yeterlidir.

Model indirme (eksik model varsa komut üretilir):

```bash
hf download <repo> <dosya> --local-dir /data/models
```

Ardından CPU model switch ile modeli aktifleştirin:

```bash
sudo cpu-model-switch list
sudo cpu-model-switch switch <alias>
sudo cpu-model-switch status
sudo cpu-model-switch stop
```

> Switch, diğer model servislerini durdurup tek bir modeli (varsayılan port 8080) başlatır.

### 5. Kontrol ve İzleme (Service Checks)

```bash
# Servis durumu (tek ekran)
./tools/status.sh --host <PVE_IP> --id <CTID/VMID>

# journalctl ile canlı log
sudo journalctl -u litellm -f
sudo journalctl -u llama-cpu-<alias> -f
sudo journalctl -u mcp-web-search -f

# Health endpoint kontrolü
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/health/liveliness

# Duman testi (provision/90-smoke.sh)
# Kurulum sonunda otomatik çalışır; manuel için:
bash /data/provision/90-smoke.sh
```

### 6. Erişim ve Anahtar Yönetimi

```bash
# Key rotation
./tools/rotate-keys.sh --host <PVE_IP> --id <CTID/VMID>
# Rotation sonrası LiteLLM/MCP istemcilerini (OpenCode, Continue) yeni anahtarla güncelleyin.
```

### 7. Güncelleme Modu

Hedefi sıfırdan silip derlemek yerine sadece kodları, config'leri ve servisleri güncellemek (anahtarları koruyarak):

```bash
./ai-brain.sh --update --host <PVE_IP> --ctid <CTID>
```

> `--ctid` zorunludur; anahtar dosyası korunur, servisler yeniden başlatılır.

---

## 📁 Mimari ve Dizin Yapısı

```
ai-brain/
├── ai-brain.sh                 # Ana giriş noktası (--type lxc|vm, --update, --dry-run)
├── ai-brain-lxc.sh             # Geriye dönük uyumluluk sarmalayıcısı (wrapper) — mevcut değil; doğrudan ai-brain.sh kullanın
├── _common.sh                  # Ortak SSH, loglama ve varsayılan ayarlar
├── .ai-brain-lxc.env.example   # Örnek ortam ayarları şablonu
├── targets/
│   ├── lxc.sh                  # Proxmox LXC sürücüsü (pct komutları ve sözleşmesi)
│   └── vm.sh                   # Proxmox VM sürücüsü (qm clone, cloud-init ve ssh)
├── provision/
│   ├── 10-base.sh              # DNS testi, apt paketleri, locale, /data izinleri
│   ├── 20-python.sh            # İzole Python venv'leri (/opt/ai_engine ve /opt/litellm)
│   ├── 30-engines.sh           # llama.cpp profil aktarımı ve cmake derleme
│   ├── 40-litellm.sh           # LiteLLM konfigürasyonu, key üretimi ve servis başlatma
│   ├── 50-mcp.sh               # MCP Web Search ortamı ve servis başlatma
│   └── 90-smoke.sh             # Duman testi (/health, 401 kontrolü, DNS, kaynak ölçümü)
├── payload/
│   ├── paths.env               # Sabit dizin ve yol sözleşmesi
│   ├── constraints.txt         # Sabit Python bağımlılık sürümleri
│   ├── engines/*.sh            # llama.cpp engine profilleri (stock, prism-cpu vb.)
│   ├── cpu_models.conf         # Model tanımları
│   ├── install_cpu_services.sh # Model servisleri ve cpu-model-switch aracı
│   ├── litellm-config.yml      # LiteLLM proxy konfigürasyon şablonu
│   ├── litellm.service         # LiteLLM systemd birimi
│   ├── mcp-web-search.env      # MCP env şablonu ({{MCP_SECRET_KEY}})
│   ├── mcp-web-search.service  # Sertleştirilmiş MCP systemd birimi
│   └── web_search_mcp.py       # MCP 2.x Web Search sunucusu
└── tools/
    ├── status.sh               # Servisler, RAM, disk ve sağlık durumu monitörü
    ├── rotate-keys.sh          # LiteLLM ve MCP anahtarlarını sıfırlama/yenileme aracı
    ├── create-vm-template.sh   # Cloud-init VM şablonu üretici
    ├── discover-pve.sh         # Proxmox ağ ve depolama keşif aracı
    └── setup-proxmox-token.sh  # Proxmox API token kurulumu
```

---

## 🛠️ Faydalı Komutlar

### Durum ve Sağlık Kontrolü
Hedefteki servislerin (`litellm`, `mcp-web-search`, `cpu-model-switch`), RAM ve disk durumunu tek ekranda görmek için:
```bash
./tools/status.sh --host 164.102.98.16 --id 250
```

### Anahtar Yenileme (Key Rotation)
LiteLLM ve MCP anahtarlarını canlı ortamda sıfırlamak ve servisleri yeniden başlatmak için:
```bash
./tools/rotate-keys.sh --host 164.102.98.16 --id 250
```

### Güncelleme Modu (--update)
Hedefi sıfırdan silip derlemek yerine sadece kodları, config'leri ve servisleri güncellemek (anahtarları koruyarak):
```bash
./ai-brain.sh --update --host 164.102.98.16 --ctid 250
```

---

## 🔒 Güvenlik Standartları
* **İzole Ortamlar:** MCP (`mcp 2.x`) ve LiteLLM ortak sistem paketleri yerine `/opt/ai_engine/venv` ve `/opt/litellm/venv` altında tamamen izole çalışır.
* **Katı Dosya İzinleri:** Tüm konfigürasyonlar ve sırlar (`/opt/litellm/config.yaml`, `/etc/ai-brain/mcp-web-search.env`, `ai-brain-*-keys.txt`) `600` izniyle tutulur.
* **Systemd Sertleştirme:** `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=strict` güvenlik yönergeleri aktif edilmiştir.