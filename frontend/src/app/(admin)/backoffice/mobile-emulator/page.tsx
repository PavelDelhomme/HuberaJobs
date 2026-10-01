"use client";

import React, { useState, useEffect, useRef } from "react";
import { AdminLayout } from "@/components/features";
import { useAuth } from "@/lib/hooks/auth";
import { FRONTEND_URLS } from "@/config/ports.config";
import {
  Smartphone,
  RefreshCw,
  Play,
  Square,
  Monitor,
  Wifi,
  WifiOff,
  Loader2,
  Image as ImageIcon,
  FlaskConical,
  Trash2,
  UserMinus,
} from "lucide-react";
import {
  AdbRunner,
  MOBILE_SCENARIOS,
  STEP_LABELS,
  SCENARIO_CATEGORIES,
  VERIFICATION_EMAIL_SCENARIO_KEYS,
  VERIFICATION_EMAIL_ACCOUNTS,
  getMobileTestCredentials,
} from "@/lib/adb";
import type { StepResult } from "@/lib/adb";

const CONTROLLER_URL_DEFAULT =
  typeof window !== "undefined"
    ? process.env.NEXT_PUBLIC_EMULATOR_CONTROLLER_URL || "http://localhost:5055"
    : "http://localhost:5055";

const API_GATEWAY_URL = FRONTEND_URLS.api;

type Avd = { name: string };
type Device = { id: string; status: string };
type FlutterDevice = { id: string; name: string; platform?: string };

