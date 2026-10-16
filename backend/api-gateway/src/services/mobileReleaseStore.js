const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parsePubspecVersion, githubTagForRelease } = require('../lib/mobilePubspec');
const {
  normalizeLegacyVersion,
  normalizeVersionWithBuild,
  computeSuggestedVersion: computeSuggestedFromPolicy,
} = require('../lib/mobileVersionPolicy');

const DEFAULT_CHANNELS = ['dev', 'preprod', 'production'];
const DEFAULT_PLATFORMS = ['android', 'ios'];

function ensureChannelPlatform(store, channel, platform) {
  if (!store.channels) store.channels = {};
  if (!store.channels[channel]) store.channels[channel] = {};
  if (!store.channels[channel][platform]) {
    store.channels[channel][platform] = {
      activeReleaseId: null,
      minVersion: '0.0.0',
      minBuild: 0,
      forceUpdate: false,
    };
  }
  return store.channels[channel][platform];
}

/** Ancien stub admin.routes.js — remplacé par email JWT réel. */
const LEGACY_STUB_AUTHORS = new Set(['user@jobbingtrack.test', 'admin@jobbingtrack.test']);

function resolveReleaseAuthor(createdBy) {
  if (!createdBy || !LEGACY_STUB_AUTHORS.has(createdBy)) return createdBy;
  return (
    process.env.MOBILE_RELEASE_DEFAULT_AUTHOR?.trim()
    || process.env.ADMIN_EMAIL?.trim()
    || createdBy
  );
}

function migrateLegacyReleaseAuthors(store) {
  let changed = false;
  for (const release of store.releases) {
    const resolved = resolveReleaseAuthor(release.createdBy);
    if (resolved !== release.createdBy) {
      release.createdBy = resolved;
      changed = true;
    }
  }
  if (changed) writeStore(store);
  return store;
}

function releasesDir() {
  return process.env.MOBILE_RELEASES_DIR?.trim() || path.join(process.cwd(), 'mobile-releases');
}

function configPath() {
  return path.join(releasesDir(), 'mobile-releases.json');
}

function emptyStore() {
  const channels = {};
  for (const channel of DEFAULT_CHANNELS) {
    channels[channel] = {};
    for (const platform of DEFAULT_PLATFORMS) {
      channels[channel][platform] = {
        activeReleaseId: null,
        minVersion: '0.0.0',
        minBuild: 0,
        forceUpdate: false,
      };
    }
  }
  return { channels, releases: [] };
}

function ensureDir() {
  const dir = releasesDir();
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function readStore() {
  ensureDir();
  const file = configPath();
  if (!fs.existsSync(file)) {
    const initial = emptyStore();
    fs.writeFileSync(file, JSON.stringify(initial, null, 2), 'utf8');
    return initial;
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    const store = migrateLegacyReleaseAuthors({
      channels: parsed.channels || emptyStore().channels,
      releases: Array.isArray(parsed.releases) ? parsed.releases : [],
    });
    // Migration douce : ajouter preprod (et plateformes manquantes) sans écraser l’existant.
    let changed = false;
    for (const channel of DEFAULT_CHANNELS) {
      for (const platform of DEFAULT_PLATFORMS) {
        if (!store.channels?.[channel]?.[platform]) {
          ensureChannelPlatform(store, channel, platform);
          changed = true;
        }
      }
    }
    if (changed) writeStore(store);
    return store;
  } catch {
    return emptyStore();
  }
}

function writeStore(store) {
  ensureDir();
  fs.writeFileSync(configPath(), JSON.stringify(store, null, 2), 'utf8');
}

function newReleaseId() {
  return `rel-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
}

function findRelease(store, id) {
  return store.releases.find((r) => r.id === id) || null;
}

function getActiveRelease(store, channel, platform) {
  const channelState = store.channels?.[channel]?.[platform];
  if (!channelState?.activeReleaseId) return null;
  return findRelease(store, channelState.activeReleaseId);
}

function resolvePublicApiBaseForMobileDownload() {
  const baseOverride = process.env.MOBILE_ANDROID_DOWNLOAD_BASE_URL?.trim();
  if (baseOverride) return baseOverride.replace(/\/$/, '');

  const publicApi = process.env.PUBLIC_API_URL?.trim() || process.env.NEXT_PUBLIC_API_URL?.trim();
  if (!publicApi) return null;

  let parsed;
  try {
    parsed = new URL(publicApi);
  } catch {
    return publicApi.replace(/\/$/, '');
  }

  const host = parsed.hostname.toLowerCase();
  const isDevLocalHost = host === 'localhost' || host === '127.0.0.1' || host.endsWith('.localhost');

  if (!isDevLocalHost) return publicApi.replace(/\/$/, '');

  const lanHost =
    process.env.MOBILE_DEV_LAN_HOST?.trim()
    || process.env.DEV_HTTPS_LAN_IP?.trim()
    || (process.env.HOST_IP?.trim() && process.env.HOST_IP.trim() !== 'localhost'
      ? process.env.HOST_IP.trim()
      : '');

  if (lanHost) {
    const gatewayPort = process.env.API_GATEWAY_PORT?.trim() || '5002';
    return `http://${lanHost}:${gatewayPort}`;
  }

  return publicApi.replace(/\/$/, '');
}

