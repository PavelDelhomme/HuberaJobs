import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:jobbingtrack_mobile/services/analytics_telemetry_queue.dart';
import 'package:jobbingtrack_mobile/services/http_correlation.dart';
import 'package:jobbingtrack_mobile/services/offline_business_sync_queue.dart';
import 'package:jobbingtrack_mobile/services/offline_mutation_helper.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/models/user.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/models/app_notification.dart';
import 'package:jobbingtrack_mobile/models/followup.dart';
import 'package:jobbingtrack_mobile/models/interview.dart';
import 'package:jobbingtrack_mobile/models/call.dart';

class ApiService {
  static const int defaultApiPort = _apiPort;
  static const int _apiPort = 5002;
  static const Duration _timeout = Duration(seconds: 10);

  static bool lastRequestWasNetworkFailure = false;
  static String? _resolvedBaseUrl;
  static DateTime? lastSuccessfulHttpAt;

  static String get _apiRoot {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    final raw = (fromEnv.isNotEmpty ? fromEnv : baseUrl).trim();
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  /// Indique si l'API répond (sans consommer le JWT métier).
  ///
  /// Un GET `/health` trop court (3 s) sur Android 9 concurrent aux appels
  /// métier donnait un faux « hors ligne » alors que refresh JWT + listes
  /// passaient. On s'aligne sur les mêmes chemins que la gateway et on
  /// considère un HTTP métier récent comme preuve de connectivité.
  static Future<bool> isReachable() async {
    final recent = lastSuccessfulHttpAt;
    if (recent != null &&
        !lastRequestWasNetworkFailure &&
        DateTime.now().difference(recent) < const Duration(seconds: 45)) {
      return true;
    }
    final root = _apiRoot;
    for (final path in const ['/api/v1/health', '/health']) {
      try {
        final res = await http
            .get(
              Uri.parse('$root$path'),
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 8));
        debugPrint('[API] isReachable $path -> ${res.statusCode}');
        if (res.statusCode >= 200 && res.statusCode < 500) {
          lastSuccessfulHttpAt = DateTime.now();
          return true;
        }
      } catch (e) {
        debugPrint('[API] isReachable $path fail: $e');
      }
    }
    return false;
  }

  static bool _isExemptAuthRevokePath(String path) {
    final p = path.toLowerCase();
    return p.contains('/analytics/') ||
        p.contains('/crashes') ||
        p.contains('/mobile/security-events') ||
        p.contains('/auth/login') ||
        p.contains('/auth/register') ||
        p.contains('/auth/refresh') ||
        p.contains('/health');
  }

  /// Appelé quand une requête authentifiée reçoit 401/403 (session révoquée côté serveur).
  static Future<void> Function(String path, int statusCode)? onSessionRevoked;

  /// Hook télémétrie (durée des requêtes API, anonymisé).
  static void Function(String path, int statusCode, int durationMs)? onRequestComplete;

