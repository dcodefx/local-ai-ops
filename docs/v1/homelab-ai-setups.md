

# YEREL YAPAY ZEKA GELİŞTİRME LABORATUVARI  

# 3 Cihazlı, LiteLLM Orkestrasyonlu, Tam İzole, Yamalanmış ve Optimize Sistem Kılavuzu

Bu rehber; kısıtlı donanım kaynaklarını (eski bir GPU laptop ve Proxmox tabanlı bir CPU sunucusu) en yüksek verimle birleştiren, ağ seviyesinde tam izole, kurumsal düzeyde güvenli ve güncel CachyOS/Arch Linux uyumsuzlukları giderilmiş nihai kurulum kılavuzudur. Farklı eski bilgisayarları tek bir yerel AI geliştirme altyapısında birleştirmek için hazırlanmıştır.

Amaç:

* Tamamen yerel çalışan
* OpenAI uyumlu API sunan
* VS Code / Continue.dev ile entegre
* RAG destekli
* İnternetten izole çalışabilen
* Düşük maliyetli ama profesyonel
  bir geliştirme laboratuvarı oluşturmaktır.


# A - GENEL MİMARİ

```text
┌────────────────────────────────────────────┐
│ GPU SUNUCU (CachyOS Laptop)                │
│ GTX 960M + 16GB RAM                        │
│--------------------------------------------│
│ llama-server (Qwen2.5-Coder-3B GPU)        │
│ llama-server (Embedding)                   │
│ 10.10.10.3                                 │
└────────────────┬───────────────────────────┘
                 │ İzole AI Ağı
                 │ 10.10.10.X
┌────────────────▼───────────────────────────┐
│ CPU SUNUCU(i7,4.th) (Proxmox LXC Debian 12)|
│ 32GB RAM                                   │
│--------------------------------------------│
│ llama-server (Qwen3-Coder-30B-A3B CPU)     │
│ LiteLLM Proxy                              │
│ LanceDB + DuckDB                           │
│ MCP Web Search                             │
│ 10.10.10.2 / 192.168.1.50                  │
└────────────────┬───────────────────────────┘
                 │ LAN
┌────────────────▼───────────────────────────┐
│ GELİŞTİRME LAPTOPU                         │
│ VS Code + Continue.dev                     │
│--------------------------------------------│
│ Tek API: http://CPU_SUNUCU:4000/v1         │
└────────────────────────────────────────────┘
```
---
## A-1 MİMARİ MANTIĞI

Sistem hiyerarşik çıkarım mantığıyla çalışır.

| Katman            | Model             | Görev                               |
| ----------------- | ----------------- | ----------------------------------- |
| Hızlı GPU Katmanı | Qwen2.5-Coder-3B  | autocomplete, hızlı düzenleme       |
| Derin CPU Katmanı | Qwen3-Coder-30B-A3B | reasoning, analiz, mimari çözümleme |
| Embedding Katmanı | nomic-embed-text  | RAG / @codebase                     |
| LiteLLM           | proxy/gateway     | tek API altında yönlendirme         |

GTX 960M gibi eski kartlarda 7B modeller VRAM sınırına çok yaklaştığı için pratik kullanımda 3B/4B modeller daha stabil çalışır.

`--parallel 1` kullanılması özellikle 4GB VRAM kartlarda OOM hatalarını önlemek için önemlidir.

Sistem, modelleri yeteneklerine, hızlarına ve bellek gereksinimlerine göre ayırarak **"Hiyerarşik Çıkarım (Hierarchical Inference)"** mantığıyla çalışır:

* **Hızlı Katman (GPU Laptop - CachyOS):** GTX 960M (4GB VRAM) üzerinde çalışan `Qwen2.5-Coder-3B-Instruct-Q4_K_M` kod tamamlama (autocomplete) modeli. Tamamen VRAM'de kaldığı için anlık tepki süresi (<100ms low-latency) sağlar.
* **Zeki Katman (CPU Sunucu - Proxmox LXC Debian 12):** 32GB RAM üzerinde koşan `Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf` karmaşık akıl yürütme (reasoning) ve derin analiz modeli.
* **Orkestrasyon ve Güvenlik Kapısı (LiteLLM Proxy):** İstemcinin hangi makineye bağlanacağını düşünmesine gerek kalmadan tek bir API arkasından modelleri ve istekleri yöneten akıllı yönlendirici.
* **İstemci Makine (Geliştirme Bilgisayarı):** Sadece VS Code ve Continue.dev eklentisini çalıştırır. Üzerinde hiçbir model yükü barındırmaz.

---
## A-2 🔒 Ağ İzolasyon Stratejisi - Bu kısma ilgili kurulumlardan sonra veya esnasında bakılabilir.

Mevcut ev/ofis ağının `192.168.1.X` bloğunda internete açık olduğunu varsayalım. Güvenliği sağlamak adına internete hiç çıkışı olmayan, tamamen izole ikinci bir yapay ağ (`10.10.10.X`) oluşturulur. GPU Laptop bu ağda ana ağ geçidi (Gateway) boş bırakılarak hapsedilir. Proxmox LXC ise çift ağ bacaklı olarak yapılandırılır: Bir bacağı internete (MCP servisleri ve güncellemeler için), diğer bacağı ise sadece GPU laptop ile konuşan izole ağa bakar. Dışarıdaki modem bu bloğu tanımadığı için veri sızıntısı fiziksel olarak imkansız hale gelir.


1. **Proxmox Container (LXC - LiteLLM):** Çift ağ kartına sahip olacak . İlk kartı (`eth0`) `192.168.1.X` üzerinden internete ve MCP sunucularına bakarken , ikinci kartı (`eth1`) sadece yapay ve izole `10.10.10.X` tüneline bakacak .(**fiziksel olması gerekmiyor bridge olarak ayarlanır.**)
2. **Gizli ve İzole AI Ağı (`10.10.10.X`):** İnternet çıkışı, ağ geçidi (Gateway) ve harici fiziksel dünyayla bağı olmayan sanal bir switch (köprü) oluşturacağız .
3. **GPU Laptop (CachyOS):** Bu izole ağdan bir IP (`10.10.10.3`) alacak ve varsayılan ağ geçidi boş bırakılarak, firewall yardımıyla tamamen bu tünele hapsedilecek .

---

### 🏗️ A-2.1: Proxmox Tarafı Altyapı Yapılandırması (VLAN Destekli)

Fiziksel dünyadaki tek portlu harici GPU laptopumuz ile Proxmox sunucumuzu ekstra bir ağ kablosu çekmeden, modem üzerindeki aynı hat üzerinden güvenle konuşturabilmek için ana sanal anahtarımızı (`vmbr0`) sanal odalara (VLAN) bölecek şekilde yapılandırıyoruz.

#### Adım 1: Proxmox Web Arayüzünden Ana Köprüyü "VLAN Aware" Yapma

1. Proxmox VE paneline giriş yapın.
2. Sol menüden ana sunucu ismine tıklayın, ardından **Network (Ağ)** sekmesine gelin.
3. Mevcut internete/modeme bağlı olan ana köprüyü (**`vmbr0`**) seçip üstteki **Edit** butonuna basın.
4. Açılan pencerede **VLAN Aware** seçeneğinin yanındaki kutucuğu işaretleyerek aktif hale getirin.
5. **OK** butonuna basın. Ardından üst menüde beliren **Apply Configuration** butonuna tıklayarak ağ değişikliklerini aktif hale getirin.

#### Adım 2: Proxmox LXC (LiteLLM Sunucusu) Çift Kart Ayarı (VLAN Tag ile)

Model yönetimini ve orkestrasyonunu üstlenen LXC container'ımıza, internet bacağını bozan `eth0` bacağına dokunmadan, ortak fiziksel hattan `VLAN 10` etiketiyle geçecek izole bir ikinci network kartı (`eth1`) ekleyeceğiz.

1. Proxmox sol menüsünden LiteLLM container'ınızı seçin.
2. Orta menüden **Network (Ağ)** sekmesine gelin.
3. **Add (Ekle)** butonuna basın ve parametreleri tam olarak şu şekilde doldurun:
* **Name:** `eth1` *(Mevcut internet kartınız muhtemelen `eth0` olarak kayıtlıdır)*
* **Bridge:** `vmbr0` *(VLAN Aware yaptığımız ana sanal anahtar)*
* **VLAN Tag:** `10` *(Fiziksel dünyadaki trafiği ev internetinden ayırıp izole AI tüneline sokan kritik nokta burasıdır)*
* **IPv4:** `Static` seçeneğini işaretleyin.
* **IPv4/CIDR:** `10.10.10.2/24` yazın.
* **Gateway (IPv4):** *KESİNLİKLE BOŞ BIRAKIN* *(Bu bacağın internete sızmaması ve yönlendirmesi olmaması için boş kalmalıdır)*


4. **Create** butonuna basarak kartı ekleyin.
5. Değişikliklerin işletim sistemi tarafından tanınması için LXC container'ı kapatıp yeniden başlatın (Reboot).

- Artık `eth0` dış dünyaya bakarken, `eth1` fiziksel ethernet kablonuzun içinden süzülen sadece `VLAN 10` etiketli `10.10.10.X` yapay zeka paketlerini dinleyecektir.
- CachyOS GPU laptop tarafında da ağ kartına `VLAN 10` kimliği ile `10.10.10.3/24` IP'si el ile (manual) tanımlanarak köprü tamamlanacaktır.

### 💻 A-2.2: CachyOS (GPU Laptop) Tarafı Ağ İzolasyonu (VLAN Yapılandırması)
Harici GPU laptopun fiziksel port kısıtlamasını aşmak için Proxmox tarafında geçtiğimiz **VLAN Aware (VLAN Etiketleme)** altyapısına tam uyumlu olacak şekilde,  CachyOS (GPU Laptop) bölümü: 

---

Laptopumuz ağa tek bir ethernet kablosu ile bağlı olsa da, ortak hattan geçen paketleri ayırmak ve izole ağa dahil olabilmek için NetworkManager üzerinde `VLAN 10` etiketine sahip sanal bir ağ bacağı oluşturacağız. Ardından UFW ile bu bacağı tamamen dış dünyaya kapatacağız.

#### Adım 1: Fiziksel Ağ Kartının Adını Öğrenme

Terminali açın ve Proxmox sunucunuza giden fiziksel ethernet bağlantısını sağlayan kartın tam adını öğrenin:

```bash
ip link

```

*Çıktıda `enp3s0` veya `eth0` gibi bir isim göreceksiniz. Bu kılavuzda fiziksel kart adının **`enp3s0`** olduğunu varsayarak ilerleyeceğiz.*

