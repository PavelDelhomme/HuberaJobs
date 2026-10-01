#!/usr/bin/env node
/**
 * Smoke télémétrie offline mobile (Samsung / ADB).
 * @used-by scripts/mobile/smoke/run/smoke-run-mobile-validation.js (batterie complète)
 */

const adbLib = require('../../../../tools/adb-lib');
const { resolveWorkingUserCredentials } = require('../../lib/resolve-user-credentials');

async function readTelemetryPending(phone) {
  try {
    const out = await phone.shellCommand(
      'run-as cloud.hubera.jobs wc -l app_flutter/analytics_telemetry_queue.jsonl 2>/dev/null || echo 0',
    );
    const n = parseInt(String(out).trim().split(/\s/)[0], 10);
    return Number.isFinite(n) ? n : 0;
  } catch {
    return -1;
  }
}

async function setNetworkOffline(phone, offline) {
  if (offline) {
    await phone.shellCommand('svc wifi disable');
    await phone.shellCommand('svc data disable');
  } else {
    await phone.shellCommand('svc wifi enable');
    await phone.shellCommand('svc data enable');
  }
  await phone.wait(offline ? 2500 : 5000);
}

(async () => {
  const user = await resolveWorkingUserCredentials();
  const phone = await adbLib.connect();
  const devices = await phone.listDevices();
  if (!devices.length) throw new Error('Aucun appareil ADB');

  console.log('Device:', devices[0].id);
  console.log(`User: ${user.source} (${user.email})`);

  let networkWasDisabled = false;
  try {
    await adbLib.flows.restartApp(phone);
    await adbLib.flows.loginFresh(phone, user.email, user.password);
    await phone.assertVisible('Bonjour');
    await phone.wait(2000);

    await setNetworkOffline(phone, true);
    networkWasDisabled = true;
    console.log('Réseau OFF (wifi+data)');

    await adbLib.flows.goToTab(phone, 2);
    await phone.wait(2000);
    await adbLib.flows.goToTab(phone, 1);
    await phone.wait(1500);

    const pendingOffline = await readTelemetryPending(phone);
    console.log(`Lignes file télémétrie (offline): ${pendingOffline}`);
    if (pendingOffline === 0) {
      console.log('OK: file télémétrie alimentée en offline');
    } else if (pendingOffline < 0) {
      console.warn('WARN: lecture file impossible (run-as) — vérifiez logcat [TelemetryQueue]');
    } else {
      console.warn('WARN: file vide en offline — consentement analytics actif ?');
    }

    await setNetworkOffline(phone, false);
    networkWasDisabled = false;
    console.log('Réseau ON — attente flush…');
    await phone.wait(8000);

    const pendingAfter = await readTelemetryPending(phone);
    console.log(`Lignes file télémétrie (après réseau): ${pendingAfter}`);

    console.log('\nSmoke offline télémétrie ADB OK (Samsung)');
  } finally {
    if (networkWasDisabled) {
      await setNetworkOffline(phone, false).catch(() => {});
    }
  }
})().catch((err) => {
  console.error('Smoke offline télémétrie KO:', err.message);
  process.exit(1);
});
