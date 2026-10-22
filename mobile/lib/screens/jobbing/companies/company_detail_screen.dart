import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/models/call.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/models/followup.dart';
import 'package:jobbingtrack_mobile/models/interview.dart';
import 'package:jobbingtrack_mobile/providers/application_provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/contact_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/applications/application_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/calls/call_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/contacts/contact_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/companies/company_edit_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/followups/followup_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/interviews/interview_detail_screen.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/entity_detail_field.dart';
import 'package:jobbingtrack_mobile/widgets/entity_link_tile.dart';
import 'package:jobbingtrack_mobile/widgets/followup_create_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/call_create_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/interview_create_sheet.dart';

/// Fiche entreprise : infos + candidatures, contacts, relances, entretiens, appels liés.
class CompanyDetailScreen extends StatefulWidget {
  final Company company;

  const CompanyDetailScreen({super.key, required this.company});

  @override
  State<CompanyDetailScreen> createState() => _CompanyDetailScreenState();
}

class _CompanyDetailScreenState extends State<CompanyDetailScreen> {
  Company? _company;
  List<Application> _apps = [];
  List<Map<String, dynamic>> _contacts = [];
  List<FollowUp> _followUps = [];
  List<Interview> _interviews = [];
  List<Call> _calls = [];
  bool _loading = true;
  String? _contactsError;
  String? _relatedError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String _appLabel(String applicationId) {
    for (final a in _apps) {
      if (a.id == applicationId) {
        return a.position.isNotEmpty ? a.position : 'Candidature';
      }
    }
    return 'Candidature';
  }