#### Adım 2: NetworkManager (nmcli) ile İzole VLAN Bağlantısını Oluşturma

Mevcut ev interneti bağlantınızı koparmadan, `enp3s0` kartınızın arkasına sadece `VLAN 10` etiketli paketleri okuyacak ve kendine `10.10.10.3` IP'sini el ile (manual) atayacak yeni bir sanal profil ekliyoruz:

```bash
# VLAN 10 etiketli sanal bağlantı profilini oluşturun
sudo nmcli connection add type vlan con-name "AI-Izole-Baglanti" dev enp3s0 id 10 ipv4.method manual ipv4.addresses 10.10.10.3/24

# Oluşturulan yeni izole tüneli aktif hale getirin
sudo nmcli connection up "AI-Izole-Baglanti"

```
#### Adım 3: UFW Firewall ile Tam Ağ İzolasyonu (En Kritik Adım)

Laptopun internete veri sızdırmasını, dış dünyayla bağ kurmasını veya ev ağındaki diğer cihazların (Akıllı TV, telefon vb.) yapay zeka modeline erişmesini tamamen engellemek için kuralları kurumsal düzeyde katılaştırıyoruz:

```bash
# 1. Mevcut UFW kurallarını sıfırlayarak temiz bir başlangıç yapın
sudo ufw --force reset

# 2. Varsayılan politikaları kapatın (Her türlü giriş ve çıkışı tamamen engeller)
sudo ufw default deny incoming
sudo ufw default deny outgoing

# 3. Yerel döngü (Loopback - localhost) trafiğine izin verin
# (Bunu yapmazsanız laptopun kendi içindeki servisler -örneğin llama-server- kendisiyle konuşamaz!)
sudo ufw allow in on lo
sudo ufw allow out on lo

# 4. Proxmox LXC (LiteLLM) Sunucusu ile İletişim Kuralları
# Laptopun sadece Proxmox LXC (10.10.10.2) IP'sine paket göndermesine izin ver (Dışa Doğru)
sudo ufw allow out to 10.10.10.2

# Sadece Proxmox LXC (10.10.10.2) IP'sinden gelen paketleri kabul et (İçe Doğru)
sudo ufw allow in from 10.10.10.2

# 5. Güvenlik duvarını aktif edin
sudo ufw enable

```

#### Adım 4: Bağlantı ve İzolasyon Testi

Yapılandırmanın doğru çalışıp çalışmadığını doğrulamak için GPU laptopunuzda şu testleri gerçekleştirin:

1. **İzolasyon Testi (İnternet Kapalı Olmalı):** `ping 8.8.8.8` veya `ping google.com` komutunu çalıştırın. UFW kuralları nedeniyle paketlerin kesinlikle dışarı çıkamaması ve hata vermesi gerekir.
2. **AI Tüneli Testi (Proxmox Bağlantısı Açık Olmalı):** `ping 10.10.10.2` komutunu çalıştırarak Proxmox üzerindeki LiteLLM container'ına erişebildiğinizi doğrulayın. Paketlerin kayıpsız gidip gelmesi gerekir.

---
# B - KURULUMLAR

## B.1 — GPU SUNUCU KURULUMU (Laptop 1 - CachyOS ( xfce4)  )

Bu makine headless (ekransız) çalışacak, sadece model sunacak.

### B.1.1 CachyOS Ortamında Kurulum ve Temel Ayarlar

```bash
# Sistemi güncelle
sudo pacman -Syu

# Geliştirme araçları
sudo pacman -S base-devel git cmake ninja curl wget python python-pip

# NVIDIA sürücüsü (GTX 960M = Maxwell = nvidia-470xx)
sudo pacman -S nvidia-470xx-dkms nvidia-470xx-utils

# Not: CachyOS hızlı kernel güncellerse sürücü derlenemeyebilir.
#       O zaman linux-lts çekirdeğini kurup onunla başlatmak çözüm olur.
# önemli not: paru veya yay gibi bir AUR yardımcısının sistemde kurulu olması gerekir.
paru -S cuda-11.7
```

**Doğrulama:**
```bash
nvidia-smi
```

#### B.1.1.1 CUDA Ortam Değişkenleri

#####  Çevre Değişkenlerinin Kalıcı Hale Getirilmesi

Kurulan CUDA kütüphanelerinin sistem geneline bildirilmesi için `~/.zshrc` (veya `~/.bashrc`) dosyanızın en altına şu satırları ekleyin:

```bash
export CUDA_HOME=/opt/cuda-11.7
export PATH=$PATH:$CUDA_HOME/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$CUDA_HOME/lib64

```
Terminali yenileyin: `source ~/.zshrc`
Kontrol:

```bash
which nvcc
```
#### B.1.1.2 Glibc / CUDA Uyumsuzluğu Düzeltmesi

Eski NVIDIA sürücüleri (örn: v470) ve eski GPU mimarileri (örn: Maxwell / GTX 960M) nedeniyle sistemde **CUDA 11.7** kullanılması zorunlu olabilir. Ancak güncel Arch Linux dağıtımlarındaki **Glibc (GNU C Library)** sürümü, `cospi`, `sinpi` ve `rsqrt` fonksiyonlarını `noexcept` (hata fırlatmayan) kuralıyla güncellenmiştir. 

CUDA 11.7'nin iç kütüphanelerinde bu kural eksik olduğu için, `llama.cpp` gibi projeleri `CMake` ile derlerken derleyici uyumsuzluk hatası (`exception specification is incompatible`) verir ve çöker.

Yedek alın:

```bash
sudo cp \
/opt/cuda-11.7/targets/x86_64-linux/include/crt/math_functions.h \
/opt/cuda-11.7/targets/x86_64-linux/include/crt/math_functions.h.bak
```
Dosyayı düzenleyin: 

```bash
sudo nano /opt/cuda-11.7/targets/x86_64-linux/include/crt/math_functions.h
```

##### Değiştirilecek Satırlar ve Yeni Halleri
Editör içinde `Ctrl + W` tuş kombinasyonunu kullanarak ilgili fonksiyon adlarını aratın. Toplamda **6 farklı fonksiyon satırının** en sonundaki noktalı virgülden (`;`) hemen önce bir boşluk bırakarak `noexcept` ifadesini ekleyin. 

> ⚠️ **Önemli Not:** Satır başlarındaki boşlukları, `extern` makrolarını veya sondaki noktalı virgülleri kesinlikle silmeyin. Sadece araya `noexcept` sıkıştırın.

###### A. cospi ve cospif Grubu
* **Eski Orijinal Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 cospi(double x);
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  cospif(float x);
  ```
* **Yeni Yamalı Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 cospi(double x) noexcept;
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  cospif(float x) noexcept;
  ```

###### B. sinpi ve sinpif Grubu
* **Eski Orijinal Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 sinpi(double x);
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  sinpif(float x);
  ```
* **Yeni Yamalı Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 sinpi(double x) noexcept;
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  sinpif(float x) noexcept;
  ```

###### C. rsqrt ve rsqrtf Grubu
* **Eski Orijinal Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x);
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x);
  ```
* **Yeni Yamalı Satırlar:**
  ```cpp
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x) noexcept;
  extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x) noexcept;
  ```
### B.1.2  Llama.cpp Derleme (Standart GCC ve Doğrudan CUDA Yolları) (GPU Build)
ilgili repodan llama.cpp yi indirin.

```bash
cd ~
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
```
GLIBC `math_functions.h` yaması yapıldıktan sonra sistemdeki güncel **standart GCC derleyicisi** tamamen uyumlu hale gelmektedir. Clang derleyicisine veya paket düşürmeye (downgrade) gerek yoktur.

CMake mimarisinin `/opt/cuda-11.7` altındaki derleyici araçlarını hatasız bulması ve GTX 960M ekran kartına göre mimari avantajlarını (Maxwell - `sm_52`) tam devreye alması için derleme parametrelerini komut satırında açıkça göstererek çalıştırın

```bash
rm -rf build

# yukarıda ortam değişkenleri kalıcı eklenmişti,fakat isterseniz
# CUDA çevre yollarını derleme oturumu için garantiye alın

# export CUDA_HOME=/opt/cuda-11.7
# export PATH=/opt/cuda-11.7/bin:$PATH
# export LD_LIBRARY_PATH=/opt/cuda-11.7/lib64:$LD_LIBRARY_PATH

# CUDA aktif, Maxwell mimari hedefi
# Standart GCC aktifken, CUDA yollarını komut satırından açıkça enjekte edin
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_COMPILER=/opt/cuda-11.7/bin/nvcc \
  -DCUDAToolkit_ROOT=/opt/cuda-11.7 \
  -DCMAKE_CUDA_ARCHITECTURES="50;52" \
  -DCMAKE_BUILD_TYPE=Release

#veya değişkenleri zaten görüyor ise:
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="50;52" \
  -DCMAKE_BUILD_TYPE=Release

# yukarıdaki kısımdan sonra 
# Derleme — $(nproc) mevcut CPU çekirdek sayısını otomatik algılar
# Tüm işlemci çekirdeklerini kullanarak derlemeyi bitirin
cmake --build build --config Release -j$(nproc)
```


### B.1.3 Model İndirme

#### B.1.3.1 Dizinler

```bash
mkdir -p ~/models/coder
mkdir -p ~/models/embedding
```
#### B.1.3.2 HuggingFace CLI

```bash
#pip install huggingface-hub -->  if not work
sudo pacman -S python-pipx

pipx install "huggingface_hub[cli]"
pipx ensurepath

source ~/.zshrc
```

#### B.1.3.3 GPU Kod Modeli (Hızlı coder (GPU))


```bash
hf download \
  Qwen/Qwen2.5-Coder-3B-Instruct-GGUF \
  qwen2.5-coder-3b-instruct-q4_k_m.gguf \
  --local-dir ~/models/coder
```
#### B.1.3.4 Embedding Modeli ( Embedding (CPU))

```bash
hf download \
  nomic-ai/nomic-embed-text-v1.5-GGUF \
  nomic-embed-text-v1.5.Q4_K_M.gguf \
  --local-dir ~/models/embedding
```

### B.1.4 Systemd Servislerinin Yapılandırılması (GPU Laptop)

Süreçlerin arka planda kütüphane çakışması yaşamadan çalışması için sistem servislerini hazırlayın. `Environment=` satırları kütüphane yollarını açıkça göstererek olası çökmeleri engeller.

#### B.1.4.1 Coder Servisi (GPU, Port 8080) (`/etc/systemd/system/llama-gpu-coder.service`)

```bash
sudo tee /etc/systemd/system/llama-gpu-coder.service << 'EOF'

