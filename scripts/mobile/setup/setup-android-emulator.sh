#!/usr/bin/env bash
# Émulateur Android local — remplace le Samsung USB pour les smokes ADB.
# Profil proche SM-G990B2 (S21 FE) : 1080×2340, API 34, google_apis x86_64.
#
# Usage (une fois, ~2–4 Go à télécharger) :
#   bash scripts/mobile/setup-android-emulator.sh install
#
# Démarrage rapide (SDK déjà installé) :
#   bash scripts/mobile/setup-android-emulator.sh start
#
# Tout-en-un install + démarrage + APK + adb reverse :
#   bash scripts/mobile/setup-android-emulator.sh up
#   bash scripts/mobile/setup-android-emulator.sh configure-gmail
#
# Variables :
#   MOBILE_ADB_DEVICE=emulator-5554   — forcé par ce script dans .env.mobile-emulator
#   EMULATOR_HEADLESS=1               — pas de fenêtre (-no-window)
#   SKIP_APK_BUILD=1                  — réutilise l’APK debug déjà buildé
#   CONFIGURE_EMULATOR_GMAIL=1        — après `up`, lance configure-emulator-gmail.js
#   CONFIGURE_EMULATOR_BLUEMAIL=1     — après `up`, installe + configure BlueMail OVH
#   JOBBINGTRACK_AVD_IMAGE=google_apis_playstore | google_apis
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/mobile/setup/resolve-flutter.sh
source "$ROOT/scripts/mobile/setup/resolve-flutter.sh"
MOBILE_DIR="$ROOT/mobile"
AVD_NAME="${JOBBINGTRACK_AVD_NAME:-JobbingTrack_S21_FE}"
_pick_sdk() {
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$ROOT/.android-sdk" "$HOME/Android/Sdk"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate" && -w "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "$ROOT/.android-sdk"
}
ANDROID_SDK="$(_pick_sdk)"
API_LEVEL="${ANDROID_API_LEVEL:-34}"
ABI="x86_64"
# google_apis_playstore = Play Store réel (installer BlueMail, etc.)
# Override : JOBBINGTRACK_AVD_IMAGE=google_apis pour l'ancienne image sans Play
AVD_IMAGE_FLAVOR="${JOBBINGTRACK_AVD_IMAGE:-google_apis_playstore}"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};${AVD_IMAGE_FLAVOR};${ABI}"
PACKAGE="cloud.hubera.jobs"
ENV_SNIPPET="$ROOT/.env.mobile-emulator"
PID_FILE="$ROOT/.android-sdk/emulator.pid"
LOG_FILE="$ROOT/.android-sdk/emulator.log"

env_bool() {
  [[ "${1:-0}" == "1" || "${1:-}" == "true" || "${1:-}" == "yes" ]]
}

read_root_env_key() {
  /usr/bin/node "$ROOT/scripts/env/env-get-key.cjs" "$1" 2>/dev/null || true
}

log() { printf '[emu-setup] %s\n' "$*"; }
fail() { printf '[emu-setup] ERREUR: %s\n' "$*" >&2; exit 1; }

export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator:$PATH"

sdkmanager_bin() {
  if [[ -x "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" ]]; then
    echo "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager"
  elif command -v sdkmanager >/dev/null 2>&1; then
    command -v sdkmanager
  else
    echo ""
  fi
}

ensure_cmdline_tools() {
  if [[ -x "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" ]]; then
    return 0
  fi
  log "Téléchargement Android command-line tools dans $ANDROID_SDK …"
  mkdir -p "$ANDROID_SDK/cmdline-tools"
  local zip="$ANDROID_SDK/cmdline-tools.zip"
  local url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  if ! curl -fsSL "$url" -o "$zip"; then
    fail "Impossible de télécharger les command-line tools ($url)"
  fi
  local tmp="$ANDROID_SDK/cmdline-tools/_unpack"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  unzip -q "$zip" -d "$tmp"
  rm -rf "$ANDROID_SDK/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$ANDROID_SDK/cmdline-tools/latest"
  rm -rf "$tmp" "$zip"
  log "command-line tools OK"
}

cmd_install_sdk() {
  ensure_cmdline_tools
  local sm
  sm="$(sdkmanager_bin)" || fail "sdkmanager introuvable"
  log "Acceptation licences SDK…"
  yes | "$sm" --sdk_root="$ANDROID_SDK" --licenses >/dev/null 2>&1 || true
  log "Installation platform-tools, emulator, API ${API_LEVEL}… (plusieurs minutes)"
  "$sm" --sdk_root="$ANDROID_SDK" \
    "platform-tools" "emulator" "platforms;android-${API_LEVEL}" "$SYSTEM_IMAGE"
  [[ -x "$ANDROID_SDK/emulator/emulator" ]] || fail "Binaire emulator absent après install"
  log "SDK Android prêt : $ANDROID_SDK"
  log "Prochaine étape : bash scripts/mobile/setup-android-emulator.sh up"
  log "Doc complète : docs/mobile/EMULATEUR_ADB.md"
}

