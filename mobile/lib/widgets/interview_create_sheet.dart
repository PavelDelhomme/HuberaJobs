import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/providers/application_provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/contact_provider.dart';
import 'package:jobbingtrack_mobile/providers/interview_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/interviews/interview_detail_screen.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/application_picker_field.dart';
import 'package:jobbingtrack_mobile/widgets/contact_picker_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/interview_calendar_offer.dart';
import 'package:jobbingtrack_mobile/widgets/location_autocomplete_field.dart';
import 'package:jobbingtrack_mobile/utils/meeting_place_policy.dart';

/// Création d'un entretien avec candidature obligatoire (picker trié par date récente).
Future<bool> showCreateInterviewSheet(
  BuildContext context, {
  Application? fixedApplication,
  Map<String, dynamic>? initialContact,
}) async {
  final appProvider = Provider.of<ApplicationProvider>(context, listen: false);
  final token = Provider.of<AuthProvider>(context, listen: false).token;
  if (appProvider.applications.isEmpty) {
    await appProvider.loadApplications(token: token);
  }

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _InterviewCreateSheetBody(
      applications: appProvider.applications,
      fixedApplication: fixedApplication,
      initialContact: initialContact,
    ),
  );
  return result == true;
}

class _InterviewCreateSheetBody extends StatefulWidget {
  final List<Application> applications;
  final Application? fixedApplication;
  final Map<String, dynamic>? initialContact;

  const _InterviewCreateSheetBody({
    required this.applications,
    this.fixedApplication,
    this.initialContact,
  });

  @override
  State<_InterviewCreateSheetBody> createState() => _InterviewCreateSheetBodyState();
}

