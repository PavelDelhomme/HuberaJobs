import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/app_version_info.dart';
import 'package:jobbingtrack_mobile/utils/app_version_policy.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class MobileReleaseInfo {
  const MobileReleaseInfo({
    required this.platform,
    required this.version,
    required this.buildNumber,
    required this.minVersion,
    required this.minBuild,
    required this.forceUpdate,
    required this.releaseNotes,
    this.downloadUrl,
    this.storeUrl,
  });

  final String platform;
  final String version;
  final int buildNumber;
  final String minVersion;
  final int minBuild;
  final bool forceUpdate;
  final String releaseNotes;
  final String? downloadUrl;
  final String? storeUrl;

  String get displayVersion =>
      AppVersionPolicy.normalizeLegacy(version, buildNumber);

  factory MobileReleaseInfo.fromJson(Map<String, dynamic> json) {
    final release = json['release'] is Map<String, dynamic>
        ? json['release'] as Map<String, dynamic>
        : json;
    return MobileReleaseInfo(
      platform: release['platform']?.toString() ?? 'android',
      version: release['version']?.toString() ?? '0.0.0',
      buildNumber: int.tryParse(release['buildNumber']?.toString() ?? '') ?? 0,
      minVersion: release['minVersion']?.toString() ?? '0.0.0',
      minBuild: int.tryParse(release['minBuild']?.toString() ?? '') ?? 0,
      forceUpdate: release['forceUpdate'] == true,
      releaseNotes: release['releaseNotes']?.toString() ?? '',
      downloadUrl: release['downloadUrl']?.toString(),
      storeUrl: release['storeUrl']?.toString(),
    );
  }
}

class AppVersionParts {
  AppVersionParts({required this.parts, required this.build});

  final List<int> parts;
  final int build;

  factory AppVersionParts.parse(String raw) {
    final split = raw.split('+');
    final build = split.length > 1 ? (int.tryParse(split[1]) ?? 0) : 0;
    final versionParts = split[0]
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    return AppVersionParts(parts: versionParts, build: build);
  }

  bool isOlderThan(AppVersionParts other) {
    final maxLen = parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < maxLen; i++) {
      final left = i < parts.length ? parts[i] : 0;
      final right = i < other.parts.length ? other.parts[i] : 0;
      if (left != right) return left < right;
    }
    return build < other.build;
  }

  /// Écart de builds (approx.) pour message « X versions de retard ».
  int buildsBehind(AppVersionParts latest) {
    if (!isOlderThan(latest)) return 0;
    if (build > 0 && latest.build > build) {
      final delta = latest.build - build;
      if (delta > 0) return delta;
    }
    // Fallback semver : compter les segments différentiels grossièrement.
    var score = 0;
    final maxLen = parts.length > latest.parts.length ? parts.length : latest.parts.length;
    for (var i = 0; i < maxLen; i++) {
      final left = i < parts.length ? parts[i] : 0;
      final right = i < latest.parts.length ? latest.parts[i] : 0;
      if (right > left) {
        score += (right - left) * (i == 0 ? 100 : i == 1 ? 10 : 1);
      }
    }
    return score < 1 ? 1 : score;
  }
}

class MobileUpdateService {
  MobileUpdateService._();

  /// Canal dev en debug, production en release — surcharge via `--dart-define=MOBILE_RELEASE_CHANNEL=dev`.
  static String get releaseChannel {
    const fromEnv = String.fromEnvironment('MOBILE_RELEASE_CHANNEL', defaultValue: '');
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return kDebugMode ? 'dev' : 'production';
  }

