import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/jobs_api_base.dart';
import 'package:jobbingtrack_mobile/services/mobile_analytics_service.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/biometric_auth_service.dart';
import 'package:jobbingtrack_mobile/services/biometric_credential_store.dart';
import 'package:jobbingtrack_mobile/config/debug_test_accounts.dart';
import 'package:jobbingtrack_mobile/utils/post_auth_navigation.dart';
import 'package:jobbingtrack_mobile/services/app_version_info.dart';
import 'package:jobbingtrack_mobile/services/hubera_id_sso.dart';

bool _prodHostWithoutPort(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty || h.contains('/') || h.contains(':')) return false;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) return false;
  return h.contains('.');
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _keepLoggedIn = true;
  bool _enableBiometric = false;
  bool _biometricAvailable = false;
  String? _savedAccountEmail;
  bool _showFullLoginForm = false;
  String? _appVersionLabel;
  List<HuberaIdDeviceAccount> _huberaAccounts = const [];

  @override
  void initState() {
    super.initState();
    _initOptions();
    AppVersionInfo.getDetails().then((details) {
      if (mounted) {
        setState(() => _appVersionLabel = details.technical);
      }
    });
  }

  Future<void> _initOptions() async {
    final (keep, bio, supported, creds, skipFlag) = await (
      ApiConfigStore.loadKeepLoggedIn(),
      ApiConfigStore.loadBiometricUnlockEnabled(),
      BiometricAuthService.canOfferUnlockOption(),
      BiometricCredentialStore.load(),
      kDebugMode
          ? ApiConfigStore.loadTestAutomationSkipBiometric()
          : Future<bool>.value(false),
    ).wait;
    final skipBioTest = kDebugMode && skipFlag;
    if (mounted) {
      setState(() {
        _keepLoggedIn = keep;
        _biometricAvailable = supported && !skipBioTest;
        _enableBiometric = bio && supported && !skipBioTest;
        _savedAccountEmail = skipBioTest ? null : creds?.email;
        _showFullLoginForm =
            skipBioTest || _savedAccountEmail == null || !supported;
        if (_savedAccountEmail != null && !_showFullLoginForm) {
          _emailController.text = _savedAccountEmail!;
        }
      });
      final hubera = await HuberaIdSso.listAccounts();
      if (mounted && hubera.isNotEmpty) {
        setState(() => _huberaAccounts = hubera);
      }
      if (!skipBioTest &&
          _savedAccountEmail != null &&
          supported &&
          !_showFullLoginForm) {
        // Empreinte dès le prochain frame — plus de délai artificiel 400 ms.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loginWithBiometric(auto: true);
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _fillTestCredentials({required bool admin, bool submit = false}) {
    setState(() {
      _showFullLoginForm = true;
      _emailController.text =
          admin ? DebugTestAccounts.adminEmail : DebugTestAccounts.userEmail;
      _passwordController.text = admin
          ? DebugTestAccounts.adminPassword
          : DebugTestAccounts.userPassword;
    });
    if (submit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _keepLoggedIn = true;
          _enableBiometric = false;
        });
        _login();
      });
    }
  }

  Widget _buildDebugTestAccountRow({
    required String label,
    required String email,
    required String password,
    required VoidCallback onFill,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey[700],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          email,
          style: TextStyle(fontSize: 12, color: Colors.grey[800]),
        ),
        const SizedBox(height: 2),
        Text(
          'Mot de passe : $password',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onFill,
            icon: const Icon(Icons.login, size: 16),
            label: const Text('Remplir et se connecter'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _navigateAfterLogin({
    required bool biometricEnabled,
    bool skipUnlockScreen = false,
  }) async {
    if (!mounted) return;
    final showUnlock = !skipUnlockScreen && _keepLoggedIn && biometricEnabled;
    final route = showUnlock ? '/biometric-unlock' : '/home';
    debugPrint('[LOGIN] Succès, navigation vers $route');
    if (showUnlock) {
      Navigator.of(context).pushReplacementNamed(route);
    } else {
      await PostAuthNavigation.go(context, route);
    }
  }

  Future<void> _loginWithBiometric({bool auto = false}) async {
    final skipBioTest = kDebugMode && await ApiConfigStore.loadTestAutomationSkipBiometric();
    if (skipBioTest) {
      if (mounted) setState(() => _showFullLoginForm = true);
      return;
    }
    final creds = await BiometricCredentialStore.load();
    if (creds == null) {
      if (!auto) _showSnackBar('Aucun compte enregistré sur cet appareil');
      return;
    }

    final bio = await BiometricAuthService.authenticate(
      reason: auto
          ? 'Connectez-vous à JobbingTrack'
          : 'Confirmez votre identité pour vous connecter',
    );
    if (!bio.success) {
      if (auto && mounted) {
        setState(() => _showFullLoginForm = true);
      }
      if (!auto && bio.errorMessage != null) {
        _showSnackBar(bio.errorMessage!);
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final bioEnabled = await ApiConfigStore.loadBiometricUnlockEnabled();
      await authProvider.login(
        creds.email,
        creds.password,
        keepLoggedIn: true,
        enableBiometric: bioEnabled || _enableBiometric,
      );
      unawaited(MobileAnalyticsService.instance.initialize(authToken: authProvider.token));
      await _navigateAfterLogin(biometricEnabled: true, skipUnlockScreen: true);
    } catch (e) {
      debugPrint('[LOGIN] Erreur empreinte: $e');
      _showSnackBar('Erreur: ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _forgetSavedAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oublier ce compte ?'),
        content: const Text(
          'Les identifiants enregistrés pour la connexion par empreinte seront effacés de cet appareil.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Oublier'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await BiometricCredentialStore.clear();
    await ApiConfigStore.saveBiometricUnlockEnabled(false);
    setState(() {
      _savedAccountEmail = null;
      _showFullLoginForm = true;
      _enableBiometric = false;
      _emailController.clear();
      _passwordController.clear();
    });
  }

  Future<void> _continueWithHubera(HuberaIdDeviceAccount acc) async {
    setState(() => _isLoading = true);
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (acc.accessToken.isNotEmpty) {
        await authProvider.loginWithHuberaSso(acc.accessToken, keepLoggedIn: _keepLoggedIn);
        unawaited(MobileAnalyticsService.instance.initialize(authToken: authProvider.token));
        if (mounted) {
          await _navigateAfterLogin(biometricEnabled: false);
        }
        return;
      }
      _emailController.text = acc.email;
      _showSnackBar('Compte Hubera : entrez le mot de passe Jobs une fois.');
    } catch (e) {
      _emailController.text = acc.email;
      _showSnackBar('SSO : ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _login() async {
    if (_emailController.text.isEmpty) {
      _showSnackBar('Veuillez saisir votre email');
      return;
    }

    debugPrint('[LOGIN] Tentative: ${_emailController.text} -> ${ApiService.baseUrl}');
    setState(() { _isLoading = true; });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.login(
        _emailController.text,
        _passwordController.text,
        keepLoggedIn: _keepLoggedIn,
        enableBiometric: _keepLoggedIn && _enableBiometric,
      );
      unawaited(MobileAnalyticsService.instance.initialize(authToken: authProvider.token));
      if (mounted) {
        await _navigateAfterLogin(
          biometricEnabled: _keepLoggedIn && _enableBiometric,
        );
      }
    } catch (e) {
      debugPrint('[LOGIN] Erreur: $e');
      _showSnackBar('Erreur: ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      if (mounted) {
        setState(() { _isLoading = false; });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: message.contains('Erreur') ? Colors.red : Colors.green,
      ),
    );
  }

  void _showApiUrlDialog(BuildContext context) {
    final current = ApiService.baseUrl
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r':\d+$'), '');
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('URL de l\'API'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Hôte (ex: jobs.hubera.cloud)',
            hintText: 'jobs.hubera.cloud',
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final host = controller.text.trim();
              if (host.isNotEmpty) {
                final next = host.contains('://')
                    ? host
                    : host.contains(':')
                        ? 'http://$host'
                        : _prodHostWithoutPort(host)
                            ? 'https://$host'
                            : 'http://$host:${ApiService.defaultApiPort}';
                if (kReleaseMode && jobsApiIsLoopback(next)) {
                  ApiService.baseUrl = jobsProdApiBase;
                } else {
                  ApiService.baseUrl = next;
                }
                Navigator.of(ctx).pop();
                setState(() {});
                _showSnackBar('API: ${ApiService.baseUrl}');
              }
            },
            child: const Text('Appliquer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connexion'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 60),

                // Logo
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset(
                    'assets/branding/jobbingtrack-logo.png',
                    width: 88,
                    height: 88,
                    fit: BoxFit.cover,
                    semanticLabel: 'Logo Hubera Jobs',
                  ),
                ),

                const SizedBox(height: 24),

                // Titre
                Text(
                  'Hubera Jobs',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Suivez vos candidatures facilement',
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 48),

                if (_huberaAccounts.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Hubera ID — facultatif',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Un compte est déjà sur cet appareil. Vous pouvez continuer avec, ou saisir e-mail et mot de passe plus bas.',
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  for (final acc in _huberaAccounts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: OutlinedButton(
                          onPressed: _isLoading ? null : () => _continueWithHubera(acc),
                          child: Text('Continuer avec ${acc.email}'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],

                if (_savedAccountEmail != null && _biometricAvailable && !_showFullLoginForm) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: Colors.blue.shade100,
                              child: Icon(Icons.person, color: Colors.blue.shade800),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _savedAccountEmail!,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    'Compte enregistré sur cet appareil',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 50,
                          child: FilledButton.icon(
                            onPressed: _isLoading ? null : () => _loginWithBiometric(),
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Connexion par empreinte'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _isLoading
                              ? null
                              : () => setState(() {
                                    _showFullLoginForm = true;
                                    if (_savedAccountEmail != null) {
                                      _emailController.text = _savedAccountEmail!;
                                    }
                                  }),
                          child: const Text('Se connecter avec le mot de passe'),
                        ),
                        TextButton(
                          onPressed: _isLoading
                              ? null
                              : () => setState(() {
                                    _showFullLoginForm = true;
                                    _emailController.clear();
                                    _passwordController.clear();
                                  }),
                          child: const Text('Utiliser un autre compte'),
                        ),
                        TextButton(
                          onPressed: _isLoading ? null : _forgetSavedAccount,
                          child: Text('Oublier ce compte', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Ou connexion manuelle', style: TextStyle(color: Colors.grey.shade600)),
                  const SizedBox(height: 16),
                ],

                // E-mail + mot de passe, toujours proposé. Hubera ID reste au-dessus, sans être exigé.
                Builder(
                  builder: (context) {
                    final isDark = Theme.of(context).brightness == Brightness.dark;
                    final cardColor = isDark ? const Color(0xFF2A2140) : const Color(0xFFF3E8FF);
                    final fieldFill = isDark ? const Color(0xFF1E1830) : const Color(0xFFFFFFFF);
                    final fieldText = isDark ? const Color(0xFFF5F3FF) : const Color(0xFF1E1B4B);
                    final buttonBg = isDark ? const Color(0xFFC4B5FD) : const Color(0xFF5B21B6);
                    final buttonFg = isDark ? const Color(0xFF1E1B4B) : const Color(0xFFFFFFFF);
                    final fieldStyle = TextStyle(color: fieldText, fontSize: 16);
                    final labelStyle = TextStyle(color: fieldText, fontSize: 14);
                    InputDecoration fieldDecoration({
                      required String label,
                      required String hint,
                      required Widget icon,
                      Widget? suffix,
                    }) {
                      return InputDecoration(
                        labelText: label,
                        hintText: hint,
                        labelStyle: labelStyle,
                        floatingLabelStyle: labelStyle,
                        hintStyle: labelStyle.copyWith(color: fieldText.withValues(alpha: 0.7)),
                        prefixIcon: icon,
                        suffixIcon: suffix,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: fieldFill,
                      );
                    }

                    return Material(
                  key: const Key('manual-login-card'),
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                  elevation: 2,
                  shadowColor: Colors.black.withValues(alpha: 0.1),
                  child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Connexion e-mail',
                          style: TextStyle(fontWeight: FontWeight.w700, color: fieldText),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('manual-login-email'),
                        controller: _emailController,
                        style: fieldStyle,
                        cursorColor: fieldText,
                        decoration: fieldDecoration(
                          label: 'Email',
                          hint: 'redacted@example.invalid',
                          icon: Icon(Icons.email, color: fieldText),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                      ),

                      const SizedBox(height: 16),

                      TextField(
                        key: const Key('manual-login-password'),
                        controller: _passwordController,
                        style: fieldStyle,
                        cursorColor: fieldText,
                        decoration: fieldDecoration(
                          label: 'Mot de passe',
                          hint: '••••••••',
                          icon: Icon(Icons.lock, color: fieldText),
                          suffix: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off : Icons.visibility,
                              color: fieldText,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
                      ),

                      const SizedBox(height: 12),

                      // Mot de passe oublié
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pushNamed('/forgot-password'),
                          child: Text(
                            'Mot de passe oublié ?',
                            style: TextStyle(fontSize: 14, color: Colors.blue[600]),
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Garder la connexion', style: TextStyle(color: fieldText)),
                        subtitle: Text(
                          'Rester connecté sur cet appareil',
                          style: TextStyle(color: fieldText.withValues(alpha: 0.85), fontSize: 12),
                        ),
                        value: _keepLoggedIn,
                        onChanged: (v) => setState(() {
                          _keepLoggedIn = v ?? true;
                          if (!_keepLoggedIn) _enableBiometric = false;
                        }),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      if (_biometricAvailable)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Déverrouiller avec la biométrie'),
                          subtitle: const Text(
                            'Empreinte ou code appareil au prochain lancement (identifiants chiffrés)',
                          ),
                          value: _enableBiometric,
                          onChanged: _keepLoggedIn
                              ? (v) => setState(() => _enableBiometric = v ?? false)
                              : null,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),

                      const SizedBox(height: 8),

                      // Bouton de connexion
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          key: const Key('manual-login-submit'),
                          onPressed: _isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: buttonBg,
                            foregroundColor: buttonFg,
                            disabledBackgroundColor: buttonBg.withValues(alpha: 0.5),
                            disabledForegroundColor: buttonFg.withValues(alpha: 0.7),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  'Se connecter',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                  ),
                );
                  },
                ),

                const SizedBox(height: 32),

                if (kDebugMode && !DebugTestAccounts.isConfigured)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Comptes debug absents : sur le PC lancez\n'
                      'node scripts/mobile/setup/sync-admin-mobile-login.js\n'
                      'puis rebuild APK debug (build-apk-debug.sh).',
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (kDebugMode && DebugTestAccounts.isConfigured) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Comptes de test (debug)',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[800],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _fillTestCredentials(
                                  admin: false,
                                  submit: true,
                                ),
                                child: const Text(
                                  'Connexion USER',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _fillTestCredentials(
                                  admin: true,
                                  submit: true,
                                ),
                                child: const Text(
                                  'Connexion ADMIN',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildDebugTestAccountRow(
                          label: 'Utilisateur (non admin)',
                          email: DebugTestAccounts.userEmail,
                          password: DebugTestAccounts.userPassword,
                          onFill: () =>
                              _fillTestCredentials(admin: false, submit: true),
                        ),
                        const Divider(height: 24),
                        _buildDebugTestAccountRow(
                          label: 'Administrateur',
                          email: DebugTestAccounts.adminEmail,
                          password: DebugTestAccounts.adminPassword,
                          onFill: () =>
                              _fillTestCredentials(admin: true, submit: true),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ] else if (kDebugMode) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Comptes de test : lancez node scripts/mobile/setup/generate-debug-test-accounts.js (TEST_USER_* / TEST_ADMIN_* dans .env).',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Lien vers l'inscription
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Pas encore de compte ? ',
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).pushNamed('/register');
                      },
                      child: Text(
                        'Créer un compte',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Indicateur serveur + lien pour changer l'URL (si besoin, ex: 192.168.x.x)
                GestureDetector(
                  onTap: () => _showApiUrlDialog(context),
                  child: Text(
                    'API: ${ApiService.baseUrl}',
                    style: TextStyle(fontSize: 10, color: Colors.grey[400], decoration: TextDecoration.underline),
                  ),
                ),

                if (_appVersionLabel != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Version $_appVersionLabel',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ],

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