[Unit]
Description=Llama.cpp GPU Coder Service
After=network.target

[Service]
Type=simple
User=ai-gpu
Group=ai-gpu
WorkingDirectory=/home/ai-gpu/llama.cpp
Environment="LD_LIBRARY_PATH=/opt/cuda-11.7/lib64:/opt/cuda-11.7/targets/x86_64-linux/lib"
Environment="PATH=/opt/cuda-11.7/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/home/ai-gpu/llama.cpp/build/bin/llama-server \
  --model /home/ai-gpu/models/coder/qwen2.5-coder-3b-instruct-q4_k_m.gguf \
  --host 10.10.10.3 --port 8080 \
  --n-gpu-layers 33 --ctx-size 8192 --threads 4 --parallel 1
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```
*Not: Kartın 4GB VRAM sınırında Out of Memory (OOM) hatası almamak adına `--parallel 1` yapılandırması fiziksel sınırları korumak için elzemdir.*

#### B.1.4.2  Embedding Servisi (CPU, Port 8081) (`/etc/systemd/system/llama-embed.service`)

```bash
sudo tee /etc/systemd/system/llama-embed.service << 'EOF'
[Unit]
Description=Llama.cpp Embedding Service
After=network.target

[Service]
Type=simple
User=ai-gpu
Group=ai-gpu
WorkingDirectory=/home/ai-gpu/llama.cpp
Environment="LD_LIBRARY_PATH=/opt/cuda-11.7/lib64:/opt/cuda-11.7/targets/x86_64-linux/lib"
Environment="PATH=/opt/cuda-11.7/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/home/ai-gpu/llama.cpp/build/bin/llama-server \
  --model /home/ai-gpu/models/embedding/nomic-embed-text-v1.5.Q4_K_M.gguf \
  --host 10.10.10.3 --port 8081 \
  --embedding --ctx-size 2048 --threads 8
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now llama-embed
```
#### B.1.4.3 Servisleri Başlat

```bash
sudo systemctl daemon-reload

sudo systemctl enable --now \
  llama-gpu-coder.service \
  llama-embed.service
```

Durum kontrolü:

```bash
sudo systemctl status llama-gpu-coder
sudo systemctl status llama-embed
```

#### B.1.4.4 libcudart Hatası Çözümü

Bazı CachyOS güncellemelerinde:

```text
status=127
libcudart.so bulunamadı
```

hatası oluşabilir.

Çözüm:

```bash
sudo ln -sf \
/opt/cuda-11.7/lib64/libcudart.so.11.7.99 \
/opt/cuda-11.7/lib64/libcudart.so.11.0

sudo ln -sf \
/opt/cuda-11.7/lib64/libcudart.so.11.7.99 \
/opt/cuda-11.7/lib64/libcudart.so.11.7
```

Ardından:

```bash
sudo systemctl daemon-reload
sudo systemctl restart llama-gpu-coder
sudo systemctl restart llama-embed
```
---

## B.2 — CPU SUNUCU KURULUMU (Proxmox LXC - Debian 12) 

#### LXC + Debian 12 + llama.cpp CPU + LiteLLM
**LXC (Linux Container)** ise işletim sistemi çekirdeğini host ile paylaşır, sadece kullanıcı alanını izole eder. Sonuç: bare-metal'a %95 yakın performans, ama yine de güvenli izolasyon. 32GB RAM'in tamamını modele verebilirsin.

Burada hem büyük kod modeli hem de LiteLLM proxy çalışacak.

### B.2.1 LXC Oluşturma (Proxmox Web Arayüzünden) & Donanım Yapılandırması

**Önce Debian template'i indir (Proxmox host shell'inde):**
```bash
# Proxmox'a SSH ile bağlan veya web arayüzünden "Shell" aç
pveam update
pveam download local debian-12-standard
```
**ya da web arayuzden templates kısmından download edebilirsiniz.**

- **CT ID:** 200  # tercihe bağlıdır,mevcut ID ler den başka istediğinizi verebilirsiniz 
- **Hostname:** ai-cpu  / ai-brain
- **Unprivileged container:** EVET (✔)  
- **Template:** debian-12-standard  | Minimal, stabil, iyi desteklenen
- **Disk:** 80 -100 GB  # minimum 60 GB ama diğer kurulumlar vs 100 GB iyi olabilir. SSD veya NVMe olması daha iyidir.
- **CPU:** 8 çekirdek  
- **CPU Type:**  host  # `host` seçimi AVX2 optimizasyonlarını doğrudan container içine geçirir.CPU çıkarım hızı %20'ye yakın artar.

- **RAM:** 28672 MB,  #(`24576` ile `28672` MB arası)  24–28 GB uygun, makinede 32 GB RAM mevcut, 4GB Proxmox host için ayır
- **Swap:** 4096 MB  
- **Ağ:** için: 

#### Network

##### eth0 — Ana Ağ  (detaylı açıklama için ağ izolasyonu kısmına  bakınız)

| Alan    | Değer                  |
| ------- | ---------------------- |
| Bridge  | vmbr0                  |
| IP      | DHCP veya 192.168.1.50/24 |  # CIDR aralığına göre sabit vermeniz daha iyi olacaktır.
| Gateway | modem gateway          |

---

##### eth1 — İzole AI Ağı (detaylı açıklama için ağ izolasyonu kısmına  bakınız)

| Alan    | Değer         |
| ------- | ------------- |
| Bridge  | vmbr0         |	
| VLAN Tag | 10         |
| IP      | 10.10.10.2/24 |
| Gateway | BOŞ           |

---
**Başlat ve içine gir:**
```bash
pct start 200
pct enter 200
```
**ya da web arayuzden shell ile giriniz**

### B.2.2 Debian 12 İçi Hazırlık & Paketlerin kurulumu

```bash
# Paket listelerini güncelle
apt update && apt upgrade -y

# Geliştirme araçları
apt install -y \
  build-essential \
  cmake \
  git \
  curl \
  wget \
  python3 \
  python3-pip \
  python3-venv \
  htop \
  tmux \
  net-tools

# Python kütüphaneleri
# --break-system-packages: Debian 12, pip'in sistem Python'ına dokunmasını kısıtlar
# Bu flag olmadan "externally-managed-environment" hatası alırsın
pip3 install --break-system-packages \
  huggingface-hub \
  lancedb \
  duckdb \
  fastapi \
  uvicorn \
  requests
```

### B.2.3 llama.cpp Kurulumu CPU Build (Zeki Katman) | Optimized CPU Build

Server'da GPU mevcut değil, cpu da AVX2 optimizasyonu kritik — 4. nesil i7, AVX2 ve FMA3 destekliyor ve bu talimatlar vektör hesaplamalarını (AI'nin kalbi) dramatik şekilde hızlandırıyor.

- ilgili repodan llama.cpp yi indirin.

```bash
cd /opt
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
```
- Optimized CPU Build
```bash
cmake -B build \
  -DGGML_AVX2=ON \
  -DGGML_F16C=ON \
  -DGGML_FMA=ON \
  -DGGML_CUDA=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-march=native" \
  -DCMAKE_CXX_FLAGS="-march=native"

cmake --build build --config Release -j$(nproc)
```


| Flag | Gerekçe |
|---|---|
| DGGML_AVX2=ON | 256-bit SIMD vektör hesaplama sağlar. |
| DGGML_F16C=ON | FP16↔FP32 donanım dönüşümünü aktif eder. |
| DGGML_FMA=ON | Fused Multiply-Add: Çarpma ve toplama işlemini tek clock döngüsünde yapar. Haswell FMA3 desteklidir, tensör hesaplamalarında %5–10 ek hız sağlar. |
| DCMAKE_C_FLAGS="-march=native" | Derleyiciyi mevcut donanım için optimize eder. Haswell mimarisine özgü tüm pipeline ve cache optimizasyonlarını aktif hale getirir. Derlenen paket başka bir makinede çalışmaz ancak bu homelab için idealdir. |
| DCMAKE_CXX_FLAGS="-march=native" |	Derleyicinin işlemciye özgü tüm optimizasyonları (AVX2, FMA, BMI, POPCNT vb.) kullanmasını sağlar. Binary başka makinelerde çalışmaz, ancak homelab için maksimum performansı verir. |




### B.2.4 Model İndirme (Qwen3-Coder-30B-A3B-Instruct-GGUF)

```bash
mkdir -p /data/models
```
-  Dense mimaride her token üretiminde modelin tüm ağırlıkları bellekten geçer. DDR3 1600 MHz çift kanal teorik bant genişliği ~25.6 GB/sn, efektif ise ~18–20 GB/sn düzeyindedir.

- Ham işlemci hızı değil, bellek veri yolu genişliği bu kısıta neden oluyor.. Dense modelden MoE'ye geçmek dışında DDR3 üzerinde bu tavanı aşmanın yolu yok.

- `MoE (Mixture of Experts)` mimarisinde model aynı RAM alanını tutsa da her token üretiminde yalnızca aktif uzman katmanları bellekten geçer:

- Bu donanım için en iyi denge: 30.5B toplam parametre, yalnızca 3.3B aktif. 256K native bağlam, ajan/araç çağırma optimizasyonu ve unsloth imatrix kuantizasyonu ile kalite kaybı minimumdur.

Q3_K_M tercih sebebi: Q4_K_M (~17.5 GB) da sığar ama Q3_K_M'nin ~15.5 GB ile 28 GB bütçede --mlock sonrası bellek marjı daha geniş kalır. unsloth imatrix bu kuantizasyonda kaliteyi %96+ düzeyinde korur.

#### Qwen3-Coder-30B-A3B Q3_K_M indir (~15.5 GB)
```bash
hf download \
       unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
       Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf \
       --local-dir /data/models
```

#### İndirme doğrulama
```bash
ls -lh /data/models/Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf
```
Alternatif : 
#### DeepSeek-Coder-V2-Lite Q4_K_M indir (~10.4 GB)
```bash
hf download \
    lmstudio-community/DeepSeek-Coder-V2-Lite-Instruct-GGUF \
    DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf \
    --local-dir /data/models
