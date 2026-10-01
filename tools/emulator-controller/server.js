#!/usr/bin/env node
/**
 * Contrôleur d'émulateur Android – à lancer sur la machine hôte (avec Android SDK + Flutter).
 * Expose : liste AVD, liste appareils ADB, démarrer AVD, build APK, run app, screenshot.
 * Port par défaut : 5055 (plage 50XX du projet). CORS activé pour le backoffice.
 */

const http = require('http');
const { exec, spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = parseInt(process.env.EMULATOR_CONTROLLER_PORT || '5055', 10);
const HOST = process.env.EMULATOR_CONTROLLER_HOST || '0.0.0.0';
const BASE_PATH = (process.env.EMULATOR_CONTROLLER_BASE_PATH || '').replace(/\/$/, '');
const MOBILE_PATH = process.env.MOBILE_PROJECT_PATH || path.resolve(__dirname, '../../mobile');
const REPO_ROOT = path.resolve(MOBILE_PATH, '..');
const BUILD_APK_SCRIPT = path.join(REPO_ROOT, 'scripts/mobile/setup/build-apk-debug.sh');
let ANDROID_HOME = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || '';
if (!ANDROID_HOME && process.env.HOME) {
  const p = path.join(process.env.HOME, 'Android', 'Sdk');
  if (fs.existsSync(p)) ANDROID_HOME = p;
}
const ANDROID_PACKAGE = process.env.ANDROID_PACKAGE || 'cloud.hubera.jobs';

/** Volume Flutter/repo hôte : git refuse le build sans safe.directory (dubious ownership). */
function ensureGitSafeDirectories() {
  const dirs = ['/opt/flutter', '/workspace', REPO_ROOT, MOBILE_PATH];
  for (const dir of dirs) {
    if (!dir || !fs.existsSync(dir)) continue;
    try {
      execSync(`git config --global --add safe.directory ${JSON.stringify(dir)}`, { stdio: 'ignore' });
    } catch { /* déjà enregistré */ }
  }
}
ensureGitSafeDirectories();

function pickLanIPv4() {
  const os = require('os');
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    if (/docker|br-|veth|tun|wg|vir/i.test(name)) continue;
    for (const net of nets[name] || []) {
      if (net.family !== 'IPv4' || net.internal) continue;
      if (/^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\./.test(net.address)) {
        return net.address;
      }
    }
  }
  return null;
}

async function setupAdbReverseForDevice(deviceId, { force = false } = {}) {
  const REVERSE_TTL_MS = 120_000;
  const now = Date.now();
  const cached = adbReverseCache.get(deviceId);
  if (!force && cached && now - cached.at < REVERSE_TTL_MS) {
    return cached.ports;
  }
  const portsToReverse = [5002, 5003, 3000, 3001, 3002, 3003, 3004, 3005, 8025];
  let ok = 0;
  for (const port of portsToReverse) {
    try {
      await execPromise(`adb -s ${deviceId} reverse tcp:${port} tcp:${port}`, { cwd: MOBILE_PATH });
      ok += 1;
    } catch (_) { /* ignore */ }
  }
  adbReverseCache.set(deviceId, { at: now, ports: ok });
  return ok;
}

const adbReverseCache = new Map();
const deviceDetailsCache = new Map();
const DEVICE_DETAILS_TTL_MS = 25_000;

function envWithAndroid() {
  const flutterSdk =
    getFlutterSdkPath()
    || process.env.FLUTTER_ROOT
    || '/opt/flutter';
  const flutterBinDir = path.join(flutterSdk, 'bin');
  const pathParts = String(process.env.PATH || '')
    .split(':')
    .filter((part) => part && part !== flutterBinDir);
  return {
    ...process.env,
    ANDROID_HOME,
    ANDROID_SDK_ROOT: ANDROID_HOME,
    FLUTTER_ROOT: flutterSdk,
    FLUTTER_BIN: path.join(flutterBinDir, 'flutter'),
    PATH: [flutterBinDir, ...pathParts].join(':'),
  };
}

function isGradleCacheCorrupted(gradleCache) {
  const pluginKt = path.join(gradleCache, 'src', 'main', 'kotlin', 'FlutterPlugin.kt');
  if (!fs.existsSync(pluginKt)) return false;
  try {
    const content = fs.readFileSync(pluginKt, 'utf8');
    return (
      content.includes('"/usr/bin/flutter"')
      || content.includes('Paths.get("/usr", "bin", flutterExecutableName)')
    );
  } catch {
    return true;
  }
}

function send(res, statusCode, body, contentType = 'application/json') {
  res.writeHead(statusCode, {
    'Content-Type': contentType,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}

function execPromise(cmd, opts = {}) {
  return new Promise((resolve, reject) => {
    exec(cmd, { maxBuffer: 10 * 1024 * 1024, env: envWithAndroid(), ...opts }, (err, stdout, stderr) => {
      if (err) {
        const msg = Buffer.isBuffer(stderr) ? stderr.toString() : (stderr || stdout || err.message);
        return reject(new Error(typeof msg === 'string' ? msg : String(msg)));
      }
      const encoding = opts.encoding;
      if (encoding === null) {
        resolve({ stdout, stderr: (Buffer.isBuffer(stderr) ? stderr.toString() : (stderr || '')).trim() });
        return;
      }
      const out = stdout == null ? '' : (Buffer.isBuffer(stdout) ? stdout.toString() : String(stdout));
      const serr = stderr == null ? '' : (Buffer.isBuffer(stderr) ? stderr.toString() : String(stderr));
      resolve({ stdout: out.trim(), stderr: serr.trim() });
    });
  });
}

/** Exécute une commande et retourne toujours { stdout, stderr, code } sans rejeter (pour build long). */
function execCapture(cmd, opts = {}) {
  return new Promise((resolve) => {
    const env = { ...envWithAndroid(), ...(opts.env || {}) };
    exec(cmd, { maxBuffer: 10 * 1024 * 1024, env, ...opts }, (err, stdout, stderr) => {
      const out = stdout == null ? '' : (Buffer.isBuffer(stdout) ? stdout.toString() : String(stdout));
      const serr = stderr == null ? '' : (Buffer.isBuffer(stderr) ? stderr.toString() : String(stderr));
      resolve({
        stdout: out.trim(),
        stderr: serr.trim(),
        code: err ? (typeof err.code === 'number' ? err.code : 1) : 0,
      });
    });
  });
}

/** Processus build/install en cours — annulables via POST /cancel-operation */
let activeBuildProcess = null;
let activeInstallProcess = null;
/** Empêche deux installs ADB concurrentes (même appareil ou flotte). */
let activeInstallDeviceId = null;

async function relaunchAppSingleInstance(deviceId) {
  const execOpts = { cwd: MOBILE_PATH };
  await execPromise(`adb -s ${deviceId} shell am force-stop ${ANDROID_PACKAGE}`, execOpts);
  // -S : force-stop puis start — une seule instance / task (évite doublons dans le recents)
  await execPromise(`adb -s ${deviceId} shell am start -S -n ${ANDROID_PACKAGE}/.MainActivity`, execOpts);
}

function execCaptureTracked(cmd, opts = {}) {
  return new Promise((resolve) => {
    const env = { ...envWithAndroid(), ...(opts.env || {}) };
    const child = exec(cmd, { maxBuffer: 10 * 1024 * 1024, env, ...opts }, (err, stdout, stderr) => {
      if (activeBuildProcess === child) activeBuildProcess = null;
      const out = stdout == null ? '' : (Buffer.isBuffer(stdout) ? stdout.toString() : String(stdout));
      const serr = stderr == null ? '' : (Buffer.isBuffer(stderr) ? stderr.toString() : String(stderr));
      resolve({
        stdout: out.trim(),
        stderr: serr.trim(),
        code: err && err.killed ? 130 : (err ? (typeof err.code === 'number' ? err.code : 1) : 0),
        cancelled: !!(err && err.killed),
      });
    });
    activeBuildProcess = child;
  });
}

function execPromiseTracked(cmd, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = exec(cmd, { maxBuffer: 10 * 1024 * 1024, env: envWithAndroid(), ...opts }, (err, stdout, stderr) => {
      if (activeInstallProcess === child) activeInstallProcess = null;
      if (err && err.killed) {
        return reject(Object.assign(new Error('Commande interrompue (annulation)'), { cancelled: true }));
      }
      if (err) {
        const msg = Buffer.isBuffer(stderr) ? stderr.toString() : (stderr || stdout || err.message);
        return reject(new Error(typeof msg === 'string' ? msg : String(msg)));
      }
      const out = stdout == null ? '' : (Buffer.isBuffer(stdout) ? stdout.toString() : String(stdout));
      const serr = stderr == null ? '' : (Buffer.isBuffer(stderr) ? stderr.toString() : String(stderr));
      resolve({ stdout: out.trim(), stderr: serr.trim() });
    });
    activeInstallProcess = child;
  });
}

