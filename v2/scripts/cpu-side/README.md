
# 1. Konfigürasyon dosyasını oluştur/düzenle 

```bash
nano /data/cpu_models.conf
```
# 2. Betiği çalıştırmak için 

dosyayı oluşturunuz:

```bash
sudo nano install_cpu_services.sh
```
verilen içeriği ekleyiniz,

sonra çalıştırılabilir hale getiriniz:
```bash
chmod +x install_cpu_services.sh
```
çalıştırınız, (sudo ile, Eğer LXC ise zaten root çalıştırıyorsanız sudo gerekmez)
```bash
sudo ./install_cpu_services.sh
```
# 3. Model listesini görmek için
```bash
cpu-model-switch list
```
# 4. Durumu görmek için
```bash
cpu-model-switch status
```
# 5. Modele değiştirmek  veya çalıştırmak için (örneğin Qwen3-30B)
```bash
cpu-model-switch switch qwen3-30b
```
# 6. Başka bir modele geçmek için
```bash
cpu-model-switch switch deepseek
cpu-model-switch switch qwen36-mudler-lordx64

```

 # Önemli Noktalar
- Model dosyalarının varlığı kontrol edilir, eksikse uyarı verir ama `indirme yapmaz` (manuel indirmeniz gerekiyor)

- Tek bir betik hem `servis`leri hem de `cpu-model-switch` aracını **günceller**.

- Argüman gerekmez – sadece  ./install_cpu_services.sh çalıştırılır.

- Konfigürasyon değişince aynı komutla yeniden güncelleyebilirsiniz.

- Model geçişleri sadece **`cpu-model-switch`** ile yapılır, **ekstra servis yönetimi** yoktur.

- `service_base` otomatik olarak `model_adı-sağlayıcı` şeklinde (sağlayıcı `hf_repo`'dan alınır).

- MTP parametreleri ve diğer vermek istediğiniz parametreler  `extra_params` içinde (--spec-type draft-mtp --spec-draft-n-max 3) verilebilir.

- threads_batch parametresi, MTP modellerinde --threads-batch değerini belirler. Konfigürasyonda belirtilmezse threads değeri kullanılır.