```


### B.2.5 CPU Model (Derin Analiz) Servisi (Port 8081) 
#### (`/etc/systemd/system/llama-cpu-qwen3-30b.service`)

gerekli llama-server parametre tablosu aşağıdadır:
#### llama-server Parametre Tablosu

| Parametre | Değer | Gerekçe |
|---|---|---|
| -m | Qwen3-Coder-30B-A3B-Q3_K_M.gguf | MoE: 15.5GB ile 28GB bütçeye sığar, 3.3B aktif parametre. |
| -t / -tb | 4 / 4 | Fiziksel çekirdek sayısına sabitle — HT rekabeti ve L1/L2/L3 kirlenmeyi önler. |
| -c | 16384 | Kod tabanı analizi için yeterli bağlam penceresi. |
| --mlock | (aktif) | Ağırlıkları RAM'e kilitle, Proxmox swap mekanizmasını devre dışı bırak. |
| -ctk / -ctv | q8_0 / q8_0 | Haswell ALU'ya Q4_0 dekompresyon yükü bindirme, Q8_0 net kazanç sağlar. |
| --parallel | 1 | Tek kullanıcılı ortamda CPU scheduler ve thread yönetim yükünü minimize et. |
| -fa | (aktif) | Flash Attention — bellek erişim örüntüsünü optimize eder. |
| --host | 127.0.0.1 | LiteLLM aynı container içinde; dışarı açmaya gerek yok. |
| --port | 8081 | Mevcut kurulumla çakışmayı önle (8080 varsa). |

---
service dosyası oluşturma komutu: 

```bash
tee /etc/systemd/system/llama-cpu-qwen3-30b.service << 'EOF'
[Unit]
Description=llama.cpp CPU — Qwen3-Coder-30B-A3B MoE
After=network.target
 
[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp
 
ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /data/models/Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf \
  --host 127.0.0.1 \
  --port 8081 \
  --ctx-size 16384 \
  --threads 4 \
  --threads-batch 4 \
  --parallel 1 \
  --mlock \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on
 
# Model ilk yüklemede 45-90 sn sürebilir
TimeoutStartSec=180
 
# Çökerse 10 sn bekleyip yeniden başlat
Restart=on-failure
RestartSec=10
 
[Install]
WantedBy=multi-user.target
EOF
```
####   Servisi Başlat

```bash
sudo systemctl daemon-reload

systemctl enable --now llama-cpu-qwen3-30b
```

Durum kontrolü:

```bash
sudo systemctl status llama-cpu-qwen3-30b

```
#### ⚠️ ÖNEMLİ:  
**Gelişmiş install script:** `install_services.sh`
 - Tüm model indirmeleri ve service lerini otomatik yapacak bir script olup extra olarak bu modeller arasında switch edebilmeyi de sağlayan ilave script de ekler.

```bash
#!/bin/bash
# ============================================================
# Homelab CPU Model Servis Kurulum Scripti
# Proxmox LXC Debian 12 içinde root olarak çalıştırın
# Kullanım: bash install_services.sh
# ============================================================

set -e

LLAMA_BIN="/opt/llama.cpp/build/bin/llama-server"
MODEL_DIR="/data/models"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Homelab CPU Model Servis Kurulumu                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── MODEL İNDİRME ──────────────────────────────────────────
download_models() {
  echo "──────────────────────────────────────────────────────"
  echo " Model indirme seçenekleri"
  echo "──────────────────────────────────────────────────────"
  echo ""
  echo "[1] Qwen3-Coder-30B-A3B Q3_K_M — ~15.5 GB (BİRİNCİL ÖNERİ)"
  echo "    hf download \\"
  echo "      unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \\"
  echo "      Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf \\"
  echo "      --local-dir $MODEL_DIR"
  echo ""
  echo "[2] DeepSeek-Coder-V2-Lite Q4_K_M — ~10.4 GB (ALTERNATİF A)"
  echo "    hf download \\"
  echo "      bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF \\"
  echo "      DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf \\"
  echo "      --local-dir $MODEL_DIR"
  echo ""
  echo "[3] Gemma4-26B-A4B Q3_K_M — ~12.7 GB (ALTERNATİF B)"
  echo "    hf download \\"
  echo "      unsloth/gemma-4-26B-A4B-it-GGUF \\"
  echo "      gemma-4-26B-A4B-it-UD-Q3_K_M.gguf \\"
  echo "      --local-dir $MODEL_DIR"
  echo ""
}

# ─── SERVİS DOSYASI: Qwen3-Coder-30B-A3B ────────────────────
install_qwen3() {
  cat > /etc/systemd/system/llama-cpu-qwen3-30b.service << 'EOF'
[Unit]
Description=llama.cpp CPU — Qwen3-Coder-30B-A3B MoE (birincil)
After=network.target
# Bu model başlatılmadan önce eski 14B servisi durdurulmuş olmalı

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp

ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /data/models/Qwen3-Coder-30B-A3B-Instruct-Q3_K_M.gguf \
  --host 127.0.0.1 \
  --port 8081 \
  --ctx-size 16384 \
  --threads 4 \
  --threads-batch 4 \
  --parallel 1 \
  --mlock \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on

# İlk yüklemede 45-90 sn sürebilir
TimeoutStartSec=180

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  echo "✓ llama-cpu-qwen3-30b.service kuruldu"
}

# ─── SERVİS DOSYASI: DeepSeek-Coder-V2-Lite ─────────────────
install_deepseek() {
  cat > /etc/systemd/system/llama-cpu-deepseek-lite.service << 'EOF'
[Unit]
Description=llama.cpp CPU — DeepSeek-Coder-V2-Lite MoE (alternatif A)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp

ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /data/models/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf \
  --host 127.0.0.1 \
  --port 8082 \
  --ctx-size 16384 \
  --threads 4 \
  --threads-batch 4 \
  --parallel 1 \
  --mlock \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on

TimeoutStartSec=180

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  echo "✓ llama-cpu-deepseek-lite.service kuruldu"
}

# ─── SERVİS DOSYASI: Gemma4-26B-A4B ────────────────────────
install_gemma4() {
  cat > /etc/systemd/system/llama-cpu-gemma4-26b.service << 'EOF'
[Unit]
Description=llama.cpp CPU — Gemma4-26B-A4B MoE (alternatif B)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp

# Gemma4 Google'ın önerdiği parametrelerle çalışır:
# --temp 1.0 --top-p 0.95 --top-k 64
# Düşük temperature (0.0) Gemma4'te tekrar döngülerine yol açabilir
ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /data/models/gemma-4-26B-A4B-it-UD-Q3_K_M.gguf \
  --host 127.0.0.1 \
  --port 8083 \
  --ctx-size 16384 \
  --threads 4 \
  --threads-batch 4 \
  --parallel 1 \
  --mlock \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on \
  --temp 1.0 \
  --top-p 0.95 \
  --top-k 64

TimeoutStartSec=180

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  echo "✓ llama-cpu-gemma4-26b.service kuruldu"
}

# ─── YARDIMCI SCRIPT: model-switch ──────────────────────────
install_switch_script() {
  cat > /usr/local/bin/model-switch << 'SWITCHEOF'
#!/bin/bash
# Kullanım: model-switch qwen3 | deepseek | gemma4 | status

SERVICES=(
  "llama-cpu-qwen3-30b"
  "llama-cpu-deepseek-lite"
  "llama-cpu-gemma4-26b"
)

status_all() {
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  CPU Model Servisleri Durum                      ║"
  echo "╚══════════════════════════════════════════════════╝"
  for svc in "${SERVICES[@]}"; do
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    port=""
    case "$svc" in
      *qwen3*)    port="8081" ;;
      *deepseek*) port="8082" ;;
      *gemma4*)   port="8083" ;;
    esac
    if [ "$state" = "active" ]; then
      echo "  ✓ AKTIF   [$port] $svc"
    else
      echo "  ✗ durmuş  [$port] $svc"
    fi
  done
  echo ""
}

stop_all() {
  echo "Tüm CPU modelleri durduruluyor..."
  for svc in "${SERVICES[@]}"; do
    systemctl stop "$svc" 2>/dev/null && echo "  durduruldu: $svc" || true
  done
}

case "$1" in
  qwen3)
    stop_all
    sleep 2
    systemctl start llama-cpu-qwen3-30b
    echo "✓ Qwen3-Coder-30B-A3B başlatıldı (port 8081)"
    echo "  Log: journalctl -fu llama-cpu-qwen3-30b"
    ;;
  deepseek)
    stop_all
    sleep 2
    systemctl start llama-cpu-deepseek-lite
    echo "✓ DeepSeek-Coder-V2-Lite başlatıldı (port 8082)"
    echo "  Log: journalctl -fu llama-cpu-deepseek-lite"
    ;;
  gemma4)
    stop_all
    sleep 2
    systemctl start llama-cpu-gemma4-26b
    echo "✓ Gemma4-26B-A4B başlatıldı (port 8083)"
    echo "  Log: journalctl -fu llama-cpu-gemma4-26b"
    ;;
  stop)
    stop_all
    echo "✓ Tüm CPU modelleri durduruldu"
    ;;
  status)
    status_all
    ;;
  *)
    echo "Kullanım: model-switch <qwen3|deepseek|gemma4|stop|status>"
    echo ""
    echo "  qwen3    → Qwen3-Coder-30B-A3B MoE    (port 8081) — birincil"
    echo "  deepseek → DeepSeek-Coder-V2-Lite MoE  (port 8082) — algoritma"
    echo "  gemma4   → Gemma4-26B-A4B MoE          (port 8083) — genel"
    echo "  stop     → Tüm CPU modellerini durdur"
    echo "  status   → Tüm servislerin durumunu göster"
    ;;
esac
SWITCHEOF

  chmod +x /usr/local/bin/model-switch
  echo "✓ model-switch komutu kuruldu → kullanım: model-switch status"
}

# ─── ANA KURULUM ─────────────────────────────────────────────
main() {
  echo "Eski servis durduruluyor (varsa)..."
  systemctl stop llama-cpu-14b 2>/dev/null && systemctl disable llama-cpu-14b 2>/dev/null || true

  echo ""
  install_qwen3
  install_deepseek
  install_gemma4
  install_switch_script

  echo ""
  echo "Systemd yenileniyor..."
  systemctl daemon-reload

  echo ""
  echo "──────────────────────────────────────────────────────"
  echo " Servisler kaydedildi ama henüz BAŞLATILMADI"
  echo " Model dosyaları indirildikten sonra başlatın:"
  echo ""
  echo "   model-switch qwen3      ← birincil (önce bunu dene)"
  echo "   model-switch deepseek   ← algoritmik analiz için"
  echo "   model-switch gemma4     ← genel amaçlı"
  echo "   model-switch status     ← durum kontrolü"
  echo ""
  download_models
  echo "──────────────────────────────────────────────────────"
  echo ""
  echo "NOT: 28 GB bütçede aynı anda yalnızca BİR CPU modeli"
  echo "     çalıştırılabilir. model-switch otomatik stop eder."
  echo ""
}

main

