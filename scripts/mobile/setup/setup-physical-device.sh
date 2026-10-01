#!/usr/bin/env bash
# Prépare un appareil Android physique pour JobbingTrack Mobile :
# - attend la détection ADB
# - active adb reverse sur les ports API/frontend
# - build APK debug (via build-apk-debug.sh = clean anti Zip)
# - installe et lance l'application
#
# Alias Make : make run-mobile · make mobile-device-ready
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/mobile/setup/resolve-flutter.sh
source "$ROOT/scripts/mobile/setup/resolve-flutter.sh"
MOBILE_DIR="$ROOT/mobile"
ADB_WAIT_SEC="${ADB_WAIT_SEC:-120}"
PACKAGE="cloud.hubera.jobs"
SKIP_BUILD="${SKIP_BUILD:-0}"
LAUNCH_APP="${LAUNCH_APP:-1}"

step=0
total_steps=5
ts() { date '+%H:%M:%S'; }
log() { printf '[%s] [mobile-setup %d/%d] %s\n' "$(ts)" "$step" "$total_steps" "$*"; }
fail() { printf '[%s] [mobile-setup] ERREUR: %s\n' "$(ts)" "$*" >&2; exit 1; }
banner() {
  printf '\n\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  printf '\033[0;36m  make run-mobile — build + install + lance (USB)\033[0m\n'
  printf '\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n'
}

pick_lan_ip() {
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '!/ docker| br-| veth| tun| wg/ { split($4, a, "/"); print a[1] }' \
    | grep -E '^192\.168\.|^10\.' \
    | head -n1
}

wait_for_device() {
  local elapsed=0
  while (( elapsed < ADB_WAIT_SEC )); do
    if adb devices | awk 'NR>1 && $2=="device" { found=1 } END { exit(found?0:1) }'; then
      adb devices -l
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed % 10 == 0 )); then
      log "En attente ADB (${elapsed}s/${ADB_WAIT_SEC}s) — câble données, débogage USB, RSA…"
    fi
  done
  fail "Aucun appareil ADB détecté après ${ADB_WAIT_SEC}s"
}

banner

# ——— 1. Appareil ———
step=1
DEVICE_ID="$(adb devices | awk 'NR>1 && $2=="device" { print $1; exit }')"
if [[ -z "${DEVICE_ID:-}" ]]; then
  log "Redémarrage serveur ADB…"
  adb kill-server >/dev/null 2>&1 || true
  adb start-server
  wait_for_device
  DEVICE_ID="$(adb devices | awk 'NR>1 && $2=="device" { print $1; exit }')"
fi
[[ -n "$DEVICE_ID" ]] || fail "Impossible de résoudre l'ID appareil"

MODEL="$(adb -s "$DEVICE_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
ANDROID="$(adb -s "$DEVICE_ID" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || true)"
log "Appareil OK · $DEVICE_ID · ${MODEL:-?} · Android ${ANDROID:-?}"

# ——— 2. adb reverse ———
step=2
PORTS=(5002 5003 3000)
for port in "${PORTS[@]}"; do
  if adb -s "$DEVICE_ID" reverse "tcp:${port}" "tcp:${port}" 2>/dev/null; then
    log "adb reverse tcp:${port} → OK"
  else
    log "adb reverse tcp:${port} ignoré"
  fi
done

# ——— 3. Comptes test + defines ———
step=3
cd "$ROOT"
node "$ROOT/scripts/mobile/setup/generate-debug-test-accounts.js"
LAN_IP="$(pick_lan_ip || true)"
export MOBILE_DEV_LAN_HOST="${MOBILE_DEV_LAN_HOST:-${LAN_IP:-}}"
if [[ -n "${MOBILE_DEV_LAN_HOST:-}" ]]; then
  log "MOBILE_DEV_LAN_HOST=$MOBILE_DEV_LAN_HOST (fallback hors reverse)"
else
  log "Pas d'IP LAN détectée — s'appuyer sur adb reverse 5002/5003"
fi
if [[ -n "${API_BASE_URL:-}" ]]; then
  log "API_BASE_URL=$API_BASE_URL"
fi

# ——— 4. Build ———
step=4
APK_FLUTTER="$MOBILE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
APK_LEGACY="$MOBILE_DIR/build/app/outputs/apk/debug/app-debug.apk"
if [[ "$SKIP_BUILD" == "1" ]]; then
  log "SKIP_BUILD=1 — pas de rebuild"
else
  t0=$(date +%s)
  log "Build APK debug (clean anti Zip) — peut prendre 1–3 min…"
  # Utilise le script canonique (clean + retry kernel_blob)
  FORCE_VERSION_BUMP="${FORCE_VERSION_BUMP:-0}" \
    bash "$ROOT/scripts/mobile/setup/build-apk-debug.sh"
  t1=$(date +%s)
  log "Build terminé en $((t1 - t0))s"
fi

APK_PATH="$APK_FLUTTER"
[[ -f "$APK_PATH" ]] || APK_PATH="$APK_LEGACY"
[[ -f "$APK_PATH" ]] || fail "APK introuvable : $APK_FLUTTER"
APK_SIZE="$(du -h "$APK_PATH" | awk '{print $1}')"
log "APK prêt · $APK_SIZE · $APK_PATH"

# ——— 5. Install + lance ———
step=5
log "Installation adb install -r (USB, ~30–90 s)…"
adb -s "$DEVICE_ID" install -r "$APK_PATH"
VER="$(adb -s "$DEVICE_ID" shell dumpsys package "$PACKAGE" 2>/dev/null \
  | awk -F= '/versionName=/{print $2; exit}' | tr -d '\r' || true)"
log "Installée · package $PACKAGE · versionName=${VER:-?}"

if [[ "$LAUNCH_APP" == "1" ]]; then
  adb -s "$DEVICE_ID" shell am force-stop "$PACKAGE" 2>/dev/null || true
  adb -s "$DEVICE_ID" shell am start -n "$PACKAGE/.MainActivity" \
    >/dev/null 2>&1 \
    || adb -s "$DEVICE_ID" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 \
    >/dev/null 2>&1 \
    || true
  log "App lancée sur le téléphone"
else
  log "LAUNCH_APP=0 — pas de lancement auto"
fi

printf '\n\033[0;32m✅ run-mobile terminé\033[0m\n'
log "Suite porteur : Connexion → Entreprises → Capgemini → candidatures/contacts/relances/entretiens/appels (MOB-ENT-01)"
log "Sans rebuild : SKIP_BUILD=1 make run-mobile   |   make mobile-apk-install-only"
log "Aide : make help-mobile-adb"
