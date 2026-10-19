import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/users/profile_edit_screen.dart';
import 'package:jobbingtrack_mobile/widgets/shell_app_bar_menu.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer_leading.dart';
import 'package:jobbingtrack_mobile/widgets/drawer_back_scope.dart';
import 'package:jobbingtrack_mobile/utils/shell_layout.dart';

class ProfileScreen extends StatefulWidget {
  final bool isShellVisible;

  const ProfileScreen({super.key, this.isShellVisible = true});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static Future<void> _requestPasswordReset(BuildContext context, AuthProvider auth) async {
    final email = auth.user?.email ?? '';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Changer le mot de passe'),
        content: Text(
          'Un lien de réinitialisation sera envoyé à :\n\n$email\n\n'
          'Vous pourrez définir un nouveau mot de passe depuis le mail (lien mobile ou web).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer le lien')),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    try {
      await auth.requestPasswordResetForCurrentUser();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email de réinitialisation envoyé — consultez votre boîte mail'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final user = auth.user;

    return Scaffold(
      key: _scaffoldKey,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: const AppDrawerLeadingButton(),
        automaticallyImplyLeading: false,
        title: const Text('Profil'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Modifier',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
            ),
          ),
          const ShellAppBarMenu(),
        ],
      ),
      body: DrawerBackScope(
        scaffoldKey: _scaffoldKey,
        active: widget.isShellVisible,
        child: shellUpdateBannerBody(
          child: SafeArea(
          top: false,
          child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CircleAvatar(
              radius: 36,
              child: Text(
                (user?.firstName.isNotEmpty == true ? user!.firstName[0] : 'U').toUpperCase(),
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${user?.firstName ?? ''} ${user?.lastName ?? ''}'.trim(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            if (user?.email != null)
              Text(
                user!.email,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
            if (user != null && user.phone.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                user.phone,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Modifier le profil'),
                    subtitle: const Text('Prénom, nom, téléphone, email'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_reset),
                    title: const Text('Changer le mot de passe'),
                    subtitle: const Text('Recevoir un lien par email'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _requestPasswordReset(context, auth),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Paramètres & confidentialité'),
                    subtitle: const Text('Télémétrie, aide, retours'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pushNamed('/settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}