```
dosyayı oluşturun:

```bash
sudo nano install_services.sh
```
yukarıda verilen içeriği ekleyiniz

sonra çalıştırılabilir hale getiriniz:
```bash
chmod +x install_services.sh
```
çalıştırınız: 
```bash
./install_services.sh
```
#### install_services.sh içindeki `model-switch` komutu

Script çalıştırıldıktan sonra artık şunu yapabilirsiniz:

```bash
model-switch qwen3      # Qwen3-30B başlat (önceki otomatik durur)
model-switch deepseek   # Değiştir
model-switch status     # Hangileri çalışıyor?
model-switch stop       # Hepsini durdur
```

28 GB'da aynı anda iki model çalıştıramazsınız. Script `stop_all` çağırıp 2 saniye bekleyip yeni modeli başlatır — bu 2 saniye `--mlock` ile kilitlenen belleğin serbest kalması için gerekne süre.
- böylelikle modelleri switch edebilirsiniz.. 
- script bunu da otomatik ilgili yere kurar,
- **`path` e eklendiği için doğrudan terminalden çağırabilirsiniz.**
---

## B.3 — LiteLLM API Gateway (Aynı CPU LXC’de)

### B.3.1 LiteLLM Kurulumu

LiteLLM, iki modeli (GPU & CPU) tek bir OpenAI uyumlu uçta birleştirecek.

**LiteLLM nedir tam olarak?**

OpenAI API formatında istekler alıp, farklı backend'lere (llama.cpp, Ollama, gerçek OpenAI, Anthropic vb.) yönlendiren bir proxy. 
Bu yapımızda üçüncü  bir cihaz buraya tek bağlantı yapacak: Continue.dev tek bir adres biliyor olacak (`http://SERVER_IP:4000/v1`), model seçimine göre LiteLLM doğru makineye yönlendiriyor.


```bash
pip3 install --break-system-packages 'litellm[proxy]'
```

### B.3.2 LiteLLM Konfigürasyon (`/opt/litellm/config.yaml`)

```bash
mkdir -p /opt/litellm
```

```bash
tee /opt/litellm/config.yaml << 'EOF'
model_list:
  # 1. Hızlı Katman (GPU Laptop - Anlık Kod Yazımı ve Tamamlama)
  - model_name: hizli-gpu
    litellm_params:
      model: openai/custom                      #burada custom yazmak zorunda
      api_base: http://10.10.10.3:8080/v1       # İzole AI Ağındaki GPU Laptop Coder (IP ve) portu
      api_key: dummy
      timeout: 60                               # GPU anlık cevap verdiği için 60sn fazlasıyla yeterli
      roles: {"user": "user", "assistant": "assistant"}

  # 2. Zeki Katman (Proxmox CPU LXC - Derin Mimari/Hata Ayıklama)
  - model_name: derin-cpu
    litellm_params:
      model: openai/custom                      #burada custom yazmak zorunda
      api_base: http://localhost:8081/v1        # Aynı container içindeki 14B modeli
      api_key: dummy
      timeout: 300                              # CPU tabanlı prompt işleme için güvenli süre (5 dk)

  # 3. Embedding Katmanı (GPU Laptop CPU'sunda - Yerel Kod Analizi/RAG)
  - model_name: hizli-embed
    litellm_params:
      model: openai/custom                      #burada custom yazmak zorunda
      api_base: http://10.10.10.3:8081/v1       # İzole AI Ağındaki GPU Laptop 8081 embedding portu
      custom_endpoint_type: "openai"            # LiteLLM'e bunun saf bir OpenAI API olduğunu dikte ediyoruz
      api_key: dummy
      timeout: 60

general_settings:
  master_key: "iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"  #tamamen size bağlı rastgele string
  request_timeout: 600                          # Genel tavan sınırı (10 dakika)
  store_model_in_db: false                      # Performans için loglama veritabanını kapalı tutuyoruz
EOF
```

**gelişmiş litellm yaml config:**

```yaml
# /opt/litellm/config.yaml
# Tüm modeller — aktif/pasif geçişler için yorum satırı kullanın

model_list:

# ──────────────────────────────────────────────────────
# GPU LAPTOP — 10.10.10.3
# ──────────────────────────────────────────────────────

# Tab autocomplete (her zaman açık)
- model_name: hizli-gpu
  litellm_params:
    model: openai/custom
    api_base: http://10.10.10.3:8080/v1
    api_key: dummy
    timeout: 60
    # Modelin ChatML şablonunu korumak ve prompt bozulmasını önlemek için rol eşleştirmesi [cite: 10, 15]
    roles: { "system": "system", "user": "user", "assistant": "assistant" }

# Embedding / RAG (her zaman açık)
- model_name: hizli-embed
  litellm_params:
    model: openai/custom
    api_base: http://10.10.10.3:8081/v1
    custom_endpoint_type: "openai"
    api_key: dummy
    timeout: 60
    # NOT: Embedding modeline 'roles' parametresi eklenmez.

    # ──────────────────────────────────────────────────────
    # CPU SUNUCU — 127.0.0.1 (Proxmox LXC)
    # Aşağıdaki modellerden yalnızca biri aynı anda çalışır.
    # Aktif olanı systemctl start ile başlatın.
    # ──────────────────────────────────────────────────────

    # BİRİNCİL: Qwen3-Coder-30B-A3B (port 8081)
- model_name: derin-cpu
  litellm_params:
    model: openai/custom
    api_base: http://127.0.0.1:8081/v1
    api_key: dummy
    timeout: 300
    # Sistem talimatlarının ve kod asistanı rollerinin doğru tercümesi için [cite: 2, 12]
    roles: { "system": "system", "user": "user", "assistant": "assistant" }

# ALTERNATİF A: DeepSeek-Coder-V2-Lite (port 8082)
- model_name: derin-cpu-deepseek
  litellm_params:
    model: openai/custom
    api_base: http://127.0.0.1:8082/v1
    api_key: dummy
    timeout: 300
    roles: { "system": "system", "user": "user", "assistant": "assistant" }

# ALTERNATİF B: Gemma4-26B-A4B (port 8083)
- model_name: derin-cpu-gemma
  litellm_params:
    model: openai/custom
    api_base: http://127.0.0.1:8083/v1
    api_key: dummy
    timeout: 300
    roles: { "system": "system", "user": "user", "assistant": "assistant" }

general_settings:
  master_key: "iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
  request_timeout: 600
  store_model_in_db: false

```


| Servis Adı | Çalıştığı Fiziksel Cihaz | LiteLLM İçindeki Adresi (api_base) | Görevi |
| :--- | :--- | :--- | :--- |
| hizli-gpu | 💻 GPU Laptop | http://10.10.10.3:8080/v1 | Satır arası hızlı kod tamamlama (Tab-autocomplete) |
| hizli-embed | 💻 GPU Laptop | http://10.10.10.3:8081/v1 | Projeyi tarayıp yapay zekaya öğretme (RAG / @codebase) |
| derin-cpu | 🎛️ Proxmox LXC | http://localhost:8080/v1 | Büyük mimari sorunları çözme, chat üzerinden derin analiz |

mevcut enabled edilmiş service leri öğrenmek için:
```bash
systemctl list-unit-files --type=service --state=enabled
```

`master_key` neden var? LiteLLM'e gelen her istekte bu key olmalı, yoksa reddeder. Bu gerçek bir güvenlik önlemi değil — yerel ağda başka bir cihazın yanlışlıkla (veya kasıtlı olarak)  modellerinizi kullanmasını önler. İstediğiniz herhangi bir kelimeyi yazabilirsiniz. 

kalıp :
```bash
curl http://localhost:4000/v1/models -H "Authorization: Bearer `master_key`"

```
örnek: 
```bash
curl http://localhost:4000/v1/models -H "Authorization: Bearer yerel-ai-sifrem-2024"
```


### B.3.3 LiteLLM Servisi 
#### (`/etc/systemd/system/litellm.service`)

```bash
tee /etc/systemd/system/litellm.service << 'EOF'
[Unit]
Description=LiteLLM Proxy
After=network.target

[Service]
Type=simple
ExecStart=litellm --config /opt/litellm/config.yaml --port 4000
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```
####   Servisi Başlat

```bash
sudo systemctl daemon-reload

systemctl enable --now litellm
```

Durum kontrolü:

```bash
sudo systemctl status litellm

```

---

# C — İSTEMCİ LAPTOP (Geliştirme Makinesi)

Artık kod yazdığınız makine. Hiçbir model yükü yok.

## C.1 VS Code + Continue.dev Kurulumu

VS Code → Extensions → “Continue” aratın, yükleyin.

## C.2 Continue Konfigürasyonu

`~/.continue/config.yaml` dosyasını şu şekilde düzenleyin:

