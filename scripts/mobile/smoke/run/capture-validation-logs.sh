#!/usr/bin/env bash
# Capture logs stack Docker + mobile (logcat) pour une session de validation.
# Usage:
#   bash scripts/mobile/smoke/run/capture-validation-logs.sh
#   bash scripts/mobile/smoke/run/capture-validation-logs.sh /chemin/sortie
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="${1:-$ROOT/tests/results/mobile-validation-$STAMP}"

if [[ -f "$ROOT/.env.mobile-emulator" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.env.mobile-emulator"
fi

DEVICE="${MOBILE_ADB_DEVICE:-emulator-5554}"
COMPOSE=(docker compose -f docker-compose.yml --profile full)

mkdir -p "$OUT/docker" "$OUT/mobile" "$OUT/meta"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "device=$DEVICE"
  echo "gateway=http://127.0.0.1:${API_GATEWAY_PORT:-5002}/health"
  echo "frontend=http://127.0.0.1:${FRONTEND_PORT:-5003}/health"
  curl -sf "http://127.0.0.1:${API_GATEWAY_PORT:-5002}/health" 2>/dev/null || echo "gateway_health=KO"
  curl -sf "http://127.0.0.1:${FRONTEND_PORT:-5003}/health" 2>/dev/null || echo "frontend_health=KO"
  echo "--- adb devices ---"
  adb devices 2>/dev/null || true
  echo "--- docker ps ---"
  "${COMPOSE[@]}" ps 2>/dev/null || docker compose ps 2>/dev/null || true
} >"$OUT/meta/session.txt"

echo "[capture] Meta → $OUT/meta/session.txt"

# Logs Docker agrégés (2 dernières heures)
if command -v docker >/dev/null 2>&1; then
  echo "[capture] Docker compose logs (since 2h)…"
  "${COMPOSE[@]}" logs --no-color --since 2h >"$OUT/docker/compose-all-since-2h.log" 2>&1 || \
    docker compose logs --no-color --since 2h >"$OUT/docker/compose-all-since-2h.log" 2>&1 || true

  SERVICES=(
    api-gateway auth-service application-service frontend postgres redis
    notification-service security-service metrics-aggregator workflow-service
  )
  for svc in "${SERVICES[@]}"; do
    cname="jobbingtrack-${svc}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
      docker logs --since 2h --timestamps "$cname" >"$OUT/docker/${svc}.log" 2>&1 || true
      echo "[capture]   $cname"
    fi
  done
fi

# Logcat mobile (app + Flutter + erreurs réseau)
if adb -s "$DEVICE" get-state >/dev/null 2>&1; then
  PKG=cloud.hubera.jobs
  echo "[capture] logcat $DEVICE (package $PKG)…"
  adb -s "$DEVICE" logcat -d -t 3000 >"$OUT/mobile/logcat-full-tail3000.log" 2>&1 || true
  adb -s "$DEVICE" logcat -d -t 2000 \
    | grep -E "flutter|Flutter|DartVM|$PKG|JobbingTrack|AndroidRuntime|FATAL|TelemetryQueue|ApiService|HTTP|401|500" \
    >"$OUT/mobile/logcat-filtered.log" 2>&1 || true
  adb -s "$DEVICE" shell dumpsys activity activities 2>/dev/null \
    | head -120 >"$OUT/mobile/dumpsys-activities-head.log" || true
  adb -s "$DEVICE" shell dumpsys package "$PKG" 2>/dev/null \
    | grep -E "versionName|versionCode|firstInstall|lastUpdate" \
    >"$OUT/mobile/package-info.txt" 2>&1 || true
else
  echo "[capture] WARN: appareil $DEVICE indisponible — logcat ignoré" >&2
fi

# Copie sortie batterie si présente
for f in /tmp/mobile-validation-emulator-fixed.log /tmp/mobile-validation-emulator-*.log; do
  if [[ -f "$f" ]]; then
    cp -a "$f" "$OUT/mobile/" 2>/dev/null || true
  fi
done

echo "[capture] Terminé → $OUT"
find "$OUT" -type f | sort
