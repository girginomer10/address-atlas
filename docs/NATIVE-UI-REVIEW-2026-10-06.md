# Address Atlas — iOS / macOS kullanım incelemesi

Tarih: 6 Ekim 2026. İncelenen kaynak: `6261c37`, başlangıçta temiz `main`. İnceleyen: Codex.
İstek: Uygulamayı iOS ve macOS üzerinde kullanarak çalışmayan yerleri, UI/UX sorunlarını ve deneyimi etkileyen noktaları kaydetmek. Ürün kodu değiştirilmedi.

## Öncelikli bulgular

`Kullanım`: çalışan uygulamada tekrarlandı. `AX`: erişilebilirlik ağacından doğrulandı; sesli VoiceOver oturumu değildir. `Kaynak`: kod yolu/fixture üzerinden doğrulandı; canlı cihaz sonucu değildir. P1 yüksek, P2 normal, P3 düşük öncelik.

### F01 — P1 · iOS uygulama değiştirici görünür anahtarı açığa çıkarıyor

- **Kanıt:** Kullanım + ekran görüntüsü. Exchanges → yalnızca `QA-ONLY-FAKE-KEY-DO-NOT-USE` yaz → göz düğmesiyle göster → uygulama değiştiriciyi aç. Sahte anahtar önizleme kartında okunuyor.
- **Etki:** Kullanıcı uygulamadan ayrıldığında görünür bıraktığı kimlik bilgileri korunmuyor. Kurtarma kodu için de aynı yaşam döngüsü riski var; kurtarma kodunun önizlemede görünmesi ayrıca denenmedi.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/RootView.swift:108`; `ExchangesScreen.swift:349`; `SettingsScreen.swift:51` (aynı iOS kaynak dizini).
- **Düzeltme:** Sahne inactive olurken opak gizlilik örtüsü göster; anahtar/kod gösterim durumunu kapat. Geri dönüşte işleme devam edilebilsin.
- **Kabul:** Gösterilmiş sahte anahtarla app switcher, ana ekran ve ekran kilidi senaryolarında hiçbir hassas metin görünmemeli.
- **Görsel:** `ios-15-app-switcher-fake-key.png`.

### F02 — P2 · iOS büyük yazıda Varlıklar ekranı yatay taşıyor

- **Kanıt:** Kullanım + AX. Halka açık burn adresi tarandı; sistem yazısı `accessibility-extra-extra-extra-large` yapıldı. Assets içeriğinin sol başlıkları/filtreleri ve sağ tutarları ekranın dışına çıktı.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/AssetsScreen.swift:320`. Değer/kaynak sütununun `fixedSize(horizontal: true)` ve yüksek yerleşim önceliği aynı yatay satırdaki diğer içeriği sıkıştırıyor.
- **Düzeltme:** Erişilebilirlik boyutlarında ve dar genişlikte dikey satır düzenine geç. Finansal değerler uzun olsa da ekran genişliğini büyütmesin.
- **Kabul:** En büyük yazıda simge, ad, miktar ve değer okunmalı; yatay kesilme olmamalı.
- **Görseller:** `ios-13-assets-accessibility.png`, `ios-13-assets-accessibility-ax.json`. Normal yazıda bazı ad/miktarlar da kısalıyor: `ios-12-assets.png`; tam bilgiyi açan satır detayı yok.

### F03 — P2 · iOS Geçmiş ekranında büyük tutar tarihi eziyor

- **Kanıt:** Kullanım + AX. Varsayılan yazıda, yaklaşık 26,7 milyar USD toplamlı test taramasında tarih sütunu 25,5 puana düştü. Tarih ve “87 assets” birkaç karakterlik satırlara bölünüyor.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/SnapshotsScreen.swift:127`; tarih sütunu `:119`.
- **Düzeltme:** Tarih/varlık sayısı ile toplam değeri dar genişlikte ayrı satırlara taşı. Sil düğmesi tarih alanını daraltmasın.
- **Kabul:** Uzun yerel para biçimi ve büyük yazıda tarih anlamlı satırlarda okunmalı.
- **Görsel:** `ios-22-snapshots.png`.

### F04 — P2 · iOS manuel bakiye hatası formun görünmeyen üstünde kalıyor

- **Kanıt:** Kullanım + AX. Tokens altındaki manuel bakiye formunda geçersiz sayıyla Add holding seçildi. Hata sayfanın en üstüne yazıldı; AX konumu görünür alanın yaklaşık 1.018 puan üstündeydi. Kullanıcı düğmeye basınca hiçbir şey olmamış gibi görüyor.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/IOSSupport.swift:25`; `TokensScreen.swift:463`.
- **Düzeltme:** Hatalı alanın yanında açıklama ve erişilebilir duyuru göster; odağı veya kaydırmayı hataya taşı. Başarı durumunu da kullanılan formun yanında göster.
- **Kabul:** Manuel formun en altında geçersiz giriş yapıldığında hata başka yere kaydırmadan anlaşılmalı.
- **Kanıt dosyası:** `ios-11-assets-result.png` (dosya adı yanıltıcıdır; görüntü Tokens formudur).