  static Future<MobileReleaseInfo?> fetchLatestRelease() async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final channel = releaseChannel;
    final uri = Uri.parse(
      '${ApiService.baseUrl}/api/v1/mobile/releases/latest?platform=$platform&channel=$channel',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['success'] != true) return null;
    return MobileReleaseInfo.fromJson(decoded);
  }

  static Future<String> readCurrentVersion() => AppVersionInfo.get();

  /// Seuil : au-delà, on insiste (force soft) même si le serveur n'a pas forceUpdate.
  static const catchUpForceAfterBuilds = 5;

  static Future<({MobileReleaseInfo release, String current, bool optional, bool blocked, int buildsBehind})?> evaluateUpdate() async {
    final release = await fetchLatestRelease();
    if (release == null) {
      debugPrint('[OTA] latest null (channel=$releaseChannel base=${ApiService.baseUrl})');
      return null;
    }

    // Sans URL de téléchargement Android, impossible de catch-up — ne pas bloquer l'app.
    if (!Platform.isIOS && (release.downloadUrl == null || release.downloadUrl!.trim().isEmpty)) {
      debugPrint('[OTA] latest sans downloadUrl — skip prompt');
      return null;
    }

    final current = await AppVersionInfo.get();
    final currentParts = AppVersionParts.parse(current);
    final latestParts = AppVersionParts.parse('${release.version}+${release.buildNumber}');
    final minParts = AppVersionParts.parse('${release.minVersion}+${release.minBuild}');
    final behind = currentParts.buildsBehind(latestParts);

    debugPrint(
      '[OTA] channel=$releaseChannel current=$current '
      'latest=${release.version}+${release.buildNumber} behind=$behind '
      'download=${release.downloadUrl != null}',
    );

    if (currentParts.isOlderThan(minParts)) {
      return (release: release, current: current, optional: false, blocked: true, buildsBehind: behind);
    }
    if (currentParts.isOlderThan(latestParts)) {
      final hardForce = release.forceUpdate || behind >= catchUpForceAfterBuilds;
      return (
        release: release,
        current: current,
        optional: !hardForce,
        blocked: hardForce,
        buildsBehind: behind,
      );
    }
    return null;
  }

  /// Chemin ou URL de téléchargement OTA — les chemins relatifs sont résolus via [ApiService.baseUrl].
  static String resolveAndroidDownloadUrl(String? serverUrl) {
    if (serverUrl == null || serverUrl.trim().isEmpty) {
      throw Exception('URL de téléchargement APK absente côté serveur');
    }
    final trimmed = serverUrl.trim();
    if (trimmed.startsWith('/')) {
      final apiBase = ApiService.baseUrl.replaceAll(RegExp(r'/+$'), '');
      return '$apiBase$trimmed';
    }

    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme) return trimmed;

    final host = parsed.host.toLowerCase();
    final isDevLocalHost = host == 'localhost'
        || host == '127.0.0.1'
        || host.endsWith('.localhost');

    if (!isDevLocalHost) return trimmed;

    const marker = '/api/v1/mobile/releases/download/';
    if (!parsed.path.contains(marker)) return trimmed;

    final apiBase = ApiService.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final path = parsed.path.startsWith('/') ? parsed.path : '/${parsed.path}';
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    final resolved = '$apiBase$path$query';
    debugPrint('[OTA] URL téléchargement réécrite: $trimmed → $resolved');
    return resolved;
  }

  /// Télécharge l’APK (avec progression optionnelle) puis ouvre l’installateur système.
  static Future<void> downloadAndInstallAndroid(
    String downloadUrl, {
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) return;

    final installPerm = await Permission.requestInstallPackages.request();
    if (installPerm.isDenied || installPerm.isPermanentlyDenied) {
      await openAppSettings();
      throw Exception(
        'Permission d’installer des apps refusée. '
        'Autorisez JobbingTrack dans Paramètres → Installer des apps inconnues, puis réessayez.',
      );
    }

    final dir = await getTemporaryDirectory();
    final cached = File('${dir.path}/ota/jobbingtrack-update.apk');
    if (await cached.exists() && await cached.length() >= 5 * 1024 * 1024) {
      onProgress?.call(1.0);
      final result = await OpenFilex.open(
        cached.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        final msg = result.message.trim();
        throw Exception(msg.isEmpty ? 'Installation APK refusée' : msg);
      }
      return;
    }

    final resolvedUrl = resolveAndroidDownloadUrl(downloadUrl);
    onProgress?.call(0.02);

    final request = http.Request('GET', Uri.parse(resolvedUrl));
    final streamed = await request.send().timeout(const Duration(minutes: 3));
    if (streamed.statusCode != 200) {
      throw Exception('Téléchargement APK échoué (${streamed.statusCode})');
    }

    final total = streamed.contentLength ?? 0;
    final bytes = <int>[];
    var received = 0;
    await for (final chunk in streamed.stream) {
      bytes.addAll(chunk);
      received += chunk.length;
      if (total > 0) {
        onProgress?.call((received / total).clamp(0.0, 0.99));
      } else if (received > 0) {
        onProgress?.call(0.5);
      }
    }

    if (bytes.length < 100 * 1024) {
      throw Exception(
        'APK téléchargé invalide (${bytes.length} octets). '
        'La release OTA serveur est corrompue ou factice — republiez un APK réel depuis le backoffice.',
      );
    }

    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(bytes, flush: true);
    onProgress?.call(1.0);
    final file = cached;

    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      final msg = result.message.trim();
      throw Exception(msg.isEmpty ? 'Installation APK refusée' : msg);
    }
  }
}
