import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:jobbingtrack_mobile/services/app_permissions_service.dart';
import 'package:jobbingtrack_mobile/utils/post_auth_navigation.dart';

/// Bloque l'accès à l'app tant que les notifications système ne sont pas autorisées.
class PermissionsGateScreen extends StatefulWidget {
  final String nextRoute;

  const PermissionsGateScreen({super.key, this.nextRoute = '/home'});

  @override
  State<PermissionsGateScreen> createState() => _PermissionsGateScreenState();
}

class _PermissionsGateScreenState extends State<PermissionsGateScreen> {
  bool _requesting = false;
  String? _status;

  Future<void> _checkAndContinue() async {
    final ok = await AppPermissionsService.instance.areRequiredPermissionsGranted();
    if (!mounted) return;
    if (ok) {
      await PostAuthNavigation.go(context, widget.nextRoute, skipPermissionsCheck: true);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndContinue());
  }

  Future<void> _request() async {
    setState(() {
      _requesting = true;
      _status = null;
    });
    final granted = await AppPermissionsService.instance.requestRequiredPermissions();
    if (!mounted) return;
    setState(() => _requesting = false);
    if (granted) {
      await PostAuthNavigation.go(context, widget.nextRoute, skipPermissionsCheck: true);
      return;
    }
    final perm = await Permission.notification.status;
    setState(() {
      _status = perm.isPermanentlyDenied
          ? 'Autorisation refusée définitivement. Ouvrez les paramètres Android → Applications → Hubera Jobs → Notifications.'
          : 'Les notifications sont obligatoires pour les relances et rappels sur votre téléphone.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Autorisations requises'), centerTitle: true),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.notifications_active_outlined, size: 72, color: Colors.blue.shade700),
                const SizedBox(height: 20),
                Text(
                  'Notifications sur le téléphone',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'Hubera Jobs a besoin d\'envoyer des alertes système (relances, entretiens, rappels). '
                  'Sans cette autorisation, l\'application ne peut pas fonctionner correctement.\n\n'
                  'Les notifications dans l\'app (cloche) restent disponibles, mais vous ne recevrez pas '
                  'd\'alerte sur l\'écran de verrouillage.',
                  style: TextStyle(color: Colors.grey.shade700, height: 1.45),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 16),
                  Text(_status!, style: TextStyle(color: Colors.orange.shade800, fontSize: 13)),
                ],
                const Spacer(),
                FilledButton.icon(
                  onPressed: _requesting ? null : _request,
                  icon: _requesting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.notifications),
                  label: Text(_requesting ? 'Vérification…' : 'Autoriser les notifications'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => AppPermissionsService.instance.openSystemSettings(),
                  icon: const Icon(Icons.settings),
                  label: const Text('Ouvrir les paramètres'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