class _InterviewCreateSheetBodyState extends State<_InterviewCreateSheetBody> {
  Application? _selectedApp;
  DateTime _date = DateTime.now().add(const Duration(days: 3));
  String _style = 'Présentiel';
  final _location = TextEditingController();
  final _videoLink = TextEditingController();
  final _duration = TextEditingController(text: '60');
  final _notes = TextEditingController();
  List<Map<String, dynamic>> _contacts = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedApp = widget.fixedApplication;
    if (widget.initialContact != null) {
      _contacts = [widget.initialContact!];
    }
  }

  @override
  void dispose() {
    _location.dispose();
    _videoLink.dispose();
    _duration.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedApp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez une candidature')),
      );
      return;
    }
    setState(() => _saving = true);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    try {
      // Si lieu = tél / lien → forcer distanciel (pas présentiel).
      applyLocationAutoStyle(
        location: _location.text,
        videoLink: _videoLink.text,
        setStyle: (s) => _style = s,
      );
      final modality = MeetingPlacePolicy.detectModality(
        location: _location.text,
        videoLink: _videoLink.text,
        text: _notes.text,
      );
      final noteParts = <String>['[Format: $_style]'];
      if (modality == MeetingModality.telephone || modality == MeetingModality.visio) {
        noteParts.add('[Pas en présentiel — ${MeetingPlacePolicy.modalityLabelFr(modality)}]');
      }
      if (MeetingPlacePolicy.isBilanDeCompetences(_notes.text)) {
        noteParts.add('[Type: bilan de compétences]');
      }
      if (_notes.text.trim().isNotEmpty) noteParts.add(_notes.text.trim());
      final created = await ApiService.createInterview(
        applicationId: _selectedApp!.id,
        interviewDate: _date,
        location: _location.text.trim().isEmpty ? null : _location.text.trim(),
        videoLink: _videoLink.text.trim().isEmpty ? null : _videoLink.text.trim(),
        estimatedDuration: int.tryParse(_duration.text.trim()),
        notes: noteParts.join('\n'),
        contactIds: _contacts.map((c) => c['id']?.toString()).whereType<String>().toList(),
        token: token,
      );
      Provider.of<InterviewProvider>(context, listen: false).addInterview(created);
      if (!mounted) return;
      final nav = Navigator.of(context);
      await offerAddInterviewToCalendar(context, interview: created);
      if (!mounted) return;
      nav.pop(true);
      await nav.push(
        MaterialPageRoute(builder: (_) => InterviewDetailScreen(interview: created)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _locationHint() {
    final m = MeetingPlacePolicy.detectModality(
      location: _location.text,
      videoLink: _videoLink.text,
    );
    if (m == MeetingModality.inconnu) return null;
    return MeetingPlacePolicy.modalityLabelFr(m);
  }

  @override
  Widget build(BuildContext context) {
    final fixed = widget.fixedApplication != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) {
          return ListView(
            controller: scroll,
            padding: scrollSafePadding(context, top: 0),
            children: [
              Text('Nouvel entretien', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (fixed && _selectedApp != null)
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Candidature liée',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.lock_outline, size: 20),
                  ),
                  child: Text(
                    '${_selectedApp!.position} · ${_selectedApp!.company.name}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                )
              else
                ApplicationPickerField(
                  applications: widget.applications,
                  selected: _selectedApp,
                  onChanged: (a) => setState(() => _selectedApp = a),
                  validator: (a) => a == null ? 'Candidature requise' : null,
                ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today),
                title: Text(formatSmartEventDate(_date)),
                subtitle: const Text('Date de l’entretien'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
              ),
              DropdownButtonFormField<String>(
                value: _style,
                decoration: const InputDecoration(labelText: 'Format', border: OutlineInputBorder()),
                items: ['Présentiel', 'Distanciel', 'Hybride']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _style = v ?? _style),
              ),
              const SizedBox(height: 12),
              LocationAutocompleteField(
                controller: _location,
                labelText: 'Lieu / tél (optionnel)',
                hintText: 'Adresse, ville ou numéro…',
                onChanged: (_) => setState(() {
                  applyLocationAutoStyle(
                    location: _location.text,
                    videoLink: _videoLink.text,
                    setStyle: (s) => _style = s,
                  );
                }),
              ),
              if (_locationHint() != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _locationHint()!,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _videoLink,
                decoration: const InputDecoration(
                  labelText: 'Lien visio (optionnel)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() {
                  applyLocationAutoStyle(
                    location: _location.text,
                    videoLink: _videoLink.text,
                    setStyle: (s) => _style = s,
                  );
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _duration,
                decoration: const InputDecoration(labelText: 'Durée (minutes)', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.people_outline),
                title: Text(
                  _contacts.isEmpty
                      ? 'Contacts (optionnel)'
                      : '${_contacts.length} contact(s) sélectionné(s)',
                ),
                trailing: const Icon(Icons.person_search),
                onTap: _selectedApp == null
                    ? null
                    : () async {
                        final token = Provider.of<AuthProvider>(context, listen: false).token;
                        final app = _selectedApp!;
                        final byApp = await ApiService.getContactsByApplication(app.id, token: token);
                        final picked = await showMultiContactPickerSheet(
                          context,
                          candidates: byApp,
                          applicationLinkedIds: byApp.map((c) => c['id']?.toString()).whereType<String>().toSet(),
                          companyName: app.company.name,
                          onCreateContact: ({
                            required String firstName,
                            required String lastName,
                            String? email,
                            String? phone,
                            String? notes,
                          }) async {
                            final created = await ApiService.createContact(
                              firstName: firstName,
                              lastName: lastName,
                              email: email,
                              phone: phone,
                              notes: notes,
                              companyId: app.company.id,
                              token: token,
                            );
                            if (context.mounted) {
                              Provider.of<ContactProvider>(context, listen: false).upsertContact(created);
                            }
                            return created;
                          },
                        );
                        if (picked != null) setState(() => _contacts = picked);
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Notes (optionnel)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.event_available),
                label: const Text('Créer l’entretien'),
              ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}
