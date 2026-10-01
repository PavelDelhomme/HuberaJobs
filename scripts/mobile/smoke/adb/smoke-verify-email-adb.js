#!/usr/bin/env node
/**
 * E2E mobile : inscription (email réel .env) → lien email (MailHog/EmailLog) → deep link → connexion.
 *
 *   node scripts/mobile/smoke/adb/smoke-verify-email-adb.js
 */

const { execFileSync } = require('child_process');
const {
  uniqueTestEmail,
  resolveVerificationPassword,
  resolveBaseTestEmail,
  registerUser,
} = require('../../lib/resolve-test-email-env');
const { resolveVerificationToken } = require('../../email/extract-verification-token');
const { compareEnvDiagnostics } = require('../../lib/resolve-test-email-env');
const { GATEWAY_URL } = require('../../lib/resolve-admin-credentials');

const PACKAGE = 'cloud.hubera.jobs';

function adbDeviceArgs(deviceId) {
  return deviceId ? ['-s', deviceId] : [];
}

(async () => {
  const adbLib = require('../../../../tools/adb-lib');
  const phone = await adbLib.connect();
  const deviceId = phone.deviceId;

  const diag = compareEnvDiagnostics();
  if (diag.length) {
    console.log('Note .env :', diag.join(' ; '));
    console.log('Astuce : node scripts/mobile/setup/sync-test-env.js --write');
  }

  const baseEmail = resolveBaseTestEmail();
  const { password, source: passSource } = resolveVerificationPassword();
  const email = uniqueTestEmail(baseEmail);
  console.log(`Email test (alias sur ${baseEmail}) : ${email}`);
  console.log(`Mot de passe : source ${passSource}`);

  const regStartedAt = Date.now();
  const reg = await registerUser(email, password);
  console.log(reg.created ? 'Inscription créée' : 'Compte existant → renvoi vérif');

  console.log('Attente email de vérification (EmailLog → MailHog → IMAP)…');
  await new Promise((r) => setTimeout(r, reg.created ? 4000 : 2000));
  const { token, source: tokenSource } = await resolveVerificationToken(email, {
    sinceMs: regStartedAt - 5000,
  });
  console.log(`Token extrait via ${tokenSource} (${token.slice(0, 8)}…)`);

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

  await phone.wait(8000);
  const verified =
    (await phone.uiContains('Email vérifié')) ||
    (await phone.uiContains('Votre compte est actif'));
  if (!verified) {
    throw new Error('Deep link : écran « Email vérifié » introuvable');
  }
  console.log('Deep link verify-email OK');

  const loginProbe = await fetch(`${GATEWAY_URL}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!loginProbe.ok) {
    throw new Error(`API login après vérif échoue (HTTP ${loginProbe.status})`);
  }
  console.log('API login après vérif OK');

  try {
    await phone.tap('Aller à la connexion');
  } catch {
    await adbLib.flows.ensureLoggedOut(phone);
  }
  await phone.wait(2500);

  await adbLib.flows.loginFresh(phone, email, password);
  await phone.assertVisible('Bonjour');
  console.log(`Smoke E2E verify-email + login mobile OK (${email})`);
})().catch((err) => {
  console.error('Smoke verify-email E2E mobile KO:', err.message);
  process.exit(1);
});
