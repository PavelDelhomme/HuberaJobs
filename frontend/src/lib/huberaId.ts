/**
 * Hubera ID SSO Integration for HuberaJobs
 * 
 * Provides cross-app Single Sign-On via Hubera ID.
 */

const HUBERA_ID_URL = process.env.NEXT_PUBLIC_HUBERA_ID_URL || 'https://id.hubera.cloud';
const DEVICE_ID_KEY = 'hubera_device_id';
const HUBERA_SESSION_KEY = 'hubera_id_session';

export const APP_ID = 'jobs';

export interface HuberaIdSession {
  accessToken: string;
  refreshToken: string;
  userId: string;
  tenantId: string;
  email: string;
  expiresIn: number;
  linkedAt?: string;
}

export interface HuberaDetectResult {
  found: boolean;
  email?: string;
  huberaUserId?: number;
  lastSeen?: string;
  canQuickLogin?: boolean;
  reason?: string;
}

export interface HuberaQuickLoginResult {
  accessToken: string;
  refreshToken: string;
  userId: string;
  tenantId: string;
  email: string;
  expiresIn: number;
  quickLogin: boolean;
  sourceApp: string;
  targetApp: string;
}

export function getHuberaIdUrl(): string {
  return HUBERA_ID_URL.replace(/\/$/, '');
}

export function getDeviceId(): string {
  if (typeof window === 'undefined') return '';
  
  let deviceId = localStorage.getItem(DEVICE_ID_KEY);
  if (!deviceId) {
    deviceId = crypto.randomUUID();
    localStorage.setItem(DEVICE_ID_KEY, deviceId);
  }
  return deviceId;
}

export async function detectHuberaSession(): Promise<HuberaDetectResult> {
  try {
    const deviceId = getDeviceId();
    if (!deviceId) return { found: false, reason: 'no_device_id' };

    const response = await fetch(`${getHuberaIdUrl()}/auth/identity/detect`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: deviceId }),
    });

    if (!response.ok) {
      return { found: false, reason: 'api_error' };
    }

    const data = await response.json();
    return {
      found: data.found === true,
      email: data.email,
      huberaUserId: data.hubera_user_id,
      lastSeen: data.last_seen,
      canQuickLogin: data.can_quick_login === true,
      reason: data.reason,
    };
  } catch (error) {
    console.warn('[HuberaID] detect error:', error);
    return { found: false, reason: 'network_error' };
  }
}

export async function quickLoginWithHuberaId(): Promise<HuberaQuickLoginResult | null> {
  try {
    const deviceId = getDeviceId();
    if (!deviceId) return null;

    const response = await fetch(`${getHuberaIdUrl()}/auth/identity/quick-login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        device_id: deviceId,
        target_app: APP_ID,
      }),
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      console.warn('[HuberaID] quick-login failed:', errorData);
      return null;
    }

    const data = await response.json();
    
    const session: HuberaIdSession = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      userId: data.user_id,
      tenantId: data.tenant_id,
      email: data.email,
      expiresIn: data.expires_in,
      linkedAt: new Date().toISOString(),
    };
    localStorage.setItem(HUBERA_SESSION_KEY, JSON.stringify(session));

    return {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      userId: data.user_id,
      tenantId: data.tenant_id,
      email: data.email,
      expiresIn: data.expires_in,
      quickLogin: data.quick_login === true,
      sourceApp: data.source_app,
      targetApp: data.target_app,
    };
  } catch (error) {
    console.error('[HuberaID] quick-login error:', error);
    return null;
  }
}

export async function loginWithHuberaId(
  email: string,
  password: string
): Promise<HuberaIdSession | null> {
  try {
    const deviceId = getDeviceId();
    const response = await fetch(`${getHuberaIdUrl()}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        password,
        device_id: deviceId,
        app_id: APP_ID,
      }),
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new Error(errorData.error || 'Login failed');
    }

    const data = await response.json();

    if (data.requires_2fa) {
      return null;
    }

    const session: HuberaIdSession = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      userId: data.user_id,
      tenantId: data.tenant_id,
      email: email,
      expiresIn: data.expires_in,
    };

    localStorage.setItem(HUBERA_SESSION_KEY, JSON.stringify(session));
    return session;
  } catch (error) {
    console.error('[HuberaID] login error:', error);
    throw error;
  }
}

export async function linkToHuberaId(
  huberaAccessToken: string,
  localUserId: string,
  localEmail: string
): Promise<boolean> {
  try {
    const response = await fetch(`${getHuberaIdUrl()}/auth/identity/link`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${huberaAccessToken}`,
      },
      body: JSON.stringify({
        app_id: APP_ID,
        external_user_id: localUserId,
        email: localEmail,
      }),
    });

    return response.ok;
  } catch (error) {
    console.error('[HuberaID] link error:', error);
    return false;
  }
}

export function getStoredHuberaSession(): HuberaIdSession | null {
  if (typeof window === 'undefined') return null;
  try {
    const sessionRaw = localStorage.getItem(HUBERA_SESSION_KEY);
    if (!sessionRaw) return null;
    return JSON.parse(sessionRaw);
  } catch {
    return null;
  }
}

export function clearHuberaSession(): void {
  if (typeof window === 'undefined') return;
  localStorage.removeItem(HUBERA_SESSION_KEY);
}
