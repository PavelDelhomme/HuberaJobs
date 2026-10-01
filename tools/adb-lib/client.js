/**
 * AdbClient – Client Node.js pour interagir avec un appareil Android
 * via l'emulator-controller (tools/emulator-controller/server.js).
 *
 * Usage:
 *   const { createAdb } = require('./client');
 *   const adb = await createAdb();          // auto-detect device
 *   const adb = createAdb('R5CT7263YJL');   // device specifique
 *   await adb.tap('Se connecter');
 *   await adb.typeInField('Email', 'admin@jobbingtrack.test');
 */

const CONTROLLER_URL = process.env.EMULATOR_CONTROLLER_URL || 'http://localhost:5055';
const UI_CACHE_MS = Number(process.env.ADB_UI_CACHE_MS || 280);
const WAIT_FOR_POLL_MS = Number(process.env.ADB_WAIT_POLL_MS || 320);
const ADB_FAST = ['1', 'true', 'yes'].includes(String(process.env.ADB_FAST || '').toLowerCase());
const FAST_SCALE = Number(process.env.ADB_FAST_SCALE || 0.22);

function scaleWait(ms) {
  const n = Number(ms) || 0;
  if (!ADB_FAST || n <= 0) return n;
  return Math.max(60, Math.round(n * FAST_SCALE));
}
const { dismissIncomingPhoneCall } = require('./dismiss-incoming-call');
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

class AdbClient {
  /**
   * @param {string} deviceId
   * @param {object} [opts]
   * @param {string} [opts.controllerUrl]
   * @param {(msg: string) => void} [opts.log]
   */
  constructor(deviceId, opts = {}) {
    this.deviceId = deviceId;
    this.baseUrl = (opts.controllerUrl || CONTROLLER_URL).replace(/\/$/, '');
    this._log = opts.log || ((msg) => console.log(`  [adb] ${msg}`));
    this._uiCache = null;
    this._uiCacheAt = 0;
  }

  _invalidateUi() {
    this._uiCache = null;
    this._uiCacheAt = 0;
  }

  static parseNodes(xml) {
    const nodes = [];
    const re = /<node[^>]*>/g;
    let m;
    while ((m = re.exec(xml)) !== null) {
      const n = m[0];
      const a = (attr) => {
        const x = n.match(new RegExp(`${attr}="([^"]*)"`));
        return x ? x[1] : '';
      };
      nodes.push({
        text: a('text'),
        contentDesc: a('content-desc'),
        className: a('class'),
        bounds: a('bounds'),
        resourceId: a('resource-id'),
        clickable: /clickable="true"/.test(n),
      });
    }
    return nodes;
  }

  // ─── HTTP helpers ──────────────────────────────────────────────

