import 'package:flutter/services.dart';

class HuberaIdDeviceAccount {
  const HuberaIdDeviceAccount({
    required this.email,
    required this.accessToken,
    required this.refreshToken,
    this.issuer = '',
  });

  final String email;
  final String accessToken;
  final String refreshToken;
  final String issuer;

  factory HuberaIdDeviceAccount.fromMap(Map<dynamic, dynamic> m) {
    return HuberaIdDeviceAccount(
      email: '${m['email'] ?? ''}'.trim().toLowerCase(),
      accessToken: '${m['access_token'] ?? ''}',
      refreshToken: '${m['refresh_token'] ?? ''}',
      issuer: '${m['issuer'] ?? ''}',
    );
  }
}

/// Le jeton Hubera ID ne sert que s’il est celui du compte déjà choisi.
bool jobsCanUseIdAccess({
  required String expectedEmail,
  required String idEmail,
  required String idAccess,
}) {
  final want = expectedEmail.trim().toLowerCase();
  final got = idEmail.trim().toLowerCase();
  if (want.isEmpty || idAccess.trim().isEmpty) return false;
  if (got.isNotEmpty && got != want) return false;
  return true;
}

class HuberaIdSso {
  HuberaIdSso._();
  static const _channel = MethodChannel('hubera_id_sso');

  static Future<List<HuberaIdDeviceAccount>> listAccounts() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listAccounts');
      return (raw ?? [])
          .whereType<Map>()
          .map(HuberaIdDeviceAccount.fromMap)
          .where((a) => a.email.isNotEmpty)
          .toList();
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<HuberaIdDeviceAccount?> freshAccount(String email) async {
    final want = email.trim().toLowerCase();
    if (want.isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>('freshAccount', {
        'email': want,
      });
      if (raw is! Map) return null;
      final account = HuberaIdDeviceAccount.fromMap(raw);
      if (account.email != want || account.accessToken.isEmpty) return null;
      return account;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> saveSession({
    required String email,
    required String accessToken,
    String refreshToken = '',
  }) async {
    try {
      await _channel.invokeMethod<void>('saveSession', {
        'email': email,
        'access_token': accessToken,
        'refresh_token': refreshToken,
      });
    } on MissingPluginException {
      // iOS / plugin absent
    }
  }
}
