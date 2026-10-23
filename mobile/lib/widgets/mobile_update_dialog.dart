import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jobbingtrack_mobile/services/mobile_update_controller.dart';
import 'package:jobbingtrack_mobile/services/mobile_update_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

String _versionLabel(String raw) {
  final parts = raw.split('+');
  if (parts.length < 2 || parts[1].isEmpty) return raw;
  return '${parts[0]} (build ${parts[1]})';
}

Future<bool> showMobileUpdateDialog(
  BuildContext context, {
  required MobileReleaseInfo release,
  required String currentVersion,
  required bool forceUpdate,
  int buildsBehind = 0,
}) async {
  var installing = false;
  double progress = 0;
  String? error;

  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: !forceUpdate,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> install() async {
            setState(() {
              installing = true;
              error = null;
              progress = 0;
            });
            try {
              if (Platform.isAndroid) {
                final url = release.downloadUrl;
                if (url == null || url.isEmpty) {
                  throw Exception(
                    'URL de téléchargement APK absente côté serveur. '
                    'Republiez la release OTA (canal ${MobileUpdateService.releaseChannel}).',
                  );
                }
                await MobileUpdateService.downloadAndInstallAndroid(
                  url,
                  onProgress: (p) {
                    MobileUpdateController.instance.setDownloadProgress(p);
                    if (context.mounted) setState(() => progress = p);
                  },
                );
              } else {
                final store = release.storeUrl ?? release.downloadUrl;
                if (store == null || store.isEmpty) {
                  throw Exception('URL App Store absente côté serveur');
                }
                final uri = Uri.parse(store);
                if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                  throw Exception('Impossible d’ouvrir l’App Store');
                }
              }
              if (context.mounted) Navigator.of(context).pop(false);
            } catch (e) {
              setState(() {
                installing = false;
                error = e.toString().replaceFirst('Exception: ', '');
              });
            } finally {
              MobileUpdateController.instance.setDownloadProgress(null);
            }
          }

          Future<void> later() async {
            await MobileUpdateController.instance.snoozeLater();
            if (context.mounted) Navigator.of(context).pop(true);
          }

          return AlertDialog(
            title: Text(forceUpdate ? 'Mise à jour obligatoire' : 'Nouvelle version disponible'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Installée : ${_versionLabel(currentVersion)}'),
                  Text('Disponible : ${_versionLabel(release.displayVersion)}'),
                  if (buildsBehind > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        buildsBehind >= MobileUpdateService.catchUpForceAfterBuilds
                            ? 'Vous avez environ $buildsBehind versions de retard — mise à jour fortement recommandée (session conservée).'
                            : 'Environ $buildsBehind versions de retard — vous pouvez rattraper en une seule installation.',
                        style: TextStyle(
                          fontSize: 13,
                          color: buildsBehind >= MobileUpdateService.catchUpForceAfterBuilds
                              ? Colors.orange.shade800
                              : Colors.grey[700],
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Canal OTA : ${MobileUpdateService.releaseChannel}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isAndroid
                        ? 'Téléchargement depuis le serveur Hubera Jobs. '
                            'Votre session est conservée (même application, pas de désinstallation).'
                        : 'Données et session conservées.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                  if (!forceUpdate)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '« Plus tard » : rappel dans 2 heures.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                  if (release.releaseNotes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(release.releaseNotes),
                  ],
                  if (installing) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: progress <= 0 ? null : progress,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      progress >= 1
                          ? 'Ouverture de l’installateur…'
                          : 'Téléchargement ${(progress * 100).clamp(0, 100).toStringAsFixed(0)} %',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                    if (error!.toLowerCase().contains('permission') ||
                        error!.toLowerCase().contains('installer')) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => openAppSettings(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Ouvrir les paramètres d’installation'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              if (!forceUpdate)
                TextButton(
                  onPressed: installing ? null : later,
                  child: const Text('Plus tard (2 h)'),
                ),
              FilledButton(
                onPressed: installing ? null : install,
                child: Text(Platform.isAndroid ? 'Télécharger' : 'Ouvrir l’App Store'),
              ),
            ],
          );
        },
      );
    },
  );

  return proceed ?? false;
}
