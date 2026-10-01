#!/usr/bin/env bash
# Build + publie OTA + installe les 3 apps (dev / préprod / prod) sur Nothing Phone + Samsung.
#
# Ne lance PAS l’install OTA in-app — pose seulement les APKs + releases avec downloadUrl.
#
# Usage :
#   bash scripts/mobile/setup/install-three-channels-devices.sh
#   SKIP_BUILD=1 bash scripts/mobile/setup/install-three-channels-devices.sh
#   SKIP_PUBLISH=1 bash scripts/mobile/setup/install-three-channels-devices.sh
#   DEVICES="serial1 serial2" bash ...
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/mobile/setup/resolve-flutter.sh
source "$ROOT/scripts/mobile/setup/resolve-flutter.sh"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env" 2>/dev/null || true
  set +a
fi

LAN_IP="${MOBILE_DEV_LAN_HOST:-${DEV_HTTPS_LAN_IP:-}}"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
LAN_IP="${LAN_IP:-192.168.1.134}"
LOCAL_API="http://${LAN_IP}:5002"
PREPROD_API="${MOBILE_PREPROD_API_URL:-https://api-preprod.jobbingtrack.com}"
PROD_API="${MOBILE_PROD_API_URL:-https://jobs.hubera.cloud}"

# Cibles appareils : Nothing Phone + Samsung (pas Blackview).
NOTHING_ID="${NOTHING_DEVICE_ID:-}"
SAMSUNG_ID="${SAMSUNG_DEVICE_ID:-}"
if [[ -z "$NOTHING_ID" || -z "$SAMSUNG_ID" ]]; then
  mapfile -t _adb_serials < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  for serial in "${_adb_serials[@]}"; do
    [[ -z "$serial" ]] && continue
    # </dev/null : sinon adb consomme le stdin de la boucle
    manufacturer="$(adb -s "$serial" shell getprop ro.product.manufacturer </dev/null 2>/dev/null | tr -d '\r')"
    brand="$(adb -s "$serial" shell getprop ro.product.brand </dev/null 2>/dev/null | tr -d '\r')"
    model="$(adb -s "$serial" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r')"
    key="${manufacturer}|${brand}|${model}"
    case "$key" in
      *Nothing*|*nothing*) NOTHING_ID="${NOTHING_ID:-$serial}" ;;
      *samsung*|*Samsung*|*SM-G*) SAMSUNG_ID="${SAMSUNG_ID:-$serial}" ;;
    esac
  done
fi

if [[ -n "${DEVICES:-}" ]]; then
  # shellcheck disable=SC2206
  TARGET_DEVICES=($DEVICES)
else
  TARGET_DEVICES=()
  [[ -n "$NOTHING_ID" ]] && TARGET_DEVICES+=("$NOTHING_ID")
  [[ -n "$SAMSUNG_ID" ]] && TARGET_DEVICES+=("$SAMSUNG_ID")
fi

