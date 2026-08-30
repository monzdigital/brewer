# Brewer Dağıtım Rehberi

## Kısa özet

Brewer, **Mac App Store'a konulamayan** bir uygulama sınıfındadır ve bunun
sebebi teknik bir zorunluluktur: App Store'daki her uygulama **App Sandbox**
içinde çalışmak zorundadır, ancak Brewer'ın temel işlevleri sandbox içinde
imkânsızdır:

| Brewer'ın yaptığı iş | Sandbox'ta mümkün mü? |
|---|---|
| `/opt/homebrew/bin/brew` çalıştırmak | ❌ (rastgele süreç yürütme yasak) |
| /opt/homebrew ve /Applications'a yazmak | ❌ |
| Çalışan başka uygulamaları kapatmak | ❌ |
| Karantina bayrağı (`xattr`) silmek | ❌ |
| ~/Library ve /Library'de kalıntı taramak | ❌ |
| Uygulama paketlerini yedekleyip değiştirmek | ❌ |
| brew servislerini (launchctl) yönetmek | ❌ |

Aynı sebepten **Cork, Cakebrew, AppCleaner, MacUpdater ve Latest de App
Store'da yoktur** - hepsi Apple'ın resmi ikinci kanalı olan **Developer ID +
Notarization** ile dağıtılır. Bu kanal Gatekeeper tarafından tam olarak
desteklenir: kullanıcı indirir, açar, macOS "Apple tarafından kötü amaçlı
yazılım taraması yapıldı" onayını gösterir.

## Developer ID ile dağıtım (önerilen ve hazır olan yol)

### 1. Bir kez yapılacak hesap işlemleri (sizin yapmanız gerekir)

1. **Apple Developer Program** üyeliği alın (99 USD/yıl):
   https://developer.apple.com/programs/enroll/
2. **Developer ID Application sertifikası** oluşturun:
   - https://developer.apple.com/account/resources/certificates/add
   - Tür: *Developer ID Application* → CSR yükleyin (Keychain Access →
     Certificate Assistant → Request a Certificate) → indirin → çift tıklayıp
     Keychain'e ekleyin.
   - Kontrol: `security find-identity -v -p codesigning` çıktısında
     `Developer ID Application: Adınız (TAKIMID)` görünmeli.
3. **Notary profili** kaydedin (app-specific password gerekir -
   https://account.apple.com → Sign-In and Security → App-Specific Passwords):

   ```bash
   xcrun notarytool store-credentials brewer-notary \
     --apple-id sizin@appleid.com \
     --team-id TAKIMID \
     --password xxxx-xxxx-xxxx-xxxx
   ```

> Not: `notarytool` ve `stapler` tam Xcode ile gelir. Xcode'u App Store'dan
> kurup `sudo xcode-select -s /Applications/Xcode.app` yapmanız gerekir
> (Command Line Tools'ta notarytool bulunmaz).

### 2. Her sürümde çalıştırılacak komut

```bash
SIGN_IDENTITY="Developer ID Application: Adınız (TAKIMID)" \
NOTARY_PROFILE="brewer-notary" \
bash scripts/release.sh
```

Script sırasıyla: arm64 + x86_64 derler, `lipo` ile evrensel ikili üretir,
`.app` paketler (ikon + PrivacyInfo.xcprivacy dahil), Hardened Runtime ile
Developer ID imzalar, Apple notary servisine gönderir, bileti staple eder ve
`dist/Brewer-<sürüm>.zip` çıktısını verir. Bu zip her Mac'te sorunsuz açılır.

### 3. Dağıtım kanalları

- **Web sitesi**: zip'i sitenize koyun. (İleride Sparkle gömülürse uygulama
  kendini güncelleyebilir - TODO.md'de.)
- **Homebrew cask**: en doğal kanal - kendi tap'inizde `brewer.rb` cask'i
  yayınlayın; kullanıcılar `brew install --cask <tap>/brewer` ile kurar.
- **GitHub Releases**: zip'i release olarak ekleyin.

## "Yine de App Store" istenirse ne olur?

Uygulamanın App Store'a girebilmesi için tüm brew/dosya işlemlerinden
arındırılması gerekirdi - geriye yalnızca formulae.brew.sh kataloğunu
*görüntüleyen* bir vitrin kalırdı (kurulum, güncelleme, servis, temizlik
olmadan). Bu, Brewer'ın amacını ortadan kaldırdığı için önerilmez. Sürüm
bilgileri, ikon, gizlilik manifestosu ve şifreleme beyanı yine de hazır
tutulmuştur; ileride böyle bir "katalog sürümü" istenirse altyapı hazırdır.

## Sürüm çıkarma kontrol listesi

- [ ] `packaging/Info.plist` → `CFBundleShortVersionString` ve `CFBundleVersion` artır
- [ ] `.build/release/Brewer --selftest` → tüm testler geçmeli
- [ ] `bash scripts/release.sh` (imza + notarizasyon değişkenleriyle)
- [ ] `spctl -a -vv dist/Brewer.app` → "accepted, source=Notarized Developer ID"
- [ ] Zip'i temiz bir Mac'te/hesapta açıp Gatekeeper akışını doğrula