  Future<void> _load() async {
    if (widget.company.id.isEmpty) {
      setState(() {
        _company = widget.company;
        _loading = false;
        _contactsError = null;
        _relatedError = null;
      });
      return;
    }
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    final companyId = widget.company.id;

    setState(() {
      _loading = true;
      _contactsError = null;
      _relatedError = null;
    });

    final appProvider = Provider.of<ApplicationProvider>(context, listen: false);
    await appProvider.loadApplications(token: token);

    Company company = widget.company;
    var contacts = <Map<String, dynamic>>[];
    String? contactsErr;
    final relatedErrs = <String>[];

    try {
      company = await ApiService.getCompany(companyId, token: token);
    } catch (_) {
      company = widget.company;
    }

    try {
      contacts = await ApiService.getContactsByCompany(companyId, token: token);
    } catch (e) {
      contactsErr = e.toString().replaceAll('Exception: ', '');
    }

    final providerApps =
        appProvider.applications.where((a) => a.company.id == companyId).toList();

    final contactIds = contacts
        .map((c) => c['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final appIds = providerApps.map((a) => a.id).where((id) => id.isNotEmpty).toSet();

    var followUps = <FollowUp>[];
    var interviews = <Interview>[];
    var calls = <Call>[];

    try {
      final allFollowUps = await ApiService.getFollowUps(token: token);
      followUps = allFollowUps.where((f) => appIds.contains(f.applicationId)).toList();
    } catch (e) {
      relatedErrs.add('Relances : ${e.toString().replaceAll('Exception: ', '')}');
    }

    try {
      final allInterviews = await ApiService.getInterviews(token: token);
      interviews = allInterviews.where((i) => appIds.contains(i.applicationId)).toList();
    } catch (e) {
      relatedErrs.add('Entretiens : ${e.toString().replaceAll('Exception: ', '')}');
    }

    try {
      final allCalls = await ApiService.getCalls(token: token);
      calls = allCalls.where((c) {
        if (c.companyId != null && c.companyId == companyId) return true;
        if (appIds.contains(c.applicationId)) return true;
        if (c.contactId != null && contactIds.contains(c.contactId)) return true;
        return false;
      }).toList();
      // Dédupliquer par id
      final seen = <String>{};
      calls = calls.where((c) => seen.add(c.id)).toList();
    } catch (e) {
      relatedErrs.add('Appels : ${e.toString().replaceAll('Exception: ', '')}');
    }

    followUps.sort((a, b) => b.scheduledDate.compareTo(a.scheduledDate));
    interviews.sort((a, b) => b.interviewDate.compareTo(a.interviewDate));
    calls.sort((a, b) => b.callDate.compareTo(a.callDate));

    if (!mounted) return;
    setState(() {
      _company = company;
      _apps = providerApps;
      _contacts = contacts;
      _followUps = followUps;
      _interviews = interviews;
      _calls = calls;
      _contactsError = contactsErr;
      _relatedError = relatedErrs.isEmpty ? null : relatedErrs.join('\n');
      _loading = false;
    });
  }

  Future<void> _createContactDialog() async {
    final c = _company ?? widget.company;
    if (c.id.isEmpty) return;
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
              TextField(controller: firstName, decoration: const InputDecoration(labelText: 'Prénom *')),
              TextField(controller: lastName, decoration: const InputDecoration(labelText: 'Nom *')),
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
    if (firstName.text.trim().isEmpty || lastName.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prénom et nom requis')));
      return;
    }
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final created = await ApiService.createContact(
        firstName: firstName.text.trim(),
        lastName: lastName.text.trim(),
        email: email.text.trim(),
        phone: phone.text.trim(),
        notes: notes.text.trim(),
        companyId: c.id,
        token: token,
      );
      if (mounted) {
        Provider.of<ContactProvider>(context, listen: false).upsertContact(created);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact créé')));
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }

  Future<Application?> _pickCompanyApplication() async {
    if (_apps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Créez d’abord une candidature pour cette entreprise')),
      );
      return null;
    }
    if (_apps.length == 1) return _apps.first;
    return showModalBottomSheet<Application>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Quelle candidature ?')),
            ..._apps.map(
              (a) => ListTile(
                leading: const Icon(Icons.assignment_outlined),
                title: Text(a.position.isNotEmpty ? a.position : 'Candidature'),
                subtitle: Text(applicationStatusLabel(a.status)),
                onTap: () => Navigator.pop(ctx, a),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddMenu() async {
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
    if (choice == 'contact') {
      await _createContactDialog();
      return;
    }
    final app = await _pickCompanyApplication();
    if (app == null || !mounted) return;
    switch (choice) {
      case 'relance':
        await showCreateFollowUpSheet(context, fixedApplication: app);
      case 'entretien':
        await showCreateInterviewSheet(context, fixedApplication: app);
      case 'appel':
        await showCreateCallSheet(context, fixedApplication: app);
    }
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _company ?? widget.company;

    return Scaffold(
      appBar: AppBar(
        title: Text(c.name.isNotEmpty ? c.name : 'Entreprise'),
        actions: [
          IconButton(
            tooltip: 'Modifier',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final ok = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => CompanyEditScreen(company: c)),
              );
              if (ok == true) _load();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_company_detail_add',
        onPressed: _showAddMenu,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: scrollSafePadding(context),
                children: [
                  EntityDetailField(label: 'Nom', value: c.name),
                  EntityDetailField(label: 'Site web', value: c.website),
                  EntityDetailField(label: 'Secteur', value: c.industry),
                  EntityDetailField(label: 'Taille', value: c.size),
                  EntityDetailField(label: 'Localisation', value: c.location),
                  EntityDetailField(label: 'Description', value: c.description, multiline: true),
                  EntityDetailField(
                    label: 'Créée le',
                    value: formatUserLocalDateTime(c.createdAt.toIso8601String(), pattern: 'd MMM y HH:mm'),
                  ),
                  if (_relatedError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        _relatedError!,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                      ),
                    ),
                  EntityLinkSectionHeader('Candidatures (${_apps.length})'),
                  if (_apps.isEmpty)
                    const EntityLinksEmptyHint('Aucune candidature liée')
                  else
                    ..._apps.map(
                      (a) => EntityLinkTile(
                        icon: Icons.assignment_outlined,
                        title: a.position.isNotEmpty ? a.position : 'Candidature',
                        subtitle: applicationStatusLabel(a.status),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ApplicationDetailScreen(application: a)),
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: EntityLinkSectionHeader('Contacts (${_contacts.length})'),
                      ),
                      TextButton.icon(
                        onPressed: _createContactDialog,
                        icon: const Icon(Icons.person_add_outlined, size: 18),
                        label: const Text('Ajouter'),
                      ),
                    ],
                  ),
                  if (_contactsError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Impossible de charger les contacts : $_contactsError',
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                      ),
                    )
                  else if (_contacts.isEmpty)
                    const EntityLinksEmptyHint('Aucun contact lié à cette entreprise')
                  else
                    ..._contacts.map(
                      (contact) => EntityLinkTile(
                        icon: Icons.person_outline,
                        title: contactDisplayName(contact),
                        subtitle: contact['email']?.toString() ?? contact['phone']?.toString() ?? '',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ContactDetailScreen(contact: contact)),
                        ),
                      ),
                    ),
                  EntityLinkSectionHeader('Relances (${_followUps.length})'),
                  if (_followUps.isEmpty)
                    const EntityLinksEmptyHint('Aucune relance liée (via candidatures)')
                  else
                    ..._followUps.map(
                      (f) => EntityLinkTile(
                        icon: Icons.schedule_send_outlined,
                        title: formatSmartEventDate(f.scheduledDate),
                        subtitle: [
                          _appLabel(f.applicationId),
                          if (f.contactDisplayName != null && f.contactDisplayName!.isNotEmpty)
                            f.contactDisplayName!,
                          followUpStatusLabel(f.status),
                        ].join(' · '),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => FollowupDetailScreen(followUp: f)),
                        ),
                      ),
                    ),
                  EntityLinkSectionHeader('Entretiens (${_interviews.length})'),
                  if (_interviews.isEmpty)
                    const EntityLinksEmptyHint('Aucun entretien lié (via candidatures)')
                  else
                    ..._interviews.map(
                      (i) => EntityLinkTile(
                        icon: Icons.event_outlined,
                        title: formatSmartEventDate(i.interviewDate),
                        subtitle: [
                          _appLabel(i.applicationId),
                          if (i.location != null && i.location!.isNotEmpty) i.location!,
                        ].join(' · '),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => InterviewDetailScreen(interview: i)),
                        ),
                      ),
                    ),
                  EntityLinkSectionHeader('Appels (${_calls.length})'),
                  if (_calls.isEmpty)
                    const EntityLinksEmptyHint('Aucun appel lié (entreprise / candidature / contact)')
                  else
                    ..._calls.map(
                      (call) => EntityLinkTile(
                        icon: call.isCompanyOnly ? Icons.business_outlined : Icons.phone_outlined,
                        title: call.subject.isNotEmpty ? call.subject : 'Appel',
                        subtitle: [
                          call.isCompanyOnly ? 'Entreprise' : 'Contact · ${call.targetLabel}',
                          if (call.applicationId.isNotEmpty) _appLabel(call.applicationId),
                          formatSmartEventDate(call.callDate),
                        ].join(' · '),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => CallDetailScreen(call: call)),
                        ),
                      ),
                    ),
                  const SizedBox(height: 72),
                ],
              ),
            ),
    );
  }
}
