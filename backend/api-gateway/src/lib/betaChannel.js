/** Canal bêta. Un compte absent de la liste ne voit jamais la version bêta. */

function isBetaAccount(email, allowList) {
  const emailNorm = String(email || '').trim().toLowerCase();
  if (!emailNorm) return false;
  const allowed = String(allowList || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return allowed.includes(emailNorm);
}

/** `channel=beta` sans compte bêta → 404. Le canal prod anonyme reste ouvert. */
function betaChannelBlocked(channel, email, allowList) {
  return String(channel || '').trim().toLowerCase() === 'beta'
    && !isBetaAccount(email, allowList);
}

module.exports = { isBetaAccount, betaChannelBlocked };
