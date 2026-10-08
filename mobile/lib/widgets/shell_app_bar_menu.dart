import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/navigation/shell_navigation.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/notification_provider.dart';
import 'package:jobbingtrack_mobile/services/global_search.dart';
import 'package:jobbingtrack_mobile/utils/auth_logout.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';

/// Menu ⋮ shell : notifications (hors icône AppBar), recherche, paramètres, déconnexion.
class ShellAppBarMenu extends StatelessWidget {
  const ShellAppBarMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<NotificationProvider>().unreadCount;

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      onSelected: (value) async {
        switch (value) {
          case 'notifications':
            await MobileNotificationCenter.openSheet(context);
          case 'search':
            openGlobalSearch(context);
          case 'settings':
            Navigator.of(context).pushNamed('/settings');
          case 'logout':
            await AuthLogout.confirmAndPerform(context);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'notifications',
          child: Semantics(
            label: 'Notifications',
            button: true,
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                leading: Badge(
                  isLabelVisible: unread > 0,
                  label: Text(unread > 9 ? '9+' : '$unread'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                title: Text(unread > 0 ? 'Notifications ($unread)' : 'Notifications'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'search',
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              leading: const Icon(Icons.search),
              title: const Text('Recherche globale'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Paramètres'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'logout',
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              leading: Icon(Icons.logout, color: Colors.red.shade700),
              title: Text('Déconnexion', style: TextStyle(color: Colors.red.shade700)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

/// Actions AppBar shell : action contextuelle optionnelle + menu ⋮ (notifications dedans).
class ShellAppBarActions extends StatelessWidget {
  final List<Widget> leadingActions;

  const ShellAppBarActions({super.key, this.leadingActions = const []});

  @override
  Widget build(BuildContext context) {
    final email = context.watch<AuthProvider>().user?.email;
    final letter = (email != null && email.trim().isNotEmpty)
        ? email.trim()[0].toUpperCase()
        : 'H';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...leadingActions,
        IconButton(
          tooltip: 'Compte',
          onPressed: () => ShellNavigation.navigateFromDrawer(context, '/profile'),
          icon: CircleAvatar(
            radius: 14,
            backgroundColor: const Color(0xFF0E4D5C).withValues(alpha: 0.15),
            foregroundColor: const Color(0xFF0E4D5C),
            child: Text(letter, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ),
        const ShellAppBarMenu(),
      ],
    );
  }
}
