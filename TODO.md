# Brewer — TODO

## Dağıtım (kullanıcı talebi: 2026-08-30)

> "Tüm testler başarılı geçerse, Mac için App Store'a koymak için tüm hazırlıkları yap."

**Test durumu:** ✅ 25/25 self-test geçti + arayüz ekran görüntüleriyle doğrulandı
(paket listesi, detay paneli, Apps envanteri, Uninstaller kalıntı taraması).

**Önemli gerçek — Mac App Store engeli:** App Store'daki tüm uygulamalar App
Sandbox zorunluluğuna tabidir. Brewer'ın yaptığı işlerin neredeyse tamamı
sandbox içinde **teknik olarak imkânsızdır**: `brew` çalıştırmak, /opt/homebrew
ve /Applications'a yazmak, başka uygulamaları kapatmak, karantina bayrağı
silmek, Library klasörlerinde kalıntı taramak, uygulama paketlerini değiştirmek.
Bu yüzden Cork, Cakebrew, AppCleaner ve MacUpdater gibi bu sınıftaki tüm
uygulamalar App Store'da DEĞİLDİR; hepsi **Developer ID imzalı + notarize
edilmiş doğrudan indirme** ile dağıtılır. Brewer için doğru ve mümkün olan yol
da budur.

### Hazır olanlar (bu repoda)
- [x] Evrensel (arm64 + x86_64) release derleme desteği — `scripts/release.sh`
- [x] Developer ID imzalama + notarizasyon + staple + zip akışı — `scripts/release.sh`
- [x] Hardened Runtime entitlements dosyası — `packaging/Brewer.entitlements`
- [x] Gizlilik manifestosu (PrivacyInfo.xcprivacy) — pakete gömülüyor
- [x] `ITSAppUsesNonExemptEncryption = NO` (Info.plist)
- [x] Uygulama ikonu (`packaging/AppIcon.icns`), kategori, sürüm bilgileri
- [x] Adım adım dağıtım rehberi — `docs/DISTRIBUTION.md`

### Kullanıcının yapması gerekenler (hesap gerektirir)
- [ ] Apple Developer Program üyeliği (99 USD/yıl) — https://developer.apple.com/programs/
- [ ] "Developer ID Application" sertifikası oluşturup Keychain'e yüklemek
- [ ] `xcrun notarytool store-credentials` ile bir notary profili kaydetmek
- [ ] `SIGN_IDENTITY` ve `NOTARY_PROFILE` ortam değişkenleriyle `scripts/release.sh` çalıştırmak
- [ ] (İsteğe bağlı) Dağıtım kanalı: kendi web sitesi + Sparkle appcast, veya `brew tap` üzerinden cask

### Sonraki geliştirmeler
- [ ] Sparkle framework'ü gömerek Brewer'ın kendi kendini güncellemesi
- [ ] Homebrew cask tanımı (`brewer.rb`) hazırlanması
- [ ] Menü çubuğu simgesini gizleme tercihi (SwiftUI `MenuBarExtra(isInserted:)`
      macOS 26'da %100 CPU hatası tetiklediği için NSStatusItem ile yeniden yazılmalı)
