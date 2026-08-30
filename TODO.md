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
- [ ] Sürüm stabil ve versiyonlu (✓ v1.0.0 hazır); notarizasyon şart değil ama önerilir
- [ ] Hazır olunca: `homebrew/homebrew-cask` fork'la → `Casks/b/brewer.rb` ekle (tap'tekinin aynısı)
      → `brew audit --new --cask brewer` temiz geçmeli → PR aç → maintainer onayı
- Kabul sonrası kendi tap'teki cask kaldırılır (çakışmayı önlemek için)

### Sonraki geliştirmeler
- [ ] Sparkle framework'ü gömerek Brewer'ın kendi kendini güncellemesi
- [ ] Homebrew cask tanımı (`brewer.rb`) hazırlanması
- [ ] Menü çubuğu simgesini gizleme tercihi (SwiftUI `MenuBarExtra(isInserted:)`
      macOS 26'da %100 CPU hatası tetiklediği için NSStatusItem ile yeniden yazılmalı)