if [[ ${#TARGET_DEVICES[@]} -eq 0 ]]; then
  echo "Aucun appareil Nothing/Samsung ADB détecté." >&2
  exit 1
fi

echo "==> Appareils cibles: ${TARGET_DEVICES[*]}"
echo "    LAN API: $LOCAL_API"

APK_DIR="$ROOT/mobile/build/app/outputs/flutter-apk"
mkdir -p "$ROOT/deploy/production/mobile-releases"

build_one() {
  local flavor="$1" api="$2" channel="$3"
  echo ""
  echo "======== BUILD $flavor → $api (channel=$channel) ========"
  API_BASE_URL="$api" \
    MOBILE_RELEASE_CHANNEL="$channel" \
    FLAVOR="$flavor" \
    SKIP_CLEAN=1 \
    bash "$ROOT/scripts/mobile/setup/build-apk-release.sh"
}

publish_one() {
  local flavor="$1" api="$2" channel="$3"
  local apk="$APK_DIR/app-${flavor}-release.apk"
  echo ""
  echo "======== PUBLISH OTA $flavor → $api #$channel ========"
  if [[ ! -f "$apk" ]]; then
    echo "APK manquant: $apk" >&2
    return 1
  fi
  # Sur VPS préprod/prod, le canal « preprod » n’existe qu’après redeploy gateway.
  # Fallback : canal dev sur API préprod (même app JT Préprod).
  local upload_channel="$channel"
  if [[ "$channel" == "preprod" ]]; then
    local probe
    probe="$(curl -fsS "$api/api/v1/mobile/releases/latest?platform=android&channel=preprod" 2>/dev/null || true)"
    if ! echo "$probe" | grep -q '"success"'; then
      echo "    (gateway distant sans canal preprod encore — upload en channel=dev)"
      upload_channel=dev
    fi
  fi
  BUILD_FIRST=0 \
    APK_PATH="$apk" \
    FLAVOR="$flavor" \
    DEPLOY_URL="$api" \
    API_BASE_URL="$api" \
    MOBILE_RELEASE_CHANNEL="$upload_channel" \
    MOBILE_RELEASE_NOTES="Install 3 canaux $(date -Iseconds) — flavor $flavor" \
    bash "$ROOT/scripts/deploy/publish-apk-remote.sh" || {
      if [[ "$upload_channel" == "preprod" ]]; then
        echo "    Retry upload channel=dev…"
        BUILD_FIRST=0 \
          APK_PATH="$apk" \
          FLAVOR="$flavor" \
          DEPLOY_URL="$api" \
          API_BASE_URL="$api" \
          MOBILE_RELEASE_CHANNEL=dev \
          MOBILE_RELEASE_NOTES="Install 3 canaux $(date -Iseconds) — flavor $flavor (fallback dev)" \
          bash "$ROOT/scripts/deploy/publish-apk-remote.sh"
      else
        return 1
      fi
    }
}

install_one() {
  local flavor="$1"
  local apk="$APK_DIR/app-${flavor}-release.apk"
  local pkg="cloud.hubera.jobs"
  case "$flavor" in
    dev) pkg="${pkg}.dev" ;;
    preprod) pkg="${pkg}.preprod" ;;
  esac
  [[ -f "$apk" ]] || { echo "APK manquant: $apk" >&2; return 1; }
  for device in "${TARGET_DEVICES[@]}"; do
    echo "---- install $flavor ($pkg) → $device ----"
    # reverse ports utiles pour JT Dev (si l’app pointe encore localhost)
    adb -s "$device" reverse tcp:5002 tcp:5002 2>/dev/null || true
    adb -s "$device" reverse tcp:5003 tcp:5003 2>/dev/null || true
    if ! adb -s "$device" install -r -d "$apk"; then
      echo "    install -r échoué — uninstall + reinstall"
      adb -s "$device" uninstall "$pkg" >/dev/null 2>&1 || true
      adb -s "$device" install "$apk"
    fi
    echo "    OK $pkg sur $device"
  done
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  bash "$ROOT/scripts/mobile/setup/clean-flutter-apk-build.sh" "$ROOT/mobile"
  # JT Dev → API LAN + canal dev
  build_one dev "$LOCAL_API" dev
  # JT Préprod → API préprod + canal dev
  # (canal « preprod » côté VPS après redeploy gateway ; d’ici là channel=dev)
  PREPROD_APP_CHANNEL=dev
  build_one preprod "$PREPROD_API" "$PREPROD_APP_CHANNEL"
  # JobbingTrack → API prod + canal production
  build_one prod "$PROD_API" production
else
  echo "==> SKIP_BUILD=1 — APKs existants réutilisés"
  PREPROD_APP_CHANNEL="${PREPROD_APP_CHANNEL:-dev}"
fi

if [[ "${SKIP_PUBLISH:-0}" != "1" ]]; then
  publish_one dev "$LOCAL_API" dev
  publish_one preprod "$PREPROD_API" "${PREPROD_APP_CHANNEL:-dev}"
  # Miroir local canal preprod (backoffice 3 canaux / détection locale)
  publish_one preprod "$LOCAL_API" preprod || echo "(publish local preprod ignoré)"
  publish_one prod "$PROD_API" production
else
  echo "==> SKIP_PUBLISH=1 — publication OTA ignorée"
fi

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  install_one dev
  install_one preprod
  install_one prod
else
  echo "==> SKIP_INSTALL=1 — installation appareils ignorée"
fi

echo ""
echo "==> Vérif OTA (downloadUrl attendu, pas d’install forcée)"
for url_channel in \
  "$LOCAL_API|dev" \
  "$PREPROD_API|dev" \
  "$PROD_API|production"
do
  api="${url_channel%%|*}"
  ch="${url_channel##*|}"
  echo -n "  $api channel=$ch → "
  curl -fsS "$api/api/v1/mobile/releases/latest?platform=android&channel=$ch" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); r=d.get("release") or {}; print("v=%s+%s download=%s" % (r.get("version"), r.get("buildNumber"), bool(r.get("downloadUrl"))))' \
    2>/dev/null || echo "(indisponible)"
done

echo ""
echo "==> Packages installés :"
for device in "${TARGET_DEVICES[@]}"; do
  echo "  [$device]"
  adb -s "$device" shell pm list packages 2>/dev/null | grep -i jobbingtrack || echo "    (aucun)"
done

echo ""
echo "OK — 3 apps posées. Ouvre JT Dev / JT Préprod / JobbingTrack ;"
echo "    une MAJ OTA apparaîtra quand tu publieras une version > 1.0.42 (sans forcer l’install)."