```yaml
name: Homelab AI
version: 1.0.0
schema: v1

# ══════════════════════════════════════════════════════════════
# MODELLER
# config.json → models, tabAutocompleteModel, embeddingsProvider
# hepsi burada roles ile ayrışıyor.
# ══════════════════════════════════════════════════════════════
models:

  # ── GPU — Chat + Edit + Apply ──────────────────────────────
  - name: "⚡ Hızlı GPU — Qwen2.5-Coder-3B"
    provider: openai
    model: hizli-gpu
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
      timeout: 30000
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      temperature: 0.1
      maxTokens: 2048
      stop:
        - "```\n\n"
        - "Human:"
        - "User:"
    chatOptions:
      baseSystemMessage: |
        Sen yerel homelab'da çalışan bir Python uzmanısın.
        Yanıtların her zaman Türkçe olsun.
        Kısa, doğrudan ve çalışır kod üret.
        Gereksiz açıklama ekleme. Yalnızca talep edilen değişikliği yap.

  # ── GPU — Autocomplete ─────────────────────────────────────
  - name: "Autocomplete — GPU"
    provider: openai
    model: hizli-gpu
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
    roles:
      - autocomplete
    autocompleteOptions:
      maxPromptTokens: 512
      debounceDelay: 300
      useCache: true
      #multilineCompletions: auto
      onlyMyCode: false
      disable: false

  # ── CPU — Derin analiz ─────────────────────────────────────
  - name: "🧠 Derin CPU — Qwen3-Coder-30B MoE"
    provider: openai
    model: derin-cpu
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
      timeout: 180000
    capabilities:
      - tool_use
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      temperature: 0.0
      maxTokens: 4096
      stop:
        - "Human:"
        - "User:"
    chatOptions:
      baseSystemMessage: |
        Sen ileri düzey Python kütüphanesi ve AI framework geliştirme konusunda uzman bir yazılım mimarısın.
        Yanıtların her zaman Türkçe olsun.

        Uzman olduğun alanlar:
        - Zaman ve alan karmaşıklığı analizi (Big-O, amortize analiz)
        - NumPy/PyTorch uyumlu API ve veri yolu tasarımı (contiguous memory, stride, broadcasting)
        - Saf Python ile C extension / Cython / Numba arasındaki performans sınırı kararları
        - Async/await, thread-safe veri yapıları, GIL stratejileri
        - Kütüphane paketi mimarisi: __init__.py katmanlaması, lazy import, public API yönetimi
        - Type annotation, Protocol sınıfları, dataclass vs NamedTuple tercihleri
        - Pytest, hypothesis (property-based testing), benchmark (pytest-benchmark) yazımı
        - Bellek profili (tracemalloc, memory_profiler) ve CPU profili (cProfile, line_profiler, scalene)

        Yanıt formatın:
        1. Sorunun kısa analizi
        2. Kod (type hint + docstring dahil)
        3. Zaman/alan karmaşıklığı (varsa)
        4. Dikkat edilmesi gereken edge case veya performans tuzakları
      
      baseAgentSystemMessage: |
        Sen bir Python kütüphanesi geliştirme uzmanısın. Yanıtların Türkçe olsun.
        Güncel bilgi, API değişiklikleri, yeni kütüphane sürümleri veya 
        dokümantasyon gerektiren sorularda web_search aracını kullan.
        Yerel codebase bilgisi yeterliyse arama yapma.

  # ── CPU — DeepSeek alternatif ──────────────────────────────
  - name: "🔬 Derin CPU — DeepSeek-Coder-V2-Lite"
    provider: openai
    model: derin-cpu-deepseek
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
      timeout: 180000
    capabilities:
      - tool_use
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      temperature: 0.0
      maxTokens: 4096
    chatOptions:
      baseSystemMessage: |
        Sen algoritma uzmanı bir Python geliştiricisisin.
        Yanıtların her zaman Türkçe olsun.
        Algoritmik sorunlarda adım adım çözüm göster, karmaşıklık analizi ver, alternatif yaklaşımları karşılaştır.

      baseAgentSystemMessage: |
        Sen bir Python kütüphanesi geliştirme uzmanısın. Yanıtların Türkçe olsun.
        Güncel bilgi, API değişiklikleri, yeni kütüphane sürümleri veya 
        dokümantasyon gerektiren sorularda web_search aracını kullan.
        Yerel codebase bilgisi yeterliyse arama yapma.
  # ── CPU — Gemma4 ───────────────────────────────────────────
  - name: "🌟 Derin CPU — Gemma4-26B MoE"
    provider: openai
    model: derin-cpu-gemma
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
      timeout: 180000
    capabilities:
      - tool_use
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      temperature: 1.0
      topP: 0.95
      topK: 64
      maxTokens: 4096
    chatOptions:
      baseSystemMessage: |
        Sen Python AI kütüphanesi geliştiren bir uzman mühendissin.
        Yanıtların her zaman Türkçe olsun.
        Tasarım kararlarını gerekçelendir, en iyi pratikleri uygula.
      
      baseAgentSystemMessage: |
        Sen bir Python kütüphanesi geliştirme uzmanısın. Yanıtların Türkçe olsun.
        Güncel bilgi, API değişiklikleri, yeni kütüphane sürümleri veya 
        dokümantasyon gerektiren sorularda web_search aracını kullan.
        Yerel codebase bilgisi yeterliyse arama yapma.

  # ── Embedding ──────────────────────────────────────────────
  # config.json embeddingsProvider → roles: [embed]
  - name: "Embedding — Nomic"
    provider: openai
    model: hizli-embed
    apiBase: http://192.168.1.50:4000/v1
    requestOptions:
      headers:
        Authorization: "Bearer iMsH%Tm%pP5KtF89Nz!pCs2e9bkytLZ-Xu"
    roles:
      - embed
    embedOptions:
      maxChunkSize: 512
      maxBatchSize: 64

# ══════════════════════════════════════════════════════════════
# CONTEXT — config.json contextProviders → context[].provider
# ══════════════════════════════════════════════════════════════
context:
  - provider: code
  - provider: docs
  - provider: diff
  - provider: terminal
  - provider: problems
  - provider: folder
  - provider: codebase
    params:
      nRetrieve: 25
      nFinal: 5
      useReranking: false
  - provider: open
    params:
      onlyPinned: false
  - provider: tree
  - provider: os

# ══════════════════════════════════════════════════════════════
# RULES — config.json'da global systemMessage yoktu,
# model bazlı systemMessage → chatOptions.baseSystemMessage oldu (yukarıda).
# Genel kurallar buraya:
# ══════════════════════════════════════════════════════════════
rules:
  - Yanıtların her zaman Türkçe olsun.
  - Kod bloklarında her zaman dil belirt (```python, ```bash vb.)
  - Yalnızca talep edilen değişikliği yap, fazlasını ekleme.

# ══════════════════════════════════════════════════════════════
# PROMPTS — config.json customCommands → prompts
# /komut adıyla çağrılır (örn: /complexity)
# ══════════════════════════════════════════════════════════════
prompts:
  - name: complexity
    description: Zaman ve alan karmaşıklığını analiz et
    prompt: |
      Seçili kodun zaman karmaşıklığını (Big-O) ve alan karmaşıklığını analiz et.
      Her döngü katmanını, özyinelemeli çağrıları ve veri yapısı seçimlerini gerekçelendir.
      Ortalama, en iyi ve en kötü durumları ayrı ayrı ver.
      Varsa daha verimli bir yaklaşımı öner. Yanıtını Türkçe ver.

  - name: profile
    description: Performans darboğazlarını bul ve profil öner
    prompt: |
      Seçili kodun performans darboğazlarını bul.
      Hangi satırların CPU veya bellek yoğun olduğunu tahmin et.
      Bu kodu profil etmek için scalene, cProfile veya line_profiler ile nasıl kullanılacağını göster.
      Somut optimizasyon önerileri sun. Yanıtını Türkçe ver.

  - name: typecheck
    description: Type annotation ekle ve mypy uyumunu kontrol et
    prompt: |
      Seçili koda eksiksiz Python type annotation ekle.
      Protocol sınıfları, TypeVar, Generic ve Union kullanımını gerektiği yerde uygula.
      mypy --strict ile uyumlu olmasını sağla.
      Değişiklikleri açıkla. Yanıtını Türkçe ver.

  - name: docstring
    description: Google stili docstring ekle
    prompt: |
      Seçili fonksiyon veya sınıfa Google stili docstring ekle.
      Her parametre için tip, açıklama ve örnek değer belirt.
      Returns, Raises ve Notes bölümlerini ekle.
      Kompleks algoritmalar için Examples bölümüne çalışır bir kod örneği koy.
      Yanıtını Türkçe ver.

  - name: pytest
    description: Kapsamlı pytest test suite üret
    prompt: |
      Seçili kod için kapsamlı bir pytest test suite yaz. Şunları dahil et:
      (1) normal akış testleri
      (2) sınır değer testleri
      (3) hatalı girdi ve exception testleri
      (4) varsa async davranış testleri
      Her test fonksiyonuna açıklayıcı Türkçe docstring ekle.
      @pytest.mark.parametrize kullan. Yanıtını Türkçe ver.

  - name: refactor
    description: SOLID prensiplerine uygun yeniden yapılandır
    prompt: |
      Seçili kodu SOLID prensiplerine göre yeniden yapılandır.
      Tek sorumluluk ihlallerini, gizli bağımlılıkları ve soyutlama eksikliklerini belirle.
      Sonuçtaki kodu daha test edilebilir, genişletilebilir ve bakımı kolay hale getir.
      Her değişikliği gerekçelendir. Yanıtını Türkçe ver.

  - name: numpy
    description: Python döngülerini NumPy vektör operasyonlarına dönüştür
    prompt: |
      Seçili Python kodundaki döngüleri NumPy vektör operasyonlarına dönüştür.
      Broadcasting kurallarını açıkla, bellek düzenini (C-contiguous vs Fortran-contiguous) göz önünde bulundur.
      Orijinal ve dönüştürülmüş versiyonun karmaşıklık farkını ve ne zaman numpy'ın avantajlı olmadığını da belirt.
      Yanıtını Türkçe ver.

  - name: async
    description: Bloklayıcı kodu async/await yapısına dönüştür
    prompt: |
      Seçili bloklayıcı kodu modern Python async/await yapısına dönüştür.
      asyncio.gather, asyncio.create_task ve context manager kullanımını göster.
      I/O sınırlı vs CPU sınırlı ayrımını yap, CPU sınırlı işlemler için ProcessPoolExecutor öner.
      Yanıtını Türkçe ver.

  - name: review
    description: "Kod incelemesi: güvenlik, performans ve stil"
    prompt: |
      Seçili kodu üç boyutta incele:
      (1) Güvenlik: injection, race condition, kaynak sızıntısı
      (2) Performans: O(n²) döngüler, gereksiz kopya, bellek sızıntısı
      (3) Stil ve bakım: adlandırma, okunabilirlik, PEP 8 uyumu
      Her bulgu için öncelik (kritik/orta/düşük) belirt. Yanıtını Türkçe ver.

  - name: api
    description: Kütüphane API'sini tasarla veya değerlendir
    prompt: |
      Seçili kodu bir Python kütüphanesinin public API'si olarak değerlendir. Şunları değerlendir:
      (1) Kullanım kolaylığı ve sezgisellik
      (2) Geriye dönük uyumluluk riskleri
      (3) Overloading ve duck typing dengesi
      (4) __repr__, __str__, __eq__ gibi özel metotların gerekliliği
      Alternatif API tasarımları öner. Yanıtını Türkçe ver.

# ══════════════════════════════════════════════════════════════
# MCP SERVERS
# ══════════════════════════════════════════════════════════════
mcpServers:
  - name: web-search-homelab
    type: sse
    url: http://192.168.1.50:8000/sse
    requestOptions:
      headers:
        X-API-Key: "IcX%ieP61lL+jOcGwG4SWR.pH!GhO7IF6O#ZV0i!1lBV8W}hk3%q6.k8f@3C"

