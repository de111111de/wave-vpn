# 🌊 Wave VPN (Android • Sing-box Core)

Нативный клиент для Android в стиле «Abyssal Neon Wave» (аналог Happ и Incy) с поддержкой всех современных протоколов и форматов подписок.

## Поддерживаемые форматы
- **Deep-links сторонних приложений:** `wave://`, `happ://`, `incy://`, `v2raytun://`, `streisand://`, `clash://`, `hiddify://`, `sing-box://`
- **Прямые подписки (`https://`):** чтение заголовков `Subscription-Userinfo` (остаток ГБ и дата окончания), `Profile-Title`, `Support-Url`, `Announce`.
- **Протоколы:** `VLESS` (Reality, XTLS-Vision, WS, gRPC, HTTPUpgrade), `VMess`, `Hysteria2` (`hy2://`), `TUIC`, `Trojan`, `Shadowsocks` (включая SS-2022), `WireGuard`.
- **Конфиги:** сырые списки URI, Base64/Base64Url, JSON (`sing-box` / `xray`), YAML (`Clash`).

## Как собрать готовый `.apk` прямо на GitHub (за 3 минуты, без ПК)
1. Создай новый репозиторий на GitHub (например, `wave-vpn`).
2. Загрузи содержимое этого архива в репозиторий (или выполни `git push` из Termux).
3. Перейди во вкладку **Actions** → выбери **Build Wave APK** → нажми **Run workflow**.
4. Через ~3 минуты готовые файлы **`Wave-arm64-v8a-release.apk`** и **`Wave-universal-release.apk`** появятся во вкладке **Releases** и в **Artifacts** сборки.
