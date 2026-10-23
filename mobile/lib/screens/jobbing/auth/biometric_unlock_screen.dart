import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/services/biometric_auth_service.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/utils/auth_logout.dart';
import 'package:jobbingtrack_mobile/utils/post_auth_navigation.dart';

/// Écran de déverrouillage : biométrie / code appareil puis session JWT (tous appareils).
class BiometricUnlockScreen extends StatefulWidget {
  const BiometricUnlockScreen({super.key});

  @override
  State<BiometricUnlockScreen> createState() => _BiometricUnlockScreenState();
}

class _BiometricUnlockScreenState extends State<BiometricUnlockScreen> {
  bool _unlocking = false;
  bool _checkingDevice = true;
  String? _error;
  String _biometricLabel = 'Biométrie';
  bool _localAuthAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadDeviceCapabilities();
      if (!mounted || !_localAuthAvailable) return;
      // Lancer l’empreinte dès que possible (plus de délai 350 ms).
      if (mounted) await _tryUnlock(auto: true);
    });
  }

  Future<void> _loadDeviceCapabilities() async {
    final skipBioTest = kDebugMode && await ApiConfigStore.loadTestAutomationSkipBiometric();
    if (skipBioTest) {
      if (!mounted) return;
      await PostAuthNavigation.go(context, '/home');
      return;
    }
    // Parallèle : support appareil + empreintes enregistrées.
    final results = await Future.wait([
      BiometricAuthService.isDeviceSupported(),
      BiometricAuthService.getEnrolledBiometrics(),
    ]);
    final supported = results[0] as bool;
    final enrolled = results[1] as List<BiometricType>;
    if (!mounted) return;
    setState(() {
      _checkingDevice = false;
      _localAuthAvailable = supported;
      _biometricLabel = BiometricAuthService.describeBiometrics(enrolled);
      if (!supported) {
        _error = 'Authentification locale indisponible sur cet appareil — utilisez votre mot de passe Hubera Jobs';
      } else if (enrolled.isEmpty) {
        _error =
            'Aucune empreinte enregistrée sur cet appareil — le code PIN Android ou votre mot de passe Hubera Jobs fonctionneront';
      }
    });
  }

  Future<void> _tryUnlock({bool auto = false}) async {
    if (_unlocking || !_localAuthAvailable) return;
    setState(() {
      _unlocking = true;
      if (auto) _error = null;
    });

    final result = await BiometricAuthService.authenticate(
      reason: 'Confirmez votre identité pour ouvrir Hubera Jobs',
    );
    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _unlocking = false;
        _error = result.errorMessage ?? 'Déverrouillage annulé ou refusé';
      });
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final sessionOk = await auth.ensureSessionAfterBiometric();
    if (!mounted) return;
    if (sessionOk) {
      await PostAuthNavigation.go(context, '/home');
      return;
    }
    setState(() {
      _unlocking = false;
      _error = 'Session expirée — saisissez votre mot de passe Hubera Jobs';
    });
  }

  Future<void> _unlockWithPassword() async {
    Navigator.of(context).pushNamed('/biometric-password');
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final user = auth.user;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.fingerprint, size: 80, color: Colors.blue.shade700),
                  const SizedBox(height: 24),
                  Text(
                    'Déverrouiller',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    user != null ? 'Bonjour ${user.firstName}' : 'Session enregistrée',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    auth.isAuthenticated
                        ? 'Confirmez votre identité pour continuer'
                        : _biometricLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  const SizedBox(height: 32),
                  if (_checkingDevice || _unlocking)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(),
                    )
                  else ...[
                    if (_localAuthAvailable)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _tryUnlock,
                          icon: const Icon(Icons.fingerprint),
                          label: Text('Utiliser $_biometricLabel'),
                        ),
                      ),
                    if (_localAuthAvailable) const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _unlockWithPassword,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Mot de passe Hubera Jobs'),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _error!,
                      style: TextStyle(color: Colors.red.shade700, height: 1.35),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 32),
                  TextButton.icon(
                    onPressed: () => AuthLogout.confirmAndPerform(context),
                    icon: Icon(Icons.logout, color: Colors.red.shade700, size: 20),
                    label: Text(
                      'Se déconnecter',
                      style: TextStyle(color: Colors.red.shade700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
