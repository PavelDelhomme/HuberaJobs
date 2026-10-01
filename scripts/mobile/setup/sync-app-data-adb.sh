#!/usr/bin/env bash
# Copie les données locales JobbingTrack (session, prefs) d'un appareil ADB vers un autre.
# Ce n'est PAS un clone complet Samsung One UI — uniquement l'app cloud.hubera.jobs.
#
# Prérequis : même APK debug (même signature) sur source et cible ; app installée des deux côtés.
#
# Usage :
#   MOBILE_ADB_SOURCE=R5CT7263YJL MOBILE_ADB_DEVICE=emulator-5554 bash scripts/mobile/sync-app-data-adb.sh
#   bash scripts/mobile/sync-app-data-adb.sh --locale   # copie aussi langue/région système (approximatif)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PACKAGE="${ANDROID_PACKAGE:-cloud.hubera.jobs}"
DATA_DIR="/data/data/$PACKAGE"
ARCHIVE="${TMPDIR:-/tmp}/jobbingtrack-app-data-$$.tar"
COPY_LOCALE=0

log() { printf '[sync-app-data] %s\n' "$*"; }
fail() { printf '[sync-app-data] ERREUR: %s\n' "$*" >&2; exit 1; }

pick_usb_device() {
  adb devices | awk '/^R|^Z|^A/ && $2=="device" { print $1; exit }'
}

pick_emulator() {
  adb devices | awk '/^emulator-/{ print $1; exit }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --locale) COPY_LOCALE=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "Option inconnue: $1" ;;
  esac
  shift
done

SOURCE="${MOBILE_ADB_SOURCE:-$(pick_usb_device)}"
TARGET="${MOBILE_ADB_DEVICE:-$(pick_emulator)}"
[[ -n "$SOURCE" ]] || fail "Source ADB introuvable (brancher Samsung ou MOBILE_ADB_SOURCE=…)"
[[ -n "$TARGET" ]] || fail "Cible ADB introuvable (lancer émulateur ou MOBILE_ADB_DEVICE=…)"
[[ "$SOURCE" != "$TARGET" ]] || fail "Source et cible identiques ($SOURCE)"

for id in "$SOURCE" "$TARGET"; do
  adb -s "$id" shell pm path "$PACKAGE" >/dev/null 2>&1 \
    || fail "App $PACKAGE absente sur $id — installez l'APK debug d'abord"
done

log "Source: $SOURCE → Cible: $TARGET"

log "Export données app depuis $SOURCE…"
if ! adb -s "$SOURCE" exec-out "run-as $PACKAGE tar cf - -C $DATA_DIR ." >"$ARCHIVE" 2>/dev/null; then
  fail "run-as échoué sur $SOURCE. APK debug requis (pas release store). Root Samsung non nécessaire si debug."
fi
[[ -s "$ARCHIVE" ]] || fail "Archive vide — pas de données ou run-as refusé"

log "Import données app vers $TARGET…"
adb -s "$TARGET" exec-out "run-as $PACKAGE sh -c 'cd $DATA_DIR && tar xf -'" <"$ARCHIVE"
rm -f "$ARCHIVE"

if [[ "$COPY_LOCALE" == "1" ]]; then
  locale="$(adb -s "$SOURCE" shell getprop persist.sys.locale 2>/dev/null | tr -d '\r' || true)"
  [[ -z "$locale" ]] && locale="$(adb -s "$SOURCE" shell settings get system system_locales 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$locale" && "$locale" != "null" ]]; then
    adb -s "$TARGET" shell settings put system system_locales "$locale" 2>/dev/null || true
    log "Locale approximative copiée: $locale (AVD ≠ One UI Samsung)"
  fi
fi

adb -s "$TARGET" shell am force-stop "$PACKAGE" || true
adb -s "$TARGET" shell am start -n "$PACKAGE/.MainActivity"
log "Terminé. Vérifiez session / préférences sur l'émulateur."
log "Limite : comptes Google/Samsung, autres apps et OS complet ne sont pas clonables via ADB."