export default function MobileEmulatorPage() {
  const { token } = useAuth();
  const [controllerUrl, setControllerUrl] = useState(CONTROLLER_URL_DEFAULT);
  const [avds, setAvds] = useState<Avd[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [flutterDevices, setFlutterDevices] = useState<FlutterDevice[]>([]);
  const [selectedAvd, setSelectedAvd] = useState("");
  const [selectedDevice, setSelectedDevice] = useState("");
  const [selectedFlutterDevice, setSelectedFlutterDevice] = useState("");
  const [controllerOk, setControllerOk] = useState<boolean | null>(null);
  const [loading, setLoading] = useState<string | null>(null);
  const [logs, setLogs] = useState<string[]>([]);
  const [logsCopied, setLogsCopied] = useState(false);
  const [screenshotUrl, setScreenshotUrl] = useState<string | null>(null);
  const [apkBuilt, setApkBuilt] = useState(false);
  const [buildNeeded, setBuildNeeded] = useState<boolean | null>(null);
  const [cleanupUsers, setCleanupUsers] = useState<
    Array<{ id: string; email: string; firstName?: string; lastName?: string }>
  >([]);
  const [cleanupUsersLoading, setCleanupUsersLoading] = useState(false);
  const [cleanupSelectedUserId, setCleanupSelectedUserId] =
    useState<string>("");
  const [appRunning, setAppRunning] = useState(false);
  const [journeyRunning, setJourneyRunning] = useState(false);
  const [journeyStepResults, setJourneyStepResults] = useState<StepResult[]>(
    [],
  );
  const [journeyProgress, setJourneyProgress] = useState({
    current: 0,
    total: 0,
  });
  const [liveViewOn, setLiveViewOn] = useState(true);
  const [buildElapsedSeconds, setBuildElapsedSeconds] = useState(0);
  const screenshotBlobRef = useRef<string | null>(null);
  const dragStart = useRef<{ x: number; y: number; time: number } | null>(null);
  const buildAbortRef = useRef<AbortController | null>(null);
  /** Ref remplie par MobileJourneyPanel pour annuler le parcours depuis l’extérieur (ex. bouton Arrêter l’app). */
  const cancelJourneyRef = useRef<(() => void) | null>(null);

  const base = () => controllerUrl.replace(/\/$/, "");
  /** URL du lanceur (port 5056) pour Démarrer / Arrêter le contrôleur depuis l'interface. */
  const launcherBase = () => {
    try {
      const u = new URL(
        controllerUrl.replace(/\/$/, "") || "http://localhost:5055",
      );
      u.port = "5056";
      return u.origin;
    } catch {
      return "http://localhost:5056";
    }
  };
  const addLog = (msg: string) =>
    setLogs((prev) => [...prev, `[${new Date().toLocaleTimeString()}] ${msg}`]);

  const fetchJson = async <T,>(
    path: string,
    opts?: RequestInit,
  ): Promise<T> => {
    const res = await fetch(`${base()}${path}`, {
      ...opts,
      headers: { "Content-Type": "application/json", ...opts?.headers },
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok)
      throw new Error((data as { error?: string }).error || res.statusText);
    return data as T;
  };

  /** Appel controller + en cas d’erreur log détaillé (error, stderr, message) puis throw. */
  const fetchControllerWithErrorLog = async <T,>(
    path: string,
    opts: RequestInit & { body?: string },
  ): Promise<
    | { ok: true; data: T }
    | { ok: false; error: string; detail?: string; statusCode?: number }
  > => {
    const url = `${base()}${path}`;
    try {
      const res = await fetch(url, {
        ...opts,
        headers: { "Content-Type": "application/json", ...opts?.headers },
      });
      const data = (await res.json().catch(() => ({}))) as Record<
        string,
        unknown
      >;
      if (res.ok) return { ok: true, data: data as T };
      const errMsg =
        (data?.error as string) || res.statusText || "Erreur inconnue";
      const parts = [errMsg];
      if (data?.stderr)
        parts.push(`stderr: ${String(data.stderr).slice(-500)}`);
      if (data?.message) parts.push(String(data.message));
      const detail = parts.join(" | ");
      addLog(`[${path}] ${res.status}: ${detail}`);
      return { ok: false, error: errMsg, detail, statusCode: res.status };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      addLog(`[${path}] Erreur réseau ou parsing: ${msg}`);
      return { ok: false, error: msg };
    }
  };

  const checkHealth = async () => {
    setControllerOk(null);
    setBuildNeeded(null);
    try {
      const data = await fetchJson<{ ok?: boolean }>("/health");
      setControllerOk(!!data.ok);
      if (data.ok) {
        addLog("Controleur emulateur connecte.");
        try {
          const status = await fetchJson<{ needsBuild?: boolean }>(
            "/build-status",
          );
          setBuildNeeded(!!status.needsBuild);
        } catch {
          setBuildNeeded(null);
        }
      } else addLog("Controleur a repondu mais ok=false.");
    } catch {
      setControllerOk(false);
      addLog(
        "Contrôleur injoignable. Utilisez « Démarrer le contrôleur » ci-dessous (ou lancez make emulator-controller une fois).",
      );
    }
  };

  const startController = async () => {
    setLoading("start-controller");
    try {
      const r = await fetch(`${launcherBase()}/start`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      const d = await r.json().catch(() => ({}));
      if (d.success) {
        addLog(d.message || "Contrôleur démarré.");
        await new Promise((resolve) => setTimeout(resolve, 2500));
        await checkHealth();
      } else {
        addLog(d.error || "Échec démarrage contrôleur.");
      }
    } catch (e) {
      addLog(
        "Lanceur injoignable (port 5056). Lancez une fois : make emulator-controller",
      );
      if (e instanceof Error && e.message) addLog(e.message);
    } finally {
      setLoading(null);
    }
  };

  const stopController = async () => {
    setLoading("stop-controller");
    try {
      const r = await fetch(`${launcherBase()}/stop`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      const d = await r.json().catch(() => ({}));
      if (d.success) {
        setControllerOk(false);
        addLog(d.message || "Contrôleur arrêté.");
      } else {
        addLog(d.error || "Échec arrêt contrôleur.");
      }
    } catch (e) {
      addLog(
        "Erreur arrêt contrôleur : " +
          (e instanceof Error ? e.message : String(e)),
      );
    } finally {
      setLoading(null);
    }
  };

  const loadAvds = async () => {
    if (!controllerOk) return;
    setLoading("avds");
    try {
      const data = await fetchJson<{ avds: Avd[] }>("/avds");
      const list = data.avds || [];
      setAvds(list);
      addLog(`AVD trouves : ${list.length}`);
      if (list.length > 0 && !selectedAvd) setSelectedAvd(list[0].name);
    } catch (e) {
      addLog(`Erreur AVD: ${e}`);
    } finally {
      setLoading(null);
    }
  };

  const loadDevices = async () => {
    if (!controllerOk) return;
    setLoading("devices");
    try {
      const data = await fetchJson<{ devices: Device[] }>("/devices");
      const list = data.devices || [];
      setDevices(list);
      addLog(`Appareils ADB : ${list.length}`);
      if (list.length > 0 && !selectedDevice) setSelectedDevice(list[0].id);
    } catch (e) {
      addLog(`Erreur appareils: ${e}`);
    } finally {
      setLoading(null);
    }
  };

  const loadFlutterDevices = async () => {
    if (!controllerOk) return;
    setLoading("flutter-devices");
    try {
      const res = await fetch(`${base()}/flutter-devices`, {
        headers: { "Content-Type": "application/json" },
      });
      const data = (await res.json()) as {
        devices?: FlutterDevice[];
        error?: string;
      };
      if (!res.ok) {
        setFlutterDevices([]);
        if (res.status === 404)
          addLog("Route /flutter-devices non disponible.");
        else addLog(`Flutter devices: ${data.error || res.statusText}`);
        return;
      }
      setFlutterDevices(data.devices || []);
      if (data.error) addLog(`Flutter devices: ${data.error}`);
    } catch {
      setFlutterDevices([]);
      addLog("Impossible de charger les appareils Flutter.");
    } finally {
      setLoading(null);
    }
  };

  useEffect(() => {
    checkHealth();
  }, [controllerUrl]);
  useEffect(() => {
    if (controllerOk) {
      loadAvds();
      loadDevices();
      loadFlutterDevices();
    }
  }, [controllerOk]);

  const startAvd = async () => {
    if (!selectedAvd) {
      addLog("Selectionnez un AVD.");
      return;
    }
    setLoading("start-avd");
    try {
      await fetchJson("/start-avd", {
        method: "POST",
        body: JSON.stringify({ avd: selectedAvd }),
      });
      addLog(
        `Demarrage AVD : ${selectedAvd}. Attendez 30-60s puis rafraichissez.`,
      );
      setTimeout(loadDevices, 5000);
    } catch (e) {
      addLog(`Erreur demarrage AVD: ${e}`);
    } finally {
      setLoading(null);
    }
  };

  const buildApk = async () => {
    setLoading("build");
    setBuildElapsedSeconds(0);
    addLog("Build APK en cours... (peut prendre 1-2 min, timeout 5 min)");
    const BUILD_TIMEOUT_MS = 5 * 60 * 1000; // 5 min
    const abort = new AbortController();
    buildAbortRef.current = abort;
    const timeoutId = setTimeout(() => abort.abort(), BUILD_TIMEOUT_MS);
    const controllerBase = base();
    const directUrl = `${controllerBase}/build-apk`;

    const handleResponse = (
      res: Response,
      data: {
        success?: boolean;
        message?: string;
        error?: string;
        stdout?: string;
        stderr?: string;
        exitCode?: number;
        _triedUrl?: string;
        _hint?: string;
      },
      source: string,
    ) => {
      if (data.success) {
        setApkBuilt(true);
        setBuildNeeded(false);
        if (selectedDevice) {
          fetchJson<{ success?: boolean }>("/stop-app", {
            method: "POST",
            body: JSON.stringify({ deviceId: selectedDevice }),
          })
            .then(() => {
              setAppRunning(false);
              addLog(
                "App arretee — vous pouvez cliquer sur Installer et lancer.",
              );
            })
            .catch(() => {});
        }
        // Redémarrer le contrôleur après un court délai pour que la réponse soit bien envoyée au client (évite NetworkError si l'utilisateur relance un build tout de suite)
        const controllerBaseForRestart = controllerBase;
        setTimeout(() => {
          fetch(`${controllerBaseForRestart}/restart`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: "{}",
          })
            .then((r) => {
              if (r.status === 404) {
                addLog(
                  "Route /restart absente (contrôleur ancien). Lancez make emulator-controller une fois pour utiliser le lanceur.",
                );
                return { success: false };
              }
              return r.json().catch(() => ({}));
            })
            .then((restartData: { success?: boolean }) => {
              if (restartData.success) {
                setControllerOk(false);
                addLog(
                  "Contrôleur en redémarrage (automatique si le lanceur tourne).",
                );
                setTimeout(() => checkHealth(), 4500);
              }
            })
            .catch(() => {});
        }, 3000);
      }
      addLog(
        data.message ||
          (data.success ? "Build reussi." : data.error || "Build echoue."),
      );
      if (!res.ok && data.error) addLog(`Erreur: ${data.error}`);
      if (!res.ok && data._triedUrl) addLog(`URL appelee: ${data._triedUrl}`);
      if (!res.ok && data._hint) addLog(data._hint);
      if (!data.success && data.stderr)
        addLog(`stderr: ${data.stderr.slice(-800)}`);
      if (!data.success && data.stdout)
        addLog(`stdout: ${data.stdout.slice(-500)}`);
    };

    try {
      // 1) Appel direct au contrôleur (évite timeout proxy / Docker). Le contrôleur a CORS *.
      let res: Response;
      let data: {
        success?: boolean;
        message?: string;
        error?: string;
        stdout?: string;
        stderr?: string;
        exitCode?: number;
        _triedUrl?: string;
        _hint?: string;
      };
      try {
        res = await fetch(directUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({}),
          signal: abort.signal,
        });
        data = (await res.json().catch(() => ({}))) as typeof data;
        if (res.ok || res.status === 502) {
          clearTimeout(timeoutId);
          handleResponse(res, data, "direct");
          return !!data?.success;
        }
      } catch (directErr) {
        addLog("Appel direct au controleur echoue, passage par le proxy...");
      }

      // 1b) Réessayer une fois après 2s (au cas où le contrôleur était en redémarrage)
      try {
        await new Promise((r) => setTimeout(r, 2000));
        if (abort.signal.aborted) throw new Error("aborted");
        res = await fetch(directUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({}),
          signal: abort.signal,
        });
        data = (await res.json().catch(() => ({}))) as typeof data;
        if (res.ok || res.status === 502) {
          clearTimeout(timeoutId);
          handleResponse(res, data, "direct");
          return !!data?.success;
        }
      } catch (_) {
        addLog("Nouvelle tentative directe echouee, utilisation du proxy...");
      }

      // 2) Fallback : proxy same-origin (pour backoffice en Docker si le navigateur ne peut pas joindre le contrôleur)
      res = await fetch("/api/emulator-proxy/build-apk", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ controllerBaseUrl: controllerBase }),
        signal: abort.signal,
      });
      clearTimeout(timeoutId);
      data = (await res.json()) as typeof data;
      handleResponse(res, data, "proxy");
      if (!res.ok && data._triedUrl) {
        addLog(
          "Conseil : verifiez que le controleur tourne (cd tools/emulator-controller && node server.js)",
        );
        addLog(
          "  Puis lancez a la main si besoin : cd mobile && flutter build apk --debug",
        );
      }
      return !!data?.success;
    } catch (e) {
      clearTimeout(timeoutId);
      const msg = e instanceof Error ? e.message : String(e);
      addLog(`Erreur build: ${msg}`);
      if (
        msg.includes("fetch") ||
        msg.includes("NetworkError") ||
        msg.includes("Failed to fetch") ||
        msg.includes("aborted")
      ) {
        addLog("Le controleur est injoignable ou le build a depasse le delai.");
        addLog(
          "Lancez le build a la main sur la machine ou tourne le controleur :",
        );
        addLog("  cd mobile && flutter build apk --debug");
      }
      return false;
    } finally {
      setLoading(null);
      setBuildElapsedSeconds(0);
      buildAbortRef.current = null;
    }
  };

  const cancelBuild = () => {
    if (buildAbortRef.current) {
      buildAbortRef.current.abort();
      addLog("Build annulé.");
    }
  };

  const deleteUserByEmail = async () => {
    if (!token) {
      addLog("Connectez-vous en admin pour supprimer un utilisateur.");
      return;
    }
    if (!cleanupSelectedUserId) {
      addLog("Choisissez un utilisateur dans la liste (rafraîchir si vide).");
      return;
    }
    setLoading("cleanup-user");
    const apiBase = API_GATEWAY_URL;
    try {
      const delRes = await fetch(
        `${apiBase}/api/v1/auth/users/${cleanupSelectedUserId}`,
        {
          method: "DELETE",
          headers: { Authorization: `Bearer ${token}` },
        },
      );
      const userEmail =
        cleanupUsers.find((u) => u.id === cleanupSelectedUserId)?.email ||
        cleanupSelectedUserId;
      if (delRes.ok) {
        addLog(
          `Utilisateur supprimé : ${userEmail}. Vous pouvez vous réinscrire pour retester.`,
        );
        setCleanupSelectedUserId("");
        loadCleanupUsers();
      } else {
        const err = await delRes.json().catch(() => ({}));
        addLog(`Suppression échouée : ${err?.error || delRes.status}.`);
      }
    } catch (e) {
      addLog(
        "Erreur nettoyage compte : " +
          (e instanceof Error ? e.message : String(e)),
      );
    } finally {
      setLoading(null);
    }
  };

  const loadCleanupUsers = async () => {
    if (!token) return;
    setCleanupUsersLoading(true);
    const apiBase = API_GATEWAY_URL;
    const ADMIN_EMAIL = "admin@jobbingtrack.test";
    try {
      const usersRes = await fetch(`${apiBase}/api/v1/auth/users`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      const usersData = await usersRes.json().catch(() => ({}));
      const users = usersData?.users ?? usersData?.data ?? [];
      const filtered = Array.isArray(users)
        ? users.filter((u: { role?: string; email?: string }) => {
            const role = (u.role || "").toUpperCase();
            const email = (u.email || "").toLowerCase();
            if (role === "ADMIN" || role === "SUPER_ADMIN") return false;
            if (email === ADMIN_EMAIL) return false;
            return true;
          })
        : [];
      const list = filtered.map(
        (u: {
          id?: string;
          email?: string;
          firstName?: string;
          lastName?: string;
        }) => ({
          id: String(u.id ?? ""),
          email: String(u.email ?? ""),
          firstName: u.firstName,
          lastName: u.lastName,
        }),
      );
      setCleanupUsers(list);
      const stillValid = list.some((u) => u.id === cleanupSelectedUserId);
      if (list.length > 0 && !stillValid) setCleanupSelectedUserId(list[0].id);
      else if (list.length === 0) setCleanupSelectedUserId("");
    } catch {
      setCleanupUsers([]);
      setCleanupSelectedUserId("");
    } finally {
      setCleanupUsersLoading(false);
    }
  };

  useEffect(() => {
    if (controllerOk && token) loadCleanupUsers();
  }, [controllerOk, token]);

  const installAndRun = async () => {
    if (!selectedDevice) {
      addLog("Selectionnez un appareil.");
      return;
    }
    if (buildNeeded === true) {
      const go = window.confirm(
        "L’APK n’est pas à jour (code mobile modifié).\n\n" +
          "• OK = Installer quand même l’APK actuel (sans rebuild)\n" +
          "• Annuler = Lancer un rebuild puis installer",
      );
      if (!go) {
        addLog("Rebuild demandé puis installation...");
        await ensureBuildAndInstall(true);
        return;
      }
    }
    await ensureBuildAndInstall(false);
  };

  /** Lance l'app sans réinstaller (force-stop + start). Utile quand l'APK est déjà installé. */
  const launchOnly = async () => {
    if (!selectedDevice) {
      addLog("Selectionnez un appareil.");
      return;
    }
    setLoading("launch-only");
    try {
      const r = await fetchControllerWithErrorLog<{ success?: boolean }>(
        "/force-restart-app",
        {
          method: "POST",
          body: JSON.stringify({ deviceId: selectedDevice }),
        },
      );
      if (r.ok && r.data?.success) {
        setAppRunning(true);
        addLog("App lancée (sans réinstallation).");
      } else if (!r.ok) {
        addLog("Échec lancement. Vérifiez les logs ci-dessus pour le détail.");
      }
    } finally {
      setLoading(null);
    }
  };

  /** Désinstalle l'app du périphérique (réinstallation propre possible ensuite). */
  const uninstallApp = async () => {
    if (!selectedDevice) {
      addLog("Selectionnez un appareil.");
      return;
    }
    if (
      !window.confirm(
        "Désinstaller l’app JobbingTrack du périphérique ? Vous pourrez réinstaller avec « Installer et lancer ».",
      )
    )
      return;
    setLoading("uninstall");
    try {
      const r = await fetchControllerWithErrorLog<{ success?: boolean }>(
        "/uninstall-app",
        {
          method: "POST",
          body: JSON.stringify({ deviceId: selectedDevice }),
        },
      );
      if (r.ok && r.data?.success) {
        setAppRunning(false);
        setApkBuilt(false);
        addLog(
          "App désinstallée. Utilisez « Installer et lancer » pour réinstaller.",
        );
      } else if (!r.ok) {
        addLog("Échec désinstallation. Vérifiez les logs ci-dessus.");
        if (r.statusCode === 404) {
          addLog(
            "Route « Désinstaller » absente : redémarrez le contrôleur (bouton ci-dessous ou make emulator-controller) pour charger la dernière version.",
          );
        }
      }
    } finally {
      setLoading(null);
    }
  };

  /** Build APK puis installation + lancement. Retourne true si l’app est prête (pour parcours). */
  const ensureBuildAndInstall = async (
    forceBuild?: boolean,
  ): Promise<boolean> => {
    if (!selectedDevice) return false;
    const controllerBase = base();
    try {
      const doInstallRun = async (): Promise<{
        success: boolean;
        error?: string;
        needBuild?: boolean;
      }> => {
        const r = await fetchControllerWithErrorLog<{
          success?: boolean;
          error?: string;
        }>("/install-run", {
          method: "POST",
          body: JSON.stringify({ deviceId: selectedDevice }),
        });
        if (r.ok) return { success: !!r.data?.success, error: r.data?.error };
        const needBuild = /APK non trouvé|non trouvé|Build APK/i.test(r.error);
        return { success: false, error: r.error, needBuild };
      };
      setLoading("install-run");
      let result = await doInstallRun();
      if (result.success) {
        setAppRunning(true);
        setApkBuilt(true);
        addLog("App installée et lancée (adb reverse activé sur ports API).");
        return true;
      }
      const shouldBuild =
        forceBuild ||
        result.needBuild ||
        (result.error != null && /APK|build/i.test(result.error));
      if (shouldBuild) {
        addLog("APK absent ou obsolète. Build en cours...");
        setLoading("build");
        const buildSuccess = await buildApk();
        if (!buildSuccess) {
          addLog(
            "Build APK a échoué. Lancez « Build APK » ou « Forcer rebuild » puis « Installer et lancer ».",
          );
          return false;
        }
        addLog("Build OK. Attente du redémarrage du contrôleur (si lancé)...");
        const maxWaitMs = 18000;
        const pollMs = 1500;
        const start = Date.now();
        while (Date.now() - start < maxWaitMs) {
          await new Promise((r) => setTimeout(r, pollMs));
          try {
            const res = await fetch(`${controllerBase}/health`, {
              method: "GET",
              headers: { "Content-Type": "application/json" },
            });
            const data = await res.json().catch(() => ({}));
            if (data?.ok) {
              addLog("Contrôleur de nouveau disponible. Installation...");
              setControllerOk(true);
              break;
            }
          } catch {
            /* pas encore prêt */
          }
        }
        setLoading("install-run");
        result = await doInstallRun();
      }
      if (result.success) {
        setAppRunning(true);
        setApkBuilt(true);
        addLog(
          "App installée, fermée puis relancée (adb reverse activé sur ports API).",
        );
        return true;
      }
      addLog(
        result.error ??
          "Installation ou lancement échoué. Vérifiez qu’un appareil ADB est sélectionné et que le contrôleur tourne (make emulator-controller).",
      );
      return false;
    } catch (e) {
      addLog(
        `Erreur install/run: ${e instanceof Error ? e.message : String(e)}`,
      );
      return false;
    } finally {
      setLoading(null);
    }
  };

  const imgToDevice = (e: React.MouseEvent<HTMLImageElement>) => {
    const img = e.currentTarget;
    const nw = img.naturalWidth || img.width;
    const nh = img.naturalHeight || img.height;
    if (!nw || !nh) return null;
    const rect = img.getBoundingClientRect();
    const scale = Math.min(rect.width / nw, rect.height / nh);
    const rw = nw * scale;
    const rh = nh * scale;
    const lf = (rect.width - rw) / 2;
    const tp = (rect.height - rh) / 2;
    const ox = e.clientX - rect.left;
    const oy = e.clientY - rect.top;
    const x = Math.round((ox - lf) / scale);
    const y = Math.round((oy - tp) / scale);
    if (x < 0 || y < 0 || x > nw || y > nh) return null;
    return { x, y };
  };

  const onImgMouseDown = (e: React.MouseEvent<HTMLImageElement>) => {
    const pt = imgToDevice(e);
    if (pt) dragStart.current = { ...pt, time: Date.now() };
  };

  const onImgMouseUp = async (e: React.MouseEvent<HTMLImageElement>) => {
    if (!selectedDevice || !dragStart.current) return;
    const end = imgToDevice(e);
    if (!end) {
      dragStart.current = null;
      return;
    }
    const start = dragStart.current;
    dragStart.current = null;
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const dist = Math.sqrt(dx * dx + dy * dy);
    const dur = Date.now() - start.time;
    try {
      if (dist < 15) {
        await fetchJson<{ success?: boolean }>("/input-tap", {
          method: "POST",
          body: JSON.stringify({
            deviceId: selectedDevice,
            x: start.x,
            y: start.y,
          }),
        });
      } else {
        const swipeDur = Math.max(100, Math.min(dur, 1500));
        await fetchJson<{ success?: boolean }>("/input-swipe", {
          method: "POST",
          body: JSON.stringify({
            deviceId: selectedDevice,
            x1: start.x,
            y1: start.y,
            x2: end.x,
            y2: end.y,
            duration: swipeDur,
          }),
        });
      }
    } catch (err) {
      addLog(`Input: ${err instanceof Error ? err.message : String(err)}`);
    }
  };

  const stopApp = async () => {
    if (!selectedDevice) return;
    setLoading("stop-app");
    try {
      await fetchJson<{ success?: boolean }>("/input-keyevent", {
        method: "POST",
        body: JSON.stringify({ deviceId: selectedDevice, keycode: 3 }),
      });
      setAppRunning(false);
      addLog("Application arretee (HOME)");
      cancelJourneyRef.current?.();
      setJourneyRunning(false);
    } catch (e) {
      addLog(`Erreur stop: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setLoading(null);
    }
  };

  const restartApp = async () => {
    if (!selectedDevice) return;
    setLoading("restart-app");
    const baseUrl = base().replace(/\/$/, "");
    const androidPackage = "cloud.hubera.jobs";
    try {
      const res = await fetch(`${baseUrl}/force-restart-app`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deviceId: selectedDevice }),
      });
      if (res.status === 404) {
        addLog("Relance via adb-shell (route force-restart-app absente)...");
        await fetch(`${baseUrl}/adb-shell`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            deviceId: selectedDevice,
            command: `am force-stop ${androidPackage}`,
          }),
        });
        await new Promise((r) => setTimeout(r, 500));
        const startRes = await fetch(`${baseUrl}/adb-shell`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            deviceId: selectedDevice,
            command: `am start -n ${androidPackage}/.MainActivity`,
          }),
        });
        const startData = await startRes.json().catch(() => ({}));
        if (startData.success) {
          setAppRunning(true);
          addLog("Application fermée et relancée (adb-shell).");
        } else {
          addLog("Erreur am start: " + (startData.error || ""));
        }
      } else {
        const data = await res.json().catch(() => ({}));
        if (data.success) {
          setAppRunning(true);
          addLog(data.message || "Application fermée et relancée");
        } else {
          addLog(data.error || "Erreur");
        }
      }
    } catch (e) {
      addLog(`Erreur restart: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setLoading(null);
    }
  };

  const runFlutter = async () => {
    const deviceId = selectedFlutterDevice || selectedDevice;
    if (!deviceId) {
      addLog("Selectionnez un appareil.");
      return;
    }
    setLoading("run-flutter");
    addLog("Lancement Flutter (build + run)...");
    try {
      const data = await fetchJson<{
        success?: boolean;
        error?: string;
        stdout?: string;
        stderr?: string;
      }>("/run-flutter", {
        method: "POST",
        body: JSON.stringify({ deviceId }),
      });
      addLog(data.success ? "Flutter run demarre." : data.error || "Erreur");
      if (data.stdout) addLog(data.stdout.slice(-500));
      if (data.stderr) addLog(data.stderr.slice(-500));
    } catch (e) {
      addLog(`Erreur run: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setLoading(null);
    }
  };

  useEffect(() => {
    let cancelled = false;

    const revokeBlob = () => {
      if (screenshotBlobRef.current) {
        URL.revokeObjectURL(screenshotBlobRef.current);
        screenshotBlobRef.current = null;
      }
    };

    const stopLive = (deviceId: string) => {
      if (!deviceId) return;
      fetch(
        `${base()}/live/stop?device=${encodeURIComponent(deviceId)}`,
      ).catch(() => {});
    };

    if (!selectedDevice || !controllerOk || (!journeyRunning && !liveViewOn)) {
      revokeBlob();
      setScreenshotUrl(null);
      stopLive(selectedDevice);
      return;
    }

    // Flux MJPEG continu (beaucoup plus fluide que le polling PNG).
    fetch(
      `${base()}/live/start?device=${encodeURIComponent(selectedDevice)}`,
    ).catch(() => {});
    revokeBlob();
    setScreenshotUrl(
      `${base()}/mjpeg?device=${encodeURIComponent(selectedDevice)}&t=${Date.now()}`,
    );

    return () => {
      cancelled = true;
      revokeBlob();
      stopLive(selectedDevice);
      void cancelled;
    };
  }, [selectedDevice, controllerOk, controllerUrl, journeyRunning, liveViewOn]);

  useEffect(() => {
    if (loading !== "build") return;
    const interval = setInterval(
      () => setBuildElapsedSeconds((s) => s + 1),
      1000,
    );
    return () => clearInterval(interval);
  }, [loading]);

  return (
    <AdminLayout>
      {/* Overlay pendant le build APK : bloque navigation et clics (sauf Annuler) */}
      {loading === "build" && (
        <div
          className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/60 backdrop-blur-sm"
          aria-modal="true"
          role="dialog"
          aria-label="Build APK en cours"
        >
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl p-8 max-w-md mx-4 flex flex-col items-center gap-6">
            <Loader2 className="h-12 w-12 animate-spin text-amber-500" />
            <p className="text-lg font-medium text-gray-900 dark:text-gray-100 text-center">
              Build APK en cours...
            </p>
            <p className="text-sm text-gray-600 dark:text-gray-400 text-center font-mono tabular-nums">
              Écoulé : {Math.floor(buildElapsedSeconds / 60)}:
              {String(buildElapsedSeconds % 60).padStart(2, "0")}
            </p>
            <ul className="text-left text-sm text-gray-600 dark:text-gray-400 space-y-1 list-disc list-inside">
              <li>Nettoyage du projet (flutter clean)</li>
              <li>Compilation Gradle (1 à 2 min)</li>
              <li>Génération de l’APK debug</li>
            </ul>
            <p className="text-xs text-gray-500 dark:text-gray-500 text-center">
              Ne fermez pas cette page. Vous ne pouvez pas naviguer tant que le
              build n&apos;est pas terminé ou annulé.
            </p>
            <button
              type="button"
              onClick={cancelBuild}
              className="px-6 py-3 rounded-lg bg-red-600 text-white font-medium hover:bg-red-700 transition"
            >
              Annuler le build
            </button>
          </div>
        </div>
      )}
      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-bold text-gray-900 dark:text-gray-100 flex items-center gap-2">
            <Smartphone className="h-8 w-8" />
            Emulateur mobile - Android
          </h1>
          <p className="text-gray-600 dark:text-gray-400 mt-1">
            Selectionnez un <strong>emulateur</strong> ou un{" "}
            <strong>telephone connecte</strong> (USB / adb), lancez l&apos;app
            et voyez le <strong>rendu en direct</strong>.
          </p>
        </div>

        <div className="bg-white dark:bg-gray-900 rounded-xl shadow-sm dark:shadow-none dark:ring-1 dark:ring-gray-800 p-6 space-y-4">
          <div className="flex flex-wrap items-center gap-4">
            <div className="flex-1 min-w-[200px]">
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-400 mb-1">
                URL du controleur
              </label>
              <input
                type="text"
                value={controllerUrl}
                onChange={(e) => setControllerUrl(e.target.value)}
                placeholder="http://localhost:5055"
                className="w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 dark:text-gray-100 text-sm focus:ring-2 focus:ring-indigo-500 dark:focus:ring-indigo-400 focus:border-transparent transition"
              />
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                Même hôte que la page (ex. si vous ouvrez 127.0.0.1:5003, mettez
                127.0.0.1:5055)
              </p>
            </div>
            <div className="flex items-center gap-2 flex-wrap">
              {controllerOk === true && (
                <Wifi className="h-5 w-5 text-emerald-500" />
              )}
              {controllerOk === false && (
                <WifiOff className="h-5 w-5 text-red-500" />
              )}
              <button
                type="button"
                onClick={checkHealth}
                disabled={loading !== null}
                data-testid="btn-verify-controller"
                className="px-3 py-2 rounded-lg bg-gray-200 dark:bg-gray-800 text-gray-800 dark:text-gray-200 text-sm font-medium disabled:opacity-50 flex items-center gap-2 hover:bg-gray-300 dark:hover:bg-gray-700 transition"
              >
                <RefreshCw className="h-4 w-4" /> Verifier
              </button>
              {controllerOk === false && (
                <button
                  type="button"
                  onClick={startController}
                  disabled={loading !== null}
                  className="px-3 py-2 rounded-lg bg-emerald-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2 hover:bg-emerald-700 transition"
                  title="Démarre le contrôleur (nécessite que le lanceur tourne : make emulator-controller une fois)"
                >
                  {loading === "start-controller" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}{" "}
                  Démarrer le contrôleur
                </button>
              )}
              {controllerOk === true && (
                <>
                  <button
                    type="button"
                    onClick={stopController}
                    disabled={loading !== null}
                    className="px-3 py-2 rounded-lg bg-red-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2 hover:bg-red-700 transition"
                    title="Arrête le contrôleur (relance possible via Démarrer le contrôleur)"
                  >
                    {loading === "stop-controller" ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <Square className="h-4 w-4" />
                    )}{" "}
                    Arrêter le contrôleur
                  </button>
                  <button
                    type="button"
                    onClick={async () => {
                      try {
                        const r = await fetch(`${base()}/restart`, {
                          method: "POST",
                          headers: { "Content-Type": "application/json" },
                          body: "{}",
                        });
                        const d = await r.json().catch(() => ({}));
                        if (d.success) {
                          setControllerOk(false);
                          addLog(
                            "Contrôleur en redémarrage (automatique dans quelques secondes).",
                          );
                          setTimeout(checkHealth, 4000);
                        }
                      } catch (e) {
                        addLog(
                          "Erreur restart: " +
                            (e instanceof Error ? e.message : String(e)),
                        );
                      }
                    }}
                    disabled={loading !== null}
                    className="px-3 py-2 rounded-lg bg-amber-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2 hover:bg-amber-700 transition"
                    title="Redémarre le contrôleur (charge la dernière version du code)"
                  >
                    Redémarrer contrôleur
                  </button>
                </>
              )}
            </div>
          </div>

          {controllerOk && (
            <>
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-400 mb-1">
                    AVD
                  </label>
                  <select
                    value={selectedAvd}
                    onChange={(e) => setSelectedAvd(e.target.value)}
                    className="w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 dark:text-gray-100 text-sm"
                  >
                    <option value="">-- Choisir un AVD --</option>
                    {avds.map((a) => (
                      <option key={a.name} value={a.name}>
                        {a.name}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={loadAvds}
                    disabled={loading === "avds"}
                    className="mt-1 text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
                  >
                    {loading === "avds" ? "Chargement..." : "Rafraichir AVD"}
                  </button>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-400 mb-1">
                    Appareil ADB
                  </label>
                  <select
                    value={selectedDevice}
                    onChange={(e) => setSelectedDevice(e.target.value)}
                    className="w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 dark:text-gray-100 text-sm"
                  >
                    <option value="">-- Choisir --</option>
                    {devices.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.id} ({d.status})
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={loadDevices}
                    disabled={loading === "devices"}
                    className="mt-1 text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
                  >
                    {loading === "devices" ? "Chargement..." : "Rafraichir"}
                  </button>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-400 mb-1">
                    Appareil Flutter
                  </label>
                  <select
                    value={selectedFlutterDevice}
                    onChange={(e) => setSelectedFlutterDevice(e.target.value)}
                    className="w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 dark:text-gray-100 text-sm"
                  >
                    <option value="">-- Meme ou choisir --</option>
                    {flutterDevices.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.name} ({d.id})
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={loadFlutterDevices}
                    disabled={loading === "flutter-devices"}
                    className="mt-1 text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
                  >
                    {loading === "flutter-devices"
                      ? "Chargement..."
                      : "Rafraichir"}
                  </button>
                </div>
              </div>

              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={startAvd}
                  disabled={!selectedAvd || loading !== null}
                  data-testid="btn-start-avd"
                  className="px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {loading === "start-avd" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}{" "}
                  Demarrer AVD
                </button>
                <span className="flex items-center gap-1">
                  <button
                    type="button"
                    onClick={buildApk}
                    disabled={loading !== null || buildNeeded === false}
                    data-testid="btn-build-apk"
                    title={
                      buildNeeded === false
                        ? "APK déjà à jour (code mobile inchangé)"
                        : undefined
                    }
                    className="px-4 py-2 rounded-lg bg-amber-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                  >
                    {loading === "build" ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : null}{" "}
                    {buildNeeded === false ? "APK à jour" : "Build APK"}
                  </button>
                  {buildNeeded === false && (
                    <button
                      type="button"
                      onClick={buildApk}
                      disabled={loading !== null}
                      data-testid="btn-force-rebuild"
                      title="Forcer un rebuild de l’APK"
                      className="px-3 py-2 rounded-lg bg-amber-500/80 text-white text-sm font-medium hover:bg-amber-500 disabled:opacity-50 flex items-center gap-1"
                    >
                      {loading === "build" ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <RefreshCw className="h-4 w-4" />
                      )}{" "}
                      Forcer rebuild
                    </button>
                  )}
                </span>
                <button
                  type="button"
                  onClick={installAndRun}
                  disabled={!selectedDevice || loading !== null || appRunning}
                  data-testid="btn-install-run"
                  title={
                    appRunning
                      ? "App en cours — arretez d'abord"
                      : "Installer l’APK puis lancer l’app"
                  }
                  className="px-4 py-2 rounded-lg bg-green-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {loading === "install-run" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : loading === "build" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}{" "}
                  Installer et lancer
                </button>
                <button
                  type="button"
                  onClick={launchOnly}
                  disabled={!selectedDevice || loading !== null || appRunning}
                  data-testid="btn-launch-only"
                  title={
                    appRunning
                      ? "App déjà en cours"
                      : "Lancer l’app sans réinstaller (déjà installée)"
                  }
                  className="px-4 py-2 rounded-lg bg-emerald-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {loading === "launch-only" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}{" "}
                  Lancer seulement
                </button>
                <button
                  type="button"
                  onClick={uninstallApp}
                  disabled={!selectedDevice || loading !== null}
                  data-testid="btn-uninstall-app"
                  title="Désinstaller l'app du périphérique (réinstaller avec Installer et lancer)"
                  className="px-4 py-2 rounded-lg bg-gray-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {loading === "uninstall" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Trash2 className="h-4 w-4" />
                  )}{" "}
                  Désinstaller l'app
                </button>
                <button
                  type="button"
                  onClick={runFlutter}
                  disabled={
                    (!selectedDevice && !selectedFlutterDevice) ||
                    loading !== null ||
                    !apkBuilt ||
                    appRunning
                  }
                  title={
                    appRunning
                      ? "App en cours - arretez d'abord"
                      : !apkBuilt
                        ? "Build APK d'abord"
                        : ""
                  }
                  className="px-4 py-2 rounded-lg bg-teal-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {loading === "run-flutter" ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}{" "}
                  Flutter run
                </button>
                {appRunning && (
                  <>
                    <button
                      type="button"
                      onClick={stopApp}
                      disabled={loading !== null}
                      data-testid="btn-stop-app"
                      className="px-4 py-2 rounded-lg bg-red-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                    >
                      {loading === "stop-app" ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Square className="h-4 w-4" />
                      )}{" "}
                      Arreter
                    </button>
                    <button
                      type="button"
                      onClick={restartApp}
                      disabled={loading !== null}
                      data-testid="btn-restart-app"
                      className="px-4 py-2 rounded-lg bg-orange-600 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                    >
                      {loading === "restart-app" ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <RefreshCw className="h-4 w-4" />
                      )}{" "}
                      Relancer
                    </button>
                  </>
                )}
              </div>

              <div
                className="mt-4 pt-4 border-t border-gray-200 dark:border-gray-700"
                data-testid="section-cleanup-account"
              >
                <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
                  <UserMinus className="h-4 w-4" /> Nettoyer un compte test
                </h3>
                <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
                  Liste des comptes en base (comptes admin exclus). Choisissez
                  un utilisateur puis supprimez-le pour refaire une inscription
                  ou retester la vérification email.
                </p>
                <div className="flex flex-wrap items-center gap-2">
                  <select
                    value={cleanupSelectedUserId}
                    onChange={(e) => setCleanupSelectedUserId(e.target.value)}
                    disabled={cleanupUsersLoading}
                    className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 dark:text-gray-100 text-sm min-w-[220px]"
                  >
                    <option value="">
                      {cleanupUsersLoading
                        ? "Chargement..."
                        : cleanupUsers.length === 0
                          ? "Aucun utilisateur"
                          : "— Choisir —"}
                    </option>
                    {cleanupUsers.map((u) => (
                      <option key={u.id} value={u.id}>
                        {u.email}
                        {u.firstName || u.lastName
                          ? ` (${[u.firstName, u.lastName].filter(Boolean).join(" ")})`
                          : ""}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={loadCleanupUsers}
                    disabled={!token || cleanupUsersLoading}
                    className="px-3 py-2 rounded-lg bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-200 text-sm font-medium disabled:opacity-50 flex items-center gap-1"
                  >
                    {cleanupUsersLoading ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <RefreshCw className="h-4 w-4" />
                    )}
                    Rafraîchir
                  </button>
                  <button
                    type="button"
                    onClick={deleteUserByEmail}
                    disabled={
                      !token || !cleanupSelectedUserId || loading !== null
                    }
                    className="px-4 py-2 rounded-lg bg-red-700 hover:bg-red-800 text-white text-sm font-medium disabled:opacity-50 flex items-center gap-2"
                  >
                    {loading === "cleanup-user" ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <Trash2 className="h-4 w-4" />
                    )}
                    Supprimer l&apos;utilisateur
                  </button>
                </div>
              </div>
            </>
          )}

          {controllerOk === false && (
            <div className="rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 p-4 text-sm text-amber-800 dark:text-amber-200">
              <p className="font-medium">Contrôleur arrêté ou non connecté</p>
              <p className="mt-1">
                Cliquez sur <strong>Démarrer le contrôleur</strong> ci-dessus.
                Une fois :{" "}
                <code className="bg-amber-100 dark:bg-amber-900/40 px-1 rounded">
                  make emulator-controller
                </code>{" "}
                dans un terminal.
              </p>
            </div>
          )}
        </div>

        {controllerOk && selectedDevice && (
          <div className="bg-white dark:bg-gray-900 rounded-xl shadow-sm dark:shadow-none dark:ring-1 dark:ring-gray-800 p-6">
            <div className="flex flex-col lg:flex-row gap-6">
              <div className="flex-1 min-w-0">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100 flex items-center gap-2 mb-3 flex-wrap">
                  <ImageIcon className="h-5 w-5 text-indigo-500" /> Rendu en
                  direct
                  <span className="text-xs font-normal text-gray-500 dark:text-gray-500 ml-2">
                    clic = tap | glisser = scroll/swipe
                  </span>
                  <label className="ml-auto flex items-center gap-2 text-sm font-medium text-indigo-700 dark:text-indigo-300 cursor-pointer bg-indigo-50 dark:bg-indigo-950/40 px-3 py-1.5 rounded-lg border border-indigo-200 dark:border-indigo-800">
                    <input
                      type="checkbox"
                      checked={liveViewOn}
                      onChange={(e) => setLiveViewOn(e.target.checked)}
                      className="rounded border-gray-300 dark:border-gray-600"
                    />
                    Aperçu live appareil ADB
                  </label>
                </h2>
                <div
                  className="rounded-2xl border-2 border-gray-300 dark:border-gray-700 overflow-hidden bg-black inline-block max-w-full cursor-crosshair select-none shadow-lg dark:shadow-black/50"
                  onContextMenu={(e) => e.preventDefault()}
                >
                  {screenshotUrl ? (
                    <img
                      src={screenshotUrl}
                      alt="Ecran appareil"
                      className="block max-h-[70vh] w-auto object-contain select-none pointer-events-auto"
                      style={{ imageRendering: "auto" }}
                      draggable={false}
                      onMouseDown={onImgMouseDown}
                      onMouseUp={onImgMouseUp}
                    />
                  ) : (
                    <div className="w-[360px] h-[640px] flex items-center justify-center text-gray-500 text-center px-4 text-sm">
                      {journeyRunning
                        ? "Rafraichissement..."
                        : "Sélectionnez un appareil ADB puis laissez « Aperçu live » coché pour le rendu en direct."}
                    </div>
                  )}
                </div>
                <div className="mt-3 flex gap-2">
                  <button
                    type="button"
                    onClick={() =>
                      fetchJson("/input-keyevent", {
                        method: "POST",
                        body: JSON.stringify({
                          deviceId: selectedDevice,
                          keycode: 4,
                        }),
                      }).catch(() => {})
                    }
                    className="px-3 py-1.5 rounded-lg bg-gray-200 dark:bg-gray-800 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-700 transition"
                  >
                    Back
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      fetchJson("/input-keyevent", {
                        method: "POST",
                        body: JSON.stringify({
                          deviceId: selectedDevice,
                          keycode: 3,
                        }),
                      }).catch(() => {})
                    }
                    className="px-3 py-1.5 rounded-lg bg-gray-200 dark:bg-gray-800 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-700 transition"
                  >
                    Home
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      fetchJson("/input-keyevent", {
                        method: "POST",
                        body: JSON.stringify({
                          deviceId: selectedDevice,
                          keycode: 187,
                        }),
                      }).catch(() => {})
                    }
                    className="px-3 py-1.5 rounded-lg bg-gray-200 dark:bg-gray-800 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-700 transition"
                  >
                    Recents
                  </button>
                </div>
              </div>
              {journeyRunning && journeyStepResults.length > 0 && (
                <div className="w-full lg:w-72 flex-shrink-0">
                  <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100 mb-2 flex items-center gap-2">
                    Étapes du parcours ({journeyProgress.current}/
                    {journeyProgress.total})
                  </h3>
                  <ul className="space-y-1 max-h-[60vh] overflow-y-auto rounded-lg bg-gray-100 dark:bg-gray-800 p-2 text-xs font-medium">
                    {journeyStepResults.map((s, i) => (
                      <li
                        key={i}
                        className={`flex items-center gap-2 px-2 py-1.5 rounded ${s.status === "running" ? "bg-amber-200 dark:bg-amber-900/50 text-amber-900 dark:text-amber-200" : s.status === "success" ? "text-emerald-700 dark:text-emerald-400" : s.status === "error" ? "text-red-700 dark:text-red-400" : "text-gray-600 dark:text-gray-400"}`}
                      >
                        {s.status === "running" && (
                          <Loader2 className="h-3 w-3 animate-spin flex-shrink-0" />
                        )}
                        {s.status === "success" && (
                          <span className="text-emerald-500">✓</span>
                        )}
                        {s.status === "error" && (
                          <span className="text-red-500">✗</span>
                        )}
                        <span className="truncate">{s.name || s.id}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          </div>
        )}

        <div className="bg-white dark:bg-gray-900 rounded-xl shadow-sm dark:shadow-none dark:ring-1 dark:ring-gray-800 p-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100 flex items-center gap-2">
              <Monitor className="h-5 w-5 text-emerald-500" /> Logs
            </h2>
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={async () => {
                  if (logs.length === 0) return;
                  try {
                    await navigator.clipboard.writeText(logs.join("\n"));
                    setLogsCopied(true);
                    setTimeout(() => setLogsCopied(false), 2000);
                  } catch {}
                }}
                disabled={logs.length === 0}
                className="text-sm text-gray-600 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 disabled:opacity-50 transition"
              >
                {logsCopied ? "Copie !" : "Copier"}
              </button>
              <button
                type="button"
                onClick={() => setLogs([])}
                className="text-sm text-gray-600 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-300 transition"
              >
                Effacer
              </button>
            </div>
          </div>
          <div className="bg-gray-950 text-emerald-400 font-mono text-sm p-4 rounded-lg h-48 overflow-y-auto select-text ring-1 ring-gray-800">
            {logs.length === 0 ? (
              <div className="text-gray-600">Aucun log.</div>
            ) : (
              logs.map((log, i) => (
                <div key={i} className="mb-0.5">
                  {log}
                </div>
              ))
            )}
          </div>
          <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">
            En dev, la console navigateur peut afficher des avertissements CSS
            (layout.css), un preload font non utilisé, ou NS_BINDING_ABORTED sur
            les screenshots ; ils sont sans impact et le build APK / install-run
            fonctionnent normalement.
          </p>
        </div>

        <MobileJourneyPanel
          addLog={addLog}
          controllerUrl={controllerUrl}
          deviceId={selectedDevice}
          authToken={token}
          onJourneyRunningChange={setJourneyRunning}
          stepResults={journeyStepResults}
          progress={journeyProgress}
          onStepResultsChange={setJourneyStepResults}
          onProgressChange={setJourneyProgress}
          controllerOk={controllerOk}
          apkBuilt={apkBuilt}
          appRunning={appRunning}
          cancelJourneyRef={cancelJourneyRef}
          onEnsureAppReady={ensureBuildAndInstall}
        />
      </div>
    </AdminLayout>
  );
}

/* ------------------------------------------------------------------ */
/* Parcours utilisateur mobile - utilise @/lib/adb                    */
/* ------------------------------------------------------------------ */

function MobileJourneyPanel({
  addLog,
  controllerUrl,
  deviceId,
  authToken,
  onJourneyRunningChange,
  stepResults: externalStepResults,
  progress: externalProgress,
  onStepResultsChange,
  onProgressChange,
  controllerOk,
  apkBuilt,
  appRunning,
  cancelJourneyRef,
  onEnsureAppReady,
}: {
  addLog: (m: string) => void;
  controllerUrl: string;
  deviceId: string;
  authToken: string | null;
  onJourneyRunningChange: (running: boolean) => void;
  stepResults?: StepResult[];
  progress?: { current: number; total: number };
  onStepResultsChange?: (
    r: StepResult[] | ((prev: StepResult[]) => StepResult[]),
  ) => void;
  onProgressChange?: (p: { current: number; total: number }) => void;
  controllerOk?: boolean | null;
  apkBuilt?: boolean;
  appRunning?: boolean;
  cancelJourneyRef?: React.MutableRefObject<(() => void) | null>;
  onEnsureAppReady?: () => Promise<boolean>;
}) {
  const [showParcoursConfig, setShowParcoursConfig] = useState(false);
  const [e2eRunning, setE2eRunning] = useState(false);
  const [e2eOutput, setE2eOutput] = useState<string | null>(null);
  const [e2eSuccess, setE2eSuccess] = useState<boolean | null>(null);
  const [selected, setSelected] = useState("mobile_register_verify_gmail");
  const [categoryFilter, setCategoryFilter] = useState<string>("all");
  const [cleanUserBetweenScenarios, setCleanUserBetweenScenarios] =
    useState(false);
  const [running, setRunning] = useState(false);
  const [localStepResults, setLocalStepResults] = useState<StepResult[]>([]);
  const [localProgress, setLocalProgress] = useState({ current: 0, total: 0 });
  const stepResults = externalStepResults ?? localStepResults;
  const setStepResults = onStepResultsChange ?? setLocalStepResults;
  const progress = externalProgress ?? localProgress;
  const setProgress = onProgressChange ?? setLocalProgress;
  const runnerRef = useRef<AdbRunner | null>(null);

  const scenario = MOBILE_SCENARIOS[selected];

  const filteredScenarios = Object.entries(MOBILE_SCENARIOS).filter(
    ([, s]) => categoryFilter === "all" || s.category === categoryFilter,
  );

  const runJourney = async () => {
    if (!scenario || running) return;
    if (!deviceId) {
      addLog("Selectionnez un appareil ADB avant de lancer un parcours");
      return;
    }
    onJourneyRunningChange(true);

    if (onEnsureAppReady) {
      addLog("Build APK + installation avant de lancer le parcours...");
      const ready = await onEnsureAppReady();
      if (!ready) {
        addLog(
          "App non prête (build ou installation échoué). Parcours annulé.",
        );
        onJourneyRunningChange(false);
        return;
      }
      addLog("App prête. Démarrage des étapes du parcours.");
    }

    if (selected === "mobile_complete_with_data") {
      if (!authToken) {
        addLog(
          "Erreur: connectez-vous en tant qu'admin pour generer les donnees avant de lancer ce parcours.",
        );
        onJourneyRunningChange(false);
        return;
      }
      addLog(
        `Generation des donnees de test (preset mobile) pour ${getMobileTestCredentials().email}...`,
      );
      try {
        const proxyUrl = "/api/emulator-proxy/generate-test-data";
        const res = await fetch(proxyUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${authToken}`,
          },
          body: JSON.stringify({ preset: "mobile" }),
        });
        const data = await res.json().catch(() => ({}));
        if (data.success) {
          addLog(
            `Donnees de test generees. Connexion en tant que ${getMobileTestCredentials().email} (${getMobileTestCredentials().password === "password123" ? "password123" : "***"})...`,
          );
        } else {
          addLog(
            "Erreur: generation des donnees echouee — " +
              (data.error || "reponse invalide") +
              ". Parcours annule.",
          );
          onJourneyRunningChange(false);
          return;
        }
      } catch (e) {
        addLog(
          "Erreur: API generate-test-data — " +
            (e instanceof Error ? e.message : String(e)) +
            ". Parcours annule.",
        );
        onJourneyRunningChange(false);
        return;
      }
    }

    // Nettoyage utilisateur de test (uniquement si option activée et scénario inscription + vérif email)
    const apiBase = FRONTEND_URLS.api;
    if (
      VERIFICATION_EMAIL_SCENARIO_KEYS.includes(selected) &&
      cleanUserBetweenScenarios &&
      authToken
    ) {
      const emailMap: Record<string, string> = {
        mobile_register_verify_gmail: VERIFICATION_EMAIL_ACCOUNTS.gmail.email,
        mobile_register_verify_proton: VERIFICATION_EMAIL_ACCOUNTS.proton.email,
        mobile_register_verify_bluemail:
          VERIFICATION_EMAIL_ACCOUNTS.bluemail.email,
      };
      const emailToClean = emailMap[selected];
      if (emailToClean) {
        try {
          const usersRes = await fetch(`${apiBase}/api/v1/auth/users`, {
            headers: { Authorization: `Bearer ${authToken}` },
          });
          const usersData = await usersRes.json().catch(() => ({}));
          const users = usersData?.users ?? usersData?.data ?? [];
          const user = Array.isArray(users)
            ? users.find((u: { email?: string }) => u.email === emailToClean)
            : null;
          if (user?.id) {
            const delRes = await fetch(
              `${apiBase}/api/v1/auth/users/${user.id}`,
              {
                method: "DELETE",
                headers: { Authorization: `Bearer ${authToken}` },
              },
            );
            if (delRes.ok) {
              addLog(
                `Utilisateur de test supprime (${emailToClean}) pour repartir propre.`,
              );
            } else {
              addLog(
                `Suppression utilisateur ${emailToClean} echouee: ${delRes.status}`,
              );
            }
          } else {
            addLog(
              `Aucun utilisateur trouve pour ${emailToClean}, on continue.`,
            );
          }
        } catch (e) {
          addLog(
            "Nettoyage utilisateur: " +
              (e instanceof Error ? e.message : String(e)),
          );
        }
      }
    }

    const baseUrl = controllerUrl.replace(/\/$/, "");
    const androidPackage = "cloud.hubera.jobs";
    addLog("Fermeture et relance de l'app pour afficher le bon ecran...");
    try {
      const res = await fetch(`${baseUrl}/force-restart-app`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deviceId }),
      });
      if (res.status === 404) {
        addLog(
          "Route /force-restart-app absente (controleur ancien) : relance via adb-shell...",
        );
        const stopRes = await fetch(`${baseUrl}/adb-shell`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            deviceId,
            command: `am force-stop ${androidPackage}`,
          }),
        });
        const stopData = await stopRes.json().catch(() => ({}));
        if (!stopData.success)
          addLog("force-stop: " + (stopData.error || "erreur"));
        await new Promise((r) => setTimeout(r, 800));
        const startRes = await fetch(`${baseUrl}/adb-shell`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            deviceId,
            command: `am start -n ${androidPackage}/.MainActivity`,
          }),
        });
        const startData = await startRes.json().catch(() => ({}));
        if (startData.success) {
          addLog("App relancee via adb-shell, attente 6s (uiautomator)...");
          await new Promise((r) => setTimeout(r, 6000));
        } else {
          addLog(
            "Attention: " +
              (startData.error || "am start echoue") +
              " - parcours lance quand meme.",
          );
        }
      } else {
        const data = await res.json().catch(() => ({}));
        if (data.success) {
          addLog(
            "App relancee, attente 6s que l'ecran et uiautomator soient prêts...",
          );
          await new Promise((r) => setTimeout(r, 6000));
        } else {
          addLog(
            "Attention: " +
              (data.error || "relance app echouee") +
              " - parcours lance quand meme.",
          );
        }
      }
    } catch (e) {
      addLog(
        "Relance app: " +
          (e instanceof Error ? e.message : String(e)) +
          " - parcours lance quand meme.",
      );
    }

    const runner = new AdbRunner(controllerUrl, deviceId, addLog);
    runnerRef.current = runner;
    if (cancelJourneyRef)
      cancelJourneyRef.current = () => runnerRef.current?.cancel();
    setRunning(true);
    setProgress({ current: 0, total: scenario.steps.length });
    setStepResults(
      scenario.steps.map((id) => ({
        id,
        name: STEP_LABELS[id] || id.replace(/_/g, " "),
        status: "pending" as const,
      })),
    );

    try {
      await runner.run(scenario, {
        onStepStart: (i) => {
          setStepResults((prev) =>
            prev.map((s, idx) =>
              idx === i ? { ...s, status: "running" as const } : s,
            ),
          );
        },
        onProgress: (current, total) => setProgress({ current, total }),
        onStepEnd: (i, result) => {
          setStepResults((prev) =>
            prev.map((s, idx) => (idx === i ? result : s)),
          );
        },
      });
    } finally {
      if (cancelJourneyRef) cancelJourneyRef.current = null;
      setRunning(false);
      runnerRef.current = null;
      onJourneyRunningChange(false);
    }
  };

  const catColors: Record<string, string> = {
    auth: "bg-indigo-500",
    navigation: "bg-blue-500",
    crud: "bg-emerald-500",
    verification: "bg-purple-500",
    complet: "bg-amber-500",
  };

  const runE2eTests = async () => {
    setE2eRunning(true);
    setE2eOutput(null);
    setE2eSuccess(null);
    try {
      const baseURL =
        typeof window !== "undefined"
          ? window.location.origin
          : "http://localhost:5003";
      const apiURL = FRONTEND_URLS.api;
      const res = await fetch("/api/test/run-playwright-mobile-email", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ baseURL, apiURL }),
      });
      const data = await res.json().catch(() => ({}));
      setE2eSuccess(!!data.success);
      setE2eOutput(data.output ?? data.error ?? "Aucune sortie.");
    } catch (e) {
      setE2eSuccess(false);
      setE2eOutput(e instanceof Error ? e.message : "Erreur réseau");
    } finally {
      setE2eRunning(false);
    }
  };

  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-xl dark:ring-1 dark:ring-indigo-500/20 p-6 text-sm">
      <h3 className="font-semibold mb-3 text-gray-900 dark:text-indigo-300 flex items-center gap-2">
        <Smartphone className="h-4 w-4" /> Parcours utilisateur mobile
        <span className="text-[10px] font-normal px-2 py-0.5 rounded-full bg-indigo-200 dark:bg-indigo-900 text-indigo-700 dark:text-indigo-400">
          interaction UI reelle
        </span>
        <span className="text-[10px] font-normal text-gray-500 dark:text-gray-500 ml-auto">
          {Object.keys(MOBILE_SCENARIOS).length} parcours
        </span>
      </h3>
      <p className="text-[11px] text-gray-600 dark:text-gray-400 mb-2">
        Les tests mobile passent par ces scénarios : sélectionnez un parcours
        puis <strong>Lancer le parcours</strong> pour exécuter les actions en
        direct sur l’appareil.
      </p>

      {!deviceId && (
        <div className="mb-3 p-2.5 bg-amber-100 dark:bg-amber-900/20 rounded-lg text-amber-800 dark:text-amber-300 text-xs ring-1 ring-amber-300 dark:ring-amber-700/50">
          Selectionnez un appareil ADB ci-dessus pour activer les parcours.
        </div>
      )}
      {deviceId && controllerOk !== true && (
        <div className="mb-3 p-2.5 bg-amber-100 dark:bg-amber-900/20 rounded-lg text-amber-800 dark:text-amber-300 text-xs ring-1 ring-amber-300 dark:ring-amber-700/50">
          Contrôleur injoignable. Cliquez sur « Verifier » ou relancez : make
          emulator-controller
        </div>
      )}
      {deviceId && controllerOk === true && !apkBuilt && (
        <div className="mb-3 p-2.5 bg-amber-100 dark:bg-amber-900/20 rounded-lg text-amber-800 dark:text-amber-300 text-xs ring-1 ring-amber-300 dark:ring-amber-700/50">
          Faites « Build APK » puis « Installer et lancer » avant de lancer un
          parcours.
        </div>
      )}
      {deviceId && controllerOk === true && apkBuilt && !appRunning && (
        <div className="mb-3 p-2.5 bg-amber-100 dark:bg-amber-900/20 rounded-lg text-amber-800 dark:text-amber-300 text-xs ring-1 ring-amber-300 dark:ring-amber-700/50">
          Cliquez sur « Installer et lancer » pour démarrer l’app sur
          l’appareil, puis lancez le parcours.
        </div>
      )}

      <div className="mb-3 p-2.5 bg-gray-100 dark:bg-gray-800/50 rounded-lg text-gray-700 dark:text-gray-300 text-xs">
        Pour tester <strong>inscription + envoi email de vérification</strong>{" "}
        (Gmail, Proton, BlueMail) <strong>en direct sur votre téléphone</strong>{" "}
        : choisissez un parcours ci-dessous, cliquez sur{" "}
        <strong>Lancer le parcours</strong>. Les actions s’exécutent en live sur
        l’appareil. Consultez{" "}
        <a
          href="/backoffice/email-monitor"
          className="text-indigo-600 dark:text-indigo-400 underline"
        >
          Email Monitor
        </a>{" "}
        (rafraîchi en temps réel) pour voir l’email envoyé ; l’utilisateur peut
        ensuite se connecter après vérification.
      </div>

      {/* Inscription + vérification email : à tester en direct sur le téléphone */}
      <div className="mb-4 p-3 bg-purple-50 dark:bg-purple-900/20 rounded-xl ring-1 ring-purple-200 dark:ring-purple-800/50">
        <p className="text-xs font-semibold text-purple-800 dark:text-purple-300 mb-2">
          Inscription + vérification email (en direct sur le téléphone)
        </p>
        <div className="flex flex-wrap gap-2 items-center">
          {VERIFICATION_EMAIL_SCENARIO_KEYS.map((key) => {
            const s = MOBILE_SCENARIOS[key];
            if (!s) return null;
            return (
              <button
                key={key}
                onClick={() => !running && setSelected(key)}
                disabled={running}
                className={`px-3 py-2 rounded-lg text-xs font-medium transition-all flex items-center gap-1.5 ${selected === key ? "bg-purple-600 text-white shadow-md ring-2 ring-purple-400" : "bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 ring-1 ring-gray-200 dark:ring-gray-700 hover:ring-purple-400"} ${running ? "opacity-50 cursor-not-allowed" : "cursor-pointer"}`}
              >
                <span className="w-1.5 h-1.5 rounded-full bg-purple-500" />
                {s.name}
              </button>
            );
          })}
          <label className="ml-auto flex items-center gap-2 text-xs text-purple-800 dark:text-purple-300 cursor-pointer">
            <input
              type="checkbox"
              checked={cleanUserBetweenScenarios}
              onChange={(e) => setCleanUserBetweenScenarios(e.target.checked)}
              className="rounded border-gray-300 dark:border-gray-600"
            />
            Nettoyer l&apos;utilisateur de test avant le parcours
          </label>
        </div>
        <p className="mt-2 text-[11px] text-purple-700 dark:text-purple-400">
          Flux attendu : Accepter les conditions → S&apos;inscrire → écran
          &quot;Vérifiez votre email&quot; → ouvrir Gmail/Proton/OVH sur
          l&apos;appareil → cliquer le lien → retour app → Se connecter →
          Dashboard. Vérifiez les envois dans{" "}
          <a href="/backoffice/email-monitor" className="underline">
            Email Monitor
          </a>{" "}
          et dans votre boîte réelle.
        </p>
      </div>

      <div className="flex flex-wrap gap-1.5 mb-2">
        <span className="text-[11px] font-medium text-gray-600 dark:text-gray-400 mr-1">
          Filtre :
        </span>
        <button
          onClick={() => setCategoryFilter("all")}
          className={`px-2.5 py-1 rounded-full text-[11px] font-medium transition ${categoryFilter === "all" ? "bg-gray-800 dark:bg-gray-200 text-white dark:text-gray-900" : "bg-gray-200 dark:bg-gray-800 text-gray-600 dark:text-gray-400 hover:bg-gray-300 dark:hover:bg-gray-700"}`}
        >
          Tous
        </button>
        {Object.entries(SCENARIO_CATEGORIES).map(([key, cat]) => (
          <button
            key={key}
            onClick={() => setCategoryFilter(key)}
            className={`px-2.5 py-1 rounded-full text-[11px] font-medium transition ${categoryFilter === key ? "bg-gray-800 dark:bg-gray-200 text-white dark:text-gray-900" : "bg-gray-200 dark:bg-gray-800 text-gray-600 dark:text-gray-400 hover:bg-gray-300 dark:hover:bg-gray-700"}`}
          >
            {cat.label}
          </button>
        ))}
      </div>

      <p className="text-[11px] text-gray-500 dark:text-gray-500 mb-2">
        Tous les parcours
      </p>
      <div className="flex flex-wrap gap-1.5 mb-4 max-h-40 overflow-y-auto">
        {filteredScenarios.map(([key, s]) => (
          <button
            key={key}
            onClick={() => !running && setSelected(key)}
            disabled={running}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-all flex items-center gap-1.5 ${selected === key ? "bg-indigo-600 text-white shadow-md shadow-indigo-600/30" : "bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 ring-1 ring-gray-200 dark:ring-gray-700 hover:ring-indigo-400 dark:hover:ring-indigo-500"} ${running ? "opacity-50 cursor-not-allowed" : "cursor-pointer"}`}
          >
            <span
              className={`w-1.5 h-1.5 rounded-full ${catColors[s.category] || "bg-gray-400"}`}
            />
            {s.name}
          </button>
        ))}
      </div>

      {scenario && (
        <div className="mb-4 p-3 bg-white dark:bg-gray-800/50 rounded-lg ring-1 ring-gray-200 dark:ring-gray-700/50">
          <div className="flex items-center justify-between mb-1">
            <span className="font-medium text-gray-900 dark:text-gray-100">
              {scenario.name}
            </span>
            <div className="flex items-center gap-2">
              <span
                className={`px-1.5 py-0.5 text-[10px] rounded-full text-white ${catColors[scenario.category] || "bg-gray-500"}`}
              >
                {SCENARIO_CATEGORIES[scenario.category]?.label ||
                  scenario.category}
              </span>
              <span className="text-xs text-gray-500 dark:text-gray-500">
                {scenario.steps.length} etapes
              </span>
            </div>
          </div>
          <p className="text-xs text-gray-600 dark:text-gray-400">
            {scenario.description}
          </p>
          <div className="mt-2 flex flex-wrap gap-1">
            {scenario.steps.map((s, i) => (
              <span
                key={i}
                className="px-1.5 py-0.5 bg-gray-100 dark:bg-gray-700/50 text-gray-600 dark:text-gray-400 rounded text-[10px]"
              >
                {STEP_LABELS[s] || s}
              </span>
            ))}
          </div>
        </div>
      )}

      <div className="flex flex-col gap-2 mb-4 sm:flex-row sm:flex-wrap sm:items-center">
        <button
          data-testid="run-journey-btn"
          onClick={runJourney}
          disabled={running || !deviceId || controllerOk !== true}
          title={
            !deviceId
              ? "Sélectionnez un appareil"
              : controllerOk !== true
                ? "Contrôleur injoignable"
                : "Build APK + installation + étapes du parcours"
          }
          className="flex w-full items-center justify-center gap-2 px-4 py-2 bg-indigo-600 text-white rounded-lg text-sm font-medium disabled:opacity-50 hover:bg-indigo-700 shadow-md shadow-indigo-600/20 transition sm:w-auto"
        >
          {running ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <Play className="h-4 w-4" />
          )}
          {running ? "En cours..." : "Lancer le parcours"}
        </button>
        {running && (
          <button
            onClick={() => {
              runnerRef.current?.cancel();
            }}
            className="flex w-full items-center justify-center gap-2 px-4 py-2 bg-red-600 text-white rounded-lg text-sm font-medium hover:bg-red-700 transition sm:w-auto"
          >
            <Square className="h-4 w-4" /> Annuler
          </button>
        )}
        <div className="flex w-full flex-wrap gap-2 sm:ml-auto sm:w-auto">
          <a
            href="/backoffice/user-journey"
            className="flex-1 px-3 py-1.5 text-center text-xs bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-700 ring-1 ring-gray-200 dark:ring-gray-700 transition sm:flex-none"
          >
            Tous les parcours
          </a>
          <a
            href="/backoffice/user-journey/custom"
            className="flex-1 px-3 py-1.5 text-center text-xs bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-700 ring-1 ring-gray-200 dark:ring-gray-700 transition sm:flex-none"
          >
            Personnalise
          </a>
          <a
            href="/backoffice/user-journey/reports"
            className="flex-1 px-3 py-1.5 text-center text-xs bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-700 ring-1 ring-gray-200 dark:ring-gray-700 transition sm:flex-none"
          >
            Rapports
          </a>
          <a
            href="/backoffice/email-monitor"
            className="flex-1 px-3 py-1.5 text-center text-xs bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-700 ring-1 ring-gray-200 dark:ring-gray-700 transition sm:flex-none"
          >
            Email Monitor
          </a>
        </div>
      </div>

      {/* Tests E2E navigateur (optionnel) */}
      <div className="mb-4 p-3 bg-amber-50 dark:bg-amber-900/10 rounded-lg ring-1 ring-amber-200 dark:ring-amber-800/50">
        <h4 className="text-xs font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
          <FlaskConical className="h-4 w-4" />
          Tests automatisés navigateur (optionnel)
        </h4>
        <p className="text-[11px] text-gray-600 dark:text-gray-400 mb-2">
          Le test principal est d’exécuter un parcours sur le téléphone
          ci-dessus. Optionnel : lancer des tests Playwright (page backoffice +
          Email Monitor) pour la CI.
        </p>
        <div className="flex flex-wrap gap-2 items-center">
          <button
            type="button"
            onClick={runE2eTests}
            disabled={e2eRunning}
            className="px-3 py-1.5 bg-amber-600 hover:bg-amber-700 disabled:opacity-50 text-white rounded-lg text-xs font-medium flex items-center gap-1.5"
          >
            {e2eRunning ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <FlaskConical className="h-4 w-4" />
            )}
            {e2eRunning ? "Tests en cours..." : "Lancer tests E2E (navigateur)"}
          </button>
          <span className="text-[11px] text-gray-500 dark:text-gray-500">
            Ou en terminal :{" "}
            <code className="bg-gray-200 dark:bg-gray-700 px-1 rounded">
              make test-e2e-mobile-email
            </code>
          </span>
        </div>
        {e2eSuccess === true && (
          <div className="mt-2 p-2 bg-green-50 dark:bg-green-900/20 rounded text-green-800 dark:text-green-300 text-xs">
            Tous les tests sont passés.
          </div>
        )}
        {e2eSuccess === false && (
          <div className="mt-2 p-2 bg-red-50 dark:bg-red-900/20 rounded text-red-800 dark:text-red-300 text-xs">
            Certains tests ont échoué.
          </div>
        )}
        {e2eOutput != null && (
          <pre className="mt-2 p-2 bg-gray-900 text-gray-100 rounded text-[10px] overflow-auto max-h-48 whitespace-pre-wrap">
            {e2eOutput}
          </pre>
        )}
      </div>

      {progress.total > 0 && (
        <div className="mb-3">
          <div className="flex items-center justify-between text-xs text-gray-600 dark:text-gray-400 mb-1">
            <span>Progression</span>
            <span>
              {progress.current}/{progress.total}
            </span>
          </div>
          <div className="w-full bg-gray-200 dark:bg-gray-800 rounded-full h-2">
            <div
              className="bg-indigo-500 h-2 rounded-full transition-all"
              style={{ width: `${(progress.current / progress.total) * 100}%` }}
            />
          </div>
        </div>
      )}

      {stepResults.length > 0 && (
        <div
          className="max-h-72 overflow-y-auto space-y-1"
          data-testid="journey-step-results"
        >
          {stepResults.map((step, i) => (
            <div
              key={i}
              data-testid={
                step.status === "success"
                  ? "step-success"
                  : step.status === "error"
                    ? "step-error"
                    : undefined
              }
              className={`flex items-center gap-2 px-2.5 py-1.5 rounded-lg text-xs ${
                step.status === "success"
                  ? "bg-emerald-50 dark:bg-emerald-900/20 text-emerald-800 dark:text-emerald-300 ring-1 ring-emerald-200 dark:ring-emerald-800/50"
                  : step.status === "error"
                    ? "bg-red-50 dark:bg-red-900/20 text-red-800 dark:text-red-300 ring-1 ring-red-200 dark:ring-red-800/50"
                    : step.status === "running"
                      ? "bg-blue-50 dark:bg-blue-900/20 text-blue-800 dark:text-blue-300 ring-1 ring-blue-200 dark:ring-blue-800/50 animate-pulse"
                      : "text-gray-500 dark:text-gray-600"
              }`}
            >
              {step.status === "success"
                ? "✅"
                : step.status === "error"
                  ? "❌"
                  : step.status === "running"
                    ? "⏳"
                    : "⬜"}
              <span className="font-medium">{step.name}</span>
              {step.message && (
                <span className="truncate text-gray-500 dark:text-gray-500 ml-auto max-w-[300px]">
                  {step.message}
                </span>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