### F05 — P2 · iOS sayısal token alanlarının erişilebilir adları ayırt edilemiyor

- **Kanıt:** AX + kaynak. Amount ve Total value alanları ayrı metin etiketlerine sahip, ancak alanların erişilebilir adlarında yalnızca ortak `0.00` yer tutucusu var.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/TokensScreen.swift:595`; alan tanımları `:417`.
- **Düzeltme:** Ortak alan bileşeninde görünür başlığı `accessibilityLabel` olarak bağla; birim/yardımı uygun ipucuna taşı.
- **Kabul:** VoiceOver her iki alana odaklandığında “Amount” ve “Total value, USD” ayrımını okuyabilmeli. Bu incelemede sesli VoiceOver kabul testi yapılmadı.

### F06 — P2 · iOS App Store paketinde iCloud kontrolü yanlışlıkla kapalı kalabilir

- **Kanıt:** Kaynak + Apple platform sözleşmesi; dağıtılmış cihaz paketinde denenmedi. Kontrol yalnızca simülatörün Mach-O entitlement bölümünü veya `embedded.mobileprovision` dosyasını okuyor. Bu iki kaynak yoksa container listesi boş ve iCloud kullanılmaz kabul ediliyor.
- **Yer:** `native/AddressAtlasMac/Sources/AddressAtlasMac/ICloudVaultService.swift:186`, `:235` ve `:51`. Bu dosya iOS tarafından da kullanılıyor.
- **Gerekçe:** [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), App Store’dan indirilen uygulamalarda gömülü provisioning profile bulunmadığını belirtir. Kodun yorumundaki App Store varsayımı bununla çelişiyor.
- **Düzeltme/kabul:** Dağıtım biçimine uygun, güvenli entitlement/configuration kontrolü kullan; App Store’dan dağıtılmış uygulamada giriş yapılmış Apple Account ile gerçek save/restore kabul testi yap. Simülatörde görülen “unavailable” mesajı tek başına bu hatanın kanıtı değildir.

### F07 — P2 · Hazır kayıtlı tokenın özel kopyası etkisiz ayarlarla kaydedilebiliyor

- **Kanıt:** Kaynak + mevcut EVM fixture. Ethereum USDC gibi hazır tokenın kontratı özel token olarak kabul ediliyor; özel satırın ad/fiyat/etkinlik ayarları tarayıcı tarafından sessizce yok sayılıyor.
- **Yer:** `native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateVaultMutations.swift:257`; `native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSupport.swift:188`.
- **Etki:** Kullanıcı ayarın kaydedildiğini görüyor ama sonuç değişmiyor; özel token kotası da tüketiliyor. Bu turda özel token ekleme etkileşimiyle tekrar edilmedi.
- **Düzeltme:** Hazır tokenın geçersiz kılınmaması korumasını koru; aynı kontratın eklenmesini açık gerekçeyle reddet veya etkisini açıkça tanımla.

### F08 — P2 · Kurtarma kodunun sistem kopyalama yolu pano korumasını atlıyor

- **Kanıt:** Kaynak. Kod metni `textSelection(.enabled)` ile seçilebilir. Sistem Copy eylemi, özel Copy code düğmesinin yalnızca yerel pano ve 60 saniye son kullanma ayarından geçmiyor.
- **Yer:** `native/AddressAtlasiOS/Sources/AddressAtlasiOS/SettingsScreen.swift:275` ve `:553`.
- **Düzeltme/kabul:** Tek korumalı kopyalama yolu sun; uzun basma ile kopyalama ve cihazlar arası pano davranışını ayrıca doğrula. Bu turda pano içeriği/kurtarma sırrı alınmadı.

### F09 — P3 · Mac gizlilik metni eski sunucu akışını anlatıyor

- **Kanıt:** Çalışan macOS uygulamasının AX ağacı + kaynak. Portfolio “Only encrypted snapshots go to your sync server” diyor; mevcut arayüz özel iCloud kopyasını sunuyor ve varsayılan legacy sync kapalı.
- **Yer:** `native/AddressAtlasMac/Sources/AddressAtlasMac/PortfolioComponents.swift:239`; açılış metninde benzeri `AddressAtlasApp.swift:147`.
- **Düzeltme:** Portföy, açılış ve iCloud açıklamalarını tek güncel veri akışına göre düzelt. macOS iCloud metnindeki yalnızca “another Mac” ifadesini de iPhone desteğiyle tutarlılaştır.

### F10 — P3 · Normal sıfır XRP trust line gereksiz tarama uyarısı üretiyor

- **Kanıt:** Kaynak + mevcut XRP fixture; canlı XRP cüzdanı denenmedi. Tek, geçerli sıfır bakiyeli trust line “invalid or non-positive” grubuna girip taramayı uyarılı gösteriyor.
- **Yer:** `native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerXRP.swift:390` ve `:449`.
- **Düzeltme:** Çelişen/bozuk kayıt kontrollerinden sonra geçerli sıfırları sessizce atla. [XRPL trust line belgeleri](https://xrpl.org/docs/concepts/tokens/fungible-tokens/trust-line-tokens), yeni trust line bakiyesinin sıfır başladığını belirtir.

### F11 — P1, legacy sunucu kapsamı · Native girişin kod değişim yolu 404 alıyor

- **Kanıt:** Gerçek proxy fonksiyonuna salt okunur yerel POST denemesi: `ADDRESS_ATLAS_SYNC_ONLY=true`, `/auth/native/exchange` → HTTP 404. Doğrudan route testleri proxy engelini kapsamıyor.
- **Yer:** `src/lib/sync/sync-only.ts:1`; native çağıran `native/AddressAtlasMac/Sources/AddressAtlasMac/PasskeyWebAuthenticator.swift:369`.
- **Etki:** Sunuculu passkey giriş/kayıt akışı browser aşamasından sonra hesap bağlantısını tamamlayamaz. **Varsayılan güncel native ürün akışında legacy sync kapalıdır; bu bulgu iCloud giriş hatası değildir.**
- **Düzeltme/kabul:** Exchange yolunu sync allowlist’e ekle; proxy üzerinden kod değişimi testi ekle. Gerçek passkey töreni veya üretim hesabı denenmedi.

## Ek UI/UX işleri

| İş | Gözlem ve öneri | Kanıt |
| --- | --- | --- |
| U01 · Sayı girişi | Ondalık klavyede görünür Done yok; boş alana dokunmak kapatmıyor. Add holding klavyenin arkasında kalabiliyor. Etkileşimli kaydırmayla aşılabildiği için tam engel değil. Done/sonraki alan ve görünür gönderim ekle. | iOS kullanım; `ios-09-decimal-keyboard.png`, `ios-10-keyboard-tap-outside.png`; `IOSSupport.swift:63` |
| U02 · Cüzdan doğrulama | Geçersiz `not-a-wallet` için “1 address detected” ve etkin Add görülüyor; gönderince doğru şekilde reddediliyor. Metin geçerli adresle değişince eski kırmızı hata başarıya kadar kalıyor. Tanıma/doğrulama dili ve eski hata temizliği tutarlı olsun. | `ios-03-invalid-wallet.png`, `ios-04-invalid-wallet-saved.png` (ismi aksine kayıt yapılmadı), `ios-05-wallet-keyboard.png`; `WalletsScreen.swift:99` |
| U03 · İlk kullanım | Boş Portfolio çok yer kaplayan sıfır metriklerle açılıyor; kaynak ekleme yönlendirmesi aşağıda. Doğrudan “Cüzdan ekle / Borsa bağla” eylemleri başlangıcı kolaylaştırır. | `ios-01-first-launch.png`; `PortfolioScreen.swift` |
| U04 · Tokens uzunluğu | Boş özel-token kartı ve tüm kontrat formu manuel bakiye formundan önce geliyor. “Özel token / Manuel bakiye” ayrımı veya ayrı ekleme akışı, sık kullanılan formu görünür kılar. | `ios-07-tokens.png`, `ios-08-manual-holding.png`; `TokensScreen.swift` |
| U05 · Tam varlık bilgisi | Uzun ad/miktar normal yazıda da kısalıyor; satır açıp tam miktarı inceleme yolu yok. Tam bilgiyi gösteren detay veya erişilebilir açıklama sun. | `ios-12-assets.png`; `AssetsScreen.swift:282` |
| U06 · Dil ve sayı biçimi | Türkçe sistemde İngilizce alan adları/tarih metinleri, Türkçe sayı ayırıcıları ve sistem Dosyalar metinleri birlikte görünüyor. Ondalık girişte beklenen ayırıcıyı görünür örnekle belirt; Türkçe ürün dili ayrı ürün kararı. | iOS kullanım; `ios-22-snapshots.png`, `ios-23-settings.png` |

## Çalışan ve denenmiş akışlar

| Akış | iOS 26.5 / iPhone 17 Pro simülatörü | macOS 26.5.1 yerel uygulama |
| --- | --- | --- |
| Açılış / yerel kasa | Yeni kurulum açıldı; yeniden başlatmada cüzdan/tarama korundu | İzole yeni kasa açıldı; cüzdan eklendi |
| Cüzdan doğrulama | Geçersiz adres reddedildi; geçerli halka açık test adresi kaydedildi | Geçerli test adresi kaydedildi |
| Gerçek salt okunur tarama | 87 varlık; bir kısmi tarama uyarısı görünür | İlk QA kasasında 87 varlık; ikinci taze QA kasasında da tarama tamamlandı |
| Varlıklar | Normal/büyük yazı, açık/koyu tema, uzun tutarlar incelendi | ETH araması 87 → 39 satır; küçük bakiyeleri gizleme 64 satır |
| Manuel bakiye | QATEST, miktar 2, toplam USD 1000 kaydedildi; sonraki snapshot gerektirdiği metinde açıklanıyor | Tokens ekranı/alanları incelendi; manuel kayıt yapılmadı |
| Geçmiş | Kayıt ve uyarı açılımı incelendi; F03 | Kaydedilmiş bir snapshot doğrulandı |
| Borsa | Sahte API anahtarı girişi ve göster/gizle; gerçek hesap bağlanmadı | Form ve tarama sürerken devre dışı durum incelendi; gerçek hesap bağlanmadı |
| CSV | Dosyalar’a yerel kaydetme başarılı; paylaşım penceresi açılıp gönderim yapılmadan kapatıldı; tekrar önizleme başarılı | Yerel CSV önizleme: 3 gezilebilir satır; kaydetme/harici paylaşım denenmedi |
| Kurtarma | Dosya hazırlama/picker açma ve iptal çalıştı; iptal durumunda kod gösterilmedi | Ayarlar/kurtarma formu incelendi; round-trip denenmedi |
| iCloud | Girişsiz, geliştirme imzalı simülatörde unavailable mesajı; aktarım kanıtı yok | Sayfa incelendi; buluta kaydetme otomatik onay denetimince engellendi |
| Pencere/erişilebilirlik | Normal ve AX5 yazı; form adları AX incelemesi | 900×632 başlangıç; 720×560 isteği minimum 900×632 ile sınırlandı; AX incelemesi |

macOS için ayrı bir iOS benzeri simülatör kullanılmadı; gerçek macOS uygulaması aynı kaynaklardan izole test kasasıyla çalıştırıldı. macOS ekran yakalama başarısız oldu; geçici uygulama içi yakalama da SwiftUI kaydırılan içeriği eksik üretti. Bu görüntüler görsel hata kanıtı olarak kullanılmadı. macOS sonuçları gerçek kontrol etkileşimleri ve AX okumalarıyla sınırlı; tam görsel QA tamamlanmış değildir.

## Açık doğrulamalar

- Export/Settings ekranından dosya hazırlanırken ayrılmanın ortak export kilidini açık bırakma olasılığı: kaynakta eksik yaşam döngüsü temizliği var. Denenen hızlı geri dönüşte picker açıldı ve iptal sonrası toparlandı; **kalıcı kilit bu turda tekrar edilmedi**. Uzun hazırlama, iPad boyut sınıfı değişimi ve tekrar deneme ayrıca test edilmeli.
- iCloud gerçek save/restore/conflict/delete, Apple Account değişimi, dağıtılmış iOS paketindeki entitlement kontrolü, fiziksel cihaz ve iCloud Keychain eşleşmesi açık.
- Gerçek borsa hesapları/anahtarları, çevrimdışı ağ kesintisi, 15 dakika otomatik yenileme, uzun süre arka plan, tam kurtarma round-trip, iPad/çoklu pencere, sesli VoiceOver ve kontrast ölçümü açık.
- macOS buluta kaydetme adımı otomatik onay incelemesince reddedildi: hedef hesap doğrulanmadığı için test portföyünün dış hedefe yüklenmesi yetkisi bulunmadığı değerlendirildi. Tekrar denenmedi; gelecekte hedef hesap ve yükleme onayı netleştirilmeli.

## Otomatik doğrulamalar ve kaynak kapsamı

- `npm test`: 591 başarılı, 58 atlandı; 50 başarılı test dosyası, 6 atlanan dosya. PostgreSQL entegrasyonu için gerçek test DB kurulmadı.
- `npm run native:test`: 500 test, 3 atlanan, 0 hata.
- `npm run typecheck`: başarılı.
- `npm run ops:test`: 62 ops + 6 frontend + 19 rotation + 2 systemd kontrolü başarılı.
- `npm run native:ios:build`: başarılı, simülatör için yerel ad-hoc imza; dağıtım imzası/TestFlight/App Store kabulü değil.
- İzole macOS QA derlemeleri ve imza doğrulaması başarılı. `npm run memory:doctor`: sağlıklı, 28 not.

430 takip edilen dosyanın envanteri çıkarıldı: native app 71, native core 83, server 119, kök/ops/docs 125, dışlanan 32. Kilit dosyası, resimler ve eski oturum günlükleri deliberate dışlandı. Güncel handoff okundu.

Kaynak incelemesi **tam repo onayı değildir**: tüm 15 iOS Swift dosyası ve iOS yapılandırması; ortak state/validation/mutations/scanning/termination/iCloud yolları; 26 core implementation dosyası; sunucunun 56 TS/TSX runtime dosyasının tamamı ve 6 root config incelendi. Core storage ve bazı güvenlik/yapılandırma modülleri, kalan Mac view/theme/test gövdeleri, çoğu server test gövdesi ve ops/release dosyalarının bir bölümü satır satır tamamlanmadı. Server CSS kısmi kaldı. İlk envanter ve sahiplik listesi yerel kanıt paketindedir. Kullanım testlerinde bulunan sorunlar kaynakta ikinci kez takip edildi; otomatik testlerin geçmesi bu UI sorunlarını gidermiyor.

## Yerel kanıtlar ve tekrar kurulum

Kanıtlar takip edilmeyen `build/native-ui-review-2026-10-06/` klasöründe tutuluyor; PNG/AX çıktıları `evidence/`, SHA-256 listesi `evidence-manifest.json`, kaynak envanteri `source-inventory.json`. Görüntüler gerçek iOS simülatörü etkileşimlerinden alındı; fixture görseli değildir. Git'e üretilmiş ikili/log/kasa dosyası eklenmedi.

- iOS simülatörü: `Address Atlas Review 2026-10-06`, UDID `FB630959-C8AC-48B2-9C02-78F21C19EC65`. Uygulama `0.2.0 (90)`, kaynak `6261c37`.
- Test adresi: yalnızca halka açık `0x000000000000000000000000000000000000dEaD`; kullanıcı portföyü değildir. Çok büyük tutarlar yerleşim stres testidir, fiyat/doğruluk garantisi değildir.
- macOS QA paketleri `/private/tmp/address-atlas-ui-review/mac/` altında; ayrı QA Keychain service, ayrı geçici kasa ve endpoint trust dosyası kullanır. Ürün arayüzü değiştirilmedi; dependency injection ve başarısız yerel görüntü yakalama kancası yalnızca geçici kopyada. iCloud entitlement eklenmedi.
- Mevcut kullanıcı kasası, Keychain kayıtları, üretim hesapları ve çalışan diğer simülatörler değiştirilmedi. İkinci QA imzasının yalnızca kendi test anahtarına erişim istemesi reddedildi; kullanıcı parolası alınmadı.

Önerilen uygulama sırası: F01 → F02–F05 → F06 dağıtım doğrulaması → F07/F08 → kalan metin/form işleri. F11, legacy sunucu tekrar kullanılacaksa açılmadan önce çözülmeli. Düzeltmeler için ayrı iş gerekir; bu oturum inceleme ve not teslimidir.
