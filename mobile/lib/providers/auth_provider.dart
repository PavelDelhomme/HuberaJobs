import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jobbingtrack_mobile/services/admin_api_service.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/hubera_id_sso.dart';
import 'package:jobbingtrack_mobile/services/biometric_credential_store.dart';
import 'package:jobbingtrack_mobile/services/crash_reporter.dart';
import 'package:jobbingtrack_mobile/services/mobile_analytics_service.dart';
import 'package:jobbingtrack_mobile/services/push_notification_service.dart';
import 'package:jobbingtrack_mobile/services/user_session_cleanup.dart';
import 'package:jobbingtrack_mobile/models/user.dart';
import 'package:jobbingtrack_mobile/utils/admin_access.dart';

class AuthProvider with ChangeNotifier {
  User? _user;
  String? _token;
  String? _refreshToken;
  bool _isLoading = false;
  bool _handlingSessionRevoke = false;
  bool _sessionRestored = false;
  bool _restoringSession = false;
  bool _tokenStale = false;
  String? _impersonatorToken;
  User? _impersonatorUser;
  String? _impersonatorRefreshToken;
  String? _impersonationReturnRoute;

  AuthProvider() {
    _wireSecurityCallbacks();
  }

  User? get user => _user;
  String? get token => _token;
  bool get isLoading => _isLoading;
  bool get sessionRestored => _sessionRestored;
  bool get tokenStale => _tokenStale;

  /// Restaure la session depuis le stockage chiffré (splash / cold start).
  /// Mode offline-first : pas de déconnexion si le réseau est absent.
  Future<bool> restoreSession() async {
    if (_sessionRestored) return isAuthenticated;
    _sessionRestored = true;
    final (keepLoggedIn, stored) = await (
      ApiConfigStore.loadKeepLoggedIn(),
      ApiConfigStore.loadAuthSession(),
    ).wait;
    if (!keepLoggedIn) return false;
    if (stored == null) return false;

    _restoringSession = true;
    try {
      final userMap = jsonDecode(stored.userJson) as Map<String, dynamic>;
      _token = stored.token;
      _refreshToken = stored.refreshToken;
      _user = User.fromJson(userMap);
      _tokenStale = false;
      _restoreImpersonationFromStored(stored);
      CrashReporter.setToken(_token);
      unawaited(ApiConfigStore.ensureAnalyticsConsentEnabled());
      unawaited(MobileAnalyticsService.instance.updateAuthToken(_token));
      notifyListeners();

      // Refresh JWT / profil en fond — ne pas bloquer splash → biométrie / Accueil.
      unawaited(() async {
        try {
          if (await ApiService.isReachable()) {
            await trySilentTokenRefresh();
            unawaited(_refreshProfileFromServer());
          }
        } catch (e) {
          debugPrint('[AUTH] restoreSession background refresh: $e');
        }
      }());
      return isAuthenticated;
    } catch (e) {
      debugPrint('[AUTH] restoreSession invalid: $e');
      await ApiConfigStore.clearAuthSession();
      _token = null;
      _user = null;
      _refreshToken = null;
      return false;
    } finally {
      _restoringSession = false;
    }
  }

  /// Rafraîchit silencieusement le JWT (refresh token, impersonnalisation ou biométrie).
  Future<bool> trySilentTokenRefresh() async {
    if (_user == null) return false;

    if (isImpersonating) {
      final renewed = await _tryRenewImpersonationSession();
      if (renewed) return true;
      _tokenStale = true;
      notifyListeners();
      return false;
    }

    final storedRefresh = _refreshToken ?? await ApiConfigStore.loadRefreshToken();
    if (storedRefresh != null && storedRefresh.isNotEmpty) {
      final result = await ApiService.refreshAccessToken(storedRefresh);
      if (result != null) {
        _token = result.token;
        _refreshToken = result.refreshToken ?? storedRefresh;
        _tokenStale = false;
        CrashReporter.setToken(_token);
        unawaited(_persistSession());
        unawaited(MobileAnalyticsService.instance.updateAuthToken(_token));
        notifyListeners();
        debugPrint('[AUTH] JWT renouvelé via refresh token');
        return true;
      }
    }

    final creds = await BiometricCredentialStore.load();
    if (creds != null) {
      try {
        final response = await ApiService.login(creds.email, creds.password);
        if (response['success'] == true) {
          _token = response['token'] as String?;
          _refreshToken = response['refreshToken'] as String?;
          _user = User.fromJson(response['user']);
          _tokenStale = false;
          CrashReporter.setToken(_token);
          await _persistSession();
          MobileAnalyticsService.instance.updateAuthToken(_token);
          notifyListeners();
          debugPrint('[AUTH] JWT renouvelé via identifiants sécurisés');
          return true;
        }
      } catch (e) {
        debugPrint('[AUTH] trySilentTokenRefresh login: $e');
      }
    }
    return false;
  }

