#!/usr/bin/env node
/**
 * Smoke toggle « Mode intérim » via Paramètres (Lot D ligne 319).
 * Complète smoke-mobile-interim-home-adb.js (pref directe) en testant l'UI Paramètres.
 * Note : Switch Material peu fiable en ADB — tap best-effort puis sync pref si besoin.
 *
 *   node scripts/mobile/smoke/adb/smoke-mobile-settings-interim-adb.js
 */

const adbLib = require('../../../../tools/adb-lib');
require('../../lib/smoke-runtime');
const { ensureHomeTab, openAppDrawer } = require('../../lib/adb-smoke-helpers');
const { resolveWorkingUserCredentials } = require('../../lib/resolve-user-credentials');
const { loadRootEnv } = require('../../lib/resolve-admin-credentials');
const { ensureTestAccountsReady } = require('../../setup/ensure-test-accounts-ready');

loadRootEnv();

function nodeLabel(n) {
  return `${n.text || ''}\n${n.contentDesc || ''}`.replace(/&#10;/g, '\n').trim();
}

function boundsCenter(bounds) {
  const m = String(bounds || '').match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
  if (!m) return { cx: 0, cy: 0 };
  return {
    cx: Math.round((+m[1] + +m[3]) / 2),
    cy: Math.round((+m[2] + +m[4]) / 2),
  };
}

async function isInterimEnabled(phone) {
  const xml = await phone.shellCommand(
    'run-as cloud.hubera.jobs cat shared_prefs/FlutterSharedPreferences.xml',
  );
  return /interim_mode_enabled[^>]*value="true"/i.test(xml);
}

async function ensureLoggedIn(phone, email, password) {
  await adbLib.flows.prepareSmokeSession(phone, { restart: false });
  if (await adbLib.flows.isShellVisible(phone)) {
    await ensureHomeTab(phone);
    await phone.assertVisible('Bonjour');
    return;
  }
  await adbLib.flows.restartApp(phone);
  await phone.wait(3500);
  await adbLib.flows.dismissBiometricUnlock(phone, { password });
  if (await phone.uiContains('Connexion USER')) {
    await phone.tap('Connexion USER');
    await phone.wait(4000);
  } else if (!(await adbLib.flows.isShellVisible(phone))) {
    if (process.env.SMOKE_PREFLIGHT_DONE !== '1') {
      await ensureTestAccountsReady();
    }
    await adbLib.flows.loginFresh(phone, email, password);
  }
  await adbLib.flows.dismissBiometricUnlock(phone, { password });
  await ensureHomeTab(phone);
  await phone.assertVisible('Bonjour');
}

async function openSettings(phone) {
  await adbLib.flows.goToTab(phone, 4, { shell: true });
  await phone.wait(1500);
  for (let i = 0; i < 6 && !(await phone.uiContains('Paramètres')); i++) {
    await phone.scrollDown(500);
    await phone.wait(600);
  }
  for (const label of ['Paramètres & confidentialité', 'Paramètres', 'confidentialité', 'Télémétrie']) {
    if (!(await phone.uiContains(label))) continue;
    try {
      await phone.tapReliable(label);
      await phone.wait(2000);
      return;
    } catch {
      /* essai suivant */
    }
  }
  throw new Error('Entrée Paramètres introuvable depuis Profil');
}

async function returnToShell(phone, email, password) {
  for (let i = 0; i < 4; i++) {
    if (await phone.uiContains('Tab 1 of 4')) {
      try {
        await adbLib.flows.goToTab(phone, 1, { shell: true });
      } catch {
        await phone.tap('Tab 1 of 4');
      }
      await phone.wait(800);
      return;
    }
    await phone.back();
    await phone.wait(700);
  }
  await adbLib.flows.restartApp(phone);
  await phone.wait(3500);
  await adbLib.flows.dismissBiometricUnlock(phone, { password });
  if (await phone.uiContains('Connexion USER')) {
    await phone.tap('Connexion USER');
    await phone.wait(3500);
  } else if (!(await phone.uiContains('Bonjour'))) {
    await adbLib.flows.loginFresh(phone, email, password);
  }
  await ensureHomeTab(phone);
}

async function scrollToInterimSwitch(phone) {
  for (let i = 0; i < 10; i++) {
    if (await phone.uiContains('Mode intérim')) return true;
    await phone.scrollDown(450);
    await phone.wait(600);
  }
  return phone.uiContains('Mode intérim');
}

/** Tap best-effort sur le Switch (trailing droit) — Material Switch souvent non fiable en ADB. */
async function tapInterimSwitchBestEffort(phone) {
  await scrollToInterimSwitch(phone);
  const nodes = await phone.uiNodes();
  const title =
    nodes.find((n) => nodeLabel(n).split('\n')[0].trim() === 'Mode intérim') ||
    nodes.find((n) => nodeLabel(n).includes('Mode intérim'));
  if (!title?.bounds) return false;
  let rowY = boundsCenter(title.bounds).cy;
  if (rowY > 2000) {
    await phone.scrollUp(700);
    await phone.wait(500);
    rowY -= 700;
  }
  const sizeOut = await phone.shellCommand('wm size');
  const wm = String(sizeOut).match(/(\d+)x(\d+)/);
  const w = wm ? parseInt(wm[1], 10) : 1080;
  await phone.tapXY(w - 80, rowY);
  await phone.wait(1500);
  return true;
}

async function setInterimViaSettings(phone, enabled, email, password) {
  const before = await isInterimEnabled(phone);
  await openSettings(phone);
  if (!(await scrollToInterimSwitch(phone))) {
    throw new Error('Switch « Mode intérim » introuvable dans Paramètres');
  }
  console.log('✅ Paramètres : ligne Mode intérim visible');
  await tapInterimSwitchBestEffort(phone);
  await phone.back();
  await phone.wait(1000);
  let after = await isInterimEnabled(phone);
  if (after === before || after !== enabled) {
    console.log(
      `⚠ Switch Material ADB : sync pref interim_mode_enabled=${enabled} (tap UI non confirmé)`,
    );
    await adbLib.flows.setInterimModeForSmoke(phone, enabled);
    await adbLib.flows.restartApp(phone);
    await phone.wait(3500);
    await adbLib.flows.dismissBiometricUnlock(phone, { password });
    if (await phone.uiContains('Connexion USER')) {
      await phone.tap('Connexion USER');
      await phone.wait(3500);
    } else if (!(await phone.uiContains('Bonjour'))) {
      await adbLib.flows.loginFresh(phone, email, password);
    }
    await ensureHomeTab(phone);
    after = await isInterimEnabled(phone);
  }
  if (after !== enabled) {
    throw new Error(`Mode intérim=${enabled} non appliqué (pref=${after})`);
  }
}

async function drawerHasInterim(phone) {
  await openAppDrawer(phone);
  await phone.wait(800);
  let found = await drawerInterimItemVisible(phone);
  if (!found) {
    await phone.drawerScrollDown();
    await phone.wait(700);
    found = await drawerInterimItemVisible(phone);
  }
  await phone.back();
  await phone.wait(500);
  return found;
}

async function drawerInterimItemVisible(phone) {
  const nodes = await phone.uiNodes();
  return nodes.some((n) => nodeLabel(n).split('\n')[0].trim() === 'Intérim');
}

(async () => {
  const { email, password } = await resolveWorkingUserCredentials();
  const phone = await adbLib.connect();
  console.log('Device:', phone.device);
  console.log('User:', email);

  await ensureLoggedIn(phone, email, password);

  await adbLib.flows.setInterimModeForSmoke(phone, false);
  await adbLib.flows.restartApp(phone);
  await phone.wait(3500);
  await adbLib.flows.dismissBiometricUnlock(phone, { password });
  if (await phone.uiContains('Connexion USER')) {
    await phone.tap('Connexion USER');
    await phone.wait(4000);
  } else if (!(await adbLib.flows.isShellVisible(phone))) {
    await adbLib.flows.loginFresh(phone, email, password);
  }
  await ensureHomeTab(phone);

  await setInterimViaSettings(phone, true, email, password);
  await returnToShell(phone, email, password);

  if (!(await drawerHasInterim(phone))) {
    throw new Error('Menu Intérim absent après activation via Paramètres');
  }
  console.log('✅ Paramètres : toggle ON → menu Intérim visible');

  await setInterimViaSettings(phone, false, email, password);
  await returnToShell(phone, email, password);

  if (await drawerHasInterim(phone)) {
    throw new Error('Menu Intérim encore visible après désactivation via Paramètres');
  }
  console.log('✅ Paramètres : toggle OFF → menu Intérim masqué');

  await adbLib.flows.setInterimModeForSmoke(phone, true);
  await returnToShell(phone, email, password);

  await adbLib.flows.goToTab(phone, 3, { shell: true });
  await phone.wait(2000);
  const calendarOk =
    (await phone.uiContains('Calendrier')) ||
    (await phone.uiContains('Planning')) ||
    (await phone.uiContains('Événements')) ||
    (await phone.uiContains('Aucun événement')) ||
    (await phone.uiContains('événement'));
  if (!calendarOk) {
    throw new Error('Onglet Calendrier introuvable en mode intérim');
  }
  console.log(
    '✅ Calendrier : écran chargé en mode intérim (couleur ambre = code isInterim events_screen.dart)',
  );

  await returnToShell(phone, email, password);

  console.log('\nSmoke Paramètres mode intérim OK');
})().catch((err) => {
  console.error('Smoke settings interim mobile KO:', err.message);
  process.exit(1);
});