function isDevLocalDownloadHost(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === 'localhost' || host === '127.0.0.1' || host.endsWith('.localhost');
  } catch {
    return false;
  }
}

function effectiveAndroidDownloadUrl(release) {
  const fullOverride = process.env.MOBILE_ANDROID_DOWNLOAD_URL?.trim();
  if (fullOverride) return fullOverride;
  if (release.downloadUrl && !isDevLocalDownloadHost(release.downloadUrl)) {
    return release.downloadUrl;
  }
  if (release.filename) return buildDownloadUrlForFilename(release.filename);
  return release.downloadUrl || null;
}

function isDevPublicApiUrl() {
  const publicApi = process.env.PUBLIC_API_URL?.trim() || process.env.NEXT_PUBLIC_API_URL?.trim();
  if (!publicApi) return false;
  try {
    const host = new URL(publicApi).hostname.toLowerCase();
    return host === 'localhost' || host === '127.0.0.1' || host.endsWith('.localhost');
  } catch {
    return false;
  }
}

function buildDownloadUrlForFilename(filename) {
  const fullOverride = process.env.MOBILE_ANDROID_DOWNLOAD_URL?.trim();
  if (fullOverride) return fullOverride;

  const baseOverride = process.env.MOBILE_ANDROID_DOWNLOAD_BASE_URL?.trim();
  if (baseOverride && filename) {
    return `${baseOverride.replace(/\/$/, '')}/api/v1/mobile/releases/download/${encodeURIComponent(filename)}`;
  }

  // Dev local : chemin relatif — l'app mobile le résout via ApiService.baseUrl (adb reverse / LAN).
  if (isDevPublicApiUrl() && filename) {
    return `/api/v1/mobile/releases/download/${encodeURIComponent(filename)}`;
  }

  const publicApi = resolvePublicApiBaseForMobileDownload();
  if (!filename || !publicApi) return null;
  return `${publicApi}/api/v1/mobile/releases/download/${encodeURIComponent(filename)}`;
}

function releaseToPublicInfo(release, channelState) {
  if (!release) return null;
  const displayVersion = normalizeLegacyVersion(release.version, release.buildNumber);
  const base = {
    platform: release.platform,
    channel: release.channel,
    version: displayVersion,
    buildNumber: release.buildNumber,
    minVersion: channelState?.minVersion || '0.0.0',
    minBuild: channelState?.minBuild ?? 0,
    forceUpdate: channelState?.forceUpdate === true,
    releaseNotes: release.releaseNotes || '',
    releaseId: release.id,
    publishedAt: release.createdAt,
  };

  if (release.platform === 'ios') {
    const storeUrl = release.storeUrl || process.env.MOBILE_IOS_APP_STORE_URL?.trim() || null;
    return { ...base, storeUrl, downloadUrl: storeUrl };
  }

  return {
    ...base,
    downloadUrl: effectiveAndroidDownloadUrl(release),
  };
}

const MIN_APK_BYTES = 100 * 1024; // 100 Ko — rejette les faux APK smoke (17 o)

function assertValidApkOnDisk(filePath) {
  if (!filePath || !fs.existsSync(filePath)) {
    throw new Error(`APK introuvable : ${filePath}`);
  }
  const size = fs.statSync(filePath).size;
  if (size < MIN_APK_BYTES) {
    throw new Error(
      `APK invalide (${size} octets) — fichier trop petit pour être installé sur Android. `
      + 'Utilisez un APK Flutter buildé (étape 1 backoffice), pas un fichier de test.',
    );
  }
}