function cancelActiveOperations() {
  const cancelled = [];
  if (activeBuildProcess) {
    activeBuildProcess.kill('SIGTERM');
    activeBuildProcess = null;
    cancelled.push('build');
  }
  if (activeInstallProcess) {
    activeInstallProcess.kill('SIGTERM');
    activeInstallProcess = null;
    cancelled.push('install');
  }
  return cancelled;
}

function parsePubspecVersion() {
  try {
    const yaml = fs.readFileSync(path.join(MOBILE_PATH, 'pubspec.yaml'), 'utf8');
    const m = yaml.match(/^version:\s*([0-9.]+)\+(\d+)/m);
    if (!m) return null;
    return { version: m[1], buildNumber: parseInt(m[2], 10) || 1 };
  } catch {
    return null;
  }
}

function sanitizeApkFilenamePart(value) {
  return String(value ?? '').replace(/[^a-zA-Z0-9._+-]/g, '_') || '0';
}

/** Nom de fichier téléchargement PC : jobbingtrack-v1.0.0+101-debug.apk */
function buildApkDownloadFilename(version, buildNumber) {
  const v = sanitizeApkFilenamePart(version || '0.0.0');
  const b = sanitizeApkFilenamePart(buildNumber ?? 1);
  return `jobbingtrack-v${v}+${b}-debug.apk`;
}

function resolveApkPath() {
  const apkPathFlutter = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk');
  const apkPathLegacy = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'apk', 'debug', 'app-debug.apk');
  if (fs.existsSync(apkPathFlutter)) return apkPathFlutter;
  if (fs.existsSync(apkPathLegacy)) return apkPathLegacy;
  return null;
}

