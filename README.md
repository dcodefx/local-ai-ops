


#  Homelab Local AI Gateway & Orchestration (v1)

Eski ve kısıtlı donanımları (Low-VRAM GPU laptop ve eski nesil CPU sunucuları) ağ seviyesinde birleştirerek; tamamen **yerel, internetten izole, web arama yetenekli (MCP)** ve yüksek performanslı bir Yapay Zeka Geliştirme Laboratuvarı kurma kılavuzu.

Bu depo, bütçe dostu donanımlarla, gizlilikten ödün vermeden (veri sızıntısız) kurumsal düzeyde bir kod asistanı altyapısını nasıl ayağa kaldıracağınızı adım adım gösterir.

---

##  Hangi İhtiyaca Yanıt Veriyor?

* **Eski Donanım Optimizasyonu:** Maxwell mimarili, 4GB VRAM'li eski kartları (GTX 960M) ve DDR3 bellek darboğazına sahip CPU sunucularını çöpe atmak yerine verimli birer AI işçisine dönüştürür.
* **Akıllı Çıkarım (Hierarchical Inference):** İstekleri türüne göre (hızlı satır arası tamamlama, derin mantık yürütme, embedding) ilgili donanıma otomatik yönlendirir.
* **Gerçek Zamanlı Bilgi (MCP Web Search):** Tamamen yerel ve ücretsiz DuckDuckGo kütüphanesi kullanarak, LLM'lerin güncel web dökümantasyonlarına erişmesini sağlar.
* **Tam Ağ İzolasyonu:** LLM servislerinin ev/ofis ağındaki diğer cihazlara veya dış dünyaya veri sızdırmasını ağ geçidi (VLAN) seviyesinde engeller.
* **IDE Entegrasyonu:** VS Code üzerinden `Continue.dev` veya `OpenCode.ai` eklentileriyle sıfır gecikmeli, akıcı bir geliştirme deneyimi sunar.

---

##  v1 Genel Mimarisi ve İletişim Akışı

Sistem, bütçe dostu cihazları tek bir OpenAI uyumlu API arkasında birleştiren katmanlı bir topolojiyle çalışır:

```text
┌────────────────────────────────────────────┐
│ GPU SUNUCU (CachyOS Laptop)                │
│ GTX 960M (4GB VRAM)                        │
│--------------------------------------------│
│  llama-server (Qwen2.5-Coder-3B GPU)     │
│  llama-server (Nomic Embedding CPU)      │
│ IP: 10.10.10.3                             │
└────────────────┬───────────────────────────┘
                 │
                 │ Tam İzole AI Ağı (VLAN Tüneli - 10.10.10.X)
                 │
┌────────────────▼───────────────────────────┐
│ CPU SUNUCU (Proxmox LXC Debian 12)         │
│ i7 4. Nesil, 32GB DDR3 RAM   (28 GB LXC)   │
│--------------------------------------------│
│  llama-server (Qwen3-Coder-30B-A3B MoE)  │
│  LiteLLM Proxy / Gateway (Port 4000)     │
│ 🔍 DDG-Search MCP Sunucusu (Port 8000)     │
│ IP: 10.10.10.2 / LAN: 192.168.1.50         │
└────────────────┬───────────────────────────┘
                 │
                 ▼ API: [http://192.168.1.50:4000/v1](http://192.168.1.50:4000/v1)
┌────────────────────────────────────────────┐
│ GELİŞTİRİCİ İSTEMCİ (Client PC)            │
│ VS Code + Continue.dev / OpenCode.ai       │
└────────────────────────────────────────────┘

```

---

## 🖥️ Test Edilen Donanım Altyapısı

| Cihaz Rolü | İşletim Sistemi / Katman | Donanım Özellikleri |
| --- | --- | --- |
| **GPU Sunucu** | CachyOS (Linux, xfce4) | Intel i7 4th Gen, NVIDIA GTX 960M (4GB VRAM), 16GB RAM |
| **CPU Sunucu** | (Proxmox VE 9.x) Debian 12 LXC (cpu=host) | Intel i7 4th Gen (4C/8T), 32GB DDR3 RAM |
| **Geliştirici PC** | Herhangi bir OS | Sadece VS Code ve istemci eklentileri yükü barındırır |

---

##  Öne Çıkan v1 Yetenekleri (Kullanım)

Geliştirme yaparken tek bir `LiteLLM` uç noktasına bağlanarak şu özellikleri kullanabilirsiniz:

* **Hızlı Kod Tamamlama:** GPU'da 3B model ile <100ms tepki.
* **Özel yazılmış web search `MCP`ile Güncel Arama:** DuckDuckGo üzerinden MCP entegrasyonu.
* **Derin Analiz için CPU Modeli:** 30B MoE model ile büyük bağlamlı kod incelemesi.
* **Model Switcher:** Gelişmiş otomatik `systemd` scripti sayesinde tek komutla (şimdilik sadece cpu tarafa uyarlandı) (`model-switch qwen3 | deepseek`) bellek kısıtlarına takılmadan modeller arası geçiş. 
Not: bu script şimdilik sadece ilgili cihaz üzerinde çalışır. Bu donanım özelliklerinde  aynı anda tek bir buyuk model çalışabildiği için tasarlandı
* **IDE Entegrasyonu:** VS Code + Continue.dev / OpenCode.ai ile tek API üzerinden erişim.

---

>  **Detaylı Kurulum Adımları:** Donanım hazırlığı, GLIBC/CUDA uyumsuzluk yamaları, UFW izolasyon kuralları ve adım adım konfigürasyonlar için [docs/v1/homelab-ai-setups.md](docs/v1/homelab-ai-setups.md) dosyasını inceleyin.

---

**Not:** daha detaylı ve geliştirilmiş yapı (farklı donanım, yeni modeller, kolay konfigurasyon) v2 ve sonrasında gelecektir..

##  Lisans ve Katkıda Bulunma

Bu proje **MIT** lisansı ile korunmaktadır. Benzer donanım kısıtlarına sahip homelab operatörlerinin ve bağımsız geliştiricilerin yararlarına sunulmuştur.


---

