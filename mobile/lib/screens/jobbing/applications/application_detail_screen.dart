import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/models/call.dart';
import 'package:jobbingtrack_mobile/models/followup.dart';
import 'package:jobbingtrack_mobile/models/interview.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/followup_provider.dart';
import 'package:jobbingtrack_mobile/providers/interview_provider.dart';
import 'package:jobbingtrack_mobile/providers/contact_provider.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/applications/application_form_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/calls/call_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/companies/company_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/contacts/contact_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/followups/followup_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/interviews/interview_detail_screen.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';
import 'package:jobbingtrack_mobile/utils/app_snack.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/providers/notification_provider.dart';
import 'package:jobbingtrack_mobile/utils/contact_name_utils.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/contact_picker_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';
import 'package:jobbingtrack_mobile/widgets/entity_detail_field.dart';

/// Détail complet d'une candidature : entreprise, contacts, relances, entretiens, appels.
class ApplicationDetailScreen extends StatefulWidget {
  final Application application;

  const ApplicationDetailScreen({super.key, required this.application});

  @override
  State<ApplicationDetailScreen> createState() => _ApplicationDetailScreenState();
}

class _ApplicationDetailScreenState extends State<ApplicationDetailScreen> {
  Application? _application;
  List<Map<String, dynamic>> _contacts = [];
  List<FollowUp> _followUps = [];
  List<Interview> _interviews = [];
  List<Call> _calls = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _application = widget.application;
    _load();
  }

  Future<void> _load() async {
    if (!await ApiService.isReachable()) {
      await ApiService.prepareForLogin();
    }
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    setState(() => _loading = true);
    Application? application = _application;
    var contacts = _contacts;
    var followUps = _followUps;
    var interviews = _interviews;
    var calls = _calls;
    final errors = <String>[];

    try {
      application = await ApiService.getApplication(widget.application.id, token: token);
    } catch (e) {
      errors.add('Candidature : ${e.toString().replaceAll('Exception: ', '')}');
    }
    try {
      contacts = await ApiService.getContactsByApplication(widget.application.id, token: token);
    } catch (e) {
      errors.add('Contacts : ${e.toString().replaceAll('Exception: ', '')}');
    }
    try {
      followUps = await ApiService.getFollowUps(applicationId: widget.application.id, token: token);
    } catch (e) {
      errors.add('Relances : ${e.toString().replaceAll('Exception: ', '')}');
    }
    try {
      interviews = await ApiService.getInterviews(applicationId: widget.application.id, token: token);
    } catch (e) {
      errors.add('Entretiens : ${e.toString().replaceAll('Exception: ', '')}');
    }
    try {
      calls = await ApiService.getCallsByApplication(widget.application.id, token: token);
    } catch (e) {
      errors.add('Appels : ${e.toString().replaceAll('Exception: ', '')}');
    }

    if (mounted) {
      setState(() {
        if (application != null) _application = application;
        _contacts = contacts;
        _followUps = followUps;
        _interviews = interviews;
        _calls = calls;
        _loading = false;
      });
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errors.join('\n')), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  Future<void> _changeStatus() async {
    final picked = await showApplicationStatusPicker(context, current: app.status);
    if (picked == null || picked == app.status || !mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      await ApiService.updateApplicationStatus(app.id, picked, token: token);
      await ApiService.updateApplicationFromPayload(
        app.id,
        {'statusEngineOptOut': true},
        token: token,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Statut : ${applicationStatusLabel(picked)} (suivi manuel)')),
        );
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Future<void> _handleContactAction(Map<String, dynamic> contact, String action) async {
    final id = contact['id']?.toString() ?? '';
    if (id.isEmpty) return;
    if (action == 'open') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ContactDetailScreen(contact: contact)),
      );
      return;
    }
    final label = contactDisplayName(contact);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'archive' ? 'Archiver le contact ?' : 'Mettre à la corbeille ?'),
        content: Text(
          action == 'archive'
              ? '$label sera déplacé vers les archives.'
              : '$label sera déplacé vers la corbeille.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (action == 'archive') {
        await ApiService.archiveContact(id, token: token);
      } else {
        await ApiService.deleteContact(id, token: token);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(action == 'archive' ? 'Contact archivé' : 'Contact mis à la corbeille')),
        );
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Application get app => _application ?? widget.application;

  Future<void> _openContactDetail(Map<String, dynamic> contact) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ContactDetailScreen(contact: contact)),
    );
    if (mounted) _load();
  }

  void _showCreatedSnack(String message, {VoidCallback? onOpen}) {
    AppSnack.show(
      message,
      duration: const Duration(seconds: 3),
      action: onOpen != null
          ? SnackBarAction(
              label: 'Voir détail',
              textColor: Colors.white,
              onPressed: onOpen,
            )
          : null,
      context: context,
    );
  }

  void _mergeContactIntoList(Map<String, dynamic> contact) {
    final id = contact['id']?.toString();
    if (id == null || id.isEmpty) return;
    if (_contacts.any((c) => c['id']?.toString() == id)) return;
    setState(() => _contacts = [..._contacts, contact]);
  }

  Future<Map<String, dynamic>> _createAndLinkContact({
    required String firstName,
    required String lastName,
    String? email,
    String? phone,
    String? notes,
    required String? token,
  }) async {
    final created = await ApiService.createContact(
      firstName: capitalizePersonName(firstName),
      lastName: capitalizePersonName(lastName),
      email: email ?? '',
      phone: phone ?? '',
      notes: notes,
      companyId: app.company.id.isNotEmpty ? app.company.id : null,
      token: token,
    );
    await ApiService.linkContactToApplication(
      contactId: created['id'].toString(),
      applicationId: app.id,
      token: token,
    );
    if (mounted) _mergeContactIntoList(created);
    return created;
  }

  void _notifyStatusIfChanged(String? previousStatus, {bool showSnack = true}) {
    final current = app.status;
    if (previousStatus == null || current == previousStatus || !mounted) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    Provider.of<NotificationProvider>(context, listen: false)
        .loadNotifications(token: auth.token, auth: auth)
        .catchError((_) {});
    if (!showSnack) return;
    AppSnack.show(
      'Statut mis à jour : ${applicationStatusLabel(current)}',
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: 'Notifications',
        textColor: Colors.white,
        onPressed: () {
          AppSnack.clear();
          MobileNotificationCenter.openSheet(context);
        },
      ),
      context: context,
    );
  }

  Set<String> get _applicationLinkedIds =>
      _contacts.map((c) => c['id']?.toString()).whereType<String>().where((id) => id.isNotEmpty).toSet();

  Future<({List<Map<String, dynamic>> candidates, Set<String> companyIds})> _loadContactPickerData(
    String? token,
  ) async {
    final candidates = <Map<String, dynamic>>[..._contacts];
    final companyIds = <String>{};
    if (app.company.id.isNotEmpty) {
      try {
        final byCompany = await ApiService.getContactsByCompany(app.company.id, token: token);
        for (final c in byCompany) {
          final id = c['id']?.toString();
          if (id != null) companyIds.add(id);
          if (!candidates.any((x) => x['id'] == c['id'])) candidates.add(c);
        }
      } catch (_) {}
    }
    try {
      final all = await ApiService.getContacts(token: token);
      for (final c in all) {
        if (!candidates.any((x) => x['id'] == c['id'])) candidates.add(c);
      }
    } catch (_) {}
    return (candidates: candidates, companyIds: companyIds);
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = applicationStatusColor(app.status);

    return Scaffold(
      appBar: AppBar(
        title: Text(applicationListTitle(app)),
        actions: [
          IconButton(
            tooltip: 'Modifier',
            onPressed: () async {
              final result = await ApplicationFormScreen.showCreateSheet(
                context,
                application: app,
              );
              if (result == true && mounted) _load();
            },
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: scrollSafePadding(context),
                children: [
                  _headerCard(statusColor),
                  const SizedBox(height: 16),
                  if (app.description.isNotEmpty)
                    EntityDetailField(label: 'Description', value: app.description, multiline: true),
                  if (app.location.isNotEmpty) EntityDetailField(label: 'Lieu', value: app.location),
                  if (app.notes.isNotEmpty) EntityDetailField(label: 'Notes', value: app.notes, multiline: true),
                  const SizedBox(height: 8),
                  _sectionHeader('Entreprise', onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CompanyDetailScreen(company: app.company)),
                    );
                  }),
                  _linkTile(
                    icon: Icons.business,
                    title: app.company.name.isNotEmpty ? app.company.name : 'Voir l\'entreprise',
                    subtitle: app.company.location.isNotEmpty ? app.company.location : app.company.website,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CompanyDetailScreen(company: app.company)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionHeader('Contacts'),
                  if (_contacts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Aucun contact lié', style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    ..._contacts.map((c) => _contactTile(c)),
                  const SizedBox(height: 16),
                  _sectionHeader('Relances'),
                  if (_followUps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Aucune relance', style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    ..._followUps.map((f) => _linkTile(
                          icon: Icons.schedule_send_outlined,
                          title: followUpListTitle(f),
                          subtitle: followUpStatusLabel(f.status),
                          onTap: () async {
                            final deleted = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                builder: (_) => FollowupDetailScreen(followUp: f),
                              ),
                            );
                            if (deleted == true && mounted) await _load();
                          },
                        )),
                  const SizedBox(height: 16),
                  _sectionHeader('Entretiens'),
                  if (_interviews.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Aucun entretien', style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    ..._interviews.map((i) => _linkTile(
                          icon: Icons.event_outlined,
                          title: formatSmartEventDate(i.interviewDate),
                          subtitle: i.location ?? i.notes ?? '',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => InterviewDetailScreen(interview: i)),
                          ),
                        )),
                  const SizedBox(height: 16),
                  _sectionHeader('Appels'),
                  if (_calls.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Aucun appel', style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    ..._calls.map((c) => _linkTile(
                          icon: c.isCompanyOnly ? Icons.business_outlined : Icons.phone_outlined,
                          title: c.subject,
                          subtitle: '${c.isCompanyOnly ? 'Entreprise' : 'Contact · ${c.targetLabel}'} · ${formatSmartEventDate(c.callDate)}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => CallDetailScreen(call: c)),
                          ),
                        )),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_application_detail',
        onPressed: () => _showQuickAddMenu(context),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
    );
  }

  Future<void> _showQuickAddMenu(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: const Text('Contact'),
              onTap: () => Navigator.pop(ctx, 'contact'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_outlined),
              title: const Text('Relance'),
              onTap: () => Navigator.pop(ctx, 'relance'),
            ),
            ListTile(
              leading: const Icon(Icons.event_outlined),
              title: const Text('Entretien'),
              onTap: () => Navigator.pop(ctx, 'entretien'),
            ),
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Appel'),
              onTap: () => Navigator.pop(ctx, 'appel'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'contact':
        await _showAddContact(context);
      case 'relance':
        await _showAddRelance(context);
      case 'entretien':
        await _showAddEntretien(context);
      case 'appel':
        await _showAddAppel(context);
    }
  }

  Widget _headerCard(Color statusColor) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              app.company.name.isNotEmpty ? app.company.name : 'Entreprise',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(app.position, style: TextStyle(fontSize: 14, color: Colors.purple.shade700, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(applicationStatusLabel(app.status)),
                  backgroundColor: statusColor.withValues(alpha: 0.12),
                  side: BorderSide(color: statusColor.withValues(alpha: 0.35)),
                  labelStyle: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Résultat / statut'),
                  onPressed: _changeStatus,
                ),
                Chip(
                  avatar: const Icon(Icons.event, size: 16),
                  label: Text('Postulé · ${formatSmartPostulationDate(app.appliedDate)}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {String? actionLabel, VoidCallback? onAction, VoidCallback? onTap}) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton.icon(onPressed: onAction, icon: const Icon(Icons.add, size: 18), label: Text(actionLabel)),
      ],
    );
  }

  Widget _contactTile(Map<String, dynamic> c) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.person_outline, color: Colors.blue.shade700),
        title: Text(contactDisplayName(c), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          c['email']?.toString() ?? c['phone']?.toString() ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _handleContactAction(c, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'open', child: Text('Voir le détail')),
            PopupMenuItem(value: 'archive', child: Text('Archiver')),
            PopupMenuItem(value: 'delete', child: Text('Mettre à la corbeille')),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ContactDetailScreen(contact: c)),
        ),
      ),
    );
  }

  Widget _linkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: Colors.blue.shade700),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle.isNotEmpty ? Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
        trailing: onTap != null ? const Icon(Icons.chevron_right) : null,
        onTap: onTap,
      ),
    );
  }

  Future<void> _showAddContact(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: const Text('Créer un nouveau contact'),
              onTap: () => Navigator.pop(ctx, 'create'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Lier un contact existant'),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'create') {
      await _createContactDialog();
    } else {
      await _linkExistingContact();
    }
  }

  Future<void> _createContactDialog() async {
    final firstName = TextEditingController();
    final lastName = TextEditingController();
    final email = TextEditingController();
    final phone = TextEditingController();
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouveau contact'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: 'Prénom',
                textField: true,
                child: TextField(controller: firstName, decoration: const InputDecoration(labelText: 'Prénom *'), textCapitalization: TextCapitalization.words),
              ),
              Semantics(
                label: 'Nom',
                textField: true,
                child: TextField(controller: lastName, decoration: const InputDecoration(labelText: 'Nom *'), textCapitalization: TextCapitalization.words),
              ),
              TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Notes', alignLabelWithHint: true),
                maxLines: 3,
                minLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    firstName.text = capitalizePersonName(firstName.text.trim());
    lastName.text = capitalizePersonName(lastName.text.trim());
    if (firstName.text.isEmpty || lastName.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prénom et nom sont requis.')),
      );
      return;
    }
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final created = await _createAndLinkContact(
        firstName: firstName.text.trim(),
        lastName: lastName.text.trim(),
        email: email.text.trim(),
        phone: phone.text.trim(),
        notes: notes.text.trim(),
        token: token,
      );
      if (mounted) {
        try {
          Provider.of<ContactProvider>(context, listen: false).upsertContact(created);
        } catch (_) {}
        await _load();
        _showCreatedSnack(
          'Contact ajouté',
          onOpen: () => _openContactDetail(created),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Future<void> _linkExistingContact() async {
    if (!await ApiService.isReachable()) {
      await ApiService.prepareForLogin();
    }
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final data = await _loadContactPickerData(token);
    final linkedIds = _applicationLinkedIds;
    final available = data.candidates.where((c) => !linkedIds.contains(c['id']?.toString())).toList();
    if (!mounted) return;
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucun autre contact à lier — créez-en un nouveau.')),
      );
      return;
    }
    final picked = await showContactPickerSheet(
      context,
      candidates: available,
      applicationLinkedIds: linkedIds,
      companyLinkedIds: data.companyIds,
      companyName: app.company.name,
      onCreateContact: ({
        required String firstName,
        required String lastName,
        String? email,
        String? phone,
        String? notes,
      }) =>
          _createAndLinkContact(
            firstName: firstName,
            lastName: lastName,
            email: email,
            phone: phone,
            notes: notes,
            token: token,
          ),
    );
    if (picked == null || !mounted) return;
    if (linkedIds.contains(picked['id']?.toString())) {
      await _load();
      _showCreatedSnack('Contact déjà lié', onOpen: () => _openContactDetail(picked));
      return;
    }
    try {
      await ApiService.linkContactToApplication(
        contactId: picked['id'].toString(),
        applicationId: app.id,
        token: token,
      );
      if (mounted) {
        await _load();
        _showCreatedSnack(
          'Contact lié',
          onOpen: () => _openContactDetail(picked),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Future<void> _showAddRelance(BuildContext context) async {
    final now = DateTime.now();
    // Défaut : dans 3 jours à 09:00 (évite une heure « maintenant » peu lisible).
    DateTime date = DateTime(now.year, now.month, now.day + 3, 9, 0);
    final notesController = TextEditingController();
    String channel = 'Email';
    Map<String, dynamic>? selectedContact;
    const channels = ['Email', 'Téléphone', 'LinkedIn', 'InMail', 'Courrier', 'Autre'];

    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Relance'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(formatSmartEventDate(date)),
                  subtitle: const Text('Date et heure prévues'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime.now().subtract(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked == null || !ctx.mounted) return;
                    final time = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(date),
                    );
                    setDialogState(() {
                      date = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                        time?.hour ?? 9,
                        time?.minute ?? 0,
                      );
                    });
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: channel,
                  decoration: const InputDecoration(
                    labelText: 'Canal / plateforme',
                    border: OutlineInputBorder(),
                  ),
                  items: channels.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => setDialogState(() => channel = v ?? channel),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    selectedContact == null
                        ? 'Contact (optionnel)'
                        : contactDisplayName(selectedContact!),
                  ),
                  subtitle: Text(
                    selectedContact == null
                        ? 'Relance liée à ${app.company.name.isNotEmpty ? app.company.name : "l\'entreprise"}'
                        : 'Appuyer pour changer',
                  ),
                  trailing: selectedContact != null
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(() => selectedContact = null),
                        )
                      : const Icon(Icons.person_search),
                  onTap: () async {
                    final data = await _loadContactPickerData(token);
                    final picked = await showContactPickerSheet(
                      ctx,
                      candidates: data.candidates,
                      applicationLinkedIds: _applicationLinkedIds,
                      companyLinkedIds: data.companyIds,
                      companyName: app.company.name,
                      onCreateContact: ({
                        required String firstName,
                        required String lastName,
                        String? email,
                        String? phone,
                        String? notes,
                      }) =>
                          _createAndLinkContact(
                            firstName: firstName,
                            lastName: lastName,
                            email: email,
                            phone: phone,
                            notes: notes,
                            token: token,
                          ),
                    );
                    if (picked != null) setDialogState(() => selectedContact = picked);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Contexte, message prévu, rappels…',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  minLines: 3,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      notesController.dispose();
      return;
    }
    final previousStatus = app.status;
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final noteParts = <String>['[Canal: $channel]'];
      if (notesController.text.trim().isNotEmpty) noteParts.add(notesController.text.trim());
      final created = await ApiService.createFollowUp(
        applicationId: app.id,
        followUpDate: date,
        notes: noteParts.join('\n'),
        contactId: selectedContact?['id']?.toString(),
        token: auth.token,
      );
      try {
        await Provider.of<FollowUpProvider>(context, listen: false).addFollowUp(created);
      } catch (_) {
        /* best-effort sync onglet Relances */
      }
      if (mounted) {
        await _load();
        _notifyStatusIfChanged(previousStatus, showSnack: false);
        _showCreatedSnack(
          'Relance créée',
          onOpen: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FollowupDetailScreen(followUp: created),
              ),
            );
            if (mounted) _load();
          },
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    } finally {
      notesController.dispose();
    }
  }

  Future<void> _showAddEntretien(BuildContext context) async {
    DateTime date = DateTime.now();
    final locationController = TextEditingController();
    final videoLinkController = TextEditingController();
    final durationController = TextEditingController(text: '60');
    final notesController = TextEditingController();
    String style = 'Présentiel';
    const styles = ['Présentiel', 'Distanciel', 'Hybride'];
    List<Map<String, dynamic>> selectedContacts = [];
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Nouvel entretien'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(formatSmartEventDate(date)),
                  subtitle: const Text('Date et heure (jour)'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: style,
                  decoration: const InputDecoration(labelText: 'Format', border: OutlineInputBorder()),
                  items: styles.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) => setDialogState(() => style = v ?? style),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(labelText: 'Lieu (optionnel)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: videoLinkController,
                  decoration: const InputDecoration(
                    labelText: 'Lien visio (optionnel)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: durationController,
                  decoration: const InputDecoration(
                    labelText: 'Durée estimée (minutes)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.people_outline),
                  title: Text(
                    selectedContacts.isEmpty
                        ? 'Contacts (optionnel)'
                        : '${selectedContacts.length} contact(s) sélectionné(s)',
                  ),
                  subtitle: Text(
                    selectedContacts.isEmpty
                        ? 'Lier un ou plusieurs contacts à l\'entretien'
                        : selectedContacts.map(contactDisplayName).join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: selectedContacts.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(() => selectedContacts = []),
                        )
                      : const Icon(Icons.person_search),
                  onTap: () async {
                    final data = await _loadContactPickerData(token);
                    final picked = await showMultiContactPickerSheet(
                      ctx,
                      candidates: data.candidates,
                      applicationLinkedIds: _applicationLinkedIds,
                      companyLinkedIds: data.companyIds,
                      companyName: app.company.name,
                      initialSelection: selectedContacts,
                      onCreateContact: ({
                        required String firstName,
                        required String lastName,
                        String? email,
                        String? phone,
                        String? notes,
                      }) =>
                          _createAndLinkContact(
                            firstName: firstName,
                            lastName: lastName,
                            email: email,
                            phone: phone,
                            notes: notes,
                            token: token,
                          ),
                    );
                    if (picked != null) setDialogState(() => selectedContacts = picked);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  minLines: 3,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final duration = int.tryParse(durationController.text.trim());
    if (duration != null && duration <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La durée doit être un nombre positif.')),
      );
      return;
    }
    final previousStatus = app.status;
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final noteParts = <String>['[Format: $style]'];
      if (notesController.text.trim().isNotEmpty) noteParts.add(notesController.text.trim());
      final created = await ApiService.createInterview(
        applicationId: app.id,
        interviewDate: date,
        location: locationController.text.trim().isEmpty ? null : locationController.text.trim(),
        videoLink: videoLinkController.text.trim().isEmpty ? null : videoLinkController.text.trim(),
        estimatedDuration: duration,
        notes: noteParts.join('\n'),
        contactIds: selectedContacts.map((c) => c['id'].toString()).toList(),
        token: auth.token,
      );
      try {
        Provider.of<InterviewProvider>(context, listen: false).addInterview(created);
      } catch (_) {}
      if (mounted) {
        await _load();
        _notifyStatusIfChanged(previousStatus, showSnack: false);
        _showCreatedSnack(
          'Entretien créé',
          onOpen: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => InterviewDetailScreen(interview: created)),
            );
            if (mounted) _load();
          },
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Future<void> _showAddAppel(BuildContext context) async {
    DateTime date = DateTime.now();
    final notesController = TextEditingController();
    final subjectController = TextEditingController(
      text: 'Appel · ${app.company.name.isNotEmpty ? app.company.name : app.position}',
    );
    Map<String, dynamic>? selectedContact;
    var withoutContact = false;
    final token = Provider.of<AuthProvider>(context, listen: false).token;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Nouvel appel'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(formatSmartEventDate(date)),
                  subtitle: const Text('Date de l\'appel'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime.now().subtract(const Duration(days: 30)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: subjectController,
                  decoration: const InputDecoration(labelText: 'Objet *', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    withoutContact
                        ? 'Appel sans contact'
                        : selectedContact == null
                            ? 'Contact (optionnel)'
                            : contactDisplayName(selectedContact!),
                  ),
                  subtitle: Text(
                    withoutContact
                        ? 'Lié à ${app.company.name.isNotEmpty ? app.company.name : "l\'entreprise"}'
                        : selectedContact == null
                            ? 'Choisir un contact ou appeler sans contact'
                            : 'Appuyer pour changer',
                  ),
                  trailing: (selectedContact != null || withoutContact)
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(() {
                            selectedContact = null;
                            withoutContact = false;
                          }),
                        )
                      : const Icon(Icons.person_search),
                  onTap: () async {
                    final data = await _loadContactPickerData(token);
                    final picked = await showContactPickerSheet(
                      ctx,
                      allowWithoutContact: true,
                      withoutContactLabel: app.company.name.isNotEmpty
                          ? 'Appel sans contact · ${app.company.name}'
                          : 'Appel sans contact',
                      candidates: data.candidates,
                      applicationLinkedIds: _applicationLinkedIds,
                      companyLinkedIds: data.companyIds,
                      companyName: app.company.name,
                      onCreateContact: ({required String firstName, required String lastName, String? email, String? phone, String? notes}) async {
                        return _createAndLinkContact(
                          firstName: firstName,
                          lastName: lastName,
                          email: email,
                          phone: phone,
                          notes: notes,
                          token: token,
                        );
                      },
                    );
                    if (picked == null) return;
                    setDialogState(() {
                      if (picked[kCallWithoutContactFlag] == true) {
                        withoutContact = true;
                        selectedContact = null;
                      } else {
                        withoutContact = false;
                        selectedContact = picked;
                        subjectController.text = 'Appel · ${contactDisplayName(picked)}';
                      }
                    });
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Compte-rendu, prochaines étapes…',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  minLines: 3,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (subjectController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Objet requis')));
      return;
    }
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final created = await ApiService.createCall(
        applicationId: app.id,
        callDate: date,
        subject: subjectController.text.trim(),
        notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
        contactId: withoutContact ? null : selectedContact?['id']?.toString(),
        status: inferCallStatusForDate(date),
        token: auth.token,
      );
      if (mounted) {
        await _load();
        _showCreatedSnack(
          'Appel créé',
          onOpen: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CallDetailScreen(call: created)),
            );
            if (mounted) _load();
          },
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

}