function sendFile(res, filePath, downloadName) {
  const stat = fs.statSync(filePath);
  res.writeHead(200, {
    'Content-Type': 'application/vnd.android.package-archive',
    'Content-Disposition': `attachment; filename="${downloadName}"`,
    'Content-Length': stat.size,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  fs.createReadStream(filePath).pipe(res);
}

function parseAdbDevices(stdout) {
  const lines = stdout.split('\n').filter((l) => l.trim() && !l.startsWith('List'));
  return lines.map((line) => {
    const parts = line.trim().split(/\s+/);
    const id = parts[0];
    const status = parts[1] || 'unknown';
    return { id, status };
  });
}

const BUILD_SESSION_FILE = path.join(MOBILE_PATH, '.build-session.json');
const BUILD_HISTORY_FILE = path.join(MOBILE_PATH, '.build-history.json');
const BUILD_HISTORY_MAX = 30;

function extractWarningsFromOutput(text) {
  if (!text) return [];
  const lines = String(text).split('\n');
  const warnings = [];
  const seen = new Set();
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    const isWarn =
      /^WARNING:/i.test(t) ||
      /Built-in Kotlin/i.test(t) ||
      /Kotlin Gradle Plugin/i.test(t) ||
      (/warning/i.test(t) && /flutter|gradle|kotlin|plugin/i.test(t));
    if (!isWarn) continue;
    const key = t.slice(0, 240);
    if (seen.has(key)) continue;
    seen.add(key);
    warnings.push(t.slice(0, 800));
  }
  return warnings.slice(0, 25);
}

function readBuildHistory() {
  try {
    if (fs.existsSync(BUILD_HISTORY_FILE)) {
      const arr = JSON.parse(fs.readFileSync(BUILD_HISTORY_FILE, 'utf8'));
      return Array.isArray(arr) ? arr : [];
    }
  } catch { /* ignore */ }
  return [];
}

function appendBuildHistory(entry) {
  const history = readBuildHistory();
  history.unshift(entry);
  if (history.length > BUILD_HISTORY_MAX) history.length = BUILD_HISTORY_MAX;
  try {
    fs.writeFileSync(BUILD_HISTORY_FILE, JSON.stringify(history, null, 2), 'utf8');
  } catch (e) {
    console.error('appendBuildHistory:', e.message);
  }
}

function readBuildSession() {
  try {
    if (fs.existsSync(BUILD_SESSION_FILE)) {
      return JSON.parse(fs.readFileSync(BUILD_SESSION_FILE, 'utf8'));
    }
  } catch { /* ignore */ }
  return null;
}

function writeBuildSession(session) {
  try {
    fs.writeFileSync(BUILD_SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
  } catch (e) {
    console.error('writeBuildSession:', e.message);
  }
}

async function collectAdbDiagnostics({ skipFlutter = false } = {}) {
  const hints = [];
  let adbVersion = null;
  let rawList = '';
  let allDevices = [];
  let flutterDevices = [];

  try {
    const { stdout } = await execPromise('adb version', { timeout: 8000 });
    adbVersion = (stdout || '').split('\n')[0] || null;
  } catch (e) {
    hints.push(`adb indisponible : ${e.message}`);
  }

  try {
    const { stdout } = await execPromise('adb devices -l', { timeout: 10000 });
    rawList = stdout || '';
    allDevices = parseAdbDevices(stdout);
  } catch (e) {
    hints.push(`adb devices échoué : ${e.message}`);
  }

  const ready = allDevices.filter((d) => d.status === 'device');
  const pending = allDevices.filter((d) => d.status !== 'device');

  if (allDevices.length === 0) {
    hints.push('Aucun appareil ADB — branchez le téléphone USB, activez le débogage, acceptez la clé RSA sur l’écran.');
  }
  for (const d of pending) {
    if (d.status === 'unauthorized') {
      hints.push(`${d.id} : non autorisé — déverrouillez le téléphone et acceptez « Autoriser le débogage USB ».`);
    } else if (d.status === 'offline') {
      hints.push(`${d.id} : hors ligne — rebrancher le câble ou relancer adb.`);
    } else {
      hints.push(`${d.id} : état « ${d.status} » — vérifiez le câble et le mode USB (transfert fichiers).`);
    }
  }

  if (!skipFlutter) {
    try {
      const { stdout } = await execPromise('flutter devices --machine', { cwd: MOBILE_PATH, timeout: 15000 });
      const arr = JSON.parse(stdout || '[]');
      if (Array.isArray(arr)) {
        flutterDevices = arr.map((o) => ({
          id: o.id,
          name: o.name || o.id,
          platform: o.platformType || o.platform,
        }));
      }
    } catch { /* flutter devices optionnel */ }
  }

  if (!skipFlutter && ready.length === 0 && flutterDevices.length > 0) {
    hints.push(`${flutterDevices.length} appareil(s) Flutter (émulateur) — ADB USB peut nécessiter un redémarrage du contrôleur après branchement.`);
  }

  if (pending.some((d) => d.status === 'unauthorized')) {
    hints.push(
      'Sur le téléphone : cochez « Toujours autoriser depuis cet ordinateur » pour éviter la demande en boucle.',
    );
  }

  return {
    adbVersion,
    rawList,
    readyCount: ready.length,
    pendingCount: pending.length,
    flutterDeviceCount: flutterDevices.length,
    hints,
    pending,
    flutterDevices,
  };
}

async function queryDeviceDetails(deviceId, { useCache = true } = {}) {
  if (useCache) {
    const hit = deviceDetailsCache.get(deviceId);
    if (hit && Date.now() - hit.at < DEVICE_DETAILS_TTL_MS) {
      return hit.data;
    }
  }
  const details = {
    id: deviceId,
    model: null,
    androidVersion: null,
    appInstalled: false,
    appVersionName: null,
    appVersionCode: null,
  };
  try {
    const { stdout: modelOut } = await execPromise(
      `adb -s ${deviceId} shell getprop ro.product.model`,
    );
    details.model = (modelOut || '').trim() || null;
  } catch { /* ignore */ }
  try {
    const { stdout: apiOut } = await execPromise(
      `adb -s ${deviceId} shell getprop ro.build.version.release`,
    );
    details.androidVersion = (apiOut || '').trim() || null;
  } catch { /* ignore */ }
  try {
    const { stdout: pkgOut } = await execPromise(
      `adb -s ${deviceId} shell dumpsys package ${ANDROID_PACKAGE}`,
      { maxBuffer: 4 * 1024 * 1024 },
    );
    if (pkgOut && pkgOut.includes('versionName')) {
      details.appInstalled = true;
      const nameMatch = pkgOut.match(/versionName=([^\s\n]+)/);
      const codeMatch = pkgOut.match(/versionCode=(\d+)/);
      details.appVersionName = nameMatch ? nameMatch[1] : null;
      details.appVersionCode = codeMatch ? parseInt(codeMatch[1], 10) : null;
    } else {
      const { stdout: pmOut } = await execPromise(
        `adb -s ${deviceId} shell pm path ${ANDROID_PACKAGE}`,
      );
      details.appInstalled = Boolean((pmOut || '').trim());
    }
  } catch { /* ignore */ }
  deviceDetailsCache.set(deviceId, { at: Date.now(), data: details });
  return details;
}

/** Cache frames ADB — JPEG réduit pour le live web (beaucoup plus rapide que PNG full). */
const liveFrames = new Map();
const liveCaptureLoops = new Map();
const LIVE_CAPTURE_INTERVAL_MS = parseInt(process.env.EMULATOR_LIVE_CAPTURE_MS || '50', 10);
const LIVE_MAX_WIDTH = parseInt(process.env.EMULATOR_LIVE_MAX_WIDTH || '720', 10);
const LIVE_JPEG_QUALITY = parseInt(process.env.EMULATOR_LIVE_JPEG_QUALITY || '55', 10);

function getLiveFrame(deviceId) {
  return liveFrames.get(deviceId) || null;
}

function captureLiveFrame(deviceId) {
  const existing = liveFrames.get(deviceId);
  if (existing?.inFlight) return existing.inFlight;

  const promise = new Promise((resolve, reject) => {
    const adb = spawn(
      'adb',
      ['-s', deviceId, 'exec-out', 'screencap', '-p'],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    const convert = spawn(
      'convert',
      [
        'png:-',
        '-resize',
        `${LIVE_MAX_WIDTH}x>`,
        '-quality',
        String(LIVE_JPEG_QUALITY),
        'jpeg:-',
      ],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    adb.stdout.pipe(convert.stdin);
    const chunks = [];
    convert.stdout.on('data', (c) => chunks.push(c));
    let adbErr = '';
    let convertErr = '';
    adb.stderr.on('data', (d) => {
      adbErr += d.toString();
    });
    convert.stderr.on('data', (d) => {
      convertErr += d.toString();
    });
    adb.on('error', reject);
    convert.on('error', (err) => {
      // Fallback PNG brut si ImageMagick absent
      execPromise(`adb -s ${deviceId} exec-out screencap -p`, { encoding: null })
        .then(({ stdout }) => {
          liveFrames.set(deviceId, {
            buffer: stdout,
            contentType: 'image/png',
            capturedAt: Date.now(),
            inFlight: null,
          });
          resolve(stdout);
        })
        .catch(reject);
    });
    convert.on('close', (code) => {
      if (code !== 0 || chunks.length === 0) {
        execPromise(`adb -s ${deviceId} exec-out screencap -p`, { encoding: null })
          .then(({ stdout }) => {
            liveFrames.set(deviceId, {
              buffer: stdout,
              contentType: 'image/png',
              capturedAt: Date.now(),
              inFlight: null,
            });
            resolve(stdout);
          })
          .catch((e) =>
            reject(
              new Error(
                convertErr || adbErr || e.message || `convert exit ${code}`,
              ),
            ),
          );
        return;
      }
      const buffer = Buffer.concat(chunks);
      liveFrames.set(deviceId, {
        buffer,
        contentType: 'image/jpeg',
        capturedAt: Date.now(),
        inFlight: null,
      });
      resolve(buffer);
    });
  }).catch((err) => {
    const prev = liveFrames.get(deviceId);
    if (prev) prev.inFlight = null;
    throw err;
  });

  liveFrames.set(deviceId, {
    buffer: existing?.buffer || null,
    contentType: existing?.contentType || 'image/jpeg',
    capturedAt: existing?.capturedAt || 0,
    inFlight: promise,
  });
  return promise;
}

function startLiveCaptureLoop(deviceId) {
  if (!deviceId) return;
  const current = liveCaptureLoops.get(deviceId);
  if (current?.active) {
    current.refCount = (current.refCount || 1) + 1;
    return;
  }
  const state = { active: true, refCount: 1 };
  liveCaptureLoops.set(deviceId, state);
  const tick = () => {
    if (!state.active) return;
    const frame = getLiveFrame(deviceId);
    if (!frame?.inFlight) captureLiveFrame(deviceId).catch(() => {});
    if (state.active) state.timer = setTimeout(tick, LIVE_CAPTURE_INTERVAL_MS);
  };
  captureLiveFrame(deviceId).catch(() => {});
  tick();
}

function stopLiveCaptureLoop(deviceId) {
  if (!deviceId) return;
  const state = liveCaptureLoops.get(deviceId);
  if (!state) return;
  state.refCount = (state.refCount || 1) - 1;
  if (state.refCount > 0) return;
  state.active = false;
  if (state.timer) clearTimeout(state.timer);
  liveCaptureLoops.delete(deviceId);
}

function sendImage(res, buffer, contentType, capturedAt) {
  const ageMs = capturedAt ? Date.now() - capturedAt : 0;
  res.writeHead(200, {
    'Content-Type': contentType || 'image/jpeg',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
    'X-Frame-Age-Ms': String(ageMs),
  });
  res.end(buffer);
}

function sendPng(res, buffer, capturedAt) {
  sendImage(res, buffer, 'image/png', capturedAt);
}

/** Lit le chemin du SDK Flutter depuis mobile/android/local.properties */
function getFlutterSdkPath() {
  const propsPath = path.join(MOBILE_PATH, 'android', 'local.properties');
  if (!fs.existsSync(propsPath)) return null;
  try {
    const content = fs.readFileSync(propsPath, 'utf8');
    const m = content.match(/flutter\.sdk=(.+)/);
    return m ? m[1].trim() : null;
  } catch (_) {
    return null;
  }
}

/** Copie récursive d'un dossier (Node 16+ fs.cpSync, sinon fallback). */
function copyDirRecursive(src, dest) {
  if (!fs.existsSync(src)) return false;
  fs.mkdirSync(dest, { recursive: true });
  for (const name of fs.readdirSync(src)) {
    const s = path.join(src, name);
    const d = path.join(dest, name);
    if (fs.statSync(s).isDirectory()) {
      copyDirRecursive(s, d);
    } else {
      fs.copyFileSync(s, d);
    }
  }
  return true;
}

/** Assure qu'une copie writable de flutter_tools/gradle existe et retourne son chemin (pour SDK en lecture seule). */
function ensureWritableFlutterGradle() {
  const flutterSdk = getFlutterSdkPath() || process.env.FLUTTER_ROOT || '/opt/flutter';
  const sourceGradle = path.join(flutterSdk, 'packages', 'flutter_tools', 'gradle');
  if (!fs.existsSync(sourceGradle)) return null;
  const cacheDir = path.join(MOBILE_PATH, '.flutter-gradle-cache');
  const gradleCache = path.join(cacheDir, 'gradle');
  if (fs.existsSync(gradleCache) && isGradleCacheCorrupted(gradleCache)) {
    try {
      fs.rmSync(cacheDir, { recursive: true, force: true });
      console.warn('[emulator-controller] Cache Gradle Flutter corrompu supprimé — recopie depuis SDK');
    } catch (e) {
      console.error('Suppression cache Gradle corrompu échouée:', e.message);
    }
  }
  if (!fs.existsSync(gradleCache)) {
    try {
      copyDirRecursive(sourceGradle, gradleCache);
    } catch (e) {
      console.error('Copy flutter gradle failed:', e.message);
      return null;
    }
  }
  return gradleCache;
}

/** Exécute uiautomator dump avec timeout et 2 tentatives (évite échec après redémarrage app). */
async function uiaDumpWithRetry(deviceId, timeoutMs = 25000) {
  const fast = ['1', 'true', 'yes'].includes(String(process.env.ADB_FAST || '').toLowerCase());
  const effectiveTimeout = fast ? Math.min(timeoutMs, 12000) : timeoutMs;
  const deviceArg = deviceId ? `-s ${deviceId}` : '';
  const dumpCmd = `adb ${deviceArg} shell uiautomator dump /sdcard/ui_dump.xml`;
  const catCmd = `adb ${deviceArg} shell cat /sdcard/ui_dump.xml`;
  let lastErr;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      await execPromise(dumpCmd, { timeout: effectiveTimeout });
      const { stdout } = await execPromise(catCmd, { timeout: 10000 });
      return stdout || '';
    } catch (e) {
      lastErr = e;
      if (attempt < 2) await new Promise(r => setTimeout(r, 700));
    }
  }
  throw lastErr;
}

/** Retourne la date de modification la plus récente des fichiers sous dir (récursif), ou 0 si absent. */
function getNewestMtime(dir) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return 0;
  let max = 0;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      const sub = getNewestMtime(full);
      if (sub > max) max = sub;
    } else {
      const m = stat.mtimeMs;
      if (m > max) max = m;
    }
  }
  return max;
}

