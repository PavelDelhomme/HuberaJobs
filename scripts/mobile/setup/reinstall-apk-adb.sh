#!/usr/bin/env bash
# Réinstalle l'APK debug sur l'appareil ADB déjà connecté.
# Usage :
#   make mobile-apk-reinstall | make reinstall-apk | make reinstall-app
#   bash scripts/mobile/setup/reinstall-apk-adb.sh
#
# Variables :
#   SKIP_BUILD=1     — n'exécute pas flutter build (APK déjà présent)
#   INSTALL_ONLY=1   — alias de SKIP_BUILD=1
#   FAST_INSTALL=1   — tente adb --fastdeploy (défaut : 1 si app déjà installée)
#   LAUNCH_APP=1     — lance l'app après install (make reinstall-app)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/mobile/setup/resolve-flutter.sh
source "$ROOT/scripts/mobile/setup/resolve-flutter.sh"
PACKAGE="cloud.hubera.jobs"
APK="$ROOT/mobile/build/app/outputs/flutter-apk/app-debug.apk"
APK_LEGACY="$ROOT/mobile/build/app/outputs/apk/debug/app-debug.apk"

log() { printf '[mobile-reinstall] %s\n' "$*"; }
fail() { printf '[mobile-reinstall] ERREUR: %s\n' "$*" >&2; exit 1; }

DEVICE_ID="$(adb devices | awk 'NR>1 && $2=="device" { print $1; exit }')"
[[ -n "${DEVICE_ID:-}" ]] || fail "Aucun appareil ADB. Branchez le téléphone et autorisez le débogage USB."

log "Appareil: $DEVICE_ID"

for port in 5002 5003; do
  adb -s "$DEVICE_ID" reverse "tcp:${port}" "tcp:${port}" 2>/dev/null && \
    log "adb reverse tcp:${port} OK" || true
done

skip_build="${SKIP_BUILD:-${INSTALL_ONLY:-0}}"
if [[ "$skip_build" == "1" ]]; then
  log "SKIP_BUILD=1 — build ignoré"
else
  t0=$(date +%s)
  log "Build APK debug (~15–25 s si cache Gradle chaud)..."
  bash "$ROOT/scripts/mobile/setup/build-apk-debug.sh"
  t1=$(date +%s)
  log "Build terminé en $((t1 - t0))s"
fi

APK_PATH="$APK"
[[ -f "$APK_PATH" ]] || APK_PATH="$APK_LEGACY"
[[ -f "$APK_PATH" ]] || fail "APK introuvable: $APK (lancez sans SKIP_BUILD=1)"

apk_mb=$(du -m "$APK_PATH" | awk '{print $1}')
log "APK: $APK_PATH (${apk_mb} Mo)"

app_installed=0
if adb -s "$DEVICE_ID" shell pm path "$PACKAGE" 2>/dev/null | grep -q base.apk; then
  app_installed=1
fi

use_fast="${FAST_INSTALL:-}"
if [[ -z "$use_fast" ]]; then
  use_fast="$app_installed"
fi

install_apk() {
  local mode="$1"
  shift
  t0=$(date +%s)
  log "Installation ($mode) sur $DEVICE_ID..."
  if adb -s "$DEVICE_ID" install "$@" "$APK_PATH"; then
    t1=$(date +%s)
    log "Install terminée en $((t1 - t0))s ($mode)"
    return 0
  fi
  return 1
}

installed=0
if [[ "$use_fast" == "1" && "$app_installed" == "1" ]]; then
  if install_apk "fastdeploy" -r --fastdeploy; then
    installed=1
  else
    log "fastdeploy indisponible ou refusé — fallback install -r classique"
  fi
fi

if [[ "$installed" != "1" ]]; then
  # -d autorise le downgrade (ex. téléphone en 1.0.30, APK canonique 1.0.29 après alignement)
  if install_apk "streamed -r -d" -r -d; then
    installed=1
  else
    log "install -r -d échoué — tentative désinstall + install propre..."
    adb -s "$DEVICE_ID" uninstall "$PACKAGE" >/dev/null 2>&1 || true
    install_apk "streamed fresh" || fail "adb install a échoué (même après uninstall)"
    installed=1
  fi
fi

if [[ "${LAUNCH_APP:-0}" == "1" ]]; then
  adb -s "$DEVICE_ID" shell am force-stop "$PACKAGE" 2>/dev/null || true
  adb -s "$DEVICE_ID" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
  log "App lancée ($PACKAGE)"
fi

log "OK — APK réinstallé."
if [[ "${LAUNCH_APP:-0}" != "1" ]]; then
  log "Ouvrez JobbingTrack ou: adb shell monkey -p $PACKAGE -c android.intent.category.LAUNCHER 1"
fi
log "Astuce : install seule (~10–60 s USB) sans rebuild → SKIP_BUILD=1 make reinstall-apk"
