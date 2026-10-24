# Brewer - TODO

## Dağıtım (kullanıcı talebi: 2026-08-30)

> "Tüm testler başarılı geçerse, Mac için App Store'a koymak için tüm hazırlıkları yap."

**Test durumu:** ✅ 25/25 self-test geçti + arayüz ekran görüntüleriyle doğrulandı
(paket listesi, detay paneli, Apps envanteri, Uninstaller kalıntı taraması).

**Önemli gerçek - Mac App Store engeli:** App Store'daki tüm uygulamalar App
Sandbox zorunluluğuna tabidir. Brewer'ın yaptığı işlerin neredeyse tamamı
sandbox içinde **teknik olarak imkânsızdır**: `brew` çalıştırmak, /opt/homebrew
ve /Applications'a yazmak, başka uygulamaları kapatmak, karantina bayrağı
silmek, Library klasörlerinde kalıntı taramak, uygulama paketlerini değiştirmek.
Bu yüzden Cork, Cakebrew, AppCleaner ve MacUpdater gibi bu sınıftaki tüm
uygulamalar App Store'da DEĞİLDİR; hepsi **Developer ID imzalı + notarize
edilmiş doğrudan indirme** ile dağıtılır. Brewer için doğru ve mümkün olan yol
da budur.

### Hazır olanlar (bu repoda)
- [x] Evrensel (arm64 + x86_64) release derleme desteği - `scripts/release.sh`
- [x] Developer ID imzalama + notarizasyon + staple + zip akışı - `scripts/release.sh`
- [x] Hardened Runtime entitlements dosyası - `packaging/Brewer.entitlements`
- [x] Gizlilik manifestosu (PrivacyInfo.xcprivacy) - pakete gömülüyor
- [x] `ITSAppUsesNonExemptEncryption = NO` (Info.plist)
- [x] Uygulama ikonu (`packaging/AppIcon.icns`), kategori, sürüm bilgileri
- [x] Adım adım dağıtım rehberi - `docs/DISTRIBUTION.md`

### Yayın durumu (2026-08-30)
- [x] GitHub reposu: https://github.com/monzdigital/brewer (public)
- [x] v1.0.0 Release + `Brewer-1.0.0.zip` (evrensel, SHA-256'lı, notlar Gatekeeper adımlarını içerir)
- [x] GitHub Pages sitesi: https://monzdigital.github.io/brewer/ (`docs/` klasöründen)
- [x] Sitedeki indirme butonu `releases/latest/download/…` kalıcı linkine bağlı

### 🚨 Gatekeeper sorununun TÜM kullanıcılar için tek gerçek çözümü: NOTARIZASYON
macOS 15+ "sağ tık → Aç" atlatmasını kaldırdı; imzasız uygulama her kullanıcıda
"Çöp Sepeti'ne Taşı / Bitti" diyaloguna takılıyor. Bunu evrensel olarak yalnızca
Developer ID imzası + Apple notarizasyonu çözer - o zaman uygulama ilk tıkta,
uyarısız açılır. Altyapı hazır (release.sh), eksik yalnızca hesap adımları
(aşağıda). Notarizasyon gelene kadar geçici hafifletmeler uygulandı:
site/README/cask "Open Anyway" akışını anlatıyor; terminal için
`xattr -dr com.apple.quarantine /Applications/Brewer.app` öneriliyor.
Homebrew 7 `--no-quarantine` bayrağını tamamen kaldırdı (2026-10). Ayrıca
Homebrew 7, "Open Anyway" onayını yükseltmeye yalnızca imza kimliği
eşleşirse taşıyor; ad-hoc imza her derlemede değiştiği için notarize
edilmemiş Brewer her brew yükseltmesinden sonra yeniden engelleniyor.

### Kullanıcının yapması gerekenler (hesap gerektirir)
- [ ] Apple Developer Program üyeliği (99 USD/yıl) - https://developer.apple.com/programs/
- [ ] "Developer ID Application" sertifikası oluşturup Keychain'e yüklemek
- [ ] `xcrun notarytool store-credentials` ile bir notary profili kaydetmek
- [ ] Notarize edilmiş sürüm için `SIGN_IDENTITY` + `NOTARY_PROFILE` ile `scripts/release.sh` → `gh release upload` (o zamana kadar site "notarize edilmemiş erken sürüm" notu taşıyor)
- [x] Kendi tap: https://github.com/monzdigital/homebrew-tap → `brew install --cask monzdigital/tap/brewer`
      (bu Mac'te uçtan uca test edildi; Homebrew 6 ilk kullanımda tap'e güven soruyor)

### GitHub Community Standards (kullanıcı talebi: 2026-08-30)
https://github.com/monzdigital/brewer/community listesini tamamla:
- [x] Description + website ✓, README ✓
- [x] CODE_OF_CONDUCT.md (Contributor Covenant 2.1; iletişim: GitHub issues)
- [x] CONTRIBUTING.md (derleme, selftest, stil kuralları)
- [x] SECURITY.md (GitHub private vulnerability reporting)
- [x] Issue şablonları (bug + özellik) ve PR şablonu
- [x] LICENSE - kullanıcı GPL-3.0 seçti, eklendi
- [ ] (İsteğe bağlı) Repo Settings → Security → "Private vulnerability reporting"ı aç

### Resmi Homebrew'a (homebrew/cask) girme yol haritası
Hedef: önek olmadan `brew install --cask brewer` çalışsın. Kabul şartları:
- [ ] Bilinirlik eşiği: GitHub'da ≥75 yıldız VEYA ≥30 fork VEYA ≥30 izleyiciden biri
- [ ] Repo yaşı > 30 gün (brew audit bunu denetler)
- [ ] Sürüm stabil ve versiyonlu (✓ v1.0.0 hazır); Homebrew 7 ile homebrew/cask
      artık imzalı ve notarize edilmiş uygulama şartı arıyor (brew audit), yani notarizasyon zorunlu
- [ ] Hazır olunca: `homebrew/homebrew-cask` fork'la → `Casks/b/brewer.rb` ekle (tap'tekinin aynısı)
      → `brew audit --new --cask brewer` temiz geçmeli → PR aç → maintainer onayı