  async _post(path, body = {}) {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId: this.deviceId, fast: ADB_FAST, ...body }),
    });
    return res.json();
  }

  async _get(path) {
    const res = await fetch(`${this.baseUrl}${path}`);
    return res.json();
  }

  // ─── Tap ───────────────────────────────────────────────────────

  async _dismissIncomingCallIfNeeded() {
    await dismissIncomingPhoneCall(this, { log: true });
  }

  /** Tap un element par son texte visible ou content-desc */
  async tap(text, index = 0) {
    await this._dismissIncomingCallIfNeeded();
    const r = await this._post('/find-and-tap', { text, index });
    if (!r.success) throw new Error(r.error || `"${text}" introuvable`);
    this._invalidateUi();
    this._log(`tap "${text}" -> ${r.message}`);
    return r.message;
  }

  /** Tap avec repli sur findElement + coordonnées si le contrôleur ADB échoue. */
  async tapReliable(text, index = 0) {
    try {
      return await this.tap(text, index);
    } catch {
      const el = await this.findElement(text);
      if (!el?.bounds) throw new Error(`Element not found: text="${text}" contentDesc="undefined"`);
      const c = this._boundsCenter(el.bounds);
      if (!c) throw new Error(`Bounds invalides pour "${text}"`);
      await this.tapXY(c.cx, c.cy);
      this._log(`tapReliable "${text}" -> (${c.cx},${c.cy})`);
      return `${text}@${c.cx},${c.cy}`;
    }
  }

  /** Ouvre le drawer (hamburger Flutter ou swipe edge). */
  async openNavigationDrawer() {
    const labels = ['Open navigation menu', 'Ouvrir le menu de navigation', 'Menu'];
    for (const label of labels) {
      if (!(await this.uiContains(label))) continue;
      try {
        await this.tapReliable(label);
        await this.wait(600);
        return;
      } catch {
        /* essai label suivant */
      }
    }
    await this.openDrawer();
  }

  /** Tap un onglet de la bottom bar shell (1-based, 4 onglets). */
  async tapTab(n, totalTabs = 4) {
    return this.tap(`Tab ${n} of ${totalTabs}`);
  }

  /** Tap a des coordonnees brutes */
  async tapXY(x, y) {
    await this._dismissIncomingCallIfNeeded();
    await this._post('/input-tap', { x, y });
    this._invalidateUi();
    this._log(`tap (${x},${y})`);
  }

  async tapCoords(x, y) {
    return this.tapXY(x, y);
  }

  // ─── Text input ────────────────────────────────────────────────

  /** Trouve un champ par hint, le tape, le vide, et saisit du texte */
  async typeInField(hint, value, opts = {}) {
    const isPassword =
      !!opts.isPassword ||
      !!opts.secret ||
      /mot de passe|password/i.test(String(hint));
    const r = await this._post('/tap-field-and-type', {
      hint,
      text: value,
      isPassword,
    });
    if (!r.success) throw new Error(r.error || `Champ "${hint}" introuvable`);
    this._invalidateUi();
    const masked =
      /mot de passe|password/i.test(hint) || /mot de passe|password/i.test(String(value))
        ? '***'
        : value;
    this._log(`type "${hint}" = "${masked}"`);
    return r.message;
  }

  _boundsCenter(bounds) {
    const m = String(bounds || '').match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!m) return null;
    return {
      x1: +m[1],
      y1: +m[2],
      x2: +m[3],
      y2: +m[4],
      cx: Math.round((+m[1] + +m[3]) / 2),
      cy: Math.round((+m[2] + +m[4]) / 2),
    };
  }

  /**
   * Saisie sur champs Flutter labelText (hint souvent absent de l'EditText).
   * Essaie hint/text, puis associe le libellé visible au EditText le plus proche en dessous.
   */
  async typeInLabeledField(label, value, opts = {}) {
    const hints = opts.hints || [label];
    for (const h of hints) {
      try {
        await this.typeInField(h, value);
        return;
      } catch {
        /* fallback label / index */
      }
    }
    if (opts.editIndex !== undefined) {
      await this.typeInEditTextByIndex(opts.editIndex, value, opts);
      return;
    }
    const nodes = await this.uiNodes();
    const labelLower = String(label).toLowerCase();
    const labelNode = nodes.find((n) => {
      const t = (n.text || '').toLowerCase();
      const c = (n.contentDesc || '').toLowerCase();
      return t.includes(labelLower) || c.includes(labelLower);
    });
    const edits = nodes
      .filter((n) => n.className.includes('EditText') && n.bounds)
      .map((n) => ({ n, b: this._boundsCenter(n.bounds) }))
      .filter((x) => x.b)
      .sort((a, b) => a.b.y1 - b.b.y1);
    let picked = null;
    if (labelNode) {
      const lb = this._boundsCenter(labelNode.bounds);
      if (lb) {
        picked = edits.find((e) => e.b.y1 >= lb.y1 - 40);
      }
    }
    if (!picked && edits.length === 1) picked = edits[0];
    if (!picked) {
      throw new Error(`Champ « ${label} » introuvable (${edits.length} EditText(s))`);
    }
    const idx = edits.indexOf(picked);
    const isSecret =
      !!opts.secret ||
      /mot de passe|password/i.test(String(label)) ||
      !!opts.isPassword;
    await this.typeInEditTextByIndex(idx, value, { ...opts, isPassword: isSecret });
    const masked = isSecret ? '***' : String(value).slice(0, 24);
    this._log(`type labeled "${label}" = "${masked}"`);
  }

  /** Saisit du texte brut (le champ doit etre deja focus) */
  async typeText(text) {
    await this._post('/input-text', { text });
    this._invalidateUi();
  }

  // ─── Keys ──────────────────────────────────────────────────────

  async keyevent(code) {
    await this._post('/input-keyevent', { keycode: code });
    this._invalidateUi();
  }
  async back()    { await this.keyevent(4);   this._log('BACK'); }
  async home()    { await this.keyevent(3);   this._log('HOME'); }
  async enter()   { await this.keyevent(66);  this._log('ENTER'); }
  async tab()     { await this.keyevent(61); }
  async del()     { await this.keyevent(67); }

  async closeKeyboard() { await this.back(); }

  // ─── Gestures ──────────────────────────────────────────────────

  async swipe(x1, y1, x2, y2, duration = 300) {
    await this._post('/input-swipe', { x1, y1, x2, y2, duration });
    this._invalidateUi();
    this._log(`swipe (${x1},${y1})->(${x2},${y2})`);
  }

  async scrollDown(amount = 800) {
    await this.swipe(540, 1600, 540, 1600 - amount, 500);
  }

  async scrollUp(amount = 800) {
    await this.swipe(540, 600, 540, 600 + amount, 500);
  }

  async openDrawer() {
    await this.swipe(5, 1170, 900, 1170, 350);
    this._log('drawer ouvert');
  }

  async drawerScrollDown() {
    await this.swipe(400, 1800, 400, 800, 400);
  }

  // ─── UI inspection ─────────────────────────────────────────────

  /** Dump le XML complet de l'UI (cache court pour éviter dumps redondants). */
  async uiDump(force = false) {
    const now = Date.now();
    if (!force && this._uiCache && now - this._uiCacheAt < UI_CACHE_MS) {
      return this._uiCache;
    }
    const r = await this._post('/ui-dump', {});
    this._uiCache = r.xml || '';
    this._uiCacheAt = now;
    return this._uiCache;
  }

  /** Snapshot UI : un seul dump pour plusieurs assertions. */
  async uiSnapshot(force = false) {
    const xml = await this.uiDump(force);
    const nodes = AdbClient.parseNodes(xml);
    const lower = xml.toLowerCase();
    return {
      xml,
      nodes,
      contains: (text) => lower.includes(String(text).toLowerCase()),
    };
  }

  /** Verifie si un texte est present a l'ecran */
  async uiContains(text) {
    await this._dismissIncomingCallIfNeeded();
    const xml = await this.uiDump();
    return xml.toLowerCase().includes(text.toLowerCase());
  }

  /** Parse tous les noeuds UI visibles */
  async uiNodes() {
    const xml = await this.uiDump();
    return AdbClient.parseNodes(xml);
  }

  /** Trouve un element par texte ou content-desc */
  async findElement(text) {
    const nodes = await this.uiNodes();
    const t = text.toLowerCase();
    return nodes.find(n =>
      n.text.toLowerCase().includes(t) || n.contentDesc.toLowerCase().includes(t)
    ) || null;
  }

  /** Attend qu'un texte apparaisse (polling) */
  async waitFor(text, timeoutMs = 20000, pollMs = WAIT_FOR_POLL_MS) {
    const t0 = Date.now();
    const poll = pollMs ?? WAIT_FOR_POLL_MS;
    while (Date.now() - t0 < timeoutMs) {
      if ((await this.uiSnapshot(true)).contains(text)) return true;
      await this.wait(poll);
    }
    return false;
  }

  /** Attend un prédicat basé sur un seul dump UI par itération. */
  async waitUntil(predicate, { timeoutMs = 15000, pollMs = WAIT_FOR_POLL_MS } = {}) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const snap = await this.uiSnapshot(true);
      const result = await predicate(snap);
      if (result) return result;
      await this.wait(pollMs);
    }
    return null;
  }

  /** Asserte qu'un texte est present, sinon throw */
  async assertVisible(text) {
    await this._dismissIncomingCallIfNeeded();
    const found = await this.uiContains(text);
    if (!found) throw new Error(`Assertion failed: "${text}" not visible`);
    this._log(`assert OK: "${text}" visible`);
  }

  /** Asserte qu'un texte est absent */
  async assertNotVisible(text) {
    const found = await this.uiContains(text);
    if (found) throw new Error(`Assertion failed: "${text}" should not be visible`);
    this._log(`assert OK: "${text}" absent`);
  }

  // ─── Screen ────────────────────────────────────────────────────

  async screenInfo() {
    return this._post('/screen-info', {});
  }

  screenshotUrl() {
    return `${this.baseUrl}/screenshot?device=${encodeURIComponent(this.deviceId)}&t=${Date.now()}`;
  }

  // ─── Extended ──────────────────────────────────────────────────

  async swipeRight() {
    await this.swipe(5, 1170, 900, 1170, 350);
    this._log('swipe right (open drawer)');
  }

  async swipeLeft(y = 1170) {
    await this.swipe(900, y, 100, y, 300);
    this._log('swipe left');
  }

  async shellCommand(command) {
    const r = await this._post('/adb-shell', { command });
    if (!r.success) throw new Error(r.error || 'Shell command failed');
    this._log(`shell: ${command.substring(0, 60)}`);
    return r.stdout || '';
  }

  /** Écrit un booléen dans FlutterSharedPreferences (smokes ADB uniquement). */
  async setFlutterPrefBool(key, value) {
    const prefsPath = 'shared_prefs/FlutterSharedPreferences.xml';
    const fullKey = key.startsWith('flutter.') ? key : `flutter.${key}`;
    const pkg = 'cloud.hubera.jobs';
    let xml = '';
    try {
      xml = await this.shellCommand(`run-as ${pkg} cat ${prefsPath}`);
    } catch {
      xml = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>";
    }
    const boolTag = `<boolean name="${fullKey}" value="${value ? 'true' : 'false'}" />`;
    if (xml.includes(`name="${fullKey}"`)) {
      xml = xml.replace(
        new RegExp(`<boolean name="${fullKey}" value="(?:true|false)" */?>`, 'g'),
        boolTag,
      );
    } else {
      xml = xml.replace('</map>', `    ${boolTag}\n</map>`);
    }
    const tmpFile = path.join(os.tmpdir(), `jbt-prefs-${Date.now()}.xml`);
    fs.writeFileSync(tmpFile, xml, 'utf8');
    try {
      execSync(`adb -s ${this.deviceId} push ${JSON.stringify(tmpFile)} /data/local/tmp/flutter_prefs.xml`, {
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      await this.shellCommand(
        `run-as ${pkg} cp /data/local/tmp/flutter_prefs.xml ${prefsPath}`,
      );
    } finally {
      try {
        fs.unlinkSync(tmpFile);
      } catch {}
    }
    this._log(`pref ${fullKey}=${value}`);
    this._invalidateUi();
  }

  async tapByIndex(index) {
    const nodes = await this.uiNodes();
    const clickable = nodes.filter(n => n.clickable && (n.text || n.contentDesc));
    if (index >= clickable.length) throw new Error(`Index ${index} hors limites (${clickable.length} elements)`);
    const node = clickable[index];
    const m = node.bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!m) throw new Error(`Bounds invalides: ${node.bounds}`);
    const x = Math.round((parseInt(m[1]) + parseInt(m[3])) / 2);
    const y = Math.round((parseInt(m[2]) + parseInt(m[4])) / 2);
    await this.tapCoords(x, y);
    this._log(`tap index ${index}: "${node.text || node.contentDesc}" (${x},${y})`);
    return node.text || node.contentDesc;
  }

  async openGmail() {
    return this.shellCommand('am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.google.android.gm/.ConversationListActivityGmail');
  }

  async openEmailApp() {
    try {
      return await this.shellCommand('am start -a android.intent.action.MAIN -t "message/rfc822"');
    } catch {
      return this.openGmail();
    }
  }

  async returnToApp(packageName = 'cloud.hubera.jobs') {
    try {
      return await this.shellCommand(`am start -n ${packageName}/.MainActivity`);
    } catch {
      await this.back();
      await this.wait(500);
      await this.back();
      return 'Retour via back';
    }
  }

  // ─── Utilities ─────────────────────────────────────────────────

  wait(ms) { return new Promise((r) => setTimeout(r, scaleWait(ms))); }

  _boundsCenter(bounds) {
    const m = bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!m) return null;
    return {
      cx: Math.round((+m[1] + +m[3]) / 2),
      cy: Math.round((+m[2] + +m[4]) / 2),
    };
  }

  async listEditTexts() {
    const nodes = await this.uiNodes();
    return nodes
      .filter((n) => n.className.includes('EditText') && n.bounds)
      .sort((a, b) => this._boundsCenter(a.bounds).cy - this._boundsCenter(b.bounds).cy);
  }

  /** Saisie par index de champ EditText (formulaires Flutter sans hint accessible). */
  async typeInEditTextByIndex(index, value, opts = {}) {
    const r = await this._post('/tap-field-and-type', {
      hint: opts.isEmail ? 'email' : opts.isPassword ? 'password' : 'field',
      text: value,
      editTextIndex: index,
      isEmail: !!opts.isEmail,
      isPassword: !!(opts.isPassword || opts.secret),
    });
    if (!r.success) {
      throw new Error(r.error || `EditText #${index} introuvable`);
    }
    const masked =
      opts.secret || opts.isPassword || /mot de passe|password/i.test(String(value))
        ? '***'
        : value;
    this._log(
      `type EditText#${index} = "${String(masked).slice(0, 24)}${String(masked).length > 24 ? '…' : ''}"`,
    );
  }

  async clearField() {
    await this._post('/clear-field', {});
    this._invalidateUi();
  }

  // ─── Healthcheck & devices ─────────────────────────────────────

  async health() {
    try { const r = await this._get('/health'); return !!r.ok; } catch { return false; }
  }

  async listDevices() {
    const r = await this._get('/devices');
    return r.devices || [];
  }
}

