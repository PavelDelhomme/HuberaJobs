import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/services/email_agent_service.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/back_to_home_scope.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';
import 'package:intl/intl.dart';

class EmailAgentScreen extends StatefulWidget {
  const EmailAgentScreen({super.key});

  @override
  State<EmailAgentScreen> createState() => _EmailAgentScreenState();
}

class _EmailAgentScreenState extends State<EmailAgentScreen> {
  bool _loading = true;
  bool _actionLoading = false;
  String? _error;
  EmailAgentStatus? _status;
  List<EmailAgentTriageMessage> _messages = [];
  final Map<String, List<EmailAgentLinkSuggestion>> _linkSuggestions = {};
  final Map<String, EmailAgentProposedActions> _proposedActions = {};
  String? _expandedMessageId;
  final Map<String, bool> _consentDraft = {};
  String? _discoveryHint;
  String? _lastDiscoveredEmail;
  String? _lastSmtpHost;
  int? _lastSmtpPort;
  Timer? _discoverDebounce;
  final _emailFocus = FocusNode();

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '993');
  final _displayNameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) {
        unawaited(_discoverImap());
      }
    });
    _load();
  }

  @override
  void dispose() {
    _discoverDebounce?.cancel();
    _emailFocus.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await EmailAgentService.fetchStatus(token: token);
      for (final type in emailAgentConsentOrder) {
        final found = status.consents.where((c) => c.consentType == type).toList();
        _consentDraft[type] = found.isNotEmpty && found.first.granted;
      }
      List<EmailAgentTriageMessage> messages = [];
      if (status.accessAllowed) {
        messages = await EmailAgentService.fetchTriage(token: token);
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _messages = messages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _runAction(Future<void> Function() action, {String? success}) async {
    setState(() {
      _actionLoading = true;
      _error = null;
    });
    try {
      await action();
      await _load();
      if (success != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  Future<void> _discoverImap() async {
    final email = _emailCtrl.text.trim();
    if (!email.contains('@')) return;
    if (email == _lastDiscoveredEmail && _hostCtrl.text.trim().isNotEmpty) return;
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    setState(() => _discoveryHint = 'Détection IMAP/SMTP…');
    try {
      final suggestion = await EmailAgentService.discoverImap(token: token, emailAddress: email);
      if (!mounted) return;
      if (suggestion == null) {
        setState(() => _discoveryHint = 'Aucune suggestion — saisissez l\'hôte manuellement.');
        return;
      }
      _hostCtrl.text = suggestion.imapHost;
      _portCtrl.text = suggestion.imapPort.toString();
      _lastSmtpHost = suggestion.smtpHost;
      _lastSmtpPort = suggestion.smtpPort;
      if (_displayNameCtrl.text.trim().isEmpty) _displayNameCtrl.text = email;
      _lastDiscoveredEmail = email;
      final note = suggestion.note == 'proton_bridge_required'
          ? ' (Proton Bridge requis)'
          : '';
      final smtpPart = suggestion.smtpHost != null && suggestion.smtpHost!.isNotEmpty
          ? ' · SMTP ${suggestion.smtpHost}:${suggestion.smtpPort ?? 587}'
          : '';
      setState(() {
        _discoveryHint =
            '${suggestion.provider ?? 'Serveur'} : IMAP ${suggestion.imapHost}:${suggestion.imapPort}$smtpPart$note';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _discoveryHint = 'Détection indisponible — saisie manuelle.');
      }
    }
  }

  void _scheduleDiscoverImap() {
    _discoverDebounce?.cancel();
    _discoverDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_discoverImap());
    });
  }

  Future<void> _saveConsents() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    await _runAction(() async {
      await EmailAgentService.updateConsents(
        token: token,
        consents: emailAgentConsentOrder
            .map((type) => {
                  'consentType': type,
                  'granted': _consentDraft[type] == true,
                })
            .toList(),
      );
    }, success: 'Consentements enregistrés');
  }

  Future<void> _connectImap() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (_hostCtrl.text.trim().isEmpty) {
      await _discoverImap();
    }
    final smtpHost = _lastSmtpHost;
    final smtpPort = _lastSmtpPort;
    await _runAction(() async {
      await EmailAgentService.connectImap(
        token: token,
        emailAddress: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        imapHost: _hostCtrl.text.trim(),
        imapPort: int.tryParse(_portCtrl.text.trim()) ?? 993,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        displayName: _displayNameCtrl.text.trim().isEmpty
            ? _emailCtrl.text.trim()
            : _displayNameCtrl.text.trim(),
      );
      _passwordCtrl.clear();
      _lastDiscoveredEmail = null;
    }, success: 'Boîte IMAP connectée');
  }

  Future<void> _sync() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    await _runAction(() async {
      await EmailAgentService.syncNow(token: token);
    }, success: 'Synchronisation terminée');
  }

  Future<void> _revokeMailbox(EmailAgentMailbox mailbox) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Révoquer la boîte ?'),
        content: Text('Arrêter la sync pour ${mailbox.emailAddress} ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Révoquer')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    await _runAction(() async {
      await EmailAgentService.revokeMailbox(token: token, mailboxId: mailbox.id);
    }, success: 'Boîte révoquée');
  }

  Future<void> _dismissMessage(EmailAgentTriageMessage msg) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    await _runAction(() async {
      await EmailAgentService.reviewTriage(
        token: token,
        messageId: msg.id,
        reviewStatus: 'REJECTED',
      );
    });
  }

  Future<void> _reviewMessage(EmailAgentTriageMessage msg, String reviewStatus, {String? success}) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    setState(() {
      _actionLoading = true;
      _error = null;
    });
    try {
      final statusApply = await EmailAgentService.reviewTriage(
        token: token,
        messageId: msg.id,
        reviewStatus: reviewStatus,
      );
      await _load();
      if (!mounted) return;
      var text = success ?? 'Action enregistrée';
      if (statusApply.applied && statusApply.statusCode != null) {
        text = '$text · Candidature : ${applicationStatusLabel(statusApply.statusCode!)}';
      } else if (reviewStatus == 'ACCEPTED' &&
          msg.suggestedStatus != null &&
          msg.applicationId == null) {
        text = '$text · Liez une candidature pour appliquer le statut proposé';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  Future<void> _toggleMessageExpand(EmailAgentTriageMessage msg) async {
    if (_expandedMessageId == msg.id) {
      setState(() => _expandedMessageId = null);
      return;
    }
    setState(() => _expandedMessageId = msg.id);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    try {
      if (!_linkSuggestions.containsKey(msg.id) && msg.applicationId == null) {
        final suggestions = await EmailAgentService.fetchLinkSuggestions(
          token: token,
          messageId: msg.id,
        );
        if (mounted) setState(() => _linkSuggestions[msg.id] = suggestions);
      }
      if (!_proposedActions.containsKey(msg.id)) {
        final actions = await EmailAgentService.fetchProposedActions(
          token: token,
          messageId: msg.id,
        );
        if (mounted) setState(() => _proposedActions[msg.id] = actions);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  Future<void> _createTask(EmailAgentTriageMessage msg) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final actions = _proposedActions[msg.id];
    await _runAction(() async {
      await EmailAgentService.createGoogleTask(
        token: token,
        messageId: msg.id,
        title: actions?.taskTitle,
        notes: actions?.taskNotes,
      );
    }, success: 'Tâche Google créée (ou file d\'attente web)');
  }

  Future<void> _createCalendar(EmailAgentTriageMessage msg) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    await _runAction(() async {
      await EmailAgentService.createCalendarEvent(token: token, messageId: msg.id);
    }, success: 'Événement Calendar proposé');
  }

  Future<void> _linkMessage(EmailAgentTriageMessage msg, String applicationId) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    setState(() {
      _actionLoading = true;
      _error = null;
    });
    try {
      final statusApply = await EmailAgentService.linkToApplication(
        token: token,
        messageId: msg.id,
        applicationId: applicationId,
      );
      await _load();
      if (!mounted) return;
      var text = 'Email lié à la candidature';
      if (statusApply.applied && statusApply.statusCode != null) {
        text = '$text · Statut : ${applicationStatusLabel(statusApply.statusCode!)}';
      } else if (msg.reviewStatus == 'ACCEPTED' && msg.suggestedStatus != null) {
        text = '$text · Validez l\'email pour appliquer le statut';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final dateFmt = DateFormat('dd/MM/yyyy HH:mm', 'fr_FR');

    return BackToHomeScope(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Agent email'),
          centerTitle: true,
          actions: [
            if (status?.accessAllowed == true)
              IconButton(
                icon: _actionLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync),
                tooltip: 'Synchroniser',
                onPressed: _actionLoading ? null : _sync,
              ),
            const MobileNotificationCenter(),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: scrollSafePadding(context),
                  children: [
                    if (_error != null)
                      Card(
                        color: Colors.red.shade50,
                        child: ListTile(
                          leading: Icon(Icons.error_outline, color: Colors.red.shade700),
                          title: Text(_error!, style: TextStyle(color: Colors.red.shade900)),
                        ),
                      ),
                    _statusCard(status),
                    if (status != null && !status.agentEnabled) ...[
                      const SizedBox(height: 16),
                      _infoCard(
                        'Agent non activé',
                        'Demandez à un administrateur d\'activer l\'agent recherche sur votre compte. '
                        'Votre email d\'inscription (${Provider.of<AuthProvider>(context).user?.email ?? ''}) '
                        'recevra les digests une fois configuré.',
                      ),
                    ],
                    if (status != null && status.agentEnabled) ...[
                      const SizedBox(height: 16),
                      _sectionTitle('Consentements'),
                      Card(
                        child: Column(
                          children: [
                            for (final type in emailAgentConsentOrder) ...[
                              CheckboxListTile(
                                title: Text(emailAgentConsentLabels[type] ?? type),
                                subtitle: Text(_consentSubtitle(type)),
                                value: _consentDraft[type] == true,
                                onChanged: (v) => setState(() => _consentDraft[type] = v == true),
                              ),
                              if (type != emailAgentConsentOrder.last) const Divider(height: 1),
                            ],
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _actionLoading ? null : _saveConsents,
                                  child: const Text('Enregistrer les consentements'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _sectionTitle('Boîtes connectées'),
                      if (status.mailboxes.isEmpty)
                        _infoCard('Aucune boîte', 'Ajoutez une boîte IMAP ci-dessous ou liez Gmail depuis le web.')
                      else
                        Card(
                          child: Column(
                            children: status.mailboxes.map((mb) {
                              return Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.mail_outline),
                                    title: Text(mb.emailAddress),
                                    subtitle: Text(
                                      '${mb.provider} · ${mb.lastSyncStatus ?? '—'}'
                                      '${mb.lastSyncAt != null ? ' · ${dateFmt.format(mb.lastSyncAt!.toLocal())}' : ''}',
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.link_off),
                                      tooltip: 'Révoquer',
                                      onPressed: _actionLoading ? null : () => _revokeMailbox(mb),
                                    ),
                                  ),
                                  if (mb != status.mailboxes.last) const Divider(height: 1),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      const SizedBox(height: 16),
                      _sectionTitle('Ajouter une boîte IMAP'),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              TextField(
                                controller: _emailCtrl,
                                focusNode: _emailFocus,
                                decoration: const InputDecoration(
                                  labelText: 'Adresse email',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.emailAddress,
                                onChanged: (_) => _scheduleDiscoverImap(),
                                onEditingComplete: _discoverImap,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _passwordCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Mot de passe / app password',
                                  border: OutlineInputBorder(),
                                ),
                                obscureText: true,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _hostCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Hôte IMAP',
                                  hintText: 'imap.mail.ovh.net',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _portCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Port',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                              ),
                              if (_discoveryHint != null) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _discoveryHint!,
                                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: (_actionLoading || status.hasRequiredConsents != true)
                                      ? null
                                      : _connectImap,
                                  icon: const Icon(Icons.add),
                                  label: const Text('Connecter la boîte IMAP'),
                                ),
                              ),
                              if (!status.hasRequiredConsents)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    'Accordez les consentements requis avant de connecter une boîte.',
                                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (status.accessAllowed) ...[
                        const SizedBox(height: 16),
                        _sectionTitle('À traiter (${_messages.length})'),
                        if (_messages.isEmpty)
                          _infoCard(
                            'Rien en attente',
                            'Les emails traités (Valider, Reporter, Ignorer) quittent cette liste. '
                            'Synchronisez ↻ pour en importer de nouveaux, ou relancez les tests seed côté dev.',
                          )
                        else
                          ..._messages.map((msg) {
                            final expanded = _expandedMessageId == msg.id;
                            final suggestions = _linkSuggestions[msg.id] ?? [];
                            final actions = _proposedActions[msg.id];
                            return Card(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ListTile(
                                    isThreeLine: true,
                                    title: Text(msg.subject, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(
                                      '${msg.fromAddress}\n${dateFmt.format(msg.receivedAt.toLocal())}'
                                      '${msg.classification != null ? ' · ${msg.classification}' : ''}'
                                      '${msg.applicationId != null ? '\n✓ Candidature liée' : ''}',
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Semantics(
                                          label: 'Détails email triage',
                                          button: true,
                                          child: IconButton(
                                            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                                            tooltip: 'Détails / lier',
                                            onPressed: _actionLoading ? null : () => _toggleMessageExpand(msg),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.check_circle_outline),
                                          tooltip: 'Ignorer',
                                          onPressed: _actionLoading ? null : () => _dismissMessage(msg),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (expanded) ...[
                                    if (msg.snippet != null && msg.snippet!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                        child: Text(
                                          msg.snippet!,
                                          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                                        ),
                                      ),
                                    if (msg.suggestedStatus != null && msg.suggestedStatus!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                        child: Text(
                                          'Statut candidature proposé : '
                                          '${applicationStatusLabel(msg.suggestedStatus!)}'
                                          '${msg.applicationId == null ? '\nLier une candidature, puis Valider pour l\'appliquer.' : ''}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.blueGrey.shade800,
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: [
                                          TextButton(
                                            onPressed: _actionLoading
                                                ? null
                                                : () => _reviewMessage(msg, 'ACCEPTED', success: 'Email validé'),
                                            child: const Text('Valider'),
                                          ),
                                          TextButton(
                                            onPressed: _actionLoading
                                                ? null
                                                : () => _reviewMessage(msg, 'DEFERRED', success: 'Reporté'),
                                            child: const Text('Reporter'),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (msg.applicationId == null) ...[
                                      if (suggestions.isEmpty)
                                        const Padding(
                                          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                                          child: Text(
                                            'Aucune candidature suggérée — créez-en une dans Candidatures.',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      for (final s in suggestions)
                                        ListTile(
                                          dense: true,
                                          title: Text(s.companyName ?? 'Entreprise'),
                                          subtitle: Text('${s.position} · score ${s.score.toStringAsFixed(0)}'),
                                          trailing: TextButton(
                                            onPressed: _actionLoading
                                                ? null
                                                : () => _linkMessage(msg, s.applicationId),
                                            child: const Text('Lier'),
                                          ),
                                        ),
                                    ],
                                    if (actions != null) ...[
                                      const Divider(height: 1),
                                      Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Actions Google',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                                color: Colors.grey[800],
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            if (actions.taskAllowed) ...[
                                              Text(
                                                actions.taskTitle ?? 'Tâche proposée',
                                                style: const TextStyle(fontSize: 12),
                                              ),
                                              TextButton.icon(
                                                onPressed: _actionLoading ? null : () => _createTask(msg),
                                                icon: const Icon(Icons.task_alt, size: 18),
                                                label: const Text('Créer tâche Google'),
                                              ),
                                            ] else
                                              Text(
                                                actions.taskReason ??
                                                    'Tasks : consentement GOOGLE_TASKS + Gmail OAuth (web /agent).',
                                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                              ),
                                            if (actions.calendarAllowed &&
                                                actions.calendarDecision == 'schedule')
                                              TextButton.icon(
                                                onPressed: _actionLoading ? null : () => _createCalendar(msg),
                                                icon: const Icon(Icons.event, size: 18),
                                                label: const Text('Créer événement (10h)'),
                                              )
                                            else if (!actions.calendarAllowed)
                                              Text(
                                                actions.calendarReason ??
                                                    'Calendar : consentement GOOGLE_CALENDAR requis.',
                                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                              )
                                            else if (actions.calendarMessage != null)
                                              Text(
                                                actions.calendarMessage!,
                                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            );
                          }),
                      ],
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
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

  Widget _statusCard(EmailAgentStatus? status) {
    if (status == null) return const SizedBox.shrink();
    Color color;
    String label;
    if (!status.agentEnabled) {
      color = Colors.orange;
      label = 'Agent désactivé';
    } else if (!status.hasRequiredConsents) {
      color = Colors.amber.shade800;
      label = 'Consentements incomplets';
    } else if (status.accessAllowed) {
      color = Colors.green;
      label = 'Actif · ${status.pendingTriageCount} en attente';
    } else {
      color = Colors.blueGrey;
      label = status.accessReason.isNotEmpty ? status.accessReason : 'Configuration requise';
    }
    return Card(
      color: color.withValues(alpha: 0.12),
      child: ListTile(
        leading: Icon(Icons.smart_toy_outlined, color: color),
        title: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        subtitle: Text(
          '${status.mailboxes.length} boîte(s) IMAP lue(s) · '
          'compte Hubera Jobs : ${Provider.of<AuthProvider>(context).user?.email ?? ''}\n'
          'Le digest et la connexion utilisent ce compte ; les emails viennent des boîtes ci-dessous.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.35),
        ),
      ),
    );
  }

  Widget _infoCard(String title, String body) {
    return Card(
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(body),
      ),
    );
  }

  String _consentSubtitle(String type) {
    switch (type) {
      case 'MAILBOX_ACCESS':
        return 'Lecture seule des emails de recherche d\'emploi.';
      case 'CONTENT_CLASSIFICATION':
        return 'Détection refus, entretiens, relances.';
      case 'DIGEST_NOTIFICATIONS':
        return 'Récap quotidien vers votre email d\'inscription.';
      case 'GOOGLE_CALENDAR':
        return 'Propositions d\'événements calendrier.';
      case 'GOOGLE_TASKS':
        return 'Synchronisation des tâches.';
      case 'AI_PROCESSING':
        return 'Optionnel — enrichissement assisté.';
      default:
        return '';
    }
  }
}
