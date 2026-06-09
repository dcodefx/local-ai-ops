
# 1. Konfigürasyon dosyasını düzenleyiniz

```bash
nano /home/qfx/gpu_models.conf
```
# 2. Tek komutla kurunuz / güncelle (sudo ile)
```bash
sudo ./install_gpu_services.sh
```
# 3. Model listesini görebilirsiniz
```bash
gpu-model-switch list
```

# 4. Geçiş yapmak için

```bash
gpu-model-switch switch qwen3.5-4b-jackrong
```
# 5. Durumu kontrol etmek için

```bash
gpu-model-switch status
```


# Özet
- Tek bir betik hem `servis`leri hem de `gpu-model-switch` aracını **günceller**.

- Argüman gerekmez – sadece sudo ./install_gpu_services.sh çalıştırılır.

- Konfigürasyon değişince aynı komutla yeniden güncelleyebilirsiniz.

- Model geçişleri sadece **`gpu-model-switch`** ile yapılır, **ekstra servis yönetimi** yoktur.

- `service_base` otomatik olarak `model_adı-sağlayıcı` şeklinde (sağlayıcı `hf_repo`'dan alınır).


--- 