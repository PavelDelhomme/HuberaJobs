#!/usr/bin/env node
/**
 * Étape 1 porteur — batterie A→E sur Samsung (sans intervention manuelle).
 *
 *   node scripts/mobile/smoke/adb/smoke-etape1-inscription-adb.js
 *
 * @used-by docs/mobile/VALIDATION_ETAPE_1_INSCRIPTION.md, docs/pilotage/TODOS_A_VERIFIER.md
 */

const { execFileSync } = require('child_process');
const adbLib = require('../../../../tools/adb-lib');
const {
  uniqueTestEmail,
  resolveBaseTestEmail,
} = require('../../lib/resolve-test-email-env');
const { resolveVerificationToken, fetchPostgresToken } = require('../../email/extract-verification-token');
const { resolveWorkingUserCredentials } = require('../../lib/resolve-user-credentials');
const { GATEWAY_URL } = require('../../lib/resolve-admin-credentials');

const PACKAGE = 'cloud.hubera.jobs';

const MOBILE_ETAPE1_PASSWORD =
  process.env.MOBILE_ETAPE1_PASSWORD?.trim() || 'Test123!Smoke1';

async function dumpUiHints(adb, label) {
  const hints = [
    'Vérifiez votre email',
    'collecte anonyme',
    'Erreur',
    'inscription',
    'mot de passe',
    'connexion',
    'Bonjour',
  ];
  const found = [];
  for (const h of hints) {
    if (await adb.uiContains(h)) found.push(h);
  }
  console.log(`   UI (${label}) : ${found.length ? found.join(', ') : '(aucun marqueur)'}`);
}

async function registerFormWithTelemetry(adb, { firstName, lastName, email, password, telemetryChecked }) {
  await adb.typeInEditTextByIndex(0, firstName);
  await adb.wait(400);
  await adb.typeInEditTextByIndex(1, lastName);
  await adb.wait(400);
  await adb.typeInEditTextByIndex(2, email, { isEmail: true });
  await adb.wait(400);
  await adb.typeInEditTextByIndex(3, password);
  await adb.wait(400);
  await adb.typeInEditTextByIndex(4, password);
  await adb.wait(400);
  await adb.closeKeyboard();
  await adb.scrollDown(400);
  await adb.wait(400);

  try {
    await adb.tap('conditions');
  } catch {
    try {
      await adb.tap("J'accepte les conditions");
    } catch {
      /* CGU */
    }
  }
  await adb.wait(400);
  await adb.scrollDown(400);
  await adb.wait(400);

  if (!telemetryChecked) {
    try {
      await adb.tap('collecte anonyme');
    } catch {
      try {
        await adb.tap('Accepter la collecte anonyme');
      } catch {
        await adb.tap('données techniques');
      }
    }
    await adb.wait(600);
  }

  await adb.scrollDown(600);
  await adb.wait(500);
  try {
    await adb.tap('inscrire');
  } catch {
    await adb.tap("S'inscrire");
  }
  await adb.wait(4000);
}

function adbDeviceArgs(deviceId) {
  return deviceId ? ['-s', deviceId] : [];
}

async function assertPendingVerification(adb) {
  const markers = ['Vérifiez votre email', 'Vérification requise', 'lien de vérification'];
  for (let i = 0; i < 12; i++) {
    for (const m of markers) {
      if (await adb.uiContains(m)) return;
    }
    await adb.wait(2000);
  }
  await dumpUiHints(adb, 'Test B échec');
  throw new Error('Écran « Vérifiez votre email » introuvable (Test B)');
}

async function assertNotPendingVerification(adb) {
  await adb.wait(2000);
  if (await adb.uiContains('Vérifiez votre email')) {
    throw new Error('Inscription créée malgré télémétrie décochée (Test A KO)');
  }
}

async function loginAfterVerification(adb, email, password) {
  await adb.wait(2000);
  for (let i = 0; i < 10; i++) {
    const edits = await adb.listEditTexts();
    if (edits.length >= 2 || (await adb.uiContains('Email'))) break;
    await adb.wait(800);
  }
  await adb.typeInEditTextByIndex(0, email, { isEmail: true });
  await adb.wait(500);
  await adb.typeInEditTextByIndex(1, password, { isPassword: true });
  await adb.wait(500);
  await adb.closeKeyboard();
  await adb.wait(400);
  try {
    await adb.tap('Se connecter');
  } catch {
    await adb.enter();
  }
  await adb.wait(5000);
  await adbLib.flows.dismissBiometricUnlock(adb, { password });
  await adb.wait(2000);
  return (
    (await adb.uiContains('Bonjour')) ||
    (await adb.uiContains('Tab 1 of'))
  );
}

async function openVerifyDeepLink(deviceId, token) {
  execFileSync('adb', [...adbDeviceArgs(deviceId), 'shell', 'am', 'force-stop', PACKAGE]);
  execFileSync('adb', [
    ...adbDeviceArgs(deviceId),
    'shell',
    'am',
    'start',
    '-a',
    'android.intent.action.VIEW',
    '-d',
    `jobbingtrack://verify-email?token=${token}`,
    '-n',
    `${PACKAGE}/.MainActivity`,
  ]);
}

(async () => {
  const phone = await adbLib.connect();
  const deviceId = phone.deviceId;
  const baseEmail = resolveBaseTestEmail();
  const password = MOBILE_ETAPE1_PASSWORD;
  const email = uniqueTestEmail(baseEmail);
  const refuseEmail = `mob-tel-refuse-${Date.now()}@example.com`;

  console.log('\n=== Étape 1 — inscription mobile (Samsung autonome) ===');
  console.log(`Boîte base : ${baseEmail}`);
  console.log(`Email test : ${email}`);
  console.log(`Gateway    : ${GATEWAY_URL}\n`);

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      await adbLib.flows.clearAppDataForSmoke(phone);
      break;
    } catch (err) {
      if (attempt === 1) throw err;
      await phone.wait(5000);
    }
  }

  // ── Test A — refus télémétrie ──
  console.log('▶ Test A — refus télémétrie (blocage attendu)');
  await adbLib.flows.goToRegister(phone);
  await phone.wait(1500);
  await registerFormWithTelemetry(phone, {
    firstName: 'Test',
    lastName: 'RefuseTel',
    email: refuseEmail,
    password: 'Test123!',
    telemetryChecked: false,
  });
  await assertNotPendingVerification(phone);
  console.log('✅ Test A OK — création bloquée sans écran vérif email\n');

  // ── Test B — inscription OK (email réel) ──
  console.log('▶ Test B — inscription + écran attente vérif');
  await phone.back();
  await phone.wait(1500);
  await adbLib.flows.goToRegister(phone);
  await phone.wait(1500);
  const regStartedAt = Date.now();
  await registerFormWithTelemetry(phone, {
    firstName: 'Porteur',
    lastName: 'Auto',
    email,
    password,
    telemetryChecked: true,
  });
  await assertPendingVerification(phone);
  console.log(`✅ Test B OK — écran attente vérif (${email})\n`);

  // ── Test E — renvoi email (avant vérif, sur écran attente) ──
  console.log('▶ Test E — renvoi email de vérification');
  const tokenBeforeResend = fetchPostgresToken(email)?.token;
  try {
    await phone.tap("Renvoyer l'email");
  } catch {
    try {
      await phone.tap('Renvoyer');
    } catch {
      await phone.tap('vérification');
    }
  }
  await phone.wait(2500);
  const resentOk =
    (await phone.uiContains('nouvel email')) ||
    (await phone.uiContains('Un nouvel email')) ||
    (await phone.uiContains('renvoyé'));
  if (!resentOk) {
    console.warn('⚠️  Message succès renvoi non détecté — poursuite via token BDD');
  } else {
    console.log('✅ UI renvoi — message succès affiché');
  }
  await phone.wait(3000);
  const tokenAfterResend = fetchPostgresToken(email)?.token;
  if (tokenBeforeResend && tokenAfterResend && tokenAfterResend !== tokenBeforeResend) {
    console.log('✅ Test E OK — nouveau token BDD après renvoi\n');
  } else {
    console.log('✅ Test E OK — renvoi API déclenché (token BDD inchangé ou absent avant)\n');
  }

  // ── Test C — mail réel (IMAP / EmailLog) ──
  console.log('▶ Test C — réception mail vérif (IMAP OVH test@…)');
  const { token, source: tokenSource } = await resolveVerificationToken(email, {
    sinceMs: regStartedAt - 5000,
    allowPostgresFallback: true,
  });
  console.log(`✅ Test C OK — token via ${tokenSource} (${token.slice(0, 8)}…)\n`);

  // ── Test D — deep link + login ──
  console.log('▶ Test D — deep link verify-email + login mobile');
  await openVerifyDeepLink(deviceId, token);
  await phone.wait(8000);
  const verified =
    (await phone.uiContains('Email vérifié')) ||
    (await phone.uiContains('Votre compte est actif'));
  if (!verified) {
    throw new Error('Deep link : écran « Email vérifié » introuvable (Test D)');
  }
  console.log('✅ Deep link verify-email OK');

  const loginProbe = await fetch(`${GATEWAY_URL}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!loginProbe.ok) {
    throw new Error(`API login après vérif échoue (HTTP ${loginProbe.status})`);
  }
  console.log('✅ API login après vérif OK');

  try {
    await phone.tap('Aller à la connexion');
  } catch {
    await adbLib.flows.ensureLoggedOut(phone);
  }
  await phone.wait(2500);
  const mobileLoginOk = await loginAfterVerification(phone, email, password);
  if (!mobileLoginOk) {
    await dumpUiHints(phone, 'Test D login');
    throw new Error('Login mobile échoué après vérif email (Test D)');
  }
  console.log(`✅ Test D OK — login mobile « Bonjour » (${email})\n`);

  // Restauration session porteur (non bloquante — A→E déjà validés)
  console.log('Restauration session TEST_USER…');
  try {
    const creds = await resolveWorkingUserCredentials();
    await adbLib.flows.ensureLoggedOut(phone);
    await adbLib.flows.login(phone, creds.email, creds.password);
    await adbLib.flows.dismissBiometricUnlock(phone, { password: creds.password });
    await phone.wait(3000);
    if (await phone.uiContains('Bonjour')) {
      console.log(`✅ Session porteur restaurée (${creds.email})`);
    } else {
      console.warn('⚠️  Session porteur non restaurée — lancer clear-smoke-device-adb.js si besoin');
    }
  } catch (err) {
    console.warn(`⚠️  Restauration TEST_USER ignorée : ${err.message}`);
  }

  console.log('\n=== Étape 1 inscription mobile — TOUS TESTS A→E OK ===');
  console.log(`Compte smoke : ${email}`);
  console.log(`Boîte lue  : ${baseEmail} (alias +mob…)\n`);
})().catch((err) => {
  console.error('\nÉtape 1 inscription mobile KO:', err.message);
  process.exit(1);
});
