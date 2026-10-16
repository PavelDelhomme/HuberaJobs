const express = require('express');
const path = require('path');
const fs = require('fs');
const jwt = require('jsonwebtoken');
const { getMobileReleaseInfo } = require('../lib/mobileReleaseConfig');
const { betaChannelBlocked } = require('../lib/betaChannel');
const { channelForFilename } = require('../services/mobileReleaseStore');

const router = express.Router();

function optionalJwtEmail(req) {
  const header = String(req.headers.authorization || '');
  if (!header.startsWith('Bearer ') || !process.env.JWT_SECRET) return '';
  try {
    const decoded = jwt.verify(header.slice(7), process.env.JWT_SECRET);
    return String(decoded.email || '');
  } catch {
    return '';
  }
}

router.get('/latest', (req, res) => {
  const channel = req.query.channel || 'production';
  if (betaChannelBlocked(channel, optionalJwtEmail(req), process.env.HUBERA_BETA_EMAILS || '')) {
    return res.status(404).json({ success: false, error: 'APK non publiée' });
  }
  const info = getMobileReleaseInfo(req.query.platform, channel);
  if (!info) {
    return res.status(400).json({
      success: false,
      error: 'Plateforme non supportée (android | ios)',
    });
  }
  return res.json({ success: true, release: info });
});

router.get('/download/:filename', (req, res) => {
  const releasesDir = process.env.MOBILE_RELEASES_DIR?.trim();
  if (!releasesDir) {
    return res.status(503).json({
      success: false,
      error: 'Hébergement APK non configuré (MOBILE_RELEASES_DIR)',
    });
  }

  const safeName = path.basename(String(req.params.filename || ''));
  if (!safeName || !safeName.toLowerCase().endsWith('.apk')) {
    return res.status(400).json({ success: false, error: 'Nom de fichier APK invalide' });
  }
  if (betaChannelBlocked(channelForFilename(safeName), optionalJwtEmail(req), process.env.HUBERA_BETA_EMAILS || '')) {
    return res.status(404).json({ success: false, error: 'APK non publiée' });
  }

  const filePath = path.join(releasesDir, safeName);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ success: false, error: 'APK introuvable' });
  }

  res.setHeader('Content-Type', 'application/vnd.android.package-archive');
  res.setHeader('Content-Disposition', `attachment; filename="${safeName}"`);
  return res.sendFile(filePath);
});

module.exports = router;
