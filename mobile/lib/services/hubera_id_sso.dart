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