/**
 * Factory : cree un AdbClient. Si pas de deviceId, auto-detecte le premier appareil.
 * @param {string} [deviceId]
 * @param {object} [opts]
 * @returns {Promise<AdbClient>}
 */
async function createAdb(deviceId, opts = {}) {
  const tmp = new AdbClient('_probe_', opts);
  const devs = await tmp.listDevices();
  if (devs.length === 0) {
    throw new Error(
      'Aucun appareil ADB detecte. Branchez le Samsung ou lancez: bash scripts/mobile/setup-android-emulator.sh up',
    );
  }

  const preferred =
    deviceId || process.env.MOBILE_ADB_DEVICE || process.env.ADB_DEVICE_ID;
  if (preferred) {
    const found = devs.find((d) => d.id === preferred);
    if (!found) {
      throw new Error(
        `Appareil ${preferred} introuvable (${devs.map((d) => d.id).join(', ')})`,
      );
    }
    console.log(`[adb-lib] Appareil cible: ${preferred}`);
    return new AdbClient(preferred, opts);
  }

  if (process.env.MOBILE_PREFER_EMULATOR === '1') {
    const emu = devs.find((d) => d.id.startsWith('emulator-'));
    if (emu) {
      console.log(`[adb-lib] Emulateur auto: ${emu.id}`);
      return new AdbClient(emu.id, opts);
    }
  }

  const physical = devs.find((d) => !d.id.startsWith('emulator-'));
  deviceId = physical ? physical.id : devs[0].id;
  console.log(`[adb-lib] Appareil auto-detecte: ${deviceId}`);
  return new AdbClient(deviceId, opts);
}

module.exports = { AdbClient, createAdb, scaleWait, ADB_FAST };
