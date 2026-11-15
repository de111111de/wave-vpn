# Wave (Android, sing-box / libbox)

Flutter UI + нативный Kotlin-слой: `WaveVpnService` держит TUN и ядро sing-box (libbox.aar),
`MainActivity` отдаёт Flutter методы `com.wave.vpn/core` и поток `com.wave.vpn/stats`.

## Сборка на GitHub
1. Залей проект в репозиторий (ветка `main`).
2. Actions -> **Build Wave APK** -> Run workflow (или просто push).
3. APK: Releases / Artifacts (`Wave-arm64-v8a-release.apk`, `Wave-universal-release.apk`).

CI сам собирает `libbox.aar` из исходников sing-box (тег в `SING_BOX_VERSION`), генерит недостающий
android-скелет через `flutter create` и кладёт libbox в `android/app/libs`.
Версия sing-box и Flutter закреплены: `WaveVpnService.kt` написан под libbox v1.10.x.

## Подпись (необязательно)
Секреты репозитория: `WAVE_KEYSTORE_B64` (base64 .jks), `WAVE_KS_PASS`, `WAVE_KEY_ALIAS`, `WAVE_KEY_PASS`.
Без них APK подписывается debug-ключом: ставится, но обновляться поверх можно только сборкой с тем же ключом.

## Подписки
`https://` ссылки, `happ://add|import/...`, `incy://`, `v2raytun://`, `streisand://`, `clash://install-config?url=`,
`hiddify://import/...`, `wave://`, прямые `vless/vmess/trojan/ss/hy2/tuic/wg`, Base64, sing-box/xray JSON, Clash YAML.
Не поддерживается: `happ://crypt...` (зашифровано ключом Happ), XHTTP-транспорт (нет в sing-box).
