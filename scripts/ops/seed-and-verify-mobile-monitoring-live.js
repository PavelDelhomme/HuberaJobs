#!/usr/bin/env node
/**
 * Génère plusieurs erreurs mobile distinctes (app réelle + pipeline API) puis vérifie le backoffice.
 *
 *   API_GATEWAY_URL=http://127.0.0.1:5002 node scripts/ops/seed-and-verify-mobile-monitoring-live.js
 */
const { execSync } = require('child_process');
const adbLib = require('../../tools/adb-lib');
const {
  resolveWorkingAdminCredentials,
  loadRootEnv,
  GATEWAY_URL,
} = require('../mobile/lib/resolve-admin-credentials');
const { resolveWorkingUserCredentials } = require('../mobile/lib/resolve-user-credentials');

loadRootEnv();

const BASE = (process.env.API_GATEWAY_URL || GATEWAY_URL || 'http://127.0.0.1:5002').replace(/\/$/, '');
const TAG = `live-verify-${Date.now()}`;

async function login(email, password) {
  const res = await fetch(`${BASE}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!res.ok) throw new Error(`Login ${email} HTTP ${res.status}`);
  const data = await res.json();
  const token = data.token || data.accessToken;
  if (!token) throw new Error('Token absent');
  return { token, user: data.user };
}

async function postAnalyticsError(token, payload) {
  const res = await fetch(`${BASE}/api/v1/analytics/errors`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.success) {
    throw new Error(`POST error ${payload.errorName}: HTTP ${res.status} ${JSON.stringify(body)}`);
  }
  return body.data;
}

async function postCrash(body, token) {
  const res = await fetch(`${BASE}/api/v1/crashes`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  if (res.status !== 201) {
    const t = await res.text();
    throw new Error(`POST crash HTTP ${res.status}: ${t.slice(0, 200)}`);
  }
}

async function adminCounts(token) {
  const q = 'scope=application&platform=mobile&days=7&limit=500';
  const [errorsRes, crashesRes] = await Promise.all([
    fetch(`${BASE}/api/v1/analytics/errors?${q}&excludeFeedback=true`, {
      headers: { Authorization: `Bearer ${token}` },
    }),
    fetch(`${BASE}/api/v1/crashes?limit=500`, {
      headers: { Authorization: `Bearer ${token}` },
    }),
  ]);
  const errorsJson = await errorsRes.json();
  const crashesJson = await crashesRes.json();
  const errors = errorsJson.data || [];
  const crashes = crashesJson.data || [];
  const feedback = crashes.filter((c) =>
    /^\[(bug|suggestion|signalement)\]/i.test(String(c.message || '')) ||
    c.crashType === 'ManualReport',
  );
  const autoCrashes = crashes.filter((c) => !feedback.includes(c));
  return { errors, crashes, feedback, autoCrashes };
}

function adbReverseRemove() {
  try {
    execSync('adb reverse --remove tcp:5002', { stdio: 'pipe' });
  } catch {
    /* ok */
  }
}

function adbReverseRestore() {
  execSync('adb reverse tcp:5002 tcp:5002', { stdio: 'pipe' });
  execSync('adb reverse tcp:5003 tcp:5003', { stdio: 'pipe' });
}

async function triggerAppNetworkErrors(email, password) {
  const devices = execSync('adb devices', { encoding: 'utf8' });
  if (!devices.includes('\tdevice')) {
    console.log('WARN: pas d’appareil ADB — skip erreurs réseau app');
    return 0;
  }

  adbReverseRestore();
  execSync(
    'adb shell am start -n cloud.hubera.jobs/.MainActivity 2>/dev/null || adb shell monkey -p cloud.hubera.jobs -c android.intent.category.LAUNCHER 1',
    { stdio: 'pipe' },
  );

  const phone = await adbLib.connect();
  await adbLib.flows.dismissBiometricUnlock(phone, { password });
  if (
    !(await phone.uiContains('Bonjour')) &&
    !(await phone.uiContains('Tab 1 of 4'))
  ) {
    await adbLib.flows.loginFresh(phone, email, password);
    await adbLib.flows.dismissBiometricUnlock(phone, { password });
  }

  console.log('App connectée — coupure API (adb reverse) + navigation onglets…');
  adbReverseRemove();
  await phone.wait(1500);
  for (const tab of [1, 2, 3, 1]) {
    try {
      await adbLib.flows.goToTab(phone, tab, { shell: true });
    } catch (e) {
      console.warn('WARN navigation tab', tab, e.message);
    }
    await phone.wait(2500);
  }

  adbReverseRestore();
  await phone.wait(2000);
  execSync('adb shell am force-stop cloud.hubera.jobs', { stdio: 'pipe' });
  await phone.wait(800);
  execSync(
    'adb shell am start -n cloud.hubera.jobs/.MainActivity',
    { stdio: 'pipe' },
  );
  await phone.wait(8000);
  console.log('App relancée après retour réseau (flush télémétrie)');
  return 1;
}

async function seedDiverseErrors(userToken) {
  const sessionId = `sess-${TAG}`;
  const deviceId = `dev-${TAG}`;
  const now = new Date().toISOString();
  const seeds = [
    {
      sessionId,
      deviceId,
      errorType: 'network',
      errorName: 'connection_refused',
      errorMessage: `[${TAG}] Connexion refusée ou réseau indisponible sur /api/v1/applications (42ms)`,
      page: '/home',
      platform: 'android',
      severity: 'critical',
      properties: { endpoint: '/api/v1/applications', statusCode: 0, tag: TAG },
    },
    {
      sessionId,
      deviceId,
      errorType: 'api',
      errorName: 'api_error',
      errorMessage: `[${TAG}] HTTP 503 sur /api/v1/followups (120ms)`,
      page: '/applications',
      platform: 'android',
      severity: 'warning',
      properties: { endpoint: '/api/v1/followups', statusCode: 503, tag: TAG },
    },
    {
      sessionId,
      deviceId,
      errorType: 'mobile',
      errorName: 'UncaughtError',
      errorMessage: `[${TAG}] ClientException: Connection refused (simulation porteur)`,
      page: '/home',
      platform: 'android',
      severity: 'critical',
      properties: { tag: TAG, simulatedAt: now },
    },
  ];

  for (const s of seeds) {
    await postAnalyticsError(userToken, s);
    console.log('  + erreur auto:', s.errorName);
  }

  await postCrash(
    {
      crashType: 'FlutterError',
      message: `[${TAG}] FlutterError smoke validation`,
      screenName: '/home',
      sessionId,
      metadata: { tag: TAG, validation: true },
    },
    userToken,
  );
  console.log('  + crash auto: FlutterError');

  await postCrash(
    {
      crashType: 'ManualReport',
      message: `[bug] [${TAG}] Retour utilisateur test validation`,
      screenName: 'help_feedback/bug',
      sessionId,
      metadata: { feedback: true, category: 'bug', tag: TAG },
    },
    userToken,
  );
  console.log('  + retour utilisateur: bug');

  await postCrash(
    {
      crashType: 'UncaughtError',
      message: `[${TAG}] UncaughtError fichier gateway`,
      screenName: '/home',
      metadata: { tag: TAG },
    },
    userToken,
  );
  console.log('  + crash auto: UncaughtError');
}

async function main() {
  console.log('=== Seed & verify mobile monitoring ===');
  console.log('Gateway:', BASE);
  console.log('Tag:', TAG);

  try {
    execSync('node scripts/mobile/setup/ensure-device-api-ready.js', {
      stdio: 'inherit',
      cwd: require('path').resolve(__dirname, '../..'),
    });
  } catch {
    console.warn('WARN ensure-device-api-ready partiel');
  }

  const user = await resolveWorkingUserCredentials();
  const admin = await resolveWorkingAdminCredentials();
  const userAuth = await login(user.email, user.password);
  const adminAuth = await login(admin.email, admin.password);

  await triggerAppNetworkErrors(user.email, user.password);

  console.log('\nInjection pipeline (même API que l’app)…');
  await seedDiverseErrors(userAuth.token);

  await new Promise((r) => setTimeout(r, 2000));

  const { errors, feedback, autoCrashes } = await adminCounts(adminAuth.token);
  const taggedErrors = errors.filter((e) => String(e.errorMessage || '').includes(TAG));
  const taggedFeedback = feedback.filter((c) => String(c.message || '').includes(TAG));
  const taggedAuto = autoCrashes.filter((c) => String(c.message || '').includes(TAG));

  console.log('\n--- Résultat backoffice (7 j) ---');
  console.log('Erreurs auto total:', errors.length, '| avec tag:', taggedErrors.length);
  console.log('Retours total:', feedback.length, '| avec tag:', taggedFeedback.length);
  console.log('Crashs auto total:', autoCrashes.length, '| avec tag:', taggedAuto.length);

  if (taggedErrors.length < 3) {
    throw new Error(`Attendu ≥3 erreurs auto taguées, obtenu ${taggedErrors.length}`);
  }
  if (taggedFeedback.length < 1) {
    throw new Error('Retour utilisateur tagué absent');
  }
  if (taggedAuto.length < 2) {
    throw new Error(`Attendu ≥2 crashs auto tagués, obtenu ${taggedAuto.length}`);
  }

  console.log('\nTypes erreurs auto taguées:', [
    ...new Set(taggedErrors.map((e) => e.errorName || e.errorType)),
  ].join(', '));

  console.log('\nOK seed-and-verify-mobile-monitoring-live');
  console.log('→ Backoffice: Administration → Mobile — erreurs & retours (rafraîchir la page)');
}

main().catch((e) => {
  console.error('KO seed-and-verify-mobile-monitoring-live:', e.message);
  process.exit(1);
});