  /// Token impersonnalisation (2 h, sans refresh) — renouvelé via session admin stockée.
  Future<bool> _tryRenewImpersonationSession() async {
    if (!isImpersonating || _user == null) return false;
    final targetUserId = _user!.id;
    var adminToken = _impersonatorToken;
    if (adminToken == null || adminToken.isEmpty) return false;

    Future<bool> issueImpersonation(String token) async {
      try {
        final result = await AdminApiService.impersonateUser(targetUserId, token: token);
        _token = result.token;
        _user = User.fromJson(result.user);
        _tokenStale = false;
        CrashReporter.setToken(_token);
        await _persistSession();
        MobileAnalyticsService.instance.updateAuthToken(_token);
        notifyListeners();
        debugPrint('[AUTH] JWT impersonnalisation renouvelé');
        return true;
      } catch (e) {
        debugPrint('[AUTH] renew impersonation: $e');
        return false;
      }
    }

    if (await issueImpersonation(adminToken)) return true;

    final adminRefresh = _impersonatorRefreshToken ?? await ApiConfigStore.loadRefreshToken();
    if (adminRefresh != null && adminRefresh.isNotEmpty) {
      final refreshed = await ApiService.refreshAccessToken(adminRefresh);
      if (refreshed != null) {
        _impersonatorToken = refreshed.token;
        _impersonatorRefreshToken = refreshed.refreshToken ?? adminRefresh;
        adminToken = _impersonatorToken;
        if (adminToken != null && await issueImpersonation(adminToken)) return true;
      }
    }
    return false;
  }

  /// Au retour réseau : renouvelle le JWT de façon sécurisée (sans déconnexion).
  Future<void> refreshSessionIfOnline() async {
    if (_token == null || _user == null) return;
    if (!await ApiService.isReachable()) return;
    await trySilentTokenRefresh();
  }

  Future<void> _refreshProfileFromServer() async {
    if (_token == null) return;
    try {
      final profile = await ApiService.getProfile(token: _token);
      if (profile != null) {
        _user = profile;
        _tokenStale = false;
        await _persistSession();
        notifyListeners();
      } else if (await ApiService.isReachable()) {
        _tokenStale = true;
      }
    } catch (e) {
      debugPrint('[AUTH] refreshProfile: $e');
    }
  }

  Future<void> clearLocalSession() async {
    _user = null;
    _token = null;
    _refreshToken = null;
    _tokenStale = false;
    CrashReporter.setToken(null);
    MobileAnalyticsService.instance.updateAuthToken(null);
    notifyListeners();
  }

  Future<void> _persistSession() async {
    if (_token == null || _user == null) return;
    await ApiConfigStore.saveAuthSession(
      token: _token!,
      userJson: jsonEncode(_user!.toJson()),
      refreshToken: _refreshToken,
      impersonatorToken: _impersonatorToken,
      impersonatorUserJson:
          _impersonatorUser != null ? jsonEncode(_impersonatorUser!.toJson()) : null,
      impersonatorRefreshToken: _impersonatorRefreshToken,
      impersonationReturnRoute: _impersonationReturnRoute,
    );
  }

  void _clearImpersonationState() {
    _impersonatorToken = null;
    _impersonatorUser = null;
    _impersonatorRefreshToken = null;
    _impersonationReturnRoute = null;
  }