cmd_create_avd() {
  ensure_cmdline_tools
  local avdm="$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"
  [[ -x "$avdm" ]] || fail "avdmanager introuvable"
  if "$ANDROID_SDK/emulator/emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    log "AVD déjà présent : $AVD_NAME"
    return 0
  fi
  log "Création AVD $AVD_NAME (Pixel 6 / API ${API_LEVEL})…"
  echo no | "$avdm" create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device pixel_6 \
    --force
  # Résolution proche Samsung S21 FE
  local cfg="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
  if [[ -f "$cfg" ]]; then
    {
      echo "hw.lcd.width=1080"
      echo "hw.lcd.height=2340"
      echo "hw.lcd.density=420"
    } >> "$cfg"
  fi
  log "AVD $AVD_NAME créé"
}

wait_for_boot() {
  local id="${1:-emulator-5554}"
  local elapsed=0
  local max="${EMULATOR_BOOT_SEC:-180}"
  log "Attente boot $id (max ${max}s)…"
  adb -s "$id" wait-for-device >/dev/null 2>&1 || true
  while (( elapsed < max )); do
    local boot
    boot="$(adb -s "$id" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]]; then
      adb -s "$id" shell input keyevent 82 >/dev/null 2>&1 || true
      log "Émulateur prêt : $id"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  fail "Timeout boot émulateur ($id)"
}

cmd_start_emulator() {
  [[ -x "$ANDROID_SDK/emulator/emulator" ]] || fail "SDK incomplet — lancez: $0 install"
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "Émulateur déjà lancé (pid $(cat "$PID_FILE"))"
    return 0
  fi
  mkdir -p "$(dirname "$PID_FILE")"
  local -a args=(-avd "$AVD_NAME" -no-snapshot-save -gpu swiftshader_indirect)
  if [[ "${EMULATOR_WRITABLE_SYSTEM:-0}" == "1" ]]; then
    args+=(-writable-system)
    log "Mode root possible : EMULATOR_WRITABLE_SYSTEM=1 (-writable-system)"
  fi
  if [[ "${EMULATOR_HEADLESS:-0}" == "1" ]]; then
    args+=(-no-window)
  fi
  log "Démarrage émulateur ${AVD_NAME}…"
  nohup "$ANDROID_SDK/emulator/emulator" "${args[@]}" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 2
  local emu_id
  emu_id="$(adb devices | awk '/^emulator-/{print $1; exit}')"
  [[ -n "$emu_id" ]] || fail "Aucun emulator-* dans adb devices — voir $LOG_FILE"
  wait_for_boot "$emu_id"
  write_env_snippet "$emu_id"
  echo "$emu_id"
}

write_env_snippet() {
  local id="${1:-emulator-5554}"
  cat >"$ENV_SNIPPET" <<EOF
# Généré par scripts/mobile/setup-android-emulator.sh
# Chargé automatiquement si MOBILE_PREFER_EMULATOR=1 dans .env
ANDROID_HOME=$ANDROID_SDK
ANDROID_SDK_ROOT=$ANDROID_SDK
MOBILE_ADB_DEVICE=$id
MOBILE_PREFER_EMULATOR=1
EMULATOR_CONTROLLER_URL=http://127.0.0.1:5055
ADB_FAST=1
ADB_UI_CACHE_MS=280
ADB_WAIT_POLL_MS=320
EOF
  log "Config émulateur : MOBILE_PREFER_EMULATOR=1 + MOBILE_ADB_DEVICE=$id → $ENV_SNIPPET"
  log "Prochaine étape : bash scripts/mobile/setup-android-emulator.sh up  (ou start + reverse)"
  log "Doc : docs/mobile/EMULATEUR_ADB.md"
}

cmd_reverse_and_apk() {
  local id
  id="$(adb devices | awk '/^emulator-/{print $1; exit}')"
  [[ -n "$id" ]] || fail "Émulateur non détecté"
  for port in 5002 5003 3000; do
    adb -s "$id" reverse "tcp:${port}" "tcp:${port}" 2>/dev/null && log "adb reverse tcp:${port} OK" || true
  done
  local apk="$MOBILE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
  [[ -f "$apk" ]] || apk="$MOBILE_DIR/build/app/outputs/apk/debug/app-debug.apk"
  if [[ ! -f "$apk" ]] && [[ "${SKIP_APK_BUILD:-0}" != "1" ]]; then
    log "Build APK debug…"
    (cd "$MOBILE_DIR" && "$FLUTTER_BIN" build apk --debug)
    apk="$MOBILE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
  fi
  [[ -f "$apk" ]] || fail "APK introuvable — build mobile ou copiez l’APK du Samsung"
  adb -s "$id" install -r "$apk"
  adb -s "$id" shell am force-stop "$PACKAGE" || true
  adb -s "$id" shell am start -n "$PACKAGE/.MainActivity"
  log "App installée sur $id — gateway 127.0.0.1:5002 via adb reverse"
}