  /// URL de l'API. Par défaut en local : 127.0.0.1 (adb reverse) ou 10.0.2.2 (émulateur).
  static String get baseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (_resolvedBaseUrl != null) return _resolvedBaseUrl!;
    return 'http://127.0.0.1:$_apiPort';
  }

  static set baseUrl(String url) {
    _resolvedBaseUrl = url;
    ApiConfigStore.saveBaseUrl(url);
  }

  static Future<bool> _probeHealth(String url) async {
    final root = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    for (final path in const ['/api/v1/health', '/health']) {
      try {
        debugPrint('[API] Test: $root$path');
        final res = await http
            .get(
              Uri.parse('$root$path'),
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode >= 200 && res.statusCode < 500) {
          _resolvedBaseUrl = root;
          lastSuccessfulHttpAt = DateTime.now();
          debugPrint('[API] OK: $root$path (${res.statusCode})');
          return true;
        }
      } catch (e) {
        debugPrint('[API] Echec: $root$path ($e)');
      }
    }
    return false;
  }

  static List<String> _localCandidates() {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    const lanHost = String.fromEnvironment('MOBILE_DEV_LAN_HOST', defaultValue: '');
    final candidates = <String>[];
    if (fromEnv.isNotEmpty) candidates.add(fromEnv);
    if (lanHost.isNotEmpty) candidates.add('http://$lanHost:$_apiPort');
    candidates.addAll([
      'http://127.0.0.1:$_apiPort', // Appareil physique avec adb reverse
      'http://10.0.2.2:$_apiPort', // Émulateur Android
      'http://localhost:$_apiPort',
    ]);
    return candidates;
  }

  /// Tente de trouver un baseUrl fonctionnel.
  /// Ordre : dart-define, URL sauvegardée, 127.0.0.1, IP LAN build, 10.0.2.2, localhost.
  /// Si aucune ne répond, on passe quand même à l'écran de connexion (pas de blocage).
  static Future<bool> autoDetectApi() async {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromEnv.isNotEmpty) {
      _resolvedBaseUrl = fromEnv;
      debugPrint('[API] URL prod (dart-define): $fromEnv');
      return true;
    }

    final saved = await ApiConfigStore.loadBaseUrl();
    if (saved != null && await _probeHealth(saved)) {
      return true;
    }

    for (final url in _localCandidates()) {
      if (await _probeHealth(url)) return true;
    }

    _resolvedBaseUrl = 'http://127.0.0.1:$_apiPort';
    debugPrint('[API] Aucune URL OK, passage à l\'écran connexion avec: $_resolvedBaseUrl');
    return true;
  }

  static Future<http.Response> _get(String path, {Map<String, String>? headers}) async {
    return _timed(path, () async {
      debugPrint('[API] GET $baseUrl$path');
      final response =
          await http.get(Uri.parse('$baseUrl$path'), headers: headers).timeout(_timeout);
      _maybeNotifySessionRevoked(response, headers, path);
      return response;
    });
  }

  static Future<http.Response> _post(String path, {Map<String, String>? headers, Object? body}) async {
    return _timed(path, () async {
      debugPrint('[API] POST $baseUrl$path');
      final response =
          await http.post(Uri.parse('$baseUrl$path'), headers: headers, body: body).timeout(_timeout);
      _maybeNotifySessionRevoked(response, headers, path);
      return response;
    });
  }

  static Future<http.Response> _put(String path, {Map<String, String>? headers, Object? body}) async {
    return _timed(path, () async {
      debugPrint('[API] PUT $baseUrl$path');
      final response =
          await http.put(Uri.parse('$baseUrl$path'), headers: headers, body: body).timeout(_timeout);
      _maybeNotifySessionRevoked(response, headers, path);
      return response;
    });
  }

  static Future<http.Response> _delete(String path, {Map<String, String>? headers}) async {
    return _timed(path, () async {
      debugPrint('[API] DELETE $baseUrl$path');
      final response =
          await http.delete(Uri.parse('$baseUrl$path'), headers: headers).timeout(_timeout);
      _maybeNotifySessionRevoked(response, headers, path);
      return response;
    });
  }

  static Future<http.Response> _timed(
    String path,
    Future<http.Response> Function() request,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final response = await request();
      sw.stop();
      lastRequestWasNetworkFailure = false;
      final cb = onRequestComplete;
      if (cb != null &&
          !path.contains('/analytics/') &&
          !path.contains('/crashes') &&
          !path.contains('/mobile/security-events')) {
        cb(path, response.statusCode, sw.elapsedMilliseconds);
      }
      if (response.statusCode >= 200 && response.statusCode < 500) {
        lastSuccessfulHttpAt = DateTime.now();
        unawaited(AnalyticsTelemetryQueue.instance.flush());
        unawaited(OfflineBusinessSyncQueue.instance.flush());
      }
      return response;
    } catch (e) {
      sw.stop();
      lastRequestWasNetworkFailure = AnalyticsTelemetryQueue.isNetworkError(e);
      final cb = onRequestComplete;
      if (cb != null &&
          !path.contains('/analytics/') &&
          !path.contains('/crashes') &&
          !path.contains('/mobile/security-events')) {
        cb(path, 0, sw.elapsedMilliseconds);
      }
      rethrow;
    }
  }

  static void _maybeNotifySessionRevoked(
    http.Response response,
    Map<String, String>? headers,
    String path,
  ) {
    final auth = headers?['Authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return;
    if (response.statusCode != 401 && response.statusCode != 403) return;
    if (_isExemptAuthRevokePath(path)) return;
    if (lastRequestWasNetworkFailure) return;
    final handler = onSessionRevoked;
    if (handler != null) {
      handler(path, response.statusCode);
    }
  }

  static Map<String, String> _jsonHeaders([String? token]) =>
      HttpCorrelation.jsonHeaders(bearerToken: token);

  /// Signaux sécurité mobile (session révoquée, échec auth, etc.) — B9
  static Future<void> postSecurityEvent({
    required String eventType,
    String? message,
    String? deviceId,
    String? userId,
    Map<String, dynamic>? metadata,
    String? token,
  }) async {
    final body = {
      'eventType': eventType,
      'message': message,
      'deviceId': deviceId,
      'userId': userId,
      'metadata': metadata ?? {},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'source': 'mobile',
    };
    await _postTelemetry(
      kind: 'security_event',
      path: '/api/v1/mobile/security-events',
      body: body,
      token: token,
    );
  }

  static Future<bool> _postTelemetry({
    required String kind,
    required String path,
    required Map<String, dynamic> body,
    String? token,
  }) async {
    try {
      final response = await _post(
        path,
        headers: _jsonHeaders(token),
        body: jsonEncode(body),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      if (AnalyticsTelemetryQueue.isRetriableHttpStatus(response.statusCode)) {
        await AnalyticsTelemetryQueue.instance.enqueue(
          kind: kind,
          path: path,
          body: body,
          token: token,
        );
      }
      debugPrint('[API] telemetry $kind HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      if (AnalyticsTelemetryQueue.isNetworkError(e)) {
        await AnalyticsTelemetryQueue.instance.enqueue(
          kind: kind,
          path: path,
          body: body,
          token: token,
        );
      }
      debugPrint('[API] telemetry $kind en file: $e');
      return false;
    }
  }

  // ——— Analytics utilisateur (optionnel, anonyme si pas de token) ———

  static Future<void> postAnalyticsSession({
    required String sessionId,
    String? deviceId,
    String platform = 'mobile',
    String? deviceModel,
    String? osName,
    String? osVersion,
    String? token,
  }) async {
    await _postTelemetry(
      kind: 'session',
      path: '/api/v1/analytics/sessions',
      token: token,
      body: {
        'sessionId': sessionId,
        'deviceId': deviceId,
        'platform': platform,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (osName != null) 'osName': osName,
        if (osVersion != null) 'osVersion': osVersion,
        'appVersion': '1.0.0',
      },
    );
  }

  static Future<void> postAnalyticsDevice({
    required String deviceId,
    String platform = 'mobile',
    String? deviceModel,
    String? osName,
    String? osVersion,
    String? appVersion,
    String? token,
  }) async {
    await _postTelemetry(
      kind: 'device',
      path: '/api/v1/analytics/device',
      token: token,
      body: {
        'deviceId': deviceId,
        'platform': platform,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (osName != null) 'osName': osName,
        if (osVersion != null) 'osVersion': osVersion,
        'appVersion': appVersion ?? '1.0.0',
      },
    );
  }

  static Future<void> postAnalyticsEvent({
    String? sessionId,
    String? deviceId,
    required String eventType,
    required String eventName,
    String? category,
    String? page,
    Map<String, dynamic>? properties,
    String platform = 'mobile',
    String? token,
  }) async {
    await _postTelemetry(
      kind: 'event',
      path: '/api/v1/analytics/events',
      token: token,
      body: {
        if (sessionId != null) 'sessionId': sessionId,
        if (deviceId != null) 'deviceId': deviceId,
        'eventType': eventType,
        'eventName': eventName,
        if (category != null) 'category': category,
        if (page != null) 'page': page,
        'properties': properties ?? {},
        'platform': platform,
        'appVersion': '1.0.0',
      },
    );
  }

  static Future<void> postAnalyticsPerformance({
    String? sessionId,
    String? deviceId,
    required String metricType,
    required String metricName,
    int? duration,
    int? memoryUsage,
    int? value,
    String? page,
    int? networkLatency,
    String platform = 'mobile',
    String? token,
  }) async {
    await _postTelemetry(
      kind: 'performance',
      path: '/api/v1/analytics/performance',
      token: token,
      body: {
        if (sessionId != null) 'sessionId': sessionId,
        if (deviceId != null) 'deviceId': deviceId,
        'metricType': metricType,
        'metricName': metricName,
        if (duration != null) 'duration': duration,
        if (memoryUsage != null) 'memoryUsage': memoryUsage,
        if (value != null) 'value': value,
        if (networkLatency != null) 'networkLatency': networkLatency,
        if (page != null) 'page': page,
        'platform': platform,
        'appVersion': '1.0.0',
      },
    );
  }

  static Future<void> postAnalyticsError({
    String? sessionId,
    String? deviceId,
    required String errorType,
    required String errorName,
    required String errorMessage,
    String? stackTrace,
    String? page,
    String severity = 'error',
    String platform = 'mobile',
    Map<String, dynamic>? properties,
    String? token,
  }) async {
    await _postTelemetry(
      kind: 'error',
      path: '/api/v1/analytics/errors',
      token: token,
      body: {
        if (sessionId != null) 'sessionId': sessionId,
        if (deviceId != null) 'deviceId': deviceId,
        'errorType': errorType,
        'errorName': errorName,
        'errorMessage': errorMessage.length > 1000
            ? errorMessage.substring(0, 1000)
            : errorMessage,
        if (stackTrace != null) 'stackTrace': stackTrace,
        if (page != null) 'page': page,
        'severity': severity,
        'platform': platform,
        'appVersion': '1.0.0',
        'properties': properties ?? {},
      },
    );
  }

  /// Prépare l’API avant login — sans reset ni double health inutiles.
  static Future<bool> prepareForLogin() async {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromEnv.isNotEmpty) {
      // Prod / préprod : URL figée au build — aucun probe (évite 0–2 s inutiles).
      _resolvedBaseUrl = fromEnv;
      return true;
    }
    if (_resolvedBaseUrl != null && _resolvedBaseUrl!.isNotEmpty) {
      try {
        final res = await http.get(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) return true;
      } catch (_) {}
    }
    return autoDetectApi();
  }

  static Future<Map<String, dynamic>> loginWithHuberaSso(String accessToken) async {
    final ready = await prepareForLogin();
    if (!ready) {
      throw Exception('API injoignable ($baseUrl) pour le SSO Hubera ID.');
    }
    final response = await _post(
      '/api/v1/auth/login/hubera-sso',
      headers: _jsonHeaders(),
      body: jsonEncode({'access_token': accessToken}),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    final body = response.body.isNotEmpty ? jsonDecode(response.body) : {};
    throw Exception(
      body['message'] ?? body['error'] ?? 'SSO Hubera ID refusé (${response.statusCode})',
    );
  }

  static Future<Map<String, dynamic>> login(String email, String password) async {
    final ready = await prepareForLogin();
    if (!ready) {
      throw Exception(
        'API injoignable ($baseUrl). Câble USB + PC allumé ? '
        'Sur le PC : adb reverse tcp:5002 tcp:5002 — '
        'ou touchez « API » en bas de l\'écran et saisissez l\'IP LAN du PC (ex. 192.168.x.x).',
      );
    }
    try {
      final response = await _post(
        '/api/v1/auth/login',
        headers: _jsonHeaders(),
        body: jsonEncode({'email': email, 'password': password}),
      );
      debugPrint('[API] Login response: ${response.statusCode}');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      final body = response.body.isNotEmpty ? jsonDecode(response.body) : {};
      if (response.statusCode == 429) {
        final retry = body['retryAfter'];
        throw Exception(
          body['message'] ??
              'Trop de tentatives de connexion${retry != null ? ' — réessayez dans ${retry}s' : ''}',
        );
      }
      if (response.statusCode == 401) {
        throw Exception('Mot de passe incorrect');
      }
      throw Exception(body['message'] ?? body['error'] ?? 'Erreur HTTP ${response.statusCode}');
    } catch (e) {
      debugPrint('[API] Login error: $e');
      if (e is Exception) rethrow;
      throw Exception(
        'Impossible de joindre l\'API ($baseUrl). Vérifiez le réseau et adb reverse tcp:5002 tcp:5002',
      );
    }
  }

  /// Renouvelle le JWT via refresh token (stocké chiffré côté appareil).
  static Future<({String token, String? refreshToken})?> refreshAccessToken(String refreshToken) async {
    try {
      final response = await _post(
        '/api/v1/auth/refresh',
        headers: _jsonHeaders(),
        body: jsonEncode({'refreshToken': refreshToken}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String?;
        if (token == null || token.isEmpty) return null;
        return (token: token, refreshToken: data['refreshToken'] as String?);
      }
      return null;
    } catch (e) {
      debugPrint('[API] refreshAccessToken: $e');
      return null;
    }
  }

  /// Profil utilisateur courant (rafraîchit rôle / email après restauration session).
  static Future<User?> getProfile({String? token}) async {
    try {
      final response = await _get('/api/v1/auth/profile', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['user'] ?? data;
        if (raw is Map) return User.fromJson(Map<String, dynamic>.from(raw));
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return null;
      }
      return null;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  /// Met à jour le profil de l'utilisateur connecté (prénom, nom, téléphone).
  static Future<User> updateUserProfile({
    required String userId,
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
    String? token,
  }) async {
    try {
      final body = <String, dynamic>{
        'firstName': firstName,
        'lastName': lastName,
        if (phone != null) 'phone': phone,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim().toLowerCase(),
      };
      final response = await _put(
        '/api/v1/auth/users/${Uri.encodeComponent(userId)}',
        headers: _jsonHeaders(token),
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['user'];
        if (raw is Map) return User.fromJson(Map<String, dynamic>.from(raw));
      }
      final err = response.body.isNotEmpty ? jsonDecode(response.body) : {};
      throw Exception(err['error'] ?? err['message'] ?? 'Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final response = await _post(
        '/api/v1/auth/register',
        headers: _jsonHeaders(),
        body: jsonEncode({
          'email': email,
          'password': password,
          'firstName': firstName,
          'lastName': lastName,
        }),
      );
      debugPrint('[API] Register response: ${response.statusCode}');
      if (response.statusCode == 201 || response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['message'] ?? 'Erreur HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[API] Register error: $e');
      if (e is Exception) rethrow;
      throw Exception('Erreur de connexion réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> forgotPassword(String email) async {
    try {
      final response = await _post(
        '/api/v1/auth/forgot-password',
        headers: _jsonHeaders(),
        body: jsonEncode({'email': email.trim()}),
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
      throw Exception(body['message'] ?? body['error'] ?? 'Erreur ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> resetPassword(String token, String password) async {
    try {
      final response = await _post(
        '/api/v1/auth/reset-password/$token',
        headers: _jsonHeaders(),
        body: jsonEncode({'password': password}),
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
      throw Exception(body['message'] ?? body['error'] ?? 'Erreur ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> verifyEmail(String token) async {
    try {
      final response = await _get('/api/v1/auth/verify-email/$token');
      if (response.statusCode == 200) return jsonDecode(response.body);
      final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
      throw Exception(body['message'] ?? body['error'] ?? 'Erreur ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> resendVerificationEmail(String email) async {
    try {
      final response = await _post(
        '/api/v1/auth/resend-verification',
        headers: _jsonHeaders(),
        body: jsonEncode({'email': email.trim()}),
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
      throw Exception(body['message'] ?? body['error'] ?? 'Erreur ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<List<Application>> getApplications({String? token, int limit = 100}) async {
    try {
      final response = await _get(
        '/api/v1/applications?limit=$limit',
        headers: _jsonHeaders(token),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['applications'] != null) {
          return (data['applications'] as List).map((json) => Application.fromJson(json)).toList();
        }
        return [];
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
        throw Exception(body['message'] ?? 'Session expirée — reconnectez-vous');
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Application> createApplication(Application application, {String? token}) async {
    const path = '/api/v1/applications';
    final payload = application.toJson();
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: payload,
      entityType: 'application',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(payload)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Application.fromJson(data['application']);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Exception _httpError(http.Response response, [String? fallback]) {
    final body = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
    if (body is Map) {
      final errors = body['errors'];
      if (errors is List && errors.isNotEmpty) {
        final msgs = errors.map((e) {
          if (e is Map) return (e['msg'] ?? e['message'] ?? e).toString();
          return e.toString();
        }).join(' · ');
        return Exception(msgs);
      }
      return Exception(body['message'] ?? body['error'] ?? fallback ?? 'Erreur HTTP ${response.statusCode}');
    }
    return Exception(fallback ?? 'Erreur HTTP ${response.statusCode}');
  }

  static Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  /// Création candidature avec payload complet (tous les champs backend).
  static Future<Application> createApplicationFromPayload(Map<String, dynamic> payload, {String? token}) async {
    const path = '/api/v1/applications';
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: payload,
      entityType: 'application',
      token: token,
      successStatuses: const {200, 201},
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(payload)),
      onSuccess: (response) {
        final decoded = response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};
        final root = _asJsonMap(decoded);
        final nested = root['application'] ?? root['data'] ?? root;
        final map = _asJsonMap(nested);
        try {
          return Application.fromJson(map.isNotEmpty ? map : root);
        } catch (_) {
          // Création OK côté API : construire un objet local pour ne pas bloquer l'UI.
          return Application.fromJson({
            ...payload,
            'id': map['id']?.toString() ?? 'local-${DateTime.now().millisecondsSinceEpoch}',
            'company': map['company'] ?? {
              'id': payload['companyId']?.toString() ?? '',
              'name': payload['companyName']?.toString() ?? '',
            },
            'status': map['status'] ?? payload['status'] ?? 'CANDIDATE_PENDING',
            'applicationDate': map['applicationDate'] ?? payload['applicationDate'],
            'createdAt': map['createdAt'] ?? DateTime.now().toIso8601String(),
            'updatedAt': map['updatedAt'] ?? DateTime.now().toIso8601String(),
          });
        }
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  /// Mise à jour candidature avec payload complet (champs autorisés backend).
  static Future<List<Map<String, dynamic>>> getPlatforms({String? token}) async {
    try {
      final response = await _get('/api/v1/applications/platforms', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['platforms'] is List) {
          return List<Map<String, dynamic>>.from(
            (data['platforms'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
      }
      return [];
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> createPlatform({
    required String name,
    String? url,
    String? token,
  }) async {
    const path = '/api/v1/applications/platforms';
    final body = <String, dynamic>{
      'name': name,
      if (url != null && url.isNotEmpty) 'url': url,
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'platform',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Map<String, dynamic>.from(data['platform'] as Map);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<Application> updateApplicationFromPayload(String id, Map<String, dynamic> payload, {String? token}) async {
    final path = '/api/v1/applications/$id';
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: payload,
      entityType: 'application',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(payload)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Application.fromJson(data['application'] ?? data);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  /// Changement manuel de statut (+ commentaire optionnel).
  static Future<Application> updateApplicationStatus(
    String id,
    String status, {
    String? comment,
    String? token,
  }) async {
    final path = '/api/v1/applications/$id/status';
    final body = <String, dynamic>{
      'status': status,
      if (comment != null && comment.isNotEmpty) 'comment': comment,
    };
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'application',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Application.fromJson(data['application'] ?? data);
      },
      onHttpError: (response) => _httpError(response),
    );
  }
  static Future<Application> updateApplication(String id, Application application, {String? token}) async {
    final path = '/api/v1/applications/$id';
    final payload = application.toJson();
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: payload,
      entityType: 'application',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(payload)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Application.fromJson(data['application']);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<void> deleteApplication(String id, {String? token}) async {
    final path = '/api/v1/applications/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'application',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> archiveApplication(String id, {String? token, String? reason}) async {
    final path = '/api/v1/applications/$id/archive';
    final body = <String, dynamic>{
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    };
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      body: body.isEmpty ? null : body,
      entityType: 'application',
      token: token,
      successStatus: 200,
      send: () => _post(
        path,
        headers: _jsonHeaders(token),
        body: jsonEncode(body),
      ),
    );
  }

  static Future<Application> getApplication(String id, {String? token}) async {
    try {
      final response = await _get('/api/v1/applications/$id', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['application'];
        if (raw != null) return Application.fromJson(Map<String, dynamic>.from(raw));
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Company> getCompany(String id, {String? token}) async {
    try {
      final response = await _get('/api/v1/companies/$id', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['company'];
        if (raw != null) return Company.fromJson(Map<String, dynamic>.from(raw));
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<List<Company>> getCompanies({String? token, String? companyType}) async {
    try {
      var path = '/api/v1/companies?limit=100';
      if (companyType != null && companyType.isNotEmpty) {
        path += '&companyType=$companyType';
      }
      final response = await _get(path, headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['companies'] != null) {
          return (data['companies'] as List).map((json) => Company.fromJson(json)).toList();
        }
        return [];
      } else {
        throw Exception('Erreur HTTP ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Company> createCompany({
    required String name,
    String? website,
    String? industry,
    String? location,
    String? description,
    String companyType = 'EMPLOYER',
    String? token,
  }) async {
    const path = '/api/v1/companies';
    final body = <String, dynamic>{
      'name': name.trim(),
      'companyType': companyType,
      if (website != null && website.trim().isNotEmpty) 'website': website.trim(),
      if (industry != null && industry.trim().isNotEmpty) 'industry': industry.trim(),
      if (location != null && location.trim().isNotEmpty) 'location': location.trim(),
      if (description != null && description.trim().isNotEmpty) 'description': description.trim(),
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'company',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        final raw = data['company'];
        return Company.fromJson(Map<String, dynamic>.from(raw));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<Company> updateCompany(
    String id, {
    String? name,
    String? website,
    String? industry,
    String? location,
    String? description,
    String? token,
  }) async {
    final path = '/api/v1/companies/$id';
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (website != null) body['website'] = website;
    if (industry != null) body['industry'] = industry;
    if (location != null) body['location'] = location;
    if (description != null) body['description'] = description;
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'company',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Company.fromJson(Map<String, dynamic>.from(data['company']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<void> archiveCompany(String id, {String? token}) async {
    final path = '/api/v1/companies/$id/archive';
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      entityType: 'company',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> deleteCompany(String id, {String? token}) async {
    final path = '/api/v1/companies/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'company',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<List<AppNotification>> getNotifications({
    String? token,
    int limit = 50,
    bool? isRead,
    String scope = 'in_app',
  }) async {
    try {
      var path = '/api/v1/notifications?limit=$limit&scope=$scope';
      if (isRead != null) path += '&isRead=$isRead';
      final response = await _get(path, headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['notifications'] is List) {
          return (data['notifications'] as List)
              .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<void> markNotificationRead(String id, {String? token}) async {
    final path = '/api/v1/notifications/${Uri.encodeComponent(id)}/mark-read';
    await OfflineMutationHelper.executeVoid(
      method: 'PUT',
      path: path,
      entityType: 'notification',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> markAllNotificationsRead({String? token}) async {
    final path = '/api/v1/notifications/mark-all-read?scope=in_app';
    await OfflineMutationHelper.executeVoid(
      method: 'PUT',
      path: path,
      entityType: 'notification',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> deleteNotification(String id, {String? token}) async {
    final path = '/api/v1/notifications/${Uri.encodeComponent(id)}';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'notification',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  /// Enregistre un token push FCM/APNs (ou dev) côté notification-service.
  static Future<void> registerPushDevice({
    required String token,
    required String platform,
    required String provider,
    String? deviceId,
    String? authToken,
  }) async {
    final response = await _post(
      '/api/v1/notifications/push/register',
      headers: _jsonHeaders(authToken),
      body: jsonEncode({
        'token': token,
        'platform': platform,
        'provider': provider,
        if (deviceId != null) 'deviceId': deviceId,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      final err = response.body.isNotEmpty ? jsonDecode(response.body) : {};
      throw Exception(err['error'] ?? err['message'] ?? 'Erreur HTTP ${response.statusCode}');
    }
  }

  static Future<void> unregisterPushDevice({
    String? token,
    String? deviceId,
    String? authToken,
  }) async {
    final response = await _post(
      '/api/v1/notifications/push/unregister',
      headers: _jsonHeaders(authToken),
      body: jsonEncode({
        if (token != null) 'token': token,
        if (deviceId != null) 'deviceId': deviceId,
      }),
    );
    if (response.statusCode != 200) {
      final err = response.body.isNotEmpty ? jsonDecode(response.body) : {};
      throw Exception(err['error'] ?? err['message'] ?? 'Erreur HTTP ${response.statusCode}');
    }
  }

  static Future<List<User>> getUsers({String? token}) async {
    try {
      final response = await _get('/api/v1/auth/users', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['users'] != null) {
          return (data['users'] as List).map((json) => User.fromJson(json)).toList();
        }
        return [];
      } else {
        throw Exception('Erreur HTTP ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Erreur réseau: $e');
    }
  }

  /// Contacts : liste
  static Future<List<Map<String, dynamic>>> getContacts({String? token}) async {
    try {
      final response = await _get('/api/v1/contacts?limit=100', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['contacts'] != null) {
          return List<Map<String, dynamic>>.from(
            (data['contacts'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
        return [];
      } else {
        throw Exception('Erreur HTTP ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> getContact(String id, {String? token}) async {
    try {
      final response = await _get('/api/v1/contacts/$id', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['contact'] != null) {
          return Map<String, dynamic>.from(data['contact']);
        }
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> getContactsByApplication(
    String applicationId, {
    String? token,
  }) async {
    try {
      final response = await _get(
        '/api/v1/contacts/application/${Uri.encodeComponent(applicationId)}',
        headers: _jsonHeaders(token),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['contacts'] != null) {
          return List<Map<String, dynamic>>.from(
            (data['contacts'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> getContactsByCompany(
    String companyId, {
    String? token,
  }) async {
    try {
      final response = await _get(
        '/api/v1/contacts/company/${Uri.encodeComponent(companyId)}',
        headers: _jsonHeaders(token),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['contacts'] != null) {
          return List<Map<String, dynamic>>.from(
            (data['contacts'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> createContact({
    required String firstName,
    required String lastName,
    String? email,
    String? phone,
    String? notes,
    String? companyId,
    String? token,
  }) async {
    const path = '/api/v1/contacts';
    final body = <String, dynamic>{
      'firstName': firstName,
      'lastName': lastName,
      if (email != null && email.isNotEmpty) 'email': email,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (companyId != null && companyId.isNotEmpty) 'companyId': companyId,
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'contact',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Map<String, dynamic>.from(data['contact']);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<Map<String, dynamic>> updateContact(
    String id, {
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? position,
    String? notes,
    String? token,
  }) async {
    final path = '/api/v1/contacts/$id';
    final body = <String, dynamic>{};
    if (firstName != null) body['firstName'] = firstName;
    if (lastName != null) body['lastName'] = lastName;
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;
    if (position != null) body['position'] = position;
    if (notes != null) body['notes'] = notes;
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'contact',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Map<String, dynamic>.from(data['contact']);
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<void> archiveContact(String id, {String? token}) async {
    final path = '/api/v1/contacts/$id/archive';
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      entityType: 'contact',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> deleteContact(String id, {String? token}) async {
    final path = '/api/v1/contacts/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'contact',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> linkContactToApplication({
    required String contactId,
    required String applicationId,
    String? token,
  }) async {
    final path = '/api/v1/contacts/$contactId/link-application';
    final body = {'applicationId': applicationId};
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'contact',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
    );
  }

  static Future<FollowUp> getFollowUp(String id, {String? token}) async {
    try {
      final raw = await getFollowUpDetail(id, token: token);
      return FollowUp.fromJson(raw);
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> getFollowUpDetail(String id, {String? token}) async {
    final response = await _get('/api/v1/followups/$id', headers: _jsonHeaders(token));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['followup'] != null) {
        return Map<String, dynamic>.from(data['followup'] as Map);
      }
    }
    throw Exception('Erreur HTTP ${response.statusCode}');
  }

  static Future<Interview> getInterview(String id, {String? token}) async {
    try {
      final raw = await getInterviewDetail(id, token: token);
      return Interview.fromJson(raw);
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Map<String, dynamic>> getInterviewDetail(String id, {String? token}) async {
    final response = await _get('/api/v1/interviews/$id', headers: _jsonHeaders(token));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['interview'] != null) {
        return Map<String, dynamic>.from(data['interview'] as Map);
      }
    }
    throw Exception('Erreur HTTP ${response.statusCode}');
  }

  /// Relances : liste (optionnel applicationId) et création
  static Future<List<FollowUp>> getFollowUps({String? applicationId, String? token}) async {
    try {
      String path = '/api/v1/followups?limit=100';
      if (applicationId != null && applicationId.isNotEmpty) {
        path += '&applicationId=${Uri.encodeComponent(applicationId)}';
      }
      final response = await _get(path, headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['followups'] != null) {
          return (data['followups'] as List).map((j) => FollowUp.fromJson(Map<String, dynamic>.from(j))).toList();
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<FollowUp> createFollowUp({
    required String applicationId,
    required DateTime followUpDate,
    String? notes,
    String? contactId,
    String? followUpTypeId,
    String status = 'PENDING',
    String? token,
  }) async {
    const path = '/api/v1/followups';
    final body = {
      'applicationId': applicationId,
      'followUpDate': followUpDate.toUtc().toIso8601String(),
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (contactId != null && contactId.isNotEmpty) 'contactId': contactId,
      if (followUpTypeId != null && followUpTypeId.isNotEmpty) 'followUpTypeId': followUpTypeId,
      'status': status,
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'followup',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return FollowUp.fromJson(Map<String, dynamic>.from(data['followup']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<FollowUp> updateFollowUp(
    String id, {
    DateTime? followUpDate,
    String? notes,
    String? response,
    String? status,
    String? token,
  }) async {
    final path = '/api/v1/followups/$id';
    final body = <String, dynamic>{};
    if (followUpDate != null) body['followUpDate'] = followUpDate.toUtc().toIso8601String();
    if (notes != null) body['notes'] = notes;
    if (response != null) body['response'] = response;
    if (status != null) body['status'] = status;
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'followup',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return FollowUp.fromJson(Map<String, dynamic>.from(data['followup']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<FollowUp> completeFollowUp(String id, String responseText, {String? token}) async {
    final path = '/api/v1/followups/$id/complete';
    final body = {'response': responseText};
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'followup',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return FollowUp.fromJson(Map<String, dynamic>.from(data['followup']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<void> deleteFollowUp(String id, {String? token}) async {
    final path = '/api/v1/followups/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'followup',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> archiveFollowUp(String id, {String? token}) async {
    final path = '/api/v1/followups/$id/archive';
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      entityType: 'followup',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token)),
    );
  }

  /// Entretiens : liste et création
  static Future<List<Interview>> getInterviews({String? applicationId, String? token}) async {
    try {
      final response = await _get('/api/v1/interviews?limit=100', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['interviews'] != null) {
          var list = (data['interviews'] as List).map((j) => Interview.fromJson(Map<String, dynamic>.from(j))).toList();
          if (applicationId != null && applicationId.isNotEmpty) {
            list = list.where((i) => i.applicationId == applicationId).toList();
          }
          return list;
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<Interview> createInterview({
    required String applicationId,
    required DateTime interviewDate,
    String? location,
    String? videoLink,
    String? notes,
    int? estimatedDuration,
    List<String>? contactIds,
    String? token,
  }) async {
    const path = '/api/v1/interviews';
    final body = {
      'applicationId': applicationId,
      'interviewDate': interviewDate.toUtc().toIso8601String(),
      if (location != null && location.isNotEmpty) 'location': location,
      if (videoLink != null && videoLink.isNotEmpty) 'videoLink': videoLink,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (estimatedDuration != null) 'estimatedDuration': estimatedDuration,
      if (contactIds != null && contactIds.isNotEmpty) 'contactIds': contactIds,
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'interview',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Interview.fromJson(Map<String, dynamic>.from(data['interview']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<Interview> updateInterview(
    String id, {
    DateTime? interviewDate,
    String? location,
    String? videoLink,
    String? notes,
    int? estimatedDuration,
    String? status,
    String? token,
  }) async {
    final path = '/api/v1/interviews/$id';
    final body = <String, dynamic>{};
    if (interviewDate != null) body['interviewDate'] = interviewDate.toUtc().toIso8601String();
    if (location != null) body['location'] = location;
    if (videoLink != null) body['videoLink'] = videoLink;
    if (notes != null) body['notes'] = notes;
    if (estimatedDuration != null) body['estimatedDuration'] = estimatedDuration;
    if (status != null) body['status'] = status;
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'interview',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Interview.fromJson(Map<String, dynamic>.from(data['interview']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  /// Appels : liste globale et par candidature
  static Future<List<Call>> getCalls({String? token}) async {
    try {
      final response = await _get('/api/v1/calls?limit=100', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['calls'] != null) {
          return (data['calls'] as List).map((j) => Call.fromJson(Map<String, dynamic>.from(j))).toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<Call>> getCallsByApplication(String applicationId, {String? token}) async {
    try {
      final response = await _get('/api/v1/calls/application/$applicationId', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['calls'] != null) {
          return (data['calls'] as List).map((j) => Call.fromJson(Map<String, dynamic>.from(j))).toList();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> getCallDetail(String id, {String? token}) async {
    final response = await _get('/api/v1/calls/$id', headers: _jsonHeaders(token));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['call'] != null) {
        return Map<String, dynamic>.from(data['call'] as Map);
      }
    }
    throw Exception('Erreur HTTP ${response.statusCode}');
  }

  static Future<Call> getCall(String id, {String? token}) async {
    final raw = await getCallDetail(id, token: token);
    return Call.fromJson(raw);
  }

  static Future<Call> createCall({
    required String applicationId,
    required DateTime callDate,
    required String subject,
    String? notes,
    String? contactId,
    String? status,
    String? token,
  }) async {
    const path = '/api/v1/calls';
    final body = {
      'applicationId': applicationId,
      'callDate': callDate.toUtc().toIso8601String(),
      'subject': subject,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (contactId != null && contactId.isNotEmpty) 'contactId': contactId,
      if (status != null && status.isNotEmpty) 'status': status,
    };
    return OfflineMutationHelper.execute(
      method: 'POST',
      path: path,
      body: body,
      entityType: 'call',
      token: token,
      successStatus: 201,
      send: () => _post(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Call.fromJson(Map<String, dynamic>.from(data['call']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<Call> updateCall({
    required String id,
    DateTime? callDate,
    String? subject,
    String? notes,
    String? contactId,
    bool clearContact = false,
    String? token,
  }) async {
    final path = '/api/v1/calls/$id';
    final body = <String, dynamic>{};
    if (callDate != null) body['callDate'] = callDate.toUtc().toIso8601String();
    if (subject != null) body['subject'] = subject;
    if (notes != null) body['notes'] = notes;
    if (clearContact) {
      body['contactId'] = null;
    } else if (contactId != null && contactId.isNotEmpty) {
      body['contactId'] = contactId;
    }
    return OfflineMutationHelper.execute(
      method: 'PUT',
      path: path,
      body: body,
      entityType: 'call',
      token: token,
      successStatus: 200,
      send: () => _put(path, headers: _jsonHeaders(token), body: jsonEncode(body)),
      onSuccess: (response) {
        final data = jsonDecode(response.body);
        return Call.fromJson(Map<String, dynamic>.from(data['call']));
      },
      onHttpError: (response) => _httpError(response),
    );
  }

  static Future<void> deleteCall(String id, {String? token}) async {
    final path = '/api/v1/calls/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'call',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> deleteInterview(String id, {String? token}) async {
    final path = '/api/v1/interviews/$id';
    await OfflineMutationHelper.executeVoid(
      method: 'DELETE',
      path: path,
      entityType: 'interview',
      token: token,
      successStatus: 200,
      send: () => _delete(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> archiveInterview(String id, {String? token}) async {
    final path = '/api/v1/interviews/$id/archive';
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      entityType: 'interview',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<void> archiveCall(String id, {String? token}) async {
    final path = '/api/v1/calls/$id/archive';
    await OfflineMutationHelper.executeVoid(
      method: 'POST',
      path: path,
      entityType: 'call',
      token: token,
      successStatus: 200,
      send: () => _post(path, headers: _jsonHeaders(token)),
    );
  }

  static Future<List<Map<String, dynamic>>> getTrashEvents({String? token}) async {
    try {
      final response = await _get('/api/v1/events/trash', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['items'] is List) {
          return List<Map<String, dynamic>>.from(
            (data['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception('Accès admin requis');
      }
      return [];
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> getCalendarEvents({String? token, int limit = 50}) async {
    try {
      final response = await _get('/api/v1/events?limit=$limit', headers: _jsonHeaders(token));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['events'] ?? data['data'];
        if (raw is List) {
          return List<Map<String, dynamic>>.from(
            raw.map((e) => Map<String, dynamic>.from(e as Map)),
          );
        }
        return [];
      }
      throw Exception('Erreur HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Erreur réseau: $e');
    }
  }
}
