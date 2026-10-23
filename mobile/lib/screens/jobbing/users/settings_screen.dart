import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/users/help_feedback_screen.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/crash_reporter.dart';
import 'package:jobbingtrack_mobile/services/mobile_analytics_service.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';
import 'package:jobbingtrack_mobile/services/biometric_auth_service.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/app_version_info.dart';
import 'package:jobbingtrack_mobile/services/local_phone_integrations_service.dart';
import 'package:jobbingtrack_mobile/services/mobile_update_controller.dart';
import 'package:jobbingtrack_mobile/services/mobile_update_service.dart';
import 'package:jobbingtrack_mobile/services/network_recovery_service.dart';
import 'package:jobbingtrack_mobile/services/offline_business_sync_queue.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/back_to_home_scope.dart';
import 'package:jobbingtrack_mobile/services/theme_controller.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_update_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  bool _consent = false;
  bool _performance = true;
  bool _activityTrace = true;
  bool _interimMode = false;
  bool _biometricUnlock = false;
  bool _biometricAvailable = false;
  bool _keepLoggedIn = true;
  int _localCallLogCount = 0;
  int _localPhoneContactsCount = 0;
  DateTime? _callLogSyncedAt;
  DateTime? _phoneContactsSyncedAt;
  bool _phoneSyncing = false;
  String _appVersionLine = '…';
  int _offlinePending = 0;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    await MobileAnalyticsService.instance.reloadFromStore(authToken: auth.token);
    final consent = await ApiConfigStore.loadAnalyticsConsent();
    final perf = await ApiConfigStore.loadPerformanceTelemetryEnabled();
    final trace = await ApiConfigStore.loadActivityTraceEnabled();
    final interim = await ApiConfigStore.loadInterimModeEnabled();
    final bio = await ApiConfigStore.loadBiometricUnlockEnabled();
    final keep = await ApiConfigStore.loadKeepLoggedIn();
    final bioAvail = await BiometricAuthService.canOfferUnlockOption();
    final callCount = await LocalPhoneIntegrationsService.getLocalCallLogCount();
    final phoneContactsCount = await LocalPhoneIntegrationsService.getLocalPhoneContactsCount();
    final callSynced = await LocalPhoneIntegrationsService.getCallLogSyncedAt();
    final contactsSynced = await LocalPhoneIntegrationsService.getContactsSyncedAt();
    final details = await AppVersionInfo.getDetails();
    await OfflineBusinessSyncQueue.instance.initialize();
    final pending = OfflineBusinessSyncQueue.instance.pendingCount;
    await MobileUpdateController.instance.refresh(silent: true);
    if (!ThemeController.instance.isLoaded) {
      await ThemeController.instance.load();
    }
    if (!mounted) return;
    setState(() {
      _consent = consent;
      _performance = perf;
      _activityTrace = trace;
      _interimMode = interim;
      _biometricUnlock = bio;
      _keepLoggedIn = keep;
      _biometricAvailable = bioAvail;
      _localCallLogCount = callCount;
      _localPhoneContactsCount = phoneContactsCount;
      _callLogSyncedAt = callSynced;
      _phoneContactsSyncedAt = contactsSynced;
      _appVersionLine = details.displayVersionLine;
      _offlinePending = pending;
      _themeMode = ThemeController.instance.mode;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);

    return BackToHomeScope(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Paramètres'),
          centerTitle: true,
          actions: [MobileNotificationCenter()],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: scrollSafePadding(context),
                children: [
                  _sectionTitle('Confidentialité & télémétrie'),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('Partager des données anonymes'),
                          subtitle: const Text(
                            'Performances, navigation et stabilité — sans contenu personnel (RGPD).',
                          ),
                          value: _consent,
                          onChanged: (v) async {
                            setState(() => _consent = v);
                            await MobileAnalyticsService.instance.setConsent(
                              v,
                              authToken: auth.token,
                            );
                            if (v) {
                              setState(() {
                                _performance = true;
                                _activityTrace = true;
                              });
                            }
                          },
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('Performances anonymes'),
                          subtitle: const Text('Latence API, mémoire, durée de session'),
                          value: _consent && _performance,
                          onChanged: _consent
                              ? (v) async {
                                  setState(() => _performance = v);
                                  await MobileAnalyticsService.instance.setPerformanceEnabled(v);
                                }
                              : null,
                        ),
                        SwitchListTile(
                          title: const Text('Trace d\'activité'),
                          subtitle: const Text('Écrans visités, types d\'actions — pas de texte saisi'),
                          value: _consent && _activityTrace,
                          onChanged: _consent
                              ? (v) async {
                                  setState(() => _activityTrace = v);
                                  await MobileAnalyticsService.instance.setActivityTraceEnabled(v);
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Les retours manuels (bug, signalement) peuvent inclure un diagnostic technique sur votre demande, même si la télémétrie est désactivée.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Aide & retours'),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.bug_report_outlined, color: Colors.orange.shade700),
                          title: const Text('Signaler un bug'),
                          subtitle: const Text('Problème technique, écran bloqué, crash'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openFeedback(context, HelpFeedbackType.bug),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.lightbulb_outline, color: Colors.amber.shade800),
                          title: const Text('Suggestion'),
                          subtitle: const Text('Idée d\'amélioration produit'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openFeedback(context, HelpFeedbackType.suggestion),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.flag_outlined, color: Colors.red.shade700),
                          title: const Text('Signalement'),
                          subtitle: const Text('Comportement suspect, données, sécurité'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openFeedback(context, HelpFeedbackType.signalement),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.insights_outlined, color: Colors.blue.shade700),
                          title: const Text('Diagnostic local'),
                          subtitle: const Text('Voir le résumé technique de cette session'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showDiagnostics(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Apparence'),
                  Card(
                    child: Column(
                      children: [
                        for (final mode in ThemeMode.values) ...[
                          if (mode != ThemeMode.values.first) const Divider(height: 1),
                          RadioListTile<ThemeMode>(
                            title: Text(ThemeController.label(mode)),
                            subtitle: mode == ThemeMode.system
                                ? const Text('Suit le réglage Android / iOS')
                                : null,
                            value: mode,
                            groupValue: _themeMode,
                            onChanged: (v) async {
                              if (v == null) return;
                              setState(() => _themeMode = v);
                              await ThemeController.instance.setMode(v);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Parcours & sécurité'),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('Mode intérim'),
                          subtitle: const Text(
                            'Affiche l\'onglet Intérim, le champ agence sur les candidatures et les couleurs ambre au calendrier.',
                          ),
                          value: _interimMode,
                          onChanged: (v) async {
                            setState(() => _interimMode = v);
                            await ApiConfigStore.saveInterimModeEnabled(v);
                          },
                        ),
                        if (_biometricAvailable) ...[
                          const Divider(height: 1),
                          SwitchListTile(
                            title: const Text('Déverrouillage biométrique'),
                            subtitle: Text(
                              _keepLoggedIn
                                  ? 'Identifiants chiffrés (Keychain/Keystore) + empreinte au lancement'
                                  : 'Activez « Garder la connexion » à la prochaine connexion',
                            ),
                            value: _keepLoggedIn && _biometricUnlock,
                            onChanged: _keepLoggedIn
                                ? (v) => _setBiometricUnlock(context, auth, v)
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Téléphone (local uniquement)'),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.phone_in_talk_outlined),
                          title: const Text('Historique d\'appels téléphone'),
                          subtitle: Text(
                            _localCallLogCount > 0
                                ? '$_localCallLogCount entrée(s)${_callLogSyncedAt != null ? ' · ${_formatSyncDate(_callLogSyncedAt!)}' : ''}'
                                : 'Non importé — données stockées uniquement sur cet appareil',
                          ),
                          trailing: _phoneSyncing
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.download_outlined),
                          onTap: _phoneSyncing ? null : () => _syncCallLog(context),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.contacts_outlined),
                          title: const Text('Contacts du téléphone'),
                          subtitle: Text(
                            _localPhoneContactsCount > 0
                                ? '$_localPhoneContactsCount contact(s) sur cet appareil · proposés au picker (création Hubera Jobs manuelle)'
                                : 'Import local uniquement — pas de création auto dans Hubera Jobs',
                          ),
                          trailing: _phoneSyncing
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.download_outlined),
                          onTap: _phoneSyncing ? null : () => _syncPhoneContacts(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Recherche d\'emploi'),
                  Card(
                    child: Semantics(
                      label: 'Agent email',
                      button: true,
                      child: ListTile(
                        leading: const Icon(Icons.mark_email_read_outlined),
                        title: const Text('Agent email'),
                        subtitle: const Text(
                          'Boîtes IMAP, triage candidatures, digest — consentements et sync.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).pushNamed('/email-agent'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Mise à jour & synchronisation'),
                  Card(
                    child: AnimatedBuilder(
                      animation: MobileUpdateController.instance,
                      builder: (context, _) {
                        final ctrl = MobileUpdateController.instance;
                        final hasUpdate = ctrl.hasUpdate;
                        final last = ctrl.lastCheckedAt;
                        final lastLabel = last == null
                            ? 'Pas encore vérifié'
                            : 'Vérifié ${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
                        return Column(
                          children: [
                            ListTile(
                              leading: Icon(
                                hasUpdate ? Icons.system_update_alt : Icons.system_update_outlined,
                                color: hasUpdate ? Colors.blue : null,
                              ),
                              title: Text(hasUpdate ? 'Mise à jour disponible' : 'Application à jour'),
                              subtitle: Text(
                                '$_appVersionLine · canal ${MobileUpdateService.releaseChannel}\n'
                                '$lastLabel'
                                '${ctrl.lastError != null ? '\nErreur: ${ctrl.lastError}' : ''}',
                              ),
                              isThreeLine: true,
                              trailing: ctrl.checking
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.refresh),
                              onTap: ctrl.checking
                                  ? null
                                  : () async {
                                      final result = await ctrl.refresh(silent: true);
                                      if (!mounted) return;
                                      if (result != null) {
                                        await showMobileUpdateDialog(
                                          context,
                                          release: result.release,
                                          currentVersion: result.current,
                                          forceUpdate: result.blocked,
                                          buildsBehind: result.buildsBehind,
                                        );
                                        await ctrl.refresh(silent: true);
                                      } else if (ctrl.lastError != null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Vérification échouée: ${ctrl.lastError}')),
                                        );
                                      } else {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Aucune mise à jour disponible')),
                                        );
                                      }
                                      setState(() {});
                                    },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.cloud_sync_outlined),
                              title: const Text('Synchroniser maintenant'),
                              subtitle: Text(
                                _offlinePending > 0
                                    ? '$_offlinePending modification(s) en attente'
                                    : 'File vide — sync au retour réseau automatique',
                              ),
                              trailing: const Icon(Icons.play_arrow),
                              onTap: () async {
                                final ok = await NetworkRecoveryService.recoverConnection();
                                await OfflineBusinessSyncQueue.instance.flush();
                                await OfflineBusinessSyncQueue.instance.initialize();
                                if (!mounted) return;
                                setState(() {
                                  _offlinePending = OfflineBusinessSyncQueue.instance.pendingCount;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? 'Sync terminée ($_offlinePending restant(s))'
                                          : 'Réseau indisponible — les actions restent en file',
                                    ),
                                  ),
                                );
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.info_outline),
                              title: const Text('Hubera Jobs'),
                              subtitle: Text('$_appVersionLine · API ${ApiService.baseUrl}'),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
    );
  }

  String _formatSyncDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _syncCallLog(BuildContext context) async {
    setState(() => _phoneSyncing = true);
    try {
      final count = await LocalPhoneIntegrationsService.syncCallLogLocally();
      if (!mounted) return;
      setState(() {
        _localCallLogCount = count;
        _callLogSyncedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count appel(s) importé(s) localement')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _phoneSyncing = false);
    }
  }

  Future<void> _syncPhoneContacts(BuildContext context) async {
    setState(() => _phoneSyncing = true);
    try {
      final count = await LocalPhoneIntegrationsService.syncPhoneContactsLocally();
      if (!mounted) return;
      setState(() {
        _localPhoneContactsCount = count;
        _phoneContactsSyncedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'Aucun contact téléphone (permission ou carnet vide)'
                : '$count contact(s) prêt(s) sur cet appareil — '
                    'ils seront proposés quand vous ajoutez un contact à une candidature '
                    '(pas créés automatiquement dans Hubera Jobs).',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _phoneSyncing = false);
    }
  }

  void _openFeedback(BuildContext context, HelpFeedbackType type) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HelpFeedbackScreen(type: type)),
    );
  }

  Future<void> _setBiometricUnlock(BuildContext context, AuthProvider auth, bool enabled) async {
    if (!enabled) {
      setState(() => _biometricUnlock = false);
      await auth.disableBiometricUnlock();
      return;
    }

    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activer la biométrie'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Confirmez votre mot de passe pour enregistrer vos identifiants de façon chiffrée sur cet appareil.',
              style: TextStyle(color: Colors.grey.shade700, height: 1.35),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Mot de passe actuel'),
            ),
            if (kDebugMode) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('Coller depuis le presse-papier'),
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    controller.text = data.text!;
                  }
                },
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Activer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await auth.verifyPasswordForBiometric(controller.text);
      await auth.saveBiometricCredentials(controller.text.trim());
      final bio = await BiometricAuthService.authenticate(
        reason: 'Confirmez votre identité pour activer le déverrouillage',
      );
      if (!mounted) return;
      setState(() => _biometricUnlock = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            bio.success
                ? 'Déverrouillage biométrique activé'
                : 'Biométrie enregistrée — empreinte ou code appareil au prochain lancement',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  void _showDiagnostics(BuildContext context) {
    final preview = MobileAnalyticsService.instance.localDiagnosticsPreview();
    final device = CrashReporter.getDeviceMonitoring();
    final errors = preview['errorCounts'] is Map
        ? Map<String, dynamic>.from(preview['errorCounts'] as Map)
        : <String, dynamic>{};
    final lines = <String>[
      '--- Session ---',
      ...preview.entries.where((e) => e.key != 'errorCounts').map((e) => '${e.key}: ${e.value}'),
      '',
      '--- Appareil ---',
      'memoryRssBytes: ${device['memoryRssBytes'] ?? '—'}',
      'platform: ${device['platform'] ?? Platform.operatingSystem}',
      '',
      '--- Erreurs réseau / app (${errors.length}) ---',
      if (errors.isEmpty) 'Aucune erreur enregistrée cette session',
      ...errors.entries.map((e) => '${e.key}: ${e.value}x'),
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnostic local'),
        content: SingleChildScrollView(
          child: Text(
            lines.join('\n'),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
        ],
      ),
    );
  }
}