function formatFileSize(bytes) {
  if (!bytes || bytes <= 0) return null;
  if (bytes < 1024) return `${bytes} o`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} Ko`;
  return `${(bytes / 1024 / 1024).toFixed(1)} Mo`;
}

function enrichReleaseForAdmin(release) {
  if (!release) return null;
  const displayVersion = normalizeLegacyVersion(release.version, release.buildNumber);
  const enriched = {
    ...release,
    displayVersion,
    githubTag: release.githubTag || githubTagForRelease(displayVersion, release.buildNumber),
  };

  if (release.filename) {
    const filePath = path.join(releasesDir(), release.filename);
    if (fs.existsSync(filePath)) {
      try {
        assertValidApkOnDisk(filePath);
      } catch (e) {
        enriched.apkInvalid = true;
        enriched.apkInvalidReason = e.message;
      }
      const stat = fs.statSync(filePath);
      enriched.fileSizeBytes = stat.size;
      enriched.fileSizeLabel = formatFileSize(stat.size);
    }
  }

  return enriched;
}

function computeSuggestedVersion(androidReleases, activeDev, pubspec) {
  return computeSuggestedFromPolicy(androidReleases, activeDev, pubspec);
}

function getDeployHints(store) {
  const androidReleases = store.releases.filter((r) => r.platform === 'android');
  const latest = androidReleases[0] || null;
  const activeDev = getActiveRelease(store, 'dev', 'android');
  const activeProd = getActiveRelease(store, 'production', 'android');
  const pubspec = parsePubspecVersion();
  const { suggestedVersion, suggestedBuild } = computeSuggestedVersion(
    androidReleases,
    activeDev,
    pubspec,
  );

  const needsPubspecBump = Boolean(
    pubspec
    && activeDev
    && pubspec.buildNumber <= activeDev.buildNumber,
  );

  const canPublishCurrentBuild = !needsPubspecBump;
  const publishBlockedReason = needsPubspecBump
    ? `Le build ${normalizeVersionWithBuild(pubspec.version, pubspec.buildNumber)} (n°${pubspec.buildNumber}) est déjà actif sur dev. Lancez « Build APK » (incrément auto vers ${computeSuggestedFromPolicy(androidReleases, activeDev, pubspec).suggestedVersion}) ou bump manuel dans pubspec.`
    : null;

  return {
    publicApiUrl:
      process.env.PUBLIC_API_URL?.trim()
      || process.env.NEXT_PUBLIC_API_URL?.trim()
      || null,
    mobileDownloadBaseUrl: resolvePublicApiBaseForMobileDownload(),
    suggestedVersion,
    suggestedBuild,
    pubspecVersion: pubspec?.version || null,
    pubspecBuild: pubspec?.buildNumber || null,
    pubspecPath: pubspec?.pubspecPath || null,
    needsPubspecBump,
    canPublishCurrentBuild,
    publishBlockedReason,
    activeDevRelease: enrichReleaseForAdmin(activeDev),
    activeProdRelease: enrichReleaseForAdmin(activeProd),
    latestAndroidRelease: enrichReleaseForAdmin(latest),
    githubReleasesEnabled: process.env.MOBILE_GITHUB_RELEASES_ENABLED === 'true',
    githubRepository:
      process.env.GITHUB_REPOSITORY?.trim()
      || process.env.MOBILE_GITHUB_REPOSITORY?.trim()
      || null,
  };
}

function listAdminState() {
  const store = readStore();
  const channels = {};
  for (const channel of DEFAULT_CHANNELS) {
    channels[channel] = {};
    for (const platform of DEFAULT_PLATFORMS) {
      const channelState = store.channels[channel][platform];
      channels[channel][platform] = {
        ...channelState,
        activeRelease: enrichReleaseForAdmin(getActiveRelease(store, channel, platform)),
      };
    }
  }
  return {
    releasesDir: releasesDir(),
    deployHints: getDeployHints(store),
    channels,
    releases: [...store.releases]
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
      .map((release) => enrichReleaseForAdmin(release)),
  };
}

function createRelease({
  channel,
  platform,
  version,
  buildNumber,
  releaseNotes,
  filename,
  createdBy,
  storeUrl,
}) {
  const store = readStore();
  const resolvedBuild = parseInt(String(buildNumber), 10) || 1;
  const resolvedVersion = normalizeVersionWithBuild(String(version), resolvedBuild);
  if (platform === 'android' && filename) {
    assertValidApkOnDisk(path.join(releasesDir(), filename));
  }
  const release = {
    id: newReleaseId(),
    channel,
    platform,
    version: resolvedVersion,
    buildNumber: resolvedBuild,
    releaseNotes: releaseNotes || '',
    filename: filename || null,
    storeUrl: storeUrl || null,
    downloadUrl: platform === 'android' && filename ? buildDownloadUrlForFilename(filename) : null,
    createdAt: new Date().toISOString(),
    createdBy: resolveReleaseAuthor(createdBy || null),
    status: 'active',
    githubTag: githubTagForRelease(resolvedVersion, resolvedBuild),
    githubReleaseUrl: null,
  };

  for (const existing of store.releases) {
    if (
      existing.channel === channel
      && existing.platform === platform
      && existing.status === 'active'
    ) {
      existing.status = 'superseded';
    }
  }

  store.releases.unshift(release);
  ensureChannelPlatform(store, channel, platform).activeReleaseId = release.id;
  writeStore(store);
  return release;
}

function activateRelease(releaseId, channel, platform) {
  const store = readStore();
  const release = findRelease(store, releaseId);
  if (!release) return null;
  if (release.platform !== platform) return null;

  for (const existing of store.releases) {
    if (
      existing.channel === channel
      && existing.platform === platform
      && existing.status === 'active'
    ) {
      existing.status = 'superseded';
    }
  }

  release.channel = channel;
  release.status = 'active';
  ensureChannelPlatform(store, channel, platform).activeReleaseId = release.id;
  writeStore(store);
  return release;
}

function promoteRelease({ platform, fromChannel = 'dev', toChannel = 'production', promotedBy }) {
  const store = readStore();
  const source = getActiveRelease(store, fromChannel, platform);
  if (!source) return null;

  for (const existing of store.releases) {
    if (
      existing.channel === toChannel
      && existing.platform === platform
      && existing.status === 'active'
    ) {
      existing.status = 'superseded';
    }
  }

  source.status = 'promoted';

  const promoted = {
    id: newReleaseId(),
    channel: toChannel,
    platform,
    version: source.version,
    buildNumber: source.buildNumber,
    releaseNotes: source.releaseNotes,
    filename: source.filename,
    storeUrl: source.storeUrl,
    downloadUrl:
      source.filename
        ? buildDownloadUrlForFilename(source.filename)
        : effectiveAndroidDownloadUrl(source),
    createdAt: new Date().toISOString(),
    createdBy: resolveReleaseAuthor(promotedBy || `promote:${fromChannel}->${toChannel}`),
    status: 'active',
    githubTag: source.githubTag || githubTagForRelease(source.version, source.buildNumber),
    githubReleaseUrl: source.githubReleaseUrl || null,
  };

  store.releases.unshift(promoted);
  ensureChannelPlatform(store, toChannel, platform).activeReleaseId = promoted.id;
  writeStore(store);
  return promoted;
}

function updateChannelPolicy(channel, platform, patch) {
  const store = readStore();
  const current = store.channels[channel]?.[platform];
  if (!current) return null;

  if (patch.minVersion !== undefined) current.minVersion = String(patch.minVersion);
  if (patch.minBuild !== undefined) current.minBuild = parseInt(String(patch.minBuild), 10) || 0;
  if (patch.forceUpdate !== undefined) current.forceUpdate = patch.forceUpdate === true;
  writeStore(store);
  return current;
}

function channelForFilename(filename) {
  const name = path.basename(String(filename || ''));
  if (!name) return null;
  const file = configPath();
  if (!fs.existsSync(file)) return null;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    const hit = (parsed.releases || []).find((r) => r && r.filename === name);
    return hit ? String(hit.channel || '') : null;
  } catch {
    return null;
  }
}

function getPublicReleaseInfo(platformRaw, channelRaw) {
  const platform = String(platformRaw || 'android').toLowerCase();
  const channel = String(channelRaw || 'production').toLowerCase();
  const store = readStore();
  const channelState = store.channels?.[channel]?.[platform];
  const active = getActiveRelease(store, channel, platform);
  if (active) {
    return releaseToPublicInfo(active, channelState);
  }

  if (channel !== 'production') {
    return null;
  }

  // Fallback env Portainer (production seulement)
  const { getMobileReleaseInfoFromEnv } = require('../lib/mobileReleaseConfigEnv');
  const envInfo = getMobileReleaseInfoFromEnv(platform);
  if (!envInfo) return null;
  return {
    ...envInfo,
    channel: 'production',
    minVersion: channelState?.minVersion || envInfo.minVersion,
    minBuild: channelState?.minBuild ?? envInfo.minBuild,
    forceUpdate: channelState?.forceUpdate === true || envInfo.forceUpdate,
  };
}

function resolveBuiltApkPath() {
  const candidates = [
    process.env.MOBILE_APK_BUILD_PATH?.trim(),
    '/app/mobile-apk-build/app-debug.apk',
    path.join(process.cwd(), 'mobile/build/app/outputs/flutter-apk/app-debug.apk'),
    path.join(process.cwd(), '../mobile/build/app/outputs/flutter-apk/app-debug.apk'),
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

/** Copie l'APK debug buildé (étape 1) vers le stockage OTA — sans upload navigateur. */
function resolvePublishVersionInputs(version, buildNumber) {
  const pubspec = parsePubspecVersion();
  const resolvedVersion = version?.toString().trim() || pubspec?.version;
  const resolvedBuild = buildNumber?.toString().trim()
    ? parseInt(String(buildNumber), 10)
    : pubspec?.buildNumber;

  if (!resolvedVersion || !resolvedBuild) {
    throw new Error(
      'version et buildNumber requis — lancez « Build APK » (incrément auto pubspec) ou éditez mobile/pubspec.yaml.',
    );
  }

  return {
    version: normalizeVersionWithBuild(resolvedVersion, resolvedBuild),
    buildNumber: resolvedBuild,
    pubspec,
  };
}

function attachGithubReleaseMetadata(releaseId, { githubReleaseUrl, githubTag }) {
  const store = readStore();
  const release = findRelease(store, releaseId);
  if (!release) return null;
  if (githubReleaseUrl) release.githubReleaseUrl = githubReleaseUrl;
  if (githubTag) release.githubTag = githubTag;
  writeStore(store);
  return release;
}

function publishBuiltApk({
  channel = 'dev',
  version,
  buildNumber,
  releaseNotes = '',
  createdBy = null,
}) {
  const srcPath = resolveBuiltApkPath();
  if (!srcPath) {
    throw new Error(
      'APK debug introuvable sur le serveur. Lancez « Build APK » (étape 1) ou make reinstall-app, '
      + 'puis si besoin : docker compose up -d api-gateway --force-recreate '
      + '(montage mobile/build → /app/mobile-apk-build parfois vide jusqu’au recreate). '
      + 'Alternative : bash scripts/mobile/publish-built-dev.sh',
    );
  }

  const resolved = resolvePublishVersionInputs(version, buildNumber);

  const storeBefore = readStore();
  const activeOnChannel = getActiveRelease(storeBefore, channel, 'android');
  if (
    activeOnChannel
    && activeOnChannel.buildNumber === resolved.buildNumber
    && normalizeLegacyVersion(activeOnChannel.version, activeOnChannel.buildNumber)
      === normalizeVersionWithBuild(resolved.version, resolved.buildNumber)
  ) {
    throw new Error(
      `Build ${resolved.version} (n°${resolved.buildNumber}) déjà actif sur le canal ${channel}. `
      + 'Lancez « Build APK » pour incrémenter automatiquement le pubspec.',
    );
  }

  const { safeApkFilename } = require('../middleware/mobileApkUpload');
  const destFilename = safeApkFilename(
    `jobbingtrack-v${resolved.version}+${resolved.buildNumber}-debug.apk`,
  );
  const destPath = path.join(releasesDir(), destFilename);
  fs.copyFileSync(srcPath, destPath);
  assertValidApkOnDisk(destPath);

  return createRelease({
    channel,
    platform: 'android',
    version: resolved.version,
    buildNumber: resolved.buildNumber,
    releaseNotes,
    filename: destFilename,
    createdBy,
  });
}

module.exports = {
  releasesDir,
  readStore,
  listAdminState,
  createRelease,
  publishBuiltApk,
  resolveBuiltApkPath,
  resolvePublishVersionInputs,
  attachGithubReleaseMetadata,
  activateRelease,
  promoteRelease,
  updateChannelPolicy,
  getPublicReleaseInfo,
  channelForFilename,
  buildDownloadUrlForFilename,
  resolvePublicApiBaseForMobileDownload,
  enrichReleaseForAdmin,
  computeSuggestedVersion,
};
