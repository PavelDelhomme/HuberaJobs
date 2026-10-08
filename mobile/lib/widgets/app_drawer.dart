import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/navigation/shell_navigation.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/app_version_info.dart';
import 'package:jobbingtrack_mobile/utils/admin_access.dart';
import 'package:jobbingtrack_mobile/utils/auth_logout.dart';
import 'package:jobbingtrack_mobile/widgets/impersonation_banner.dart';
import 'package:jobbingtrack_mobile/theme/theme_extensions.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({super.key});

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  bool _interimMode = false;
  AppVersionDetails? _appVersion;

  @override
  void initState() {
    super.initState();
    _loadInterimMode();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final details = await AppVersionInfo.getDetails();
    if (!mounted) return;
    setState(() => _appVersion = details);
  }

  Future<void> _loadInterimMode() async {
    final enabled = await ApiConfigStore.loadInterimModeEnabled();
    if (!mounted || enabled == _interimMode) return;
    setState(() => _interimMode = enabled);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInterimMode());
    final authProvider = Provider.of<AuthProvider>(context);
    final user = authProvider.user;
    final isAdmin = AdminAccess.canAccessAdmin(user);
    final isImpersonating = authProvider.isImpersonating;
    final cs = context.cs;

    return ValueListenableBuilder<int>(
      valueListenable: ShellTabRegistry.revision,
      builder: (context, _, __) => Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (isImpersonating)
            Material(
              elevation: 4,
              color: cs.tertiaryContainer,
              child: ListTile(
                leading: Icon(Icons.switch_account, color: cs.onTertiaryContainer),
                title: Text(
                  'Désimpersonnaliser',
                  style: TextStyle(
                    color: cs.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Impersonnalisation — ${user?.email ?? ''}\nRetour au hub administrateur',
                  style: TextStyle(
                    color: cs.onTertiaryContainer.withValues(alpha: 0.85),
                    fontSize: 12,
                  ),
                ),
                isThreeLine: true,
                onTap: () async {
                  Navigator.of(context).pop();
                  await ImpersonationBanner.exitAndRestoreAdminSession(context);
                },
              ),
            ),
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  cs.primary,
                  cs.primary.withValues(alpha: 0.82),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            currentAccountPicture: CircleAvatar(
              backgroundColor: cs.onPrimary.withValues(alpha: 0.15),
              child: Text(
                (user?.firstName.isNotEmpty == true
                        ? user!.firstName.substring(0, 1)
                        : 'U')
                    .toUpperCase(),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: cs.onPrimary,
                ),
              ),
            ),
            accountName: Text(
              '${user?.firstName ?? ''} ${user?.lastName ?? ''}'.trim(),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            accountEmail: Text(
              user?.email ?? '',
              style: const TextStyle(
                fontSize: 14,
              ),
            ),
            onDetailsPressed: () =>
                ShellNavigation.navigateFromDrawer(context, '/profile'),
          ),

          // Navigation principale
          _buildDrawerSection(
            context,
            title: 'NAVIGATION',
            items: [
              _DrawerItem(
                icon: Icons.home,
                title: 'Accueil',
                route: '/home',
              ),
              _DrawerItem(
                icon: Icons.assignment,
                title: 'Candidatures',
                route: '/applications',
              ),
              if (_interimMode)
                _DrawerItem(
                  icon: Icons.business_center,
                  title: 'Intérim',
                  route: '/interim',
                ),
              _DrawerItem(
                icon: Icons.search,
                title: 'Recherche globale',
                route: '/search',
              ),
              _DrawerItem(
                icon: Icons.business,
                title: 'Entreprises',
                route: '/companies',
              ),
              _DrawerItem(
                icon: Icons.people,
                title: 'Contacts',
                route: '/contacts',
              ),
              _DrawerItem(
                icon: Icons.event,
                title: 'Entretiens',
                route: '/interviews',
              ),
              _DrawerItem(
                icon: Icons.phone,
                title: 'Appels',
                route: '/calls',
              ),
              _DrawerItem(
                icon: Icons.schedule_send,
                title: 'Relances',
                route: '/followups',
              ),
            ],
          ),

          const Divider(),

          // Administration — visible uniquement pour comptes admin autorisés
          if (isAdmin)
            _buildDrawerSection(
              context,
              title: 'ADMINISTRATION',
              items: [
                _DrawerItem(
                  icon: Icons.admin_panel_settings,
                  title: 'Hub administration',
                  route: '/admin',
                ),
                _DrawerItem(
                  icon: Icons.analytics,
                  title: 'Analytics',
                  route: '/analytics',
                ),
                _DrawerItem(
                  icon: Icons.bar_chart,
                  title: 'Statistiques',
                  route: '/statistics',
                ),
                _DrawerItem(
                  icon: Icons.people_alt,
                  title: 'Utilisateurs',
                  route: '/users',
                ),
                _DrawerItem(
                  icon: Icons.article,
                  title: 'Logs',
                  route: '/logs',
                ),
                _DrawerItem(
                  icon: Icons.delete_outline,
                  title: 'Corbeille',
                  route: '/trash',
                ),
              ],
            ),

          const Divider(),
          _HuberaSuiteGrid(),
          const Divider(),

          // Paramètres et profil
          _buildDrawerSection(
            context,
            title: 'COMPTE',
            items: [
              _DrawerItem(
                icon: Icons.settings,
                title: 'Paramètres',
                route: '/settings',
              ),
              _DrawerItem(
                icon: Icons.mark_email_read_outlined,
                title: 'Agent email',
                route: '/email-agent',
              ),
            ],
          ),

          const Divider(),

          // Déconnexion
          ListTile(
            leading: Icon(Icons.logout, color: cs.error),
            title: Text(
              'Déconnexion',
              style: TextStyle(
                color: cs.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () async {
              await AuthLogout.confirmAndPerform(context);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),

          // Version de l'app (semver + build — voir docs/mobile/VERSIONNEMENT.md)
          if (_appVersion != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  Text(
                    _appVersion!.displayVersionLine,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (_appVersion!.displayBuildLine != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _appVersion!.displayBuildLine!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    ),
    );
  }

  Widget _buildDrawerSection(
    BuildContext context, {
    required String title,
    required List<_DrawerItem> items,
  }) {
    final cs = context.cs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ),
        ...items.map((item) => _buildDrawerTile(context, item)),
      ],
    );
  }

  Widget _buildDrawerTile(BuildContext context, _DrawerItem item) {
    final isSelected = ShellNavigation.isDrawerRouteSelected(item.route);
    final cs = context.cs;

    return ListTile(
      leading: Icon(
        item.icon,
        color: isSelected ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Text(
        item.title,
        style: TextStyle(
          color: isSelected ? cs.primary : cs.onSurface,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      selected: isSelected,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.55),
      onTap: () => ShellNavigation.navigateFromDrawer(context, item.route),
    );
  }
}

class _DrawerItem {
  final IconData icon;
  final String title;
  final String route;

  _DrawerItem({
    required this.icon,
    required this.title,
    required this.route,
  });
}

class _HuberaSuiteGrid extends StatelessWidget {
  static const _apps = <(String, String, IconData)>[
    ('Music', 'https://music.hubera.cloud', Icons.music_note_outlined),
    ('Maps', 'https://maps.hubera.cloud', Icons.map_outlined),
    ('Fuel', 'https://fuel.hubera.cloud', Icons.directions_car_outlined),
    ('Docs', 'https://docs.hubera.cloud', Icons.menu_book_outlined),
    ('Agenda', 'https://calendar.hubera.cloud', Icons.calendar_month_outlined),
    ('Mail', 'https://mail.hubera.cloud', Icons.mail_outline),
    ('Pass', 'https://pass.hubera.cloud', Icons.lock_outline),
    ('ID', 'https://id.hubera.cloud', Icons.person_outline),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Apps Hubera', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.85,
            children: [
              for (final app in _apps)
                InkWell(
                  onTap: () => launchUrl(Uri.parse(app.$2), mode: LaunchMode.externalApplication),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(app.$3, color: const Color(0xFF0E4D5C), size: 22),
                      const SizedBox(height: 4),
                      Text(app.$1, style: Theme.of(context).textTheme.labelSmall, textAlign: TextAlign.center),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

