/**
 * Refuse les appels entrants système pendant les smokes ADB uniquement.
 * Activé seulement si le process est un script sous scripts/mobile/smoke/
 * (voir scripts/mobile/lib/smoke-runtime.js) — jamais via .env produit.
 */

const JOBINGTRACK_PKG = 'cloud.hubera.jobs';

const INCOMING_PACKAGES = [
  'com.android.incallui',
  'com.samsung.android.incallui',
  'com.google.android.dialer',
  'com.android.dialer',
  'com.samsung.android.dialer',
];

const DECLINE_LABELS = [
  'Refuser',
  'Decline',
  'Raccrocher',
  'Rejeter',
  'Reject',
  'REFUSE',
  'Ignorer',
  'Dismiss',
];

function smokeDismissIncomingCallsEnabled() {
  return process.env.SMOKE_DISMISS_INCOMING_CALLS === '1';
}

function xmlLooksLikeIncomingCall(xml) {
  const lower = String(xml || '').toLowerCase();
  if (!lower) return false;

  if (INCOMING_PACKAGES.some((pkg) => lower.includes(pkg))) {
    if (
      lower.includes('incoming') ||
      lower.includes('entrant') ||
      lower.includes('appel entrant') ||
      lower.includes('ringing')
    ) {
      return true;
    }
    const hasAnswer =
      lower.includes('répondre') ||
      lower.includes('answer call') ||
      lower.includes('content-desc="answer"');
    const hasDecline = DECLINE_LABELS.some((l) => lower.includes(l.toLowerCase()));
    if (hasAnswer && hasDecline) return true;
  }

  const hasAnswerUi =
    lower.includes('répondre') ||
    lower.includes('answer call') ||
    (lower.includes('answer') && lower.includes('decline'));
  const hasDeclineUi = DECLINE_LABELS.some((l) => lower.includes(l.toLowerCase()));
  if (hasAnswerUi && hasDeclineUi && !lower.includes('nouvel appel')) {
    return true;
  }

  return false;
}

async function shellEndCall(adb) {
  try {
    await adb.shellCommand('input keyevent 6');
  } catch {
    /* ENDCALL indisponible */
  }
  try {
    await adb.shellCommand('cmd telecom end-call');
  } catch {
    /* API telecom absente */
  }
}

async function bringJobbingTrackToFront(adb) {
  try {
    await adb.shellCommand(`am start -n ${JOBINGTRACK_PKG}/.MainActivity`);
  } catch {
    /* ignore */
  }
}

/**
 * Refuse un appel entrant système (jamais « Répondre »).
 * @returns {boolean} true si un overlay appel a été traité
 */
async function dismissIncomingPhoneCall(adb, { log = true } = {}) {
  if (!smokeDismissIncomingCallsEnabled()) return false;

  let xml = '';
  try {
    xml = await adb.uiDump(true);
  } catch {
    return false;
  }

  if (!xmlLooksLikeIncomingCall(xml)) {
    return false;
  }

  if (log && adb._log) {
    adb._log('appel entrant — refus auto (smoke uniquement)');
  }

  for (const label of DECLINE_LABELS) {
    if (!xml.toLowerCase().includes(label.toLowerCase())) continue;
    try {
      const r = await adb._post('/find-and-tap', { text: label, index: 0 });
      if (r.success) {
        adb._invalidateUi?.();
        await adb.wait(400);
        await bringJobbingTrackToFront(adb);
        await adb.wait(500);
        return true;
      }
    } catch {
      /* essai suivant */
    }
  }

  await shellEndCall(adb);
  await adb.wait(400);
  await bringJobbingTrackToFront(adb);
  await adb.wait(500);
  adb._invalidateUi?.();
  return true;
}

module.exports = {
  dismissIncomingPhoneCall,
  xmlLooksLikeIncomingCall,
  smokeDismissIncomingCallsEnabled,
};