```

Bu ayarlarla artık Continue.dev sohbet ekranında iki model arasında geçiş yapabilirsiniz:
- **Hızlı GPU:** Anlık tamamlama, küçük düzenlemeler
- **Derin CPU:** Proje çapında analiz, karmaşık kod üretimi
test: curl http://localhost:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":"merhaba, nasılsın?"}],
    "max_tokens":32,
    "stream":false
  }'
---

# D — KOD TABANI ARAMA (LanceDB + DuckDB, Opsiyonel) -( ## Continue.Dev indexleme yaptığı için UYGULANMADI)

**Önemli:** Continue.dev’in kendi `@codebase` özelliği de arama yapabilir. Eğer onu kullanmak isterseniz LanceDB’ye gerek kalmaz.  
Ama tam kontrol ve özel chunking istiyorsanız, kurulması iyi olacaktıe bu durumda,  sistemi kurun ve Continue’un dahili indekslemesini kapatın (`"disableIndexing": true` ekleyin).

**Not:** Bu kısım  uygulanmadığı için bu dökümanda yer verilmemiştir.

# E — WEB ARAMA ENTEGRASYONU (Opsiyonel) - Uygulandı.

CPU sunucusuna basit bir MCP web arama sunucusu ekleyerek güncel bilgi çekebiliriz.

## E.1 Kurulum

- Homelab felsefesine en uygun, herhangi bir ücretli API anahtarı (Google, Tavily vs.) gerektirmeyen ve tamamen sınırsız kullanabileceğiniz en temiz yöntem `DuckDuckGo` kütüphanesini kullanmaktır

 LXC container da ilgili paketleri kurunuz : 
```bash
pip3 install --break-system-packages \
      mcp \
      fastapi \
      uvicorn \
      uvloop \
      ddgs \
      cachetools \
      beautifulsoup4 \
      requests 
```
**not: duckduckgo-search paketi deprecated onun yerine ddgs paketi**

## E.2 MCP Sunucusu (`/opt/ai_engine/web_search_mcp.py`)

### E.2.1 Yapı Görseli

Yerel AI Laboratuvarı ve MCP İletişim Diyagramı (Mermaid)

```mermaid
graph TD
    %% Renklendirmeler ve Gruplar
    subgraph DevPC [GELİŞTİRİCİ BİLGİSAYARI / VS Code]
        VSCode[VS Code IDE]
        Continue[Continue.dev Eklentisi]
        VSCode <-->|Eklenti Entegrasyonu| Continue
    end

    subgraph ProxmoxHost [PROXMOX CPU LXC SUNUCUSU - 192.168.1.50]
        LiteLLM[LiteLLM Proxy <br/> Port: 4000]
        ZekiLLM[llama-server <br/> Qwen 14B Coder <br/> Port: 8080]
        MCPServer[web-search-homelab <br/> MCP Sunucusu <br/> Port: 8000]
        
        LiteLLM <-->|localhost:8080| ZekiLLM
    end

    subgraph GPULaptop [IZOLE AI AGINDAKI GPU LAPTOP - 10.10.10.3]
        HizliLLM[llama-server <br/> Qwen 3B Coder <br/> Port: 8080]
        EmbedLLM[llama-server <br/> Nomic Embed <br/> Port: 8081]
    end

    subgraph Internet [DIŞ DÜNYA]
        Google[Google / DuckDuckGo / Web]
    end

    %% İletişim Trafiği (İstekler ve Yanıtlar)
    Continue ===>|1. Kullanıcı Promptu <br/> Auth: yerel-ag-sifrem-2024| LiteLLM
    
    %% Model Yönlendirmeleri
    LiteLLM -->|2a. Hızlı Kod / Autocomplete| HizliLLM
    LiteLLM -->|2b. Derin Analiz / Akıl Yürütme| ZekiLLM
    LiteLLM -->|2c. @codebase RAG İndeksleme| EmbedLLM

    %% MCP Haberleşme Döngüsü (SSE Protokolü)
    Continue <===>|3. MCP İletişimi <br/> Protokol: SSE / HTTP POST <br/> api_key Güvenliği| MCPServer
    MCPServer -->|4. Gerçek Zamanlı Arama| Google
    Google -->|5. Arama Sonuçları / HTML Text| MCPServer
    MCPServer -->|6. Temizlenmiş Metin / Bağlam| Continue

```

### E.2.2 Kod kısmı
**Dikkat:** Kodun içerisinde Homelab sistemi için kritik öneme sahip şu özel yapılar vardır:

- `uvloop` ile asenkron olay döngüsü optimizasyonu.(CPU kısıtlarına rağmen çok düşük bir memory (51.4M)ve CPU kullanımı ile yüksek ağ performansı elde ediyorsunuz.)

- `ThreadPoolExecutor(max_workers=2)` ile arama motoru isteklerinin işlemciyi yormayacak şekilde iş parçacıklarına bölünmesi.

- `TTLCache` ile özel önbellekleme (Cache hit / Cache store) mantığı.

- `Gelişmiş regex temizlikleri`, domain ağırlıklandırma algoritmaları ve adaptif özet boyutlandırma (compact_result).

- `@mcp_server.list_tools()` ve `@mcp_server.call_tool()` şeklinde ham dekoratörler.

bunlardan dolayı `FastMCP` değil `Ham Server` + `SseServerTransport` şeklinde entegre edilmişitr.
**servisin sorunsuz ve çok düşük kaynak tüketimiyle** ayağa kalkmasını sağlayan şey de bu tercih oldu.

klasör oluşturun: 
```bash
mkdir -p /opt/ai_engine
```
dosyayı oluşturun: 
```bash
nano /opt/ai_engine/web_search_mcp.py

```
içeriği ekleyiniz:

```python
import asyncio
import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List

import uvicorn
import uvloop
from cachetools import TTLCache
from ddgs import DDGS
from mcp import types
from mcp.server import Server
from mcp.server.sse import SseServerTransport
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Mount, Route

# =========================================================
# LOGGING
# =========================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("mcp-web-search")

# =========================================================
# MCP SERVER & SSE TRANSPORT
# =========================================================
mcp_server = Server("web-search-homelab")
sse_transport = SseServerTransport("/messages")

# =========================================================
# CONFIG
# =========================================================
MCP_SECRET_KEY = "IcX%ieP61lL+jOcGwG4SWR.pH!GhO7IF6O#ZV0i!1lBV8W}hk3%q6.k8f@3C"

MAX_RESULTS        = 3
MAX_SNIPPET_LENGTH = 300
SEARCH_TIMEOUT     = 8
CACHE_TTL_SECONDS  = 600
CACHE_MAX_SIZE     = 128

executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ddg-search")
search_cache = TTLCache(maxsize=CACHE_MAX_SIZE, ttl=CACHE_TTL_SECONDS)

DOMAIN_SCORES: Dict[str, int] = {
    "github.com":            100,
    "docs.python.org":        95,
    "developer.mozilla.org":  90,
    "numpy.org":              85,
    "pytorch.org":            85,
    "stackoverflow.com":      80,
    "docs.rs":                75,
    "pypi.org":               70,
    "pkg.go.dev":             70,
    "npmjs.com":              60,
}

BAD_SNIPPET_PATTERNS = (
    "accept cookies", "cookie policy", "enable javascript",
    "javascript required", "privacy policy",
    "subscribe to read", "sign in to continue",
)

# =========================================================
# HELPERS
# =========================================================
_WHITESPACE_RE = re.compile(r"\s+")

def normalize_text(text: str) -> str:
    if not text:
        return ""
    return _WHITESPACE_RE.sub(" ", text).strip()

def trim_text(text: str, limit: int) -> str:
    text = normalize_text(text)
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "…"

def is_bad_snippet(text: str) -> bool:
    return any(p in text.lower() for p in BAD_SNIPPET_PATTERNS)

def deduplicate_results(results: List[Dict]) -> List[Dict]:
    seen: set = set()
    out = []
    for r in results:
        url = r.get("href", "").strip()
        if not url or url in seen or is_bad_snippet(r.get("body", "")):
            continue
        seen.add(url)
        out.append(r)
    return out

def prioritize_results(results: List[Dict]) -> List[Dict]:
    def score(r: Dict) -> int:
        url = r.get("href", "").lower()
        return sum(w for d, w in DOMAIN_SCORES.items() if d in url)
    return sorted(results, key=score, reverse=True)

def compact_result(index: int, result: Dict, snippet_limit: int) -> str:
    title = trim_text(result.get("title", ""), 120)
    body  = trim_text(result.get("body",  ""), snippet_limit)
    url   = result.get("href", "")
    return f"[{index}]\nTITLE: {title}\nURL: {url}\nCONTENT: {body}"

# =========================================================
# SEARCH ENGINE
# =========================================================
def run_search(query: str) -> List[Dict]:
    cached = search_cache.get(query)
    if cached is not None:
        logger.info("Cache hit | query='%s'", query)
        return cached

    with DDGS(timeout=SEARCH_TIMEOUT) as ddgs:
        raw = list(ddgs.text(query, region="wt-wt", safesearch="moderate", max_results=MAX_RESULTS))

    results = prioritize_results(deduplicate_results(raw))[:MAX_RESULTS]
    search_cache[query] = results
    logger.info("Cache store | query='%s' | hits=%d", query, len(results))
    return results

# =========================================================
# MCP TOOLS
# =========================================================
@mcp_server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="web_search",
            description=(
                "Searches the web for current information. "
                "Optimized for coding agents, Continue.dev, "
                "LiteLLM pipelines and homelab coder models."
            ),
            inputSchema={
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Search query"}},
                "required": ["query"],
            },
        )
    ]

@mcp_server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name != "web_search":
        raise ValueError(f"Unknown tool: {name}")

    query = normalize_text(arguments.get("query", "")).lower()
    if not query:
        return [types.TextContent(type="text", text="Search query is empty.")]

    try:
        logger.info("Search started | query='%s'", query)
        loop = asyncio.get_running_loop()
        results = await loop.run_in_executor(executor, run_search, query)

        if not results:
            return [types.TextContent(type="text", text="No search results found.")]

        snippet_limit = 180 if len(results) >= 3 else MAX_SNIPPET_LENGTH
        context = "\n\n".join(compact_result(i + 1, r, snippet_limit) for i, r in enumerate(results))
        logger.info("Search done | query='%s' | results=%d", query, len(results))
        return [types.TextContent(type="text", text=context)]

    except Exception:
        logger.exception("Search failed | query='%s'", query)
        return [types.TextContent(type="text", text="Search temporarily unavailable.")]

# =========================================================
# AUTH MIDDLEWARE
# =========================================================
class PureASGIAuthMiddleware:
    """
    Saf ASGI auth — SSE stream ile uyumlu.
    BaseHTTPMiddleware response'u tamponlar, SSE frame'lerini reddeder.
    Bu sınıf doğrudan ASGI (scope,receive,send) üzerinde çalışır.
    """
    _UNAUTHORIZED = json.dumps({"error": "Unauthorized"}).encode()

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        client_key = headers.get(b"x-api-key", b"").decode()
        if not client_key:
            for part in scope.get("query_string", b"").decode().split("&"):
                if part.startswith("api_key="):
                    client_key = part[len("api_key="):]
                    break

        if client_key != MCP_SECRET_KEY:
            body = self._UNAUTHORIZED
            await send({"type": "http.response.start", "status": 401,
                        "headers": [(b"content-type", b"application/json"),
                                    (b"content-length", str(len(body)).encode())]})
            await send({"type": "http.response.body", "body": body})
            return

        await self.app(scope, receive, send)