  void _restoreImpersonationFromStored(
    ({
      String token,
      String userJson,
      String? refreshToken,
      String? impersonatorToken,
      String? impersonatorUserJson,
      String? impersonatorRefreshToken,
      String? impersonationReturnRoute,
    }) stored,
  ) {
    _clearImpersonationState();
    final impToken = stored.impersonatorToken;
    final impUserJson = stored.impersonatorUserJson;
    if (impToken == null ||
        impToken.isEmpty ||
        impUserJson == null ||
        impUserJson.isEmpty) {
      return;
    }
    try {
      final adminUser = User.fromJson(jsonDecode(impUserJson) as Map<String, dynamic>);
      if (!AdminAccess.canAccessAdmin(adminUser)) {
        debugPrint('[AUTH] Session impersonation ignorée — admin stocké invalide');
        return;
      }
      _impersonatorToken = impToken;
      _impersonatorUser = adminUser;
      _impersonatorRefreshToken = stored.impersonatorRefreshToken;
      _impersonationReturnRoute = stored.impersonationReturnRoute;
    } catch (e) {
      debugPrint('[AUTH] restore impersonation: $e');
      _clearImpersonationState();
    }
  }

  Future<void> loginWithHuberaSso(
    String accessToken, {
    bool keepLoggedIn = true,
  }) async {
    _isLoading = true;
    notifyListeners();
    try {
      final response = await ApiService.loginWithHuberaSso(accessToken);
      if (response['success'] != true) {
        throw Exception(response['message'] ?? 'SSO Hubera ID refusé');
      }
      _clearImpersonationState();
      _token = response['token'];
      _refreshToken = response['refreshToken'] as String?;
      _user = User.fromJson(response['user']);
      _tokenStale = false;
      CrashReporter.setToken(_token);
      unawaited(ApiConfigStore.ensureAnalyticsConsentEnabled());
      unawaited(MobileAnalyticsService.instance.initialize(authToken: _token));
      unawaited(ApiConfigStore.saveKeepLoggedIn(keepLoggedIn));
      if (keepLoggedIn) unawaited(_persistSession());
      unawaited(
        HuberaIdSso.saveSession(
          email: _user?.email ?? '',
          accessToken: _token ?? '',
          refreshToken: _refreshToken ?? '',
        ),
      );
      unawaited(PushNotificationService.instance.registerAfterLogin(authToken: _token));
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> login(
    String email,
    String password, {
    bool keepLoggedIn = true,
    bool enableBiometric = false,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      if (kDebugMode && await ApiConfigStore.loadTestAutomationSkipBiometric()) {
        enableBiometric = false;
      }
      final response = await ApiService.login(email, password);

      if (response['success'] == true) {
        _clearImpersonationState();
        _token = response['token'];
        _refreshToken = response['refreshToken'] as String?;
        _user = User.fromJson(response['user']);
        _tokenStale = false;
        CrashReporter.setToken(_token);
        unawaited(ApiConfigStore.ensureAnalyticsConsentEnabled());
        unawaited(MobileAnalyticsService.instance.initialize(authToken: _token));
        unawaited(MobileAnalyticsService.instance.updateAuthToken(_token));
        unawaited(ApiConfigStore.saveKeepLoggedIn(keepLoggedIn));
        if (keepLoggedIn && enableBiometric) {
          unawaited(_persistSession());
          unawaited(BiometricCredentialStore.save(email: email, password: password));
          unawaited(ApiConfigStore.saveBiometricUnlockEnabled(true));
        } else if (keepLoggedIn) {
          unawaited(_persistSession());
          if (!enableBiometric) {
            unawaited(BiometricCredentialStore.clear());
            unawaited(ApiConfigStore.saveBiometricUnlockEnabled(false));
          }
        } else {
          unawaited(ApiConfigStore.clearAuthSession());
          // Pas de session persistante — identifiants empreinte conservés pour reconnexion rapide.
        }
        CrashReporter.trackAction('login:${_user?.email ?? "unknown"}');
        unawaited(CrashReporter.flushPendingReports());
        unawaited(PushNotificationService.instance.registerAfterLogin(authToken: _token));
        unawaited(
          HuberaIdSso.saveSession(
            email: _user?.email ?? email,
            accessToken: _token ?? '',
            refreshToken: _refreshToken ?? '',
          ),
        );
        _isLoading = false;
        notifyListeners();
      } else {
        throw Exception(response['message'] ?? 'Erreur de connexion');
      }
    } catch (e) {
      final deviceId = await ApiConfigStore.getOrCreateDeviceId();
      final errText = e.toString();
      ApiService.postSecurityEvent(
        eventType: 'auth_failure',
        message: errText,
        deviceId: deviceId,
      );
      final isNetwork =
          errText.contains('joindre') ||
          errText.contains('SocketException') ||
          errText.contains('Connection refused') ||
          errText.contains('Failed host lookup') ||
          ApiService.lastRequestWasNetworkFailure;
      if (isNetwork) {
        CrashReporter.reportManualError(
          message: 'Connexion mobile impossible — $errText (API: ${ApiService.baseUrl})',
          screenName: 'login',
          metadata: {
            'category': 'auth_network',
            'deviceId': deviceId,
          },
        );
      }
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await ApiService.register(
        email: email,
        password: password,
        firstName: firstName,
        lastName: lastName,
      );

      if (response['success'] == true) {
        _isLoading = false;
        notifyListeners();
      } else {
        throw Exception(response['message'] ?? 'Erreur d\'inscription');
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> ensureSessionAfterBiometric() async {
    // Session déjà en mémoire (splash) : ouvrir tout de suite, refresh en fond.
    if (_token != null && _user != null && !_tokenStale) {
      unawaited(refreshSessionIfOnline());
      return true;
    }
    if (_token != null && _user != null) {
      unawaited(refreshSessionIfOnline());
      return true;
    }
    final creds = await BiometricCredentialStore.load();
    if (creds == null) return false;
    try {
      final response = await ApiService.login(creds.email, creds.password);
      if (response['success'] == true) {
        _token = response['token'];
        _refreshToken = response['refreshToken'] as String?;
        _user = User.fromJson(response['user']);
        _tokenStale = false;
        CrashReporter.setToken(_token);
        unawaited(MobileAnalyticsService.instance.updateAuthToken(_token));
        notifyListeners();
        unawaited(_persistSession());
        return true;
      }
    } catch (e) {
      debugPrint('[AUTH] ensureSessionAfterBiometric: $e');
    }
    return false;
  }

  Future<void> saveBiometricCredentials(String password) async {
    if (_user == null || password.isEmpty) {
      throw Exception('Mot de passe requis');
    }
    await BiometricCredentialStore.save(email: _user!.email, password: password);
    await ApiConfigStore.saveBiometricUnlockEnabled(true);
    await ApiConfigStore.saveKeepLoggedIn(true);
  }

  /// Vérifie le mot de passe courant puis met à jour la session (tokens frais).
  Future<void> verifyPasswordForBiometric(String password) async {
    if (_user == null) throw Exception('Non connecté');
    final trimmed = password.trim();
    if (trimmed.isEmpty) throw Exception('Mot de passe requis');

    final response = await ApiService.login(_user!.email, trimmed);
    if (response['success'] != true) {
      throw Exception(response['message'] ?? 'Mot de passe incorrect');
    }
    _token = response['token'];
    _refreshToken = response['refreshToken'] as String?;
    _user = User.fromJson(response['user']);
    _tokenStale = false;
    CrashReporter.setToken(_token);
    unawaited(MobileAnalyticsService.instance.updateAuthToken(_token));
    notifyListeners();
    unawaited(_persistSession());
    unawaited(BiometricCredentialStore.save(email: _user!.email, password: trimmed));
  }

  Future<void> disableBiometricUnlock() async {
    await BiometricCredentialStore.clear();
    await ApiConfigStore.saveBiometricUnlockEnabled(false);
  }

  Future<void> logout() async {
    final deviceId = await ApiConfigStore.getOrCreateDeviceId();
    final userId = _user?.id;
    final token = _token;
    ApiService.postSecurityEvent(
      eventType: 'mobile_logout',
      message: 'Déconnexion utilisateur mobile',
      deviceId: deviceId,
      userId: userId,
      token: token,
    );
    CrashReporter.trackAction('logout');
    await UserSessionCleanup.onLogout(authToken: token);
    _user = null;
    _token = null;
    _refreshToken = null;
    _clearImpersonationState();
    _tokenStale = false;
    _sessionRestored = false;
    CrashReporter.setToken(null);
    MobileAnalyticsService.instance.updateAuthToken(null);
    notifyListeners();
  }

  Future<void> forgotPassword(String email) async {
    _isLoading = true;
    notifyListeners();
    try {
      await ApiService.forgotPassword(email);
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> resetPassword(String token, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      await ApiService.resetPassword(token, password);
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateProfile({
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
  }) async {
    if (_user == null || _token == null) {
      throw Exception('Non connecté');
    }
    _isLoading = true;
    notifyListeners();
    try {
      final updated = await ApiService.updateUserProfile(
        userId: _user!.id,
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        phone: phone?.trim(),
        email: email?.trim(),
        token: _token,
      );
      _user = updated;
      await _persistSession();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Demande un lien de réinitialisation de mot de passe pour le compte connecté.
  Future<void> requestPasswordResetForCurrentUser() async {
    if (_user == null) throw Exception('Non connecté');
    await forgotPassword(_user!.email);
  }

  Future<void> verifyEmail(String token) async {
    _isLoading = true;
    notifyListeners();
    try {
      await ApiService.verifyEmail(token);
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      final deviceId = await ApiConfigStore.getOrCreateDeviceId();
      ApiService.postSecurityEvent(
        eventType: 'otp_failed',
        message: 'Échec vérification email/token: ${e.toString()}',
        deviceId: deviceId,
      );
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  void _wireSecurityCallbacks() {
    ApiService.onSessionRevoked = (path, statusCode) async {
      await handleUnauthorized(path, statusCode);
    };
  }

  /// 401/403 : refresh silencieux si online ; sinon conserver la session locale (offline-first).
  Future<void> handleUnauthorized(String path, int statusCode) async {
    if (_handlingSessionRevoke || _restoringSession || _token == null) return;
    if (ApiService.lastRequestWasNetworkFailure) return;

    _handlingSessionRevoke = true;
    try {
      if (!await ApiService.isReachable()) {
        debugPrint('[AUTH] 401 ignoré (hors ligne) — session conservée');
        return;
      }
      final refreshed = await trySilentTokenRefresh();
      if (refreshed) return;

      _tokenStale = true;
      debugPrint('[AUTH] Token expiré (HTTP $statusCode sur $path) — session locale conservée');
    } finally {
      _handlingSessionRevoke = false;
    }
  }

  bool get isAuthenticated => _token != null && _user != null;

  bool get isAdmin => AdminAccess.canAccessAdmin(_user);

  bool get isImpersonating => _impersonatorToken != null;

  String? get impersonatorEmail => _impersonatorUser?.email;

  /// Route admin à rouvrir après désimpersonnalisation (défaut : hub admin).
  String get impersonationReturnRoute => _impersonationReturnRoute ?? '/admin';

  /// Ouvre la session de l'utilisateur cible (session administrateur requise).
  Future<void> impersonateUser(
    String targetUserId, {
    String returnRoute = '/admin',
  }) async {
    if (_token == null || _user == null) {
      throw Exception('Non connecté');
    }
    if (isImpersonating) {
      throw Exception('Quittez l\'impersonnalisation en cours avant d\'en ouvrir une autre');
    }
    if (!AdminAccess.canAccessAdmin(_user)) {
      throw Exception(
        'Connectez-vous d\'abord avec un compte administrateur '
        '(bouton Connexion ADMIN sur l\'écran de connexion).',
      );
    }
    final result = await AdminApiService.impersonateUser(targetUserId, token: _token);
    _impersonatorToken = _token;
    _impersonatorUser = _user;
    _impersonatorRefreshToken = _refreshToken;
    _impersonationReturnRoute = returnRoute;
    _token = result.token;
    _user = User.fromJson(result.user);
    _refreshToken = null;
    _tokenStale = false;
    CrashReporter.setToken(_token);
    await MobileAnalyticsService.instance.updateAuthToken(_token);
    await _persistSession();
    notifyListeners();
  }

  /// Quitte l'impersonation et restaure la session admin.
  Future<void> exitImpersonation() async {
    if (_impersonatorToken == null) return;
    _token = _impersonatorToken;
    _user = _impersonatorUser;
    _refreshToken = _impersonatorRefreshToken;
    _clearImpersonationState();
    _tokenStale = false;
    CrashReporter.setToken(_token);
    await MobileAnalyticsService.instance.updateAuthToken(_token);
    await _persistSession();
    notifyListeners();
  }
}