- Kabul sonrası kendi tap'teki cask kaldırılır (çakışmayı önlemek için)

### Sonraki geliştirmeler
- [ ] Sparkle framework'ü gömerek Brewer'ın kendi kendini güncellemesi
- [x] Homebrew cask tanımı (`brewer.rb`) hazırlanması (kendi tap'te yayında)
- [ ] Menü çubuğu simgesini gizleme tercihi (SwiftUI `MenuBarExtra(isInserted:)`
      macOS 26'da %100 CPU hatası tetiklediği için NSStatusItem ile yeniden yazılmalı)
- [x] Dock simgesini gizleme / yalnızca menü çubuğu modu + login'de başlatma (1.1)

## Kod incelemesi ve must-have analizi (2026-09-07)

Tüm kaynak (9.3k satır) satır satır incelendi; 18 hata düzeltildi, 14 geliştirme
eklendi (`fix/bugfixes-and-improvements` dalı, öz-test 25 → 32). Ayrıntılı rapor:
oturumdaki "Brewer Must-Have Analizi" artifact'ı. Kademeli özet:

### T0 - Yayın engelleri
- [ ] Notarizasyon (Developer ID) - hesap adımları yukarıda
- [ ] Sparkle ile kendini güncelleme (SPM bağımlılığı + GitHub Pages appcast + `generate_appcast` release.sh'ta)
- [ ] GitHub Actions CI (macOS runner: build + `--selftest`, tag'de evrensel zip)
- [ ] XCTest hedefi (parser'lar, sürüm karşılaştırma, kalıntı eşleşmesi brew'suz test edilsin)
- [ ] Resmi homebrew/cask başvurusu (bilinirlik eşiği sağlanınca)

### T1 - Rakip paritesi için şart
- [ ] Homebrew cask kataloğunu manuel uygulamalar için güncelleme kaynağı yapmak
      (Adopt eşleşmesi + cask sürümü vs CFBundleShortVersionString → "Homebrew'a taşı ve güncelle"; Latest 0.9+ modeli)
- [ ] Yerelleştirme (TR öncelikli; SwiftPM `defaultLocalization` + xcstrings)
- [ ] Servisler: log görüntüleme, `brew services run`, root servisleri (askpass)
- [ ] Açıklamaya göre arama (`brew search --desc`) + sonuçlarda durum rozetleri
- [ ] Kalıntı tarayıcı: plist içeriği (LaunchAgents/Daemons), pkg makbuzları, sahipsiz kalıntılar
- [ ] Geliştirici önbellekleri temizliği (DerivedData, npm/pip/cargo/gradle/CocoaPods, Docker)
- [ ] Login'de gizli başlangıç (menü çubuğu modunda pencere açmadan)
- [ ] Kurulum seçenekleri (`--HEAD`, `--build-from-source`, `--appdir`)
- [ ] Konsol: çıktı arama, komut paleti, Terminal'de aç
- [ ] Onboarding (Homebrew yoksa kurulum komutu, ilk çalıştırma turu)
- [ ] Menü çubuğunda Sparkle + App Store güncellemeleri, "Snooze all"
- [ ] Klavye kısayolları (⌘1-9, ⌘F, Esc) ve VoiceOver etiketleri

### T2 - Fark yaratanlar
- [ ] Discover "Trending" (formulae.brew.sh analytics API)
- [ ] Shortcuts / App Intents
- [ ] Brewfile diff, `bundle cleanup`, iCloud/Git senkron
- [ ] Anında açılış (son snapshot önbelleği)
- [ ] History'de çıktı saklama + tekrar çalıştır (çıktı saklama 1.2.0'da yapıldı; tekrar çalıştır bekliyor)
- [ ] Boyut/bağımlılık görselleştirme, "en büyük paketler"
- [ ] Yükseltme sonrası cleanup/autoremove politikası
- [ ] Widget (Xcode uzantı hedefi gerektirir)

### T3 - Kalite ve altyapı
- [ ] Swift 6 strict concurrency uyarıları (TaskConsole captured self, DownloadDelegate)
- [ ] os.Logger + "Sorun bildir" akışı (SmartDelete 1.2.0'da os.Logger kullanıyor)
- [ ] `CGWindowListCreateImage` → ScreenCaptureKit (tour-shots)
- [ ] Erişilebilirlik denetimi
- [ ] Notarizasyon sonrası Hardened Runtime regresyon testi

## Genel kontrol: macOS 27 + Homebrew 7 (2026-10-24, sürüm 1.2.0)

Ortam: macOS 27.0.1 "Golden Gate", Homebrew 7.0.10, Swift 6.4, Xcode 27.1.
Yüklü 1.1.0 yeni sistemde öz-testin tamamını geçti; Homebrew 7 JSON
biçimleri değişmemişti. Bulunan ve 1.2.0'da düzeltilenler:
- [x] Derleme bozuktu: SDK 27'de SwiftUI State bir makro, eklentisi yalnızca Xcode'da.
      `scripts/toolchain.sh` Xcode'u, yoksa CLT + macOS 26 SDK'yı seçiyor
- [x] `--no-quarantine` Homebrew 7'de kaldırıldı: site, README, cask notu ve 1.1.0 notları düzeltildi
- [x] SmartDelete hiç çalışmıyordu (~/.Trash Tam Disk Erişimi istiyor): artık
      Uygulamalar klasörleri FSEvents ile izleniyor, izin gerekmiyor
- [x] App Updates, Setapp sürümlerine satıcının normal/deneme akışından güncelleme
      öneriyordu (lisans bozabilirdi): Setapp ve App Store sürümleri hariç
- [x] Başarısız güncelleme yedeği kalıyordu, aynı sürüm tekrar yedekleniyordu
- [x] Discover: Arc kullanımdan kalktı, yerine Zen; kartlar deprecated/disabled durumunu gösteriyor
- [x] Brewfile sayacı açıklama satırlarını da sayıyordu
- [x] Homebrew 7 fırsatları: `brew doctor --json`, `brew vulns --json`, tap-info `trusted`, Tier 3 uyarısı
- [x] BrewUI (Homebrew'un resmi arayüzü, `brew install homebrew-app`, macOS 26+) karşısında
      site ve README konumlandırması
- [x] Başarısız işlemlerin çıktısı Geçmiş'te saklanıyor
- [ ] "Adopt 1password" 2026-10-24'te 21 dakika sonra başarısız oldu; çıktı o zaman
      saklanmıyordu. 1.2.0 ile tekrar denenip Geçmiş'teki çıktıya bakılmalı
- [ ] Notarizasyon hala bekliyor: Anahtar Zinciri'nde yalnızca "Apple Development"
      sertifikası var, "Developer ID Application" yok