cmd_configure_gmail() {
  local flag
  flag="$(read_root_env_key CONFIGURE_EMULATOR_GMAIL)"
  if ! env_bool "${CONFIGURE_EMULATOR_GMAIL:-$flag}"; then
    log "CONFIGURE_EMULATOR_GMAIL≠1 — lancez manuellement : node scripts/mobile/configure-emulator-gmail.js"
  fi
  if ! curl -sf "${EMULATOR_CONTROLLER_URL:-http://127.0.0.1:5055}/health" >/dev/null 2>&1; then
    fail "Contrôleur ADB absent sur ${EMULATOR_CONTROLLER_URL:-http://127.0.0.1:5055} — lancer tools/emulator-controller/server.js"
  fi
  /usr/bin/node "$ROOT/scripts/mobile/setup/configure-emulator-gmail.js"
}

cmd_configure_bluemail() {
  if ! curl -sf "${EMULATOR_CONTROLLER_URL:-http://127.0.0.1:5055}/health" >/dev/null 2>&1; then
    fail "Contrôleur ADB absent sur ${EMULATOR_CONTROLLER_URL:-http://127.0.0.1:5055} — lancer tools/emulator-controller/server.js"
  fi
  /usr/bin/node "$ROOT/scripts/mobile/setup/install-emulator-bluemail.js" || true
  /usr/bin/node "$ROOT/scripts/mobile/setup/configure-emulator-bluemail.js"
}

maybe_configure_bluemail() {
  local flag
  flag="$(read_root_env_key CONFIGURE_EMULATOR_BLUEMAIL)"
  if env_bool "${CONFIGURE_EMULATOR_BLUEMAIL:-$flag}"; then
    cmd_configure_bluemail || log "BlueMail AVD : terminer manuellement si échec IMAP (voir EMULATEUR_ADB.md)"
  fi
}

cmd_migrate_playstore() {
  log "Migration AVD → image Google Play (google_apis_playstore)…"
  log "L'AVD actuel sera recréé — comptes/apps émulateur seront perdus."
  AVD_IMAGE_FLAVOR="google_apis_playstore"
  SYSTEM_IMAGE="system-images;android-${API_LEVEL};${AVD_IMAGE_FLAVOR};${ABI}"
  cmd_stop 2>/dev/null || true
  ensure_cmdline_tools
  local sm
  sm="$(sdkmanager_bin)" || fail "sdkmanager introuvable"
  log "Téléchargement image Play Store API ${API_LEVEL} (~1 Go)…"
  yes | "$sm" --sdk_root="$ANDROID_SDK" --licenses >/dev/null 2>&1 || true
  "$sm" --sdk_root="$ANDROID_SDK" \
    "platform-tools" "emulator" "platforms;android-${API_LEVEL}" "$SYSTEM_IMAGE"
  local avdm="$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"
  if "$ANDROID_SDK/emulator/emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    log "Suppression ancien AVD $AVD_NAME…"
    echo no | "$avdm" delete avd -n "$AVD_NAME" 2>/dev/null || true
  fi
  cmd_create_avd
  cmd_start_emulator
  cmd_reverse_and_apk
  maybe_configure_gmail
  maybe_configure_bluemail
  log "Migration Play Store terminée — Play Store disponible sur l'émulateur."
}

maybe_configure_gmail() {
  local flag
  flag="$(read_root_env_key CONFIGURE_EMULATOR_GMAIL)"
  if env_bool "${CONFIGURE_EMULATOR_GMAIL:-$flag}"; then
    cmd_configure_gmail || log "Gmail AVD : terminer manuellement si 2FA Google (voir docs/mobile/EMULATEUR_ADB.md)"
  fi
}

cmd_stop() {
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  adb devices | awk '/^emulator-/{print $1}' | while read -r id; do
    adb -s "$id" emu kill 2>/dev/null || true
  done
  log "Émulateur arrêté"
}

cmd_status() {
  adb devices -l
  if [[ -f "$ENV_SNIPPET" ]]; then
    log "--- $ENV_SNIPPET ---"
    cat "$ENV_SNIPPET"
  fi
}

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Commandes : install | create-avd | start | reverse | configure-gmail | configure-bluemail | migrate-playstore | up | stop | status"
}

main() {
  mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")" 2>/dev/null || true
  local cmd="${1:-up}"
  case "$cmd" in
    install)       cmd_install_sdk; cmd_create_avd; log "→ Enchaîner : bash scripts/mobile/setup-android-emulator.sh up" ;;
    create-avd)    cmd_create_avd ;;
    start)         cmd_start_emulator ;;
    reverse)       cmd_reverse_and_apk ;;
    configure-gmail) cmd_configure_gmail ;;
    configure-bluemail) cmd_configure_bluemail ;;
    migrate-playstore) cmd_migrate_playstore ;;
    up)            cmd_install_sdk; cmd_create_avd; cmd_start_emulator; cmd_reverse_and_apk; maybe_configure_gmail; maybe_configure_bluemail ;;
    stop)          cmd_stop ;;
    status)        cmd_status ;;
    -h|--help|help) usage ;;
    *) fail "Commande inconnue: $cmd (voir --help)" ;;
  esac
}

main "${@:-up}"