# =========================================================
# SSE ASGI APP
# =========================================================
# SORUN: Starlette Route bir fonksiyon alınca request_response() ile sarar.
# request_response() endpoint'ten Response nesnesi bekler.
# connect_sse() zaten EventSourceResponse ile send'e yazıyor.
# Fonksiyon bitince request_response() tekrar response göndermeye çalışır → ÇAKIŞMA.
#
# ÇÖZÜM: Route bir SINIF alınca onu saf ASGI callable olarak kullanır,
# request_response() sarmalaması yapmaz.
# SSEApp sınıfı __call__(scope,receive,send) ile saf ASGI davranır.

class SSEApp:
    """
    Saf ASGI SSE uygulaması.
    Starlette Route'a sınıf verilince request_response() sarması yapılmaz,
    __call__(scope,receive,send) doğrudan çağrılır.
    """
    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        async with sse_transport.connect_sse(scope, receive, send) as streams:
            await mcp_server.run(
                streams[0],
                streams[1],
                mcp_server.create_initialization_options(),
            )


async def health_endpoint(request: Request) -> Response:
    data = json.dumps({
        "status": "ok",
        "cache_size": len(search_cache),
        "cache_maxsize": search_cache.maxsize,
    }).encode()
    return Response(content=data, media_type="application/json")


# =========================================================
# APP
# =========================================================
routes = [
    Route("/sse",    endpoint=SSEApp(),        methods=["GET"]),
    Route("/health", endpoint=health_endpoint, methods=["GET"]),
    Mount("/messages", app=sse_transport.handle_post_message),
]

app = Starlette(
    routes=routes,
    middleware=[Middleware(PureASGIAuthMiddleware)],
)

# =========================================================
# ENTRYPOINT
# =========================================================
if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        workers=1,
        loop="uvloop",
        timeout_keep_alive=30,
        access_log=False,
        log_level="warning",
    )

```

çalıştırılabilir hale getirin:
```bash
chmod +x  /opt/ai_engine/web_search_mcp.py
```

## E.3 7/24 Çalışacak MCP Sunucusu Systemd Servisi Oluşturma

Servisin sunucu açıldığında otomatik başlaması ve çökme durumunda kendini canlandırması için bir daemon tanımlayın:

```bash
nano /etc/systemd/system/mcp-web-search.service

```

İçerisine şu konfigürasyonu girin:

```ini
[Unit]
Description=Homelab MCP Web Search Service (SSE)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ai_engine
ExecStart=/usr/bin/python3 /opt/ai_engine/web_search_mcp.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

```

Servisi kaydedip çıkın, ardından aktif hale getirin:

```bash
systemctl daemon-reload
systemctl enable --now mcp-web-search.service

```
**kontroller:**
```bash
systemctl status mcp-web-search.service

journalctl -xu mcp-web-search.service -f
```


Artık Continue içinde “@web Python 3.13 yeni özellikler” yazdığınızda güncel arama sonuçlarıyla yanıt alırsınız.

---

# F — TEST VE DOĞRULAMA

1. **GPU servisi:**  
   `curl http://GPU_IP:8080/v1/models` → model listesi dönmeli.

2. **Embedding servisi:**  
   `curl -H "Content-Type: application/json" -d '{"content":"test"}' http://GPU_IP:8081/embedding` → embedding vektörü dönmeli.

3. **CPU model servisi:**  
   `curl http://CPU_IP:8080/v1/models` → 14B model listelenmeli.

4. **LiteLLM:**  
   `curl http://CPU_IP:4000/v1/models` → `hizli-gpu` ve `derin-cpu` modelleri görünmeli.

5. **Continue.dev bağlantısı:**  
   VS Code’da Ctrl+L ile Continue panelini açın, model seçiminden “Hızlı GPU” seçip basit bir soru sorun. Cevap gelmeli.

---

# G — API ANAHTARI MESELESİ 

**Soru:** Bu sistem tamamen yerel, neden `apiKey` diye bir şey var? Ücretli bir anahtar mı gerekli?  
**Cevap:** Hayır, hiçbir dış servise bağlanmıyoruz.  
- llama.cpp’nin dahili OpenAI uyumlu sunucusu, gelen isteklerde `Authorization: Bearer <token>` başlığını görür ama **hiçbir doğrulama yapmaz**. Yani ne yazarsanız yazın kabul eder.  
- Ancak kullandığımız istemci kütüphaneleri (Continue.dev gibi) **boş bir `apiKey` göndermeye izin vermez**, bir şeyler yazılmasını zorunlu kılar.  
- Biz de bu zorunluluğu aşmak için **"dummy"** veya istediğimiz herhangi bir kelimeyi yazıyoruz.  
- LiteLLM’deki `master_key` ise **LiteLLM proxy’sine erişim için kendi belirlediğimiz bir şifredir**. İstemci makine bu şifreyi bilmezse proxy’yi kullanamaz. Bu da yerel ağdaki basit bir güvenlik önlemidir, ücretli bir API anahtarı değildir.

Özetle: Hiçbir yerde kredi kartı, OpenAI kaydı, ücretli hesap gerekmez. Tüm sistem ücretsiz ve yerel ağınıza özeldir.

---

# H — GÜNLÜK KULLANIM ÖZETİ

1. İki sunucu makineyi açık bırakın.
2. Geliştirme laptopunuzda VS Code’u açın.
3. Continue sohbet penceresinde ihtiyaca göre:
   - `@codebase` ile proje genelinde arama yapın (LanceDB kurduysanız),
   - `@web` ile güncel konuları araştırın,
   - Küçük değişiklikler için **Hızlı GPU** modelini, büyük mimari işler için **Derin CPU** modelini seçin.
4. eğer RAG de kurdu iseniz, haftada bir `python3 /opt/ai_engine/indexer.py` çalıştırarak yeni kodları indekse ekleyin.

---

# TEKNİK ÖZET TABLOSU

| Bileşen | Hangi Makine | Görev |
|--------|--------------|-------|
| llama-server (GPU) | GPU Laptop | Hızlı kod yazımı, autocomplete |
| llama-server (CPU) | CPU LXC | Derin analiz, büyük bağlam |
| LiteLLM | CPU LXC | Tek uç nokta, model yönlendirme |
| lanceDB + DuckDB | CPU LXC | Kod vektör veritabanı, metadata |
| nomic-embed | GPU Laptop | Kod parçalarını vektöre çevirme |
| Continue.dev | İstemci Laptop | IDE içi AI asistan arayüzü |
| Web arama MCP | CPU LXC | Güncel web sonuçlarını getirir |

---

Artık elinizde, üç cihazınızı da tam verimle kullanan, tamamen yerel, ücretsiz ve profesyonel bir geliştirme ortamı var.  


# Ekstralar

## opencode.ai configleri

bu yukarıdaki anlatılan yapının opencode.ai için de uyarlanmış hali bu şekildedir: 

olması gereken yapı:

```tree
~/.opencode/
├─ opencode.json
├─ AGENTS.md
├─ instructions/
│  └─ mcp-guidance.md
└─ commands/
   ├─ complexity.md
   ├─ profile.md
   ├─ typecheck.md
   ├─ docstring.md
   ├─ pytest.md
   ├─ refactor.md
   ├─ numpy.md
   ├─ async.md
   ├─ review.md
   └─ api.md
```
ilgili dosyalar opencode-md-s dizininde mevcuttur.

`opencode.json` dosyası  (asıl ayar ve config leriniz)
```json
{
  "$schema": "https://opencode.ai/config.json",

  "model": "homelab/hizli-gpu",
  "small_model": "homelab/hizli-gpu",

  "provider": {
    "homelab": {
      "name": "Homelab LiteLLM",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://192.168.1.50:4000/v1",
        "apiKey": "iMsH%Tm%pP5KtF89NzpCs2e9bkytLZ-Xu",
        "timeout": 300000,
        "chunkTimeout": 180000,
        "setCacheKey": true
      },
      "models": {
        "hizli-gpu": {
          "name": "⚡ Hızlı GPU — Qwen2.5-Coder-3B",
          "options": {
            "temperature": 0.1,
            "maxTokens": 2048,
            "stop": ["```\n\n", "Human:", "User:"]
          }
        },
        "derin-cpu": {
          "name": "🧠 Derin CPU — Qwen3-Coder-30B MoE",
          "options": {
            "temperature": 0.0,
            "maxTokens": 4096,
            "stop": ["Human:", "User:"]
          }
        },
        "derin-cpu-deepseek": {
          "name": "🔬 Derin CPU — DeepSeek-Coder-V2-Lite",
          "options": {
            "temperature": 0.0,
            "maxTokens": 4096
          }
        },
        "derin-cpu-gemma": {
          "name": "🌟 Derin CPU — Gemma4-26B MoE",
          "options": {
            "temperature": 1.0,
            "topP": 0.95,
            "topK": 64,
            "maxTokens": 4096
          }
        }
      }
    }
  },

  "agent": {
    "hizli": {
      "model": "homelab/hizli-gpu",
      "description": "Hızlı GPU modeli",
      "instructions": [
        "AGENTS.md"
      ]
    },
    "derin": {
      "model": "homelab/derin-cpu",
      "description": "Derin CPU modeli",
      "instructions": [
        "AGENTS.md"
      ]
    },
    "deepseek": {
      "model": "homelab/derin-cpu-deepseek",
      "description": "Algoritma odaklı model",
      "instructions": [
        "AGENTS.md"
      ]
    },
    "gemma": {
      "model": "homelab/derin-cpu-gemma",
      "description": "AI mimari odaklı model",
      "instructions": [
        "AGENTS.md"
      ]
    }
  },

  "mcp": {
    "web-search-homelab": {
      "type": "remote",
      "url": "http://192.168.1.50:8000/sse",
      "headers": {
        "X-API-Key": "IcX%ieP61lL+jOcGwG4SWR.pH!GhO7IF6O#ZV0i!1lBV8W}hk3%q6.k8f@3C"
      },
      "enabled": true 
    }
  },

  "instructions": [
    "~/.opencode/AGENTS.md",
    "~/.opencode/instructions/mcp-guidance.md"
  ]
}

```


