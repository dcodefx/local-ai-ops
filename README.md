

# Homelab Local AI Gateway & Orchestration

Eski veya kısıtlı  (düşük VRAM'li GPU'lar ve DDR3 tabanlı CPU sunucuları vb.) donanımları tamamen **yerel, internetten izole, web arama yetenekli (MCP) ve performanslı** bir yapıda toplayıp **Yapay Zeka destekli Geliştirme Laboratuvarı** kurmak için hazırlanmış rehber, konfigürasyon ve otomasyon koleksiyonudur.

Amaç yalnızca model çalıştırmak değil; modeli, servisi, ağı ve geliştirme araçlarını birlikte yönetebilen sade, sürdürülebilir ve tamamen yerel bir AI altyapısı oluşturmaktır.

Sistem temel olarak üç bileşenden oluşur:


* GPU sunucu
* CPU sunucu
* Geliştirici istemcisi

Tüm yapı tek bir OpenAI uyumlu API üzerinden erişilecek şekilde tasarlanmıştır.

> ⚠️ Bu repo belirli bir model veya donanıma bağımlı değildir. Amaç, düşük bütçeli veya eski sistemlerde yerel AI geliştirme altyapılarının kurulumu, optimizasyonu ve test edilmesi noktasında bir kılavuz hazırlamak, dikkat edilmesi gereken ve karşılaşılabilecek durumlara örnekler ve çözümler sunmaktır.

---

## Hangi İhtiyaca Yanıt Veriyor?

* **Donanım Verimliliği:** Düşük VRAM'li GPU'lar ve sınırlı kaynaklara sahip CPU sistemlerini kullanılabilir AI altyapılarına dönüştürür.
* **Hiyerarşik Çıkarım (Hierarchical Inference):** Hızlı kod tamamlama, derin analiz, embedding ve yardımcı servisleri farklı donanımlara dağıtarak kaynak kullanımını optimize eder.
* **Yerel ve Gizlilik Odaklı Çalışma:** Modeller, gateway katmanı ve yardımcı servisler tamamen yerel ağ içinde çalışabilir.
* **Dinamik Model Yönetimi:** CPU ve GPU tarafındaki modeller konfigürasyon dosyaları ve model-switch araçları üzerinden yönetilebilir.
* **Gerçek Zamanlı Bilgi Erişimi:** Opsiyonel MCP Web Search entegrasyonu ile güncel dokümantasyon ve web sonuçları kullanılabilir.
* **IDE Entegrasyonu:** Continue.dev ve OpenCode.ai üzerinden tek API ile tüm modellere erişilebilir.
* **Ağ İzolasyonu:** VLAN tabanlı mimari sayesinde AI servisleri ev veya ofis ağından mantıksal olarak ayrıştırılabilir.

---

## Ne Sağlıyor?

* Hızlı kod tamamlama için GPU üzerinde çalışan küçük modeller
* Derin analiz ve geniş bağlam işlemleri için CPU üzerinde çalışan büyük modeller
* Tek API üzerinden model yönlendirmesi için LiteLLM Gateway
* Yerel ve isteğe bağlı web araması için MCP Web Search
* VS Code, Continue.dev ve OpenCode.ai entegrasyonu
* VLAN tabanlı ağ izolasyonu
* Konfigürasyon tabanlı servis yönetimi
* Otomatik model geçiş (model-switch) araçları

Bu yapı "local-first" ve "privacy-first" çalışma yaklaşımını hedefler. Modeller iş yüküne göre ayrılır; istemci makine yalnızca merkezi servislerle iletişim kurar.

---

## Genel Mimari

```text
┌────────────────────────────────────────────┐
│ GPU SUNUCU                                 │
│--------------------------------------------│
│ llama.cpp GPU Modelleri                    │
│ Embedding Servisleri                       │
│ Dynamic GPU Models Service Manager         │
└────────────────┬───────────────────────────┘
                 │
                 │ İzole AI Ağı (VLAN)
                 │
┌────────────────▼───────────────────────────┐
│ CPU SUNUCU (Proxmox / Debian LXC)          │
│--------------------------------------------│
│ llama.cpp CPU Modelleri                    │
│ LiteLLM Gateway                            │
│ MCP Web Search                             │
│ Dynamic CPU Models Service Manager         │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ GELİŞTİRİCİ İSTEMCİSİ                      │
│--------------------------------------------│
│ VS Code                                    │
│ Continue.dev                               │
│ OpenCode.ai                                │
└────────────────────────────────────────────┘

Tek OpenAI Uyumlu API
http://SERVER_IP:4000/v1

```

