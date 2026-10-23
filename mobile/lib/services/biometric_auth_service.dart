import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';

/// Déverrouillage biométrique (empreinte / Face ID / code appareil).
class BiometricAuthService {
  static final LocalAuthentication _auth = LocalAuthentication();

  static Future<bool> isDeviceSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('[BIO] isDeviceSupported: $e');
      return false;
    }
  }

  static Future<List<BiometricType>> getEnrolledBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      debugPrint('[BIO] getAvailableBiometrics: $e');
      return const [];
    }
  }

  static Future<bool> canCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (e) {
      debugPrint('[BIO] canCheckBiometrics: $e');
      return false;
    }
  }

  /// Afficher l’option « Déverrouiller avec la biométrie » (login / paramètres).
  /// Sur Android, [isAvailable] peut être false alors que empreinte ou code appareil fonctionnent.
  static Future<bool> canOfferUnlockOption() async {
    return isDeviceSupported();
  }

  /// Capable de proposer un déverrouillage local (empreinte, Face ID ou code/PIN appareil).
  static Future<bool> isAvailable() async {
    if (!await isDeviceSupported()) return false;
    final enrolled = await getEnrolledBiometrics();
    if (enrolled.isNotEmpty) return true;
    return canCheckBiometrics();
  }

  static String describeBiometrics(List<BiometricType> types) {
    if (types.contains(BiometricType.face)) return 'Face ID';
    if (types.contains(BiometricType.fingerprint)) return 'Empreinte digitale';
    if (types.contains(BiometricType.strong) || types.contains(BiometricType.weak)) {
      return 'Biométrie';
    }
    return 'Code ou empreinte de l\'appareil';
  }

  static String userMessageForException(LocalAuthException e) {
    switch (e.code) {
      case LocalAuthExceptionCode.userCanceled:
      case LocalAuthExceptionCode.systemCanceled:
        return 'Déverrouillage annulé';
      case LocalAuthExceptionCode.timeout:
        return 'Délai dépassé — réessayez';
      case LocalAuthExceptionCode.noBiometricsEnrolled:
        return 'Aucune empreinte enregistrée — utilisez votre mot de passe Hubera Jobs';
      case LocalAuthExceptionCode.noCredentialsSet:
        return 'Configurez un code ou une empreinte dans les paramètres Android';
      case LocalAuthExceptionCode.temporaryLockout:
      case LocalAuthExceptionCode.biometricLockout:
        return 'Trop de tentatives — réessayez dans quelques instants';
      case LocalAuthExceptionCode.uiUnavailable:
        return 'Interface biométrique indisponible — réessayez';
      case LocalAuthExceptionCode.userRequestedFallback:
        return 'Utilisez votre mot de passe Hubera Jobs ci-dessous';
      default:
        return e.description ?? 'Authentification impossible (${e.code.name})';
    }
  }

  static Future<({bool success, String? errorMessage})> authenticate({
    String reason = 'Déverrouillez Hubera Jobs',
    bool biometricOnly = false,
  }) async {
    if (kDebugMode && await ApiConfigStore.loadTestAutomationSkipBiometric()) {
      debugPrint('[BIO] test_automation_skip_biometric — pas de prompt empreinte');
      return (success: false, errorMessage: 'Mode test ADB — mot de passe');
    }
    if (!await isDeviceSupported()) {
      return (success: false, errorMessage: 'Authentification locale non disponible sur cet appareil');
    }
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        sensitiveTransaction: false,
        persistAcrossBackgrounding: true,
      );
      return (success: ok, errorMessage: ok ? null : 'Déverrouillage annulé');
    } on LocalAuthException catch (e) {
      debugPrint('[BIO] authenticate: $e');
      return (success: false, errorMessage: userMessageForException(e));
    } catch (e) {
      debugPrint('[BIO] authenticate failed: $e');
      return (success: false, errorMessage: 'Erreur biométrique — réessayez');
    }
  }
}