const routes = {
  async '/avds'(req, res) {
    try {
      const emulatorPath = ANDROID_HOME ? path.join(ANDROID_HOME, 'emulator', 'emulator') : 'emulator';
      const { stdout } = await execPromise(`${emulatorPath} -list-avds`);
      const avds = stdout ? stdout.split('\n').filter(Boolean).map((name) => ({ name })) : [];
      send(res, 200, { success: true, avds });
    } catch (e) {
      send(res, 200, { success: true, avds: [], error: e.message });
    }
  },

  async '/devices'(req, res, _body, url = '') {
    try {
      const light = /[?&]light=1/.test(url || '');
      const diag = await collectAdbDiagnostics({ skipFlutter: light });
      const raw = parseAdbDevices(diag.rawList).filter((d) => d.status === 'device');
      const pubspec = parsePubspecVersion();
      const devices = await Promise.all(
        raw.map(async (d) => {
          const extra = light
            ? { id: d.id, model: null, androidVersion: null, appInstalled: undefined }
            : await queryDeviceDetails(d.id);
          return {
            ...d,
            ...extra,
            localApkVersion: pubspec?.version || null,
            localApkBuild: pubspec?.buildNumber || null,
            updateNeeded:
              !light
              && extra.appInstalled
              && pubspec
              && (
                extra.appVersionName !== pubspec.version
                || (extra.appVersionCode != null && extra.appVersionCode < pubspec.buildNumber)
              ),
          };
        }),
      );
      send(res, 200, {
        success: true,
        devices,
        pendingDevices: diag.pending,
        diagnostics: {
          readyCount: diag.readyCount,
          pendingCount: diag.pendingCount,
          hints: diag.hints,
          flutterDevices: diag.flutterDevices,
        },
        package: ANDROID_PACKAGE,
      });
    } catch (e) {
      send(res, 500, { success: false, error: e.message, devices: [] });
    }
  },

  async '/adb-diagnostics'(req, res) {
    try {
      const diag = await collectAdbDiagnostics();
      send(res, 200, {
        success: true,
        ...diag,
        androidSdkPresent: !!(ANDROID_HOME && fs.existsSync(ANDROID_HOME)),
        androidSdkPath: ANDROID_HOME || null,
        gitAvailable: await execPromise('git --version', { timeout: 5000 })
          .then((r) => (r.stdout || '').trim())
          .catch(() => null),
      });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/start-avd'(req, res, body) {
    let avd;
    try {
      avd = body && body.avd;
      if (!avd) {
        return send(res, 400, { success: false, error: 'Body { "avd": "nom_avd" } requis' });
      }
      const emulatorPath = ANDROID_HOME ? path.join(ANDROID_HOME, 'emulator', 'emulator') : 'emulator';
      spawn(emulatorPath, ['-avd', avd], { detached: true, stdio: 'ignore' }).unref();
      send(res, 200, { success: true, message: `Démarrage AVD: ${avd}` });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/build-apk'(req, res) {
    try {
      ensureGitSafeDirectories();
      const pubspecStart = parsePubspecVersion();
      const buildId = new Date().toISOString();
      writeBuildSession({
        id: buildId,
        startedAt: buildId,
        inProgress: true,
        success: false,
        version: pubspecStart?.version || null,
        buildNumber: pubspecStart?.buildNumber || null,
        message: 'Build APK en cours…',
      });
      if (!fs.existsSync(path.join(MOBILE_PATH, 'pubspec.yaml'))) {
        return send(res, 400, { success: false, error: `Projet Flutter introuvable: ${MOBILE_PATH}` });
      }
      const baseEnv = envWithAndroid();
      const gradleCache = ensureWritableFlutterGradle();
      if (gradleCache) baseEnv.FLUTTER_GRADLE_BUILD_PATH = gradleCache;
      if (process.env.API_BASE_URL) baseEnv.API_BASE_URL = process.env.API_BASE_URL;
      const lanHost = process.env.MOBILE_DEV_LAN_HOST || pickLanIPv4();
      if (lanHost) baseEnv.MOBILE_DEV_LAN_HOST = lanHost;

      let stdout = '';
      let stderr = '';
      let code = 1;

      if (fs.existsSync(BUILD_APK_SCRIPT)) {
        const cmd = `bash "${BUILD_APK_SCRIPT}"`;
        ({ stdout, stderr, code } = await execCaptureTracked(cmd, { cwd: REPO_ROOT, env: baseEnv }));
      } else {
        const outputsDir = path.join(MOBILE_PATH, 'build', 'app', 'outputs');
        try {
          if (fs.existsSync(outputsDir)) fs.rmSync(outputsDir, { recursive: true, force: true });
        } catch (_) { /* ignore */ }
        const patchScript = path.join(REPO_ROOT, 'scripts/mobile/setup/patch-android-plugin-gradle-kts.sh');
        if (fs.existsSync(patchScript)) {
          await execCapture(`bash "${patchScript}"`, { cwd: REPO_ROOT, env: baseEnv });
        }
        await execCapture('flutter clean', { cwd: MOBILE_PATH, env: baseEnv });
        ({ stdout, stderr, code } = await execCaptureTracked('flutter build apk --debug', { cwd: MOBILE_PATH, env: baseEnv }));
      }

      if (code === 130) {
        writeBuildSession({
          id: buildId,
          startedAt: buildId,
          finishedAt: new Date().toISOString(),
          inProgress: false,
          success: false,
          message: 'Build annulé',
        });
        return send(res, 200, { success: false, cancelled: true, message: 'Build annulé par l’utilisateur' });
      }

      const apkPath = resolveApkPath();
      const exists = apkPath && fs.existsSync(apkPath);
      const ok = exists && code === 0;
      const pubspec = parsePubspecVersion();
      const stdoutStr = typeof stdout === 'string' ? stdout : String(stdout || '');
      const stderrStr = typeof stderr === 'string' ? stderr : String(stderr || '');
      const warnings = extractWarningsFromOutput(`${stderrStr}\n${stdoutStr}`);
      const prevSession = readBuildSession();
      const finishedAt = new Date().toISOString();

      writeBuildSession({
        id: prevSession?.id || buildId || finishedAt,
        startedAt: prevSession?.startedAt || buildId,
        finishedAt,
        inProgress: false,
        success: !!ok,
        exitCode: code,
        version: pubspec?.version || null,
        buildNumber: pubspec?.buildNumber || null,
        message: ok ? 'Build APK réussi' : (exists ? 'Build terminé avec erreur' : 'Build échoué'),
        stderrTail: stderrStr.slice(-12000),
        stdoutTail: stdoutStr.slice(-8000),
        warnings,
        warningCount: warnings.length,
        apkPath: exists ? apkPath : null,
      });

      appendBuildHistory({
        id: prevSession?.id || buildId || finishedAt,
        startedAt: prevSession?.startedAt || buildId,
        finishedAt,
        success: !!ok,
        exitCode: code,
        version: pubspec?.version || null,
        buildNumber: pubspec?.buildNumber || null,
        message: ok ? 'Build APK réussi' : (exists ? 'Build terminé avec erreur' : 'Build échoué'),
        stderrTail: stderrStr.slice(-12000),
        stdoutTail: stdoutStr.slice(-8000),
        warnings,
        warningCount: warnings.length,
      });

      return send(res, 200, {
        success: !!ok,
        message: ok ? 'Build APK réussi' : (exists ? 'Build terminé avec erreur (voir stderr)' : 'Build échoué (voir stderr)'),
        path: exists ? apkPath : null,
        exitCode: code,
        version: pubspec?.version || null,
        buildNumber: pubspec?.buildNumber || null,
        downloadUrl: exists ? '/download-apk' : null,
        stdout: stdoutStr.slice(-12000),
        stderr: stderrStr.slice(-12000),
        warnings,
        warningCount: warnings.length,
      });
    } catch (e) {
      return send(res, 200, { success: false, error: (e && e.message) || String(e), stderr: '' });
    }
  },

  async '/install-run'(req, res, body) {
    const steps = [];
    const push = (phase, ok, detail) => {
      steps.push({ phase, ok, detail, at: new Date().toISOString() });
    };
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "emulator-5554" } requis', steps });
      }
      const apkPathFlutter = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk');
      const apkPathLegacy = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'apk', 'debug', 'app-debug.apk');
      const apkPath = fs.existsSync(apkPathFlutter) ? apkPathFlutter : (fs.existsSync(apkPathLegacy) ? apkPathLegacy : null);
      if (!apkPath || !fs.existsSync(apkPath)) {
        return send(res, 400, { success: false, error: 'APK non trouvé. Lancez d\'abord "Build APK" (étape 1).', steps });
      }
      const execOpts = { cwd: MOBILE_PATH };
      const reversed = await setupAdbReverseForDevice(deviceId, { force: true });
      push('adb_reverse', true, `${reversed} port(s) API mappés`);
      push('install', true, 'Installation APK en cours…');
      await execPromise(`adb -s ${deviceId} install -r -d "${apkPath}"`, execOpts);
      push('install', true, 'APK installé');
      await relaunchAppSingleInstance(deviceId);
      push('restart', true, 'Application relancée (instance unique)');
      deviceDetailsCache.delete(deviceId);
      send(res, 200, {
        success: true,
        steps,
        message: 'App installée et relancée sur l’appareil.',
      });
    } catch (e) {
      const cancelled = !!(e && (e.cancelled || (e.message && String(e.message).includes('interrompu'))));
      push('error', false, e.message);
      send(res, cancelled ? 200 : 500, {
        success: false,
        cancelled,
        error: e.message,
        steps,
      });
    }
  },

  async '/adb-reverse-device'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "…" } requis' });
      }
      const reversed = await setupAdbReverseForDevice(deviceId, { force: true });
      send(res, 200, {
        success: true,
        ports: reversed,
        detail: `${reversed} port(s) API mappés (adb reverse)`,
      });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/install-apk-device'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "…" } requis' });
      }
      if (activeInstallProcess || activeInstallDeviceId) {
        return send(res, 409, {
          success: false,
          error: 'Installation déjà en cours sur un appareil — attendez la fin ou « Arrêter l’installation ».',
          busyDeviceId: activeInstallDeviceId,
        });
      }
      const apkPath = resolveApkPath();
      if (!apkPath || !fs.existsSync(apkPath)) {
        return send(res, 400, { success: false, error: 'APK non trouvé. Lancez d’abord « Build APK ».' });
      }
      activeInstallDeviceId = deviceId;
      const sizeMo = (fs.statSync(apkPath).size / 1024 / 1024).toFixed(1);
      const pubspec = parsePubspecVersion();
      try {
        await execPromiseTracked(`adb -s ${deviceId} install -r -d "${apkPath}"`, { cwd: MOBILE_PATH });
        deviceDetailsCache.delete(deviceId);
        send(res, 200, {
          success: true,
          detail: `APK installé (${sizeMo} Mo)`,
          apkPath,
          version: pubspec?.version,
          buildNumber: pubspec?.buildNumber,
        });
      } finally {
        if (activeInstallDeviceId === deviceId) activeInstallDeviceId = null;
      }
    } catch (e) {
      activeInstallDeviceId = null;
      const cancelled = !!(e && e.cancelled);
      send(res, cancelled ? 200 : 500, {
        success: false,
        cancelled,
        error: (e && e.message) || String(e),
      });
    }
  },

  async '/launch-app-device'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "…" } requis' });
      }
      await relaunchAppSingleInstance(deviceId);
      send(res, 200, { success: true, detail: 'Application relancée (instance unique)' });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/cancel-operation'(req, res) {
    const cancelled = cancelActiveOperations();
    try {
      const session = readBuildSession();
      if (session?.inProgress) {
        writeBuildSession({
          ...session,
          inProgress: false,
          success: false,
          finishedAt: new Date().toISOString(),
          message: 'Annulé par l’utilisateur',
        });
        if (!cancelled.includes('build')) cancelled.push('build');
      }
    } catch (_) { /* ignore */ }
    send(res, 200, { success: true, cancelled, message: cancelled.length ? 'Opération annulée' : 'Aucune opération en cours' });
  },

  /** Prépare adb reverse sur tous les appareils + expose IP LAN détectée (sans commande manuelle). */
  async '/setup-dev'(req, res) {
    try {
      const { stdout } = await execPromise('adb devices -l', { cwd: MOBILE_PATH });
      const devices = parseAdbDevices(stdout).filter((d) => d.status === 'device');
      const results = [];
      for (const d of devices) {
        const reversed = await setupAdbReverseForDevice(d.id);
        results.push({ id: d.id, adbReversePorts: reversed });
      }
      const lanHost = pickLanIPv4();
      send(res, 200, {
        success: true,
        message:
          devices.length > 0
            ? `ADB prêt (${devices.length} appareil(s), adb reverse API)`
            : 'Contrôleur OK — branchez un téléphone USB (débogage activé)',
        devices: results,
        lanHost,
      });
    } catch (e) {
      send(res, 200, {
        success: false,
        error: e.message,
        message: 'adb indisponible ou aucun appareil',
        lanHost: pickLanIPv4(),
      });
    }
  },

  /** Arrête l'app (force-stop) sans la relancer. Utile après un build APK pour réactiver "Installer et lancer". */
  async '/stop-app'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "emulator-5554" } requis' });
      }
      await execPromise(`adb -s ${deviceId} shell am force-stop ${ANDROID_PACKAGE}`, { cwd: MOBILE_PATH });
      send(res, 200, { success: true, message: 'App arrêtée (force-stop)' });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  /** Désinstalle l'app du périphérique (adb uninstall). Permet une réinstallation propre. */
  async '/uninstall-app'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "emulator-5554" } requis' });
      }
      const execOpts = { cwd: MOBILE_PATH };
      await execPromise(`adb -s ${deviceId} uninstall ${ANDROID_PACKAGE}`, execOpts);
      send(res, 200, { success: true, message: 'App désinstallée du périphérique' });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  /** Redémarre le processus du contrôleur (pour charger la dernière version du code). Le client doit relancer make emulator-controller. */
  async '/restart'(req, res, _body, _url) {
    send(res, 200, { success: true, message: 'Redémarrage du contrôleur dans 1s. Relancez : make emulator-controller' });
    setTimeout(() => process.exit(0), 1000);
  },

  /** Ferme l'app (force-stop) puis la relance sans réinstaller. Délai avant retour pour laisser uiautomator prêt. */
  async '/force-restart-app'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "emulator-5554" } requis' });
      }
      const execOpts = { cwd: MOBILE_PATH };
      await relaunchAppSingleInstance(deviceId);
      // Délai pour que l'app et uiautomator soient prêts (évite "uiauto machine failed")
      await new Promise(r => setTimeout(r, 5500));
      send(res, 200, { success: true, message: 'App fermée puis relancée (instance unique)' });
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/run-flutter'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "..." } requis' });
      }
      const child = spawn('flutter', ['run', '-d', deviceId, '--no-pub'], {
        cwd: MOBILE_PATH,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: envWithAndroid(),
        detached: true,
      });
      child.unref();
      child.stdout.on('data', (d) => process.stdout.write(d));
      child.stderr.on('data', (d) => process.stderr.write(d));
      child.on('error', (e) => console.error('flutter run error:', e.message));
      send(res, 200, { success: true, message: 'Flutter run démarré. Logs dans le terminal du contrôleur.' });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/flutter-devices'(req, res) {
    try {
      const { stdout } = await execPromise('flutter devices --machine', { cwd: MOBILE_PATH });
      let devices = [];
      try {
        const trimmed = stdout.trim();
        const parsed = JSON.parse(trimmed);
        const arr = Array.isArray(parsed) ? parsed : [parsed];
        devices = arr.map((o) => ({ id: o.id, name: o.name || o.id, platform: o.platformType || o.platform }));
      } catch (_) {
        const lines = stdout.trim().split('\n').filter(Boolean);
        devices = lines.map((line) => {
          try {
            const o = JSON.parse(line);
            return { id: o.id, name: o.name || o.id, platform: o.platformType || o.platform };
          } catch (e2) {
            return null;
          }
        }).filter(Boolean);
      }
      send(res, 200, { success: true, devices });
    } catch (e) {
      send(res, 200, { success: true, devices: [], error: (e && e.message) || String(e) });
    }
  },

  async '/input-tap'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const x = body && typeof body.x === 'number' ? Math.round(body.x) : null;
      const y = body && typeof body.y === 'number' ? Math.round(body.y) : null;
      if (!deviceId || x == null || y == null || x < 0 || y < 0) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "...", "x": number, "y": number } requis' });
      }
      await execPromise(`adb -s ${deviceId} shell input tap ${x} ${y}`);
      send(res, 200, { success: true, message: `Tap (${x}, ${y})` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/input-text'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const text = body && body.text;
      if (!deviceId || typeof text !== 'string') {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "...", "text": "..." } requis' });
      }
      const escaped = text.replace(/ /g, '%s').replace(/[&|;<>()$`\\!"']/g, (c) => `\\${c}`);
      await execPromise(`adb -s ${deviceId} shell input text "${escaped}"`);
      send(res, 200, { success: true, message: `Text: ${text.slice(0, 30)}` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/input-keyevent'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const keycode = body && body.keycode;
      if (!deviceId || keycode == null) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "...", "keycode": 4 } requis (4=BACK, 3=HOME, 66=ENTER, 67=DEL, 61=TAB)' });
      }
      await execPromise(`adb -s ${deviceId} shell input keyevent ${keycode}`);
      send(res, 200, { success: true, message: `Keyevent: ${keycode}` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/input-swipe'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const { x1, y1, x2, y2, duration } = body || {};
      if (!deviceId || x1 == null || y1 == null || x2 == null || y2 == null) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "...", "x1", "y1", "x2", "y2", "duration"? } requis' });
      }
      const dur = duration || 300;
      await execPromise(`adb -s ${deviceId} shell input swipe ${Math.round(x1)} ${Math.round(y1)} ${Math.round(x2)} ${Math.round(y2)} ${dur}`);
      send(res, 200, { success: true, message: `Swipe (${x1},${y1})->(${x2},${y2})` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/clear-field'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const length = (body && body.length) || 50;
      if (!deviceId) {
        return send(res, 400, { success: false, error: 'Body { "deviceId": "...", "length"?: 50 } requis' });
      }
      for (let i = 0; i < length; i++) {
        await execPromise(`adb -s ${deviceId} shell input keyevent 67`);
      }
      send(res, 200, { success: true, message: `Cleared ${length} chars` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/ui-dump'(req, res, body) {
    try {
      const deviceId = (body && body.deviceId) || '';
      const xml = await uiaDumpWithRetry(deviceId);
      send(res, 200, { success: true, xml });
    } catch (e) {
      send(res, 200, { success: false, xml: '', error: (e && e.message) || String(e) });
    }
  },

  async '/find-and-tap'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const text = body && body.text;
      const contentDesc = body && body.contentDesc;
      const className = body && body.className;
      const index = (body && body.index) || 0;
      const preferClickable = body && body.preferClickable !== false;
      if (!deviceId || (!text && !contentDesc && !className)) {
        return send(res, 400, { success: false, error: 'Body { "deviceId", "text"? | "contentDesc"? | "className"?, "index"?: 0 } requis' });
      }
      const xml = await uiaDumpWithRetry(deviceId);

      const nodes = [];
      const nodeRegex = /<node[^>]*>/g;
      let match;
      while ((match = nodeRegex.exec(xml)) !== null) {
        const n = match[0];
        const getText = (attr) => { const m = n.match(new RegExp(`${attr}="([^"]*)"`)); return m ? m[1] : ''; };
        const clickable = /clickable="true"/.test(n);
        nodes.push({ text: getText('text'), contentDesc: getText('content-desc'), className: getText('class'), bounds: getText('bounds'), resourceId: getText('resource-id'), clickable });
      }

      const safe = (s) => (s == null || s === undefined ? '' : String(s));
      const matches = nodes.filter((n) => {
        if (text) {
          const t = text.toLowerCase();
          if (safe(n.text).toLowerCase().includes(t) || safe(n.contentDesc).toLowerCase().includes(t)) return true;
        }
        if (contentDesc && safe(n.contentDesc).toLowerCase().includes(String(contentDesc).toLowerCase())) return true;
        if (className && safe(n.className).includes(className)) return true;
        return false;
      });

      if (matches.length === 0) {
        return send(res, 200, { success: false, error: `Element not found: text="${text}" contentDesc="${contentDesc}"`, nodes: nodes.filter(n => n.text || n.contentDesc).slice(0, 30) });
      }

      let sorted = matches;
      if (preferClickable && matches.length > 1) {
        const clickableMatches = matches.filter(n => n.clickable);
        if (clickableMatches.length > 0) sorted = clickableMatches;
      }

      const target = sorted[Math.min(index, sorted.length - 1)];
      const boundsMatch = target.bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
      if (!boundsMatch) {
        return send(res, 200, { success: false, error: `Cannot parse bounds: ${target.bounds}` });
      }
      const cx = Math.round((parseInt(boundsMatch[1]) + parseInt(boundsMatch[3])) / 2);
      const cy = Math.round((parseInt(boundsMatch[2]) + parseInt(boundsMatch[4])) / 2);

      await execPromise(`adb -s ${deviceId} shell input tap ${cx} ${cy}`);
      send(res, 200, { success: true, message: `Tapped "${target.text || target.contentDesc}" at (${cx}, ${cy})`, bounds: target.bounds, clickable: target.clickable });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/tap-field-and-type'(req, res, body) {
    try {
      const deviceId = body && body.deviceId;
      const hint = body && body.hint;
      const text = body && body.text;
      const index = Math.max(0, parseInt(body && body.index, 10) || 0);
      const editTextIndexRaw = body && body.editTextIndex;
      const hasEditTextIndex =
        editTextIndexRaw !== undefined && editTextIndexRaw !== null && editTextIndexRaw !== '';
      if (!deviceId || typeof text !== 'string' || (!hint && !hasEditTextIndex)) {
        return send(res, 400, {
          success: false,
          error: 'Body { "deviceId", "hint" ou "editTextIndex", "text": "value" } requis',
        });
      }
      const xml = await uiaDumpWithRetry(deviceId);
      const nodeRegex = /<node[^>]*>/g;
      const hintLower = hint ? String(hint).toLowerCase() : '';
      const matchStr = (attr) => attr && attr.toLowerCase().includes(hintLower);
      const editableTrue = (n) => /editable="true"/.test(n) || /class="[^"]*EditText[^"]*"/.test(n);
      const targets = [];
      const targetsEditable = [];
      const targetCurrentTexts = [];

      if (hasEditTextIndex) {
        const editIdx = Math.max(0, parseInt(editTextIndexRaw, 10) || 0);
        const editNodes = [];
        let mEdit;
        while ((mEdit = nodeRegex.exec(xml)) !== null) {
          const n = mEdit[0];
          if (!editableTrue(n)) continue;
          const boundsMatch = n.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
          if (!boundsMatch) continue;
          const t = (n.match(/text="([^"]*)"/) || [])[1];
          editNodes.push({ bounds: boundsMatch, text: (t || '').trim(), y: parseInt(boundsMatch[2], 10) });
        }
        editNodes.sort((a, b) => a.y - b.y);
        const picked = editNodes[editIdx];
        if (!picked) {
          return send(res, 200, {
            success: false,
            error: `EditText #${editIdx} introuvable (${editNodes.length} champ(s))`,
          });
        }
        targets.push(picked.bounds);
        targetCurrentTexts.push(picked.text);
        targetsEditable.push(picked.bounds);
      }

      let match;
      if (!hasEditTextIndex) {
        while ((match = nodeRegex.exec(xml)) !== null) {
        const n = match[0];
        const h = (n.match(/hint="([^"]*)"/) || [])[1];
        const t = (n.match(/text="([^"]*)"/) || [])[1];
        const c = (n.match(/content-desc="([^"]*)"/) || [])[1];
        const ok = matchStr(h) || matchStr(t) || matchStr(c);
        if (ok) {
          const boundsMatch = n.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
          if (boundsMatch) {
            const currentText = (t || '').trim();
            targets.push(boundsMatch);
            targetCurrentTexts.push(currentText);
            if (editableTrue(n)) targetsEditable.push(boundsMatch);
          }
        }
        }
      }
      const list = targetsEditable.length > 0 ? targetsEditable : targets;
      const target = list[index];
      if (!target) {
        const label = hasEditTextIndex ? `EditText #${editTextIndexRaw}` : `Field with hint/text "${hint}"`;
        return send(res, 200, {
          success: false,
          error: `${label} not found${targets.length ? ` (${targets.length} match(es), ${targetsEditable.length} editable, index ${index})` : ''}`,
        });
      }
      const targetIdxInAll = targets.indexOf(target);
      const currentFieldText = targetIdxInAll >= 0 && targetCurrentTexts[targetIdxInAll] !== undefined ? targetCurrentTexts[targetIdxInAll] : '';
      const cx = Math.round((parseInt(target[1]) + parseInt(target[3])) / 2);
      const cy = Math.round((parseInt(target[2]) + parseInt(target[4])) / 2);
      await execPromise(`adb -s ${deviceId} shell input tap ${cx} ${cy}`);
      let trimmed = typeof text === 'string' ? text.trim() : String(text).trim();
      const fast =
        (body && body.fast === true) ||
        ['1', 'true', 'yes'].includes(String(process.env.ADB_FAST || '').toLowerCase());
      const pause = (ms) =>
        new Promise((r) => setTimeout(r, fast ? Math.max(40, Math.round(ms * 0.25)) : ms));
      const isEmailField =
        body.isEmail === true ||
        (hint && String(hint).toLowerCase().includes('email')) ||
        trimmed.includes('@');
      const isPasswordField =
        body.isPassword === true ||
        (hint && /password|mot de passe/i.test(String(hint)));
      if (isEmailField) console.log(`[tap-field-and-type] Champ email: valeur reçue="${trimmed}" longueur=${trimmed.length} fin="${trimmed.slice(-6)}"`);
      if (isEmailField) {
        await pause(600);
      } else {
        await pause(400);
      }
      await execPromise(`adb -s ${deviceId} shell input keyevent KEYCODE_MOVE_END`);
      const delCount = currentFieldText.length > 0 ? Math.min(120, currentFieldText.length + 15) : 0;
      for (let i = 0; i < delCount; i++) await execPromise(`adb -s ${deviceId} shell input keyevent 67`);
      await pause(150);
      if (isEmailField && /[0-9]$/.test(trimmed)) trimmed = trimmed.slice(0, -1);
      const esc = (s) => s.replace(/ /g, '%s').replace(/[&|;<>()$`\\!"'#%]/g, (c) => `\\${c}`);
      const escaped = esc(trimmed);
      // Pour éviter que le clavier Android transforme ".com" en ".com6" ou ".me" en ".me6" : on tape les TLD caractère par caractère.
      const tldCom = trimmed.length >= 3 && trimmed.slice(-3) === 'com';
      const tldMe = trimmed.length >= 2 && trimmed.slice(-2) === 'me';
      if (isEmailField && tldCom) {
        const part1 = trimmed.slice(0, -3);
        const part1Esc = esc(part1);
        console.log(`[tap-field-and-type] Email .com: part1="${part1}" puis "com" caractère par caractère`);
        await execPromise(`adb -s ${deviceId} shell input text "${part1Esc}"`);
        await pause(550);
        for (const ch of 'com') {
          await execPromise(`adb -s ${deviceId} shell input text "${ch}"`);
          await pause(220);
        }
      } else if (isEmailField && tldMe) {
        const part1 = trimmed.slice(0, -2);
        const part1Esc = esc(part1);
        console.log(`[tap-field-and-type] Email .me: part1="${part1}" puis "me" caractère par caractère`);
        await execPromise(`adb -s ${deviceId} shell input text "${part1Esc}"`);
        await pause(450);
        for (const ch of 'me') {
          await execPromise(`adb -s ${deviceId} shell input text "${ch}"`);
          await pause(220);
        }
      } else if (isPasswordField || /[%&+]/.test(trimmed)) {
        for (const ch of trimmed) {
          if (ch === ' ') {
            await execPromise(`adb -s ${deviceId} shell input text %s`);
          } else {
            await execPromise(`adb -s ${deviceId} shell input text "${esc(ch)}"`);
          }
          await pause(fast ? 60 : 120);
        }
      } else {
        await execPromise(`adb -s ${deviceId} shell input text "${escaped}"`);
      }
      // Après saisie email : relire le champ (sauf mode rapide — dumps UI coûteux).
      if (isEmailField && !fast) {
        const emailAttempts = fast ? 2 : 4;
        for (let attempt = 0; attempt < emailAttempts; attempt++) {
          await pause(attempt === 0 ? 550 : 400);
          const xml2 = await uiaDumpWithRetry(deviceId);
          const nodeRegex2 = /<node[^>]*>/g;
          const texts2 = [];
          if (hasEditTextIndex) {
            const editIdx2 = Math.max(0, parseInt(editTextIndexRaw, 10) || 0);
            const editNodes2 = [];
            let mEdit2;
            while ((mEdit2 = nodeRegex2.exec(xml2)) !== null) {
              const n = mEdit2[0];
              if (!editableTrue(n)) continue;
              const boundsMatch = n.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
              if (!boundsMatch) continue;
              const t = (n.match(/text="([^"]*)"/) || [])[1];
              editNodes2.push({ text: (t || '').trim(), y: parseInt(boundsMatch[2], 10) });
            }
            editNodes2.sort((a, b) => a.y - b.y);
            if (editNodes2[editIdx2]) texts2.push(editNodes2[editIdx2].text);
          } else {
            let m2;
            while ((m2 = nodeRegex2.exec(xml2)) !== null) {
              const n = m2[0];
              const h = (n.match(/hint="([^"]*)"/) || [])[1];
              const t = (n.match(/text="([^"]*)"/) || [])[1];
              const ok = h && String(h).toLowerCase().includes(hintLower);
              if (ok && editableTrue(n)) texts2.push((t || '').trim());
            }
          }
          const idx = Math.min(index, texts2.length - 1);
          let currentText = idx >= 0 ? texts2[idx] : '';
          if (!currentText) break;
          if (currentText === trimmed) {
            if (attempt >= 2) break;
            continue;
          }
          const trailingDigits = (currentText.match(/[0-9]+$/) || [])[0];
          if (trailingDigits) {
            const nBack = trailingDigits.length;
            console.log(
              `[tap-field-and-type] Email: champ se termine par "${trailingDigits}", envoi de ${nBack} backspace(s)`,
            );
            for (let b = 0; b < nBack; b++) await execPromise(`adb -s ${deviceId} shell input keyevent 67`);
            currentText = currentText.slice(0, -nBack);
          }
          if (currentText && currentText !== trimmed && currentText.startsWith(trimmed)) {
            const nBack = currentText.length - trimmed.length;
            console.log(
              `[tap-field-and-type] Email: suffixe parasite "${currentText.slice(trimmed.length)}" → ${nBack} backspace(s)`,
            );
            for (let b = 0; b < nBack; b++) await execPromise(`adb -s ${deviceId} shell input keyevent 67`);
          }
        }
      }
      send(res, 200, { success: true, message: `Typed "${trimmed.slice(0, 30)}" in field "${hint}" at (${cx}, ${cy})` });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/screen-info'(req, res, body) {
    try {
      const deviceId = (body && body.deviceId) || '';
      const deviceArg = deviceId ? `-s ${deviceId}` : '';
      const { stdout } = await execPromise(`adb ${deviceArg} shell wm size`);
      const m = stdout.match(/(\d+)x(\d+)/);
      const width = m ? parseInt(m[1]) : 1080;
      const height = m ? parseInt(m[2]) : 1920;
      send(res, 200, { success: true, width, height });
    } catch (e) {
      send(res, 200, { success: false, width: 1080, height: 1920, error: (e && e.message) || String(e) });
    }
  },

  async '/screenshot'(req, res, _, url) {
    const u = new URL(url, 'http://x');
    const device = u.searchParams.get('device');
    if (!device) {
      return send(res, 400, { success: false, error: 'Query ?device=emulator-5554 requis' });
    }
    const live = u.searchParams.get('live') !== '0';
    if (live) startLiveCaptureLoop(device);
    try {
      const cached = getLiveFrame(device);
      if (cached?.buffer) {
        sendImage(res, cached.buffer, cached.contentType || 'image/jpeg', cached.capturedAt);
        const age = Date.now() - cached.capturedAt;
        if (age > LIVE_CAPTURE_INTERVAL_MS && !cached.inFlight) {
          captureLiveFrame(device).catch(() => {});
        }
        return;
      }
      const buffer = await captureLiveFrame(device);
      const frame = getLiveFrame(device);
      sendImage(
        res,
        buffer,
        frame?.contentType || 'image/jpeg',
        frame?.capturedAt || Date.now(),
      );
    } catch (e) {
      send(res, 500, { success: false, error: e.message });
    }
  },

  async '/mjpeg'(req, res, _, url) {
    const device = new URL(url, 'http://x').searchParams.get('device');
    if (!device) {
      return send(res, 400, { success: false, error: 'Query ?device= requis' });
    }
    startLiveCaptureLoop(device);
    const boundary = 'jtframe';
    res.writeHead(200, {
      'Content-Type': `multipart/x-mixed-replace; boundary=${boundary}`,
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      Connection: 'keep-alive',
    });
    let closed = false;
    req.on('close', () => {
      closed = true;
      stopLiveCaptureLoop(device);
    });
    const push = async () => {
      while (!closed) {
        try {
          let frame = getLiveFrame(device);
          if (!frame?.buffer || frame.inFlight) {
            await captureLiveFrame(device).catch(() => null);
            frame = getLiveFrame(device);
          }
          if (frame?.buffer && !closed) {
            const type = frame.contentType || 'image/jpeg';
            res.write(`--${boundary}\r\nContent-Type: ${type}\r\nContent-Length: ${frame.buffer.length}\r\n\r\n`);
            res.write(frame.buffer);
            res.write('\r\n');
          }
        } catch {
          /* ignore frame errors */
        }
        await new Promise((r) => setTimeout(r, LIVE_CAPTURE_INTERVAL_MS));
      }
    };
    void push();
  },

  async '/live/start'(req, res, _, url) {
    const device = new URL(url, 'http://x').searchParams.get('device');
    if (!device) {
      return send(res, 400, { success: false, error: 'Query ?device= requis' });
    }
    startLiveCaptureLoop(device);
    send(res, 200, { success: true, device, intervalMs: LIVE_CAPTURE_INTERVAL_MS });
  },

  async '/live/stop'(req, res, _, url) {
    const device = new URL(url, 'http://x').searchParams.get('device');
    if (device) stopLiveCaptureLoop(device);
    send(res, 200, { success: true, device: device || null });
  },

  async '/adb-shell'(req, res, body) {
    try {
      const deviceId = (body && body.deviceId) || '';
      const command = (body && body.command) || '';
      if (!command) {
        return send(res, 400, { success: false, error: 'Body { "command": "am start ..." } requis' });
      }
      const deviceArg = deviceId ? `-s ${deviceId}` : '';
      const { stdout, stderr } = await execPromise(`adb ${deviceArg} shell ${command}`, { timeout: 15000 });
      send(res, 200, { success: true, stdout: (stdout || '').trim(), stderr: (stderr || '').trim() });
    } catch (e) {
      send(res, 200, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/download-apk'(req, res) {
    try {
      const apkPath = resolveApkPath();
      if (!apkPath) {
        return send(res, 404, { success: false, error: 'APK introuvable. Lancez d’abord « Build APK ».' });
      }
      const pubspec = parsePubspecVersion();
      const downloadName = buildApkDownloadFilename(pubspec?.version, pubspec?.buildNumber);
      sendFile(res, apkPath, downloadName);
    } catch (e) {
      send(res, 500, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/apk-info'(req, res) {
    try {
      const apkPath = resolveApkPath();
      const pubspec = parsePubspecVersion();
      if (!apkPath) {
        return send(res, 200, {
          exists: false,
          version: pubspec?.version || null,
          buildNumber: pubspec?.buildNumber || null,
        });
      }
      const stat = fs.statSync(apkPath);
      const version = pubspec?.version || null;
      const buildNumber = pubspec?.buildNumber || null;
      send(res, 200, {
        exists: true,
        path: apkPath,
        sizeBytes: stat.size,
        modifiedAt: stat.mtime.toISOString(),
        version,
        buildNumber,
        downloadFilename: buildApkDownloadFilename(version, buildNumber),
      });
    } catch (e) {
      send(res, 500, { success: false, error: (e && e.message) || String(e) });
    }
  },

  async '/health'(req, res) {
    const gitOk = await execPromise('git --version', { timeout: 5000 })
      .then(() => true)
      .catch(() => false);
    const sdkOk = !!(ANDROID_HOME && fs.existsSync(ANDROID_HOME));
    const diag = await collectAdbDiagnostics({ skipFlutter: true }).catch(() => null);
    send(res, 200, {
      ok: true,
      service: 'emulator-controller',
      mobilePath: MOBILE_PATH,
      repoRoot: REPO_ROOT,
      buildScript: fs.existsSync(BUILD_APK_SCRIPT),
      apkReady: !!resolveApkPath(),
      gitAvailable: gitOk,
      androidSdkPresent: sdkOk,
      androidSdkPath: ANDROID_HOME || null,
      adbReadyCount: diag?.readyCount ?? null,
      adbPendingCount: diag?.pendingCount ?? null,
      lastBuildSession: readBuildSession(),
    });
  },

  async '/build-session'(req, res) {
    const session = readBuildSession();
    const apkPath = resolveApkPath();
    send(res, 200, {
      session,
      history: readBuildHistory(),
      apkInfo: apkPath && fs.existsSync(apkPath)
        ? {
            exists: true,
            modifiedAt: fs.statSync(apkPath).mtime.toISOString(),
            ...parsePubspecVersion(),
          }
        : { exists: false },
    });
  },

  async '/build-history'(req, res) {
    send(res, 200, { history: readBuildHistory() });
  },

  /** GET: indique si un build est nécessaire (APK plus ancien que mobile/lib). */
  async '/build-status'(req, res) {
    try {
      const apkPathFlutter = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk');
      const apkPathLegacy = path.join(MOBILE_PATH, 'build', 'app', 'outputs', 'apk', 'debug', 'app-debug.apk');
      const apkPath = fs.existsSync(apkPathFlutter) ? apkPathFlutter : (fs.existsSync(apkPathLegacy) ? apkPathLegacy : null);
      const apkMtime = apkPath && fs.existsSync(apkPath) ? fs.statSync(apkPath).mtimeMs : 0;
      const libDir = path.join(MOBILE_PATH, 'lib');
      const mobileLibMtime = getNewestMtime(libDir);
      const needsBuild = !apkPath || apkMtime < mobileLibMtime;
      send(res, 200, {
        needsBuild: !!needsBuild,
        apkPath: apkPath || null,
        apkMtime,
        mobileLibMtime,
      });
    } catch (e) {
      send(res, 200, { needsBuild: true, error: (e && e.message) || String(e) });
    }
  },

  /** Liste des routes enregistrées (GET) — pour vérifier que /stop-app est bien présent après redémarrage du contrôleur. */
  async '/routes'(req, res) {
    const list = Object.keys(routes).filter((k) => typeof routes[k] === 'function');
    send(res, 200, { routes: list, hasStopApp: list.includes('/stop-app') });
  },
};

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    return res.end();
  }

  const url = req.url || '';
  const pathname = (url.split('?')[0] || '').replace(/\/$/, '') || '/';
  let body = null;

  const next = () => {
    const handler = routes[pathname];
    if (!handler) {
      return send(res, 404, { error: 'Not found' });
    }
    const postRoutes = ['/start-avd', '/build-apk', '/install-run', '/adb-reverse-device', '/install-apk-device', '/launch-app-device', '/cancel-operation', '/setup-dev', '/stop-app', '/uninstall-app', '/restart', '/force-restart-app', '/run-flutter', '/input-tap', '/input-text', '/input-keyevent', '/input-swipe', '/clear-field', '/ui-dump', '/find-and-tap', '/tap-field-and-type', '/screen-info', '/adb-shell'];
    if (req.method === 'POST' && postRoutes.includes(pathname)) {
      let data = '';
      req.on('data', (chunk) => { data += chunk; });
      req.on('end', () => {
        try {
          body = data ? JSON.parse(data) : {};
        } catch (_) {
          body = {};
        }
        handler(req, res, body, url).catch((e) => send(res, 500, { success: false, error: e.message }));
      });
      return;
    }
    handler(req, res, body, url).catch((e) => send(res, 500, { success: false, error: e.message }));
  };

  if (req.method === 'GET' && (pathname === '/screenshot' || pathname === '/mjpeg' || pathname === '/live/start' || pathname === '/live/stop')) {
    const handler = routes[pathname];
    return handler(req, res, null, url).catch((e) => send(res, 500, { success: false, error: e.message }));
  }

  next();
});

server.listen(PORT, HOST, () => {
  console.log(`Emulator controller: http://${HOST}:${PORT} (mobile: ${MOBILE_PATH})`);
  if (HOST === '0.0.0.0') {
    console.warn('ATTENTION: écoute sur toutes interfaces — réservé au lab local, jamais en prod VPS.');
  }
});