Sisteminin temel fikri hiyerarşik çıkarımdır:

* Hızlı işler GPU tarafında çözülür.
* Ağır analiz ve reasoning işlemleri CPU tarafında çözülür.
* LiteLLM bu katmanları tek API altında birleştirir.
* İstemci tarafı hangi modelin hangi cihazda çalıştığını bilmek zorunda kalmaz.

---

## Katmanlar

### GPU Katmanı

GPU sunucu, küçük ve hızlı modeller için ayrılmıştır. Bu katman özellikle; Autocomplete, hızlı sohbet, kısa kod görevleri ve embedding servisleri için kullanılır. Kaynakları sınırlı GPU'larda daha küçük modeller daha verimli çalıştığından yapı buna göre tasarlanmıştır. GPU model servisleri ve model-switch araçları bulunur.

### CPU Katmanı

CPU tarafı daha büyük bağlam ve reasoning modellerini taşır. Aynı katmanda; LiteLLM Gateway, MCP Web Search, CPU model servisleri ve model-switch araçları bulunur. Bu bölüm özellikle bütçe dostu ancak yüksek RAM kapasitesine sahip sistemleri değerlendirmek amacıyla tasarlanmıştır.

### İstemci Katmanı

İstemci makine model çalıştırmaz. Yalnızca VS Code, Continue.dev ve OpenCode.ai gibi geliştirme araçlarını barındırır. Böylece geliştirme bilgisayarı hafif kalırken tüm AI yükü merkezi altyapıda toplanır.

---

## Ağ Yapısı

AI servisleri ayrı bir VLAN üzerinde tutulur.

* GPU sunucu yalnızca AI ağına bağlanabilir.
* CPU sunucu hem AI ağına hem ana ağa erişebilir.
* İstemciler yalnızca gateway katmanı üzerinden servislerle konuşur.

Bu yaklaşımda güvenlik sonradan eklenen bir katman değil, mimarinin doğrudan bir parçasıdır.

---

## Konfigürasyon Yaklaşımı

v2 ile birlikte servisler tek tek elle yönetilmez. CPU ve GPU tarafı için ayrı konfigürasyon dosyaları kullanılır:

* `cpu_models.conf`
* `gpu_models.conf`

Kurulum scriptleri bu dosyalardan gerekli systemd servislerini otomatik üretir. Bu yaklaşım; yeni model eklemeyi kolaylaştırır, parametre değişikliklerini merkezi hale getirir ve servis yönetimini sadeleştirir.

Model-switch araçları da aynı mantıkla çalışır. Yeni model başlatılmadan önce çalışan diğer model servisi durdurulur. Bu özellikle RAM ve VRAM açısından kısıtlı sistemlerde önemlidir.

(Donanım kısıtı sebebiyle aynı anda tek servis çalışabilir durumdadır.)

---

## v2 ile Gelen Değişiklikler

v1 sürümüne göre:

* Uzun konfigürasyonlar ana dokümandan ayrıldı.
* CPU ve GPU servisleri modüler hale getirildi.
* `.conf` tabanlı model yönetim sistemi eklendi.
* Otomatik systemd servis üretim scriptleri eklendi.
* CPU ve GPU için model-switch araçları tanıtıldı.
* MTP destekli modeller için esnek parametre desteği eklendi.
* LiteLLM, Continue.dev ve OpenCode.ai örnek konfigürasyonları ayrı dosyalara taşındı.
* Dokümantasyon daha modüler ve sürdürülebilir hale getirildi.
* Sadece model.conf dosyaları değiştirilip install scripti çalışıtırıldığında  ilgili switch scriptler ve systemd servisleri yoksa oluşturulmakta varsa  otomatik olarak güncellenmektedir.

---

## Test Edilen Donanım Altyapısı

Bu rehber öncelikle aşağıdaki donanımlar üzerinde geliştirilmiş ve test edilmiştir:

| Rol | Donanım |
| --- | --- |
| **GPU Sunucu** | Intel i7 4. Nesil + GTX 960M (4GB VRAM) + 16GB RAM |
| **CPU Sunucu** | Intel i7 4. Nesil (Haswell) + 32GB DDR3 RAM |
| **Sanallaştırma** | Proxmox VE + Debian 12 LXC (`cpu=host`) |
| **İstemci** | VS Code + Continue.dev / OpenCode.ai |

