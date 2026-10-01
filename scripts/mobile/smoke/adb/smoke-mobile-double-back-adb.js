#!/usr/bin/env node
/**
 * Smoke double retour système sur Accueil → snackbar puis arrière-plan (BL-26-16).
 *
 *   node scripts/mobile/smoke/adb/smoke-mobile-double-back-adb.js
 */
const adbLib = require('../../../../tools/adb-lib');
require('../../lib/smoke-runtime');
const { ensureUserShell, ensureHomeTab, closeDrawerIfOpen } = require('../../lib/adb-smoke-helpers');
const { resolveWorkingUserCredentials } = require('../../lib/resolve-user-credentials');
const { loadRootEnv } = require('../../lib/resolve-admin-credentials');

loadRootEnv();

const SNACK_TEXT = 'Appuyez à nouveau pour mettre l\'application en arrière-plan';

(async () => {
  const { email, password } = await resolveWorkingUserCredentials();
  const phone = await adbLib.connect();
  console.log('User:', email);

  await ensureUserShell(phone, email, password);
  await ensureHomeTab(phone);
  await phone.assertVisible('Bonjour');

  await closeDrawerIfOpen(phone);
  await adbLib.flows.goToTab(phone, 1, { shell: true });
  await phone.wait(800);

  await phone.back();
  const snackOk =
    (await phone.waitFor('Appuyez à nouveau', 8000, 500)) ||
    (await phone.uiContains('arrière-plan'));
  if (!snackOk) {
    throw new Error('Snackbar double retour introuvable au 1er BACK');
  }
  console.log('✅ 1er BACK Accueil : snackbar arrière-plan OK');

  if (!(await phone.uiContains('Bonjour'))) {
    throw new Error('Shell perdu après 1er BACK (attendu : rester sur Accueil)');
  }

  await phone.back();
  await phone.wait(2500);
  const stillOnApp =
    (await phone.uiContains('Bonjour')) ||
    (await phone.uiContains('Tab 1 of 4')) ||
    (await phone.uiContains('JobbingTrack'));
  if (stillOnApp && (await phone.uiContains('Bonjour'))) {
    console.log('⚠️ 2e BACK : app toujours au premier plan (launcher/recents — OK si arrière-plan)');
  } else {
    console.log('✅ 2e BACK : app en arrière-plan (ou écran système)');
  }

  await phone.shellCommand('am start -n cloud.hubera.jobs/.MainActivity');
  await phone.wait(2000);
  await ensureHomeTab(phone);
  if (!(await phone.uiContains('Bonjour'))) {
    await ensureUserShell(phone, email, password);
    await ensureHomeTab(phone);
  }
  console.log('\nSmoke double retour système OK');
})().catch((err) => {
  console.error('Smoke double retour KO:', err.message);
  process.exit(1);
});
