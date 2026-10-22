import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/company_provider.dart';
import 'package:jobbingtrack_mobile/providers/contact_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/contacts/contact_detail_screen.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/hubera_id_sso.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';
import 'package:jobbingtrack_mobile/utils/list_item_meta.dart';
import 'package:jobbingtrack_mobile/widgets/contact_create_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String _query = '';
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _loadError = null);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    try {
      await Provider.of<CompanyProvider>(context, listen: false).loadCompanies(token: token, force: force);
      await Provider.of<ContactProvider>(context, listen: false).loadContacts(token: token, force: force);
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = e.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  List<Map<String, dynamic>> _filtered(List<dynamic> contacts) {
    final q = _query.trim().toLowerCase();
    final list = contacts.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (q.isEmpty) return list;
    return list.where((c) {
      final name = contactDisplayName(c).toLowerCase();
      final email = (c['email'] ?? '').toString().toLowerCase();
      return name.contains(q) || email.contains(q);
    }).toList();
  }

  Future<void> _importHuberaContacts() async {
    final accounts = await HuberaIdSso.listAccounts();
    final token = accounts.isNotEmpty
        ? accounts.first.accessToken
        : Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connecte Hubera ID pour importer.')),
      );
      return;
    }
    try {
      final res = await http.get(
        Uri.parse('https://contacts.hubera.cloud/contacts'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw Exception('Hubera Contacts HTTP ${res.statusCode}');
      }
      final decoded = jsonDecode(res.body);
      final list = decoded is List ? decoded : (decoded is Map ? decoded['contacts'] : null);
      if (list is! List) throw Exception('Réponse Contacts invalide');
      final jobsToken = Provider.of<AuthProvider>(context, listen: false).token;
      var n = 0;
      for (final raw in list.take(40)) {
        if (raw is! Map) continue;
        final email = (raw['email'] ?? '').toString().trim();
        final name = (raw['display_name'] ?? raw['name'] ?? '').toString().trim();
        if (email.isEmpty && name.isEmpty) continue;
        final parts = name.split(RegExp(r'\s+'));
        await ApiService.createContact(
          firstName: parts.isNotEmpty ? parts.first : (email.split('@').first),
          lastName: parts.length > 1 ? parts.sublist(1).join(' ') : '',
          email: email.isEmpty ? null : email,
          token: jobsToken,
        );
        n += 1;
      }
      if (!mounted) return;
      await _load(force: true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$n contact(s) Hubera importé(s).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import Hubera Contacts : $e')),
      );
    }
  }

  Future<void> _createContact() async {
    final created = await showCreateContactSheet(context);
    if (created != null && mounted) {
      await _load(force: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact créé')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactProvider>();
    final contacts = _filtered(provider.contacts);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        centerTitle: true,
        actions: const [MobileNotificationCenter()],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'fab_contacts_list',
        onPressed: () async {
          final choice = await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_add_outlined),
                    title: const Text('Nouveau contact Jobs'),
                    onTap: () => Navigator.pop(ctx, 'new'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_download_outlined),
                    title: const Text('Depuis Hubera Contacts'),
                    onTap: () => Navigator.pop(ctx, 'hubera'),
                  ),
                ],
              ),
            ),
          );
          if (choice == 'hubera') {
            await _importHuberaContacts();
          } else if (choice == 'new') {
            await _createContact();
          }
        },
        child: const Icon(Icons.person_add_outlined),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Rechercher un contact…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: provider.isLoading && provider.contacts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null && provider.contacts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_loadError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: _load, child: const Text('Réessayer')),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: contacts.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 80),
                                  Center(child: Text('Aucun contact')),
                                ],
                              )
                            : ListView.builder(
                                itemCount: contacts.length,
                                itemBuilder: (_, i) {
                                  final c = contacts[i];
                                  final meta = contactListSubtitle(c);
                                  return ListTile(
                                    leading: CircleAvatar(
                                      child: Text(
                                        contactDisplayName(c).isNotEmpty
                                            ? contactDisplayName(c)[0].toUpperCase()
                                            : '?',
                                      ),
                                    ),
                                    title: Text(contactDisplayName(c)),
                                    subtitle: meta.isNotEmpty
                                        ? Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis)
                                        : null,
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ContactDetailScreen(contact: c),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
    );
  }
}