*Not: Mimari daha güçlü GPU'lara, modern CPU'lara ve farklı homelab yapılarına uyarlanabilecek şekilde tasarlanmıştır.*

---

## Test Edilen Model Aileleri

Bu repo belirli bir modele bağlı değildir. Zaman içerisinde farklı açık kaynak modeller, quantizasyon yöntemleri ve çalışma senaryoları test edilmiştir.

Örnek model aileleri:

* Qwen 2.5 Coder
* Qwen 3.5 Distill Serileri
* Qwen 3.6 A3B Distill Serileri
* Gemma 4 A4B Serileri
* DeepSeek-Coder V2 Lite
* Granite 4.x Serileri
* Nemotron Nano Serileri
* Çeşitli GGUF, MTP ve APEX varyantları

Yeni modeller ve optimizasyonlar kolayca eklenip test edilebilir.

---

## Repository Yapısı

```text

├── docs
│   ├── v1
│   │   └── homelab-ai-setups.md
│   └── v2
│       ├── configs
│       │   ├── continue-config.yaml
│       │   ├── litellm_config.yaml
│       │   └── opencode.json
│       ├── homelab-ai-setups.md
│       └── scripts
│           ├── cpu-side
│           │   ├── cpu_models.conf
│           │   ├── install_cpu_services.sh
│           │   └── README.md
│           ├── gpu-side
│           │   ├── gpu_models.conf
│           │   ├── install_gpu_services.sh
│           │   └── README.md
│           └── web_search_mcp.py
├── LICENSE
└── README.md

```

---

## Başlangıç Noktası

Bu README, mimarinin genel görünümünü ve tasarım kararlarını özetlemektedir. Kurulum adımları, konfigürasyon örnekleri ve operasyonel detaylar ise `docs/v2` altında yer almaktadır.


Yeni kurulumlar için **`docs/v2/homelab-ai-setups.md`** dosyası ile başlanması önerilir. 

Bu doküman;

* Ağ mimarisi ve VLAN izolasyonu
* Proxmox ve LXC yapılandırmaları
* llama.cpp ve LiteLLM kurulumu
* Continue.dev ve OpenCode.ai entegrasyonu
* MCP Web Search entegrasyonu
* Model yönetimi ve servis otomasyonu
* Kurulum sürecinde karşılaşılan yaygın problemler ve çözüm yöntemleri

konularını bölümlendirilmiş şekilde ve adım adım açıklar.

---

## Kimler İçin?

Bu repo özellikle:

* Eski donanımı değerlendirmek isteyen homelab kullanıcıları
* Yerel AI geliştirme ortamı kurmak isteyen geliştiriciler
* Ağ, model ve servis yönetimini tek yapıda toplamak isteyenler
* Gizlilik ve yerel çalışma önceliği olan kullanıcılar
* Homelab ölçeğinde geliştirilen dağıtık AI mimarilerinden kurumsal yapılara taşınabilecek fikirler ve yaklaşımlar arayanlar
* Sanallaştırma, ağ izolasyonu, model orkestrasyonu ve AI servis yönetimi gibi bileşenleri üretim ortamına taşımadan önce laboratuvar ölçeğinde doğrulamak isteyenler; yerel geliştirme ve gizlilik odaklı AI platformları için referans mimariler arayan ekipler

için hazırlanmıştır.

---

## Sınırlar

Bu proje bir ürün değil, referans mimaridir. Kurulumlar gerçek sistemlerde test edilmiştir ancak donanım ve ortam farklılıkları nedeniyle uyarlama gerekebilir. Bazı özellikler deneysel olabilir veya gelecekte değişebilir.

---

## Kısa Kullanım Özeti

1. GPU ve CPU servislerini başlatın.
2. LiteLLM Gateway'i çalıştırın.
3. Continue.dev veya OpenCode.ai yapılandırmasını yükleyin.
4. Tek API üzerinden modellere bağlanın.
5. Gerekirse `gpu-model-switch` veya `cpu-model-switch` ile aktif modeli değiştirin.

---

## Lisans

Bu proje [MIT Lisansı](LICENSE) altında yayınlanmaktadır.