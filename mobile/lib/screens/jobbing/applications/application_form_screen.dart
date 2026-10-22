import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/application_provider.dart';
import 'package:jobbingtrack_mobile/providers/company_provider.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_business_sync_queue.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer_leading.dart';
import 'package:jobbingtrack_mobile/widgets/drawer_back_scope.dart';
import 'package:jobbingtrack_mobile/widgets/company_picker_field.dart';
import 'package:jobbingtrack_mobile/widgets/agency_picker_field.dart';
import 'package:jobbingtrack_mobile/widgets/platform_picker_field.dart';
import 'package:jobbingtrack_mobile/widgets/location_autocomplete_field.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';

/// Écran formulaire complet pour créer ou modifier une candidature (tous les champs backend).
class ApplicationFormScreen extends StatefulWidget {
  final Application? application;
  /// Mode popup : pas de drawer ni AppBar shell.
  final bool modalMode;
  final ScrollController? scrollController;

  const ApplicationFormScreen({
    super.key,
    this.application,
    this.modalMode = false,
    this.scrollController,
  });

  /// Même formulaire pour créer ou modifier, en feuille scrollable.
  static Future<bool?> showCreateSheet(BuildContext context, {Application? application}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        final available = media.size.height - media.viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SizedBox(
            height: available * 0.92,
            child: ApplicationFormScreen(
              application: application,
              modalMode: true,
            ),
          ),
        );
      },
    );
  }

  @override
  State<ApplicationFormScreen> createState() => _ApplicationFormScreenState();
}

class _ApplicationFormScreenState extends State<ApplicationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _saving = false;
  List<Company> _companies = [];
  /// Id de l'entreprise sélectionnée dans la liste (null si "nouvelle entreprise").
  String? _companyId;
  String? _agencyId;
  List<Company> _agencies = [];
  List<Map<String, dynamic>> _platforms = [];
  String? _platformId;
  bool _interimMode = false;
  String _companyName = '';
  final _position = TextEditingController();
  final _description = TextEditingController();
  final _jobUrl = TextEditingController();
  final _location = TextEditingController();
  final _notes = TextEditingController();
  final _salaryMin = TextEditingController();
  final _salaryMax = TextEditingController();
  String _contractType = 'CDI';
  String? _workMode;
  String _applicationType = 'OFFRE';
  String _status = 'CANDIDATE_PENDING';
  /// true = cascade auto statut (relances / entretiens) ; false = suivi manuel.
  bool _autoStatusUpdate = true;
  DateTime _applicationDate = DateTime.now();
  bool _salaryNegotiable = false;

  static const _contractTypes = ['CDI', 'CDD', 'ALTERNANCE', 'STAGE', 'FREELANCE', 'INTERIM', 'SAISONNIER'];
  static const _applicationTypes = ['OFFRE', 'SPONTANEE'];

  @override
  void initState() {
    super.initState();
    if (widget.application != null) {
      final a = widget.application!;
      _position.text = a.position;
      _description.text = a.description;
      _location.text = a.location;
      _notes.text = a.notes;
      _companyId = a.company.id;
      _companyName = a.company.name;
      _agencyId = a.agencyId;
      _platformId = a.platformId;
      _applicationDate = a.appliedDate.toLocal();
      if (a.status.isNotEmpty) _status = a.status;
      _jobUrl.text = a.jobUrl;
      if (_contractTypes.contains(a.contractType)) _contractType = a.contractType;
      final mode = a.workMode?.trim();
      _workMode = (mode == null || mode.isEmpty) ? null : mode;
      if (_applicationTypes.contains(a.applicationType)) _applicationType = a.applicationType;
      if (a.salaryMin != null) _salaryMin.text = '${a.salaryMin}';
      if (a.salaryMax != null) _salaryMax.text = '${a.salaryMax}';
      _salaryNegotiable = a.salaryNegotiable;
      _autoStatusUpdate = !a.statusEngineOptOut;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCompanies();
      _loadPlatforms();
      _loadInterimPrefs();
    });
  }

  Future<void> _loadPlatforms() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    try {
      final list = await ApiService.getPlatforms(token: auth.token);
      if (mounted) setState(() => _platforms = list);
    } catch (_) {}
  }

  DateTime _applicationDateForSave() {
    return _applicationDate.toLocal();
  }

  Future<void> _loadInterimPrefs() async {
    final interim = await ApiConfigStore.loadInterimModeEnabled();
    if (!mounted) return;
    setState(() => _interimMode = interim);
    if (interim) await _loadAgencies();
  }

  Future<void> _loadAgencies() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    try {
      final list = await ApiService.getCompanies(token: auth.token, companyType: 'TEMP_AGENCY');
      final deduped = <String, Company>{};
      for (final company in list) {
        deduped.putIfAbsent(company.id, () => company);
      }
      final agencies = deduped.values.toList();
      if (mounted) {
        setState(() {
          _agencies = agencies;
          final preferred = widget.application?.agencyId ?? _agencyId;
          if (preferred != null && agencies.any((a) => a.id == preferred)) {
            _agencyId = preferred;
          } else if (_agencyId != null && !agencies.any((a) => a.id == _agencyId)) {
            _agencyId = null;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadCompanies() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final companyProvider = Provider.of<CompanyProvider>(context, listen: false);
    if (companyProvider.companies.isEmpty) {
      await companyProvider.loadCompanies(token: auth.token, userId: auth.user?.id);
    }
    if (mounted) {
      setState(() {
        _companies = companyProvider.companies;
      });
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _description.dispose();
    _jobUrl.dispose();
    _location.dispose();
    _notes.dispose();
    _salaryMin.dispose();
    _salaryMax.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildPayload() {
    final payload = <String, dynamic>{
      'position': _position.text.trim(),
      'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
      'jobUrl': _jobUrl.text.trim().isEmpty ? null : _jobUrl.text.trim(),
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'contractType': _contractType,
      'applicationType': _applicationType,
      'applicationDate': _applicationDateForSave().toUtc().toIso8601String(),
      'salaryNegotiable': _salaryNegotiable,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      'status': _status,
      'statusEngineOptOut': !_autoStatusUpdate,
    };
    if (_workMode != null && _workMode!.isNotEmpty) {
      payload['workMode'] = _workMode;
    }
    if (_companyId != null && _companyId!.isNotEmpty) {
      payload['companyId'] = _companyId;
    } else {
      final name = _companyName.trim();
      if (name.isNotEmpty) payload['companyName'] = name;
    }
    final sm = int.tryParse(_salaryMin.text.trim());
    final sx = int.tryParse(_salaryMax.text.trim());
    if (sm != null) payload['salaryMin'] = sm;
    if (sx != null) payload['salaryMax'] = sx;
    if (_agencyId != null && _agencyId!.isNotEmpty) {
      payload['agencyId'] = _agencyId;
    }
    if (_platformId != null && _platformId!.isNotEmpty) {
      payload['platformId'] = _platformId;
    }
    return payload;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final hasCompany = (_companyId != null && _companyId!.isNotEmpty) || _companyName.trim().isNotEmpty;
    if (!hasCompany) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez une entreprise ou saisissez son nom')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final token = auth.token;
      final payload = _buildPayload();
      final appProvider = Provider.of<ApplicationProvider>(context, listen: false);
      final companyProvider = Provider.of<CompanyProvider>(context, listen: false);
      if (widget.application == null) {
        final created = await ApiService.createApplicationFromPayload(payload, token: token);
        if (!mounted) return;
        appProvider.upsertLocal(created);
        if (created.company.id.isNotEmpty) {
          companyProvider.upsertLocal(created.company);
        }
        unawaitedSoftRefresh(token);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Candidature créée')));
        Navigator.of(context).pop(true);
      } else {
        final updated = await ApiService.updateApplicationFromPayload(widget.application!.id, payload, token: token);
        if (!mounted) return;
        appProvider.upsertLocal(updated);
        if (updated.company.id.isNotEmpty) {
          companyProvider.upsertLocal(updated.company);
        }
        unawaitedSoftRefresh(token);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Candidature mise à jour')));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (e is OfflineMutationQueued) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
          Navigator.of(context).pop(true);
        }
        return;
      }
      if (mounted) {
        final msg = e.toString().replaceAll('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void unawaitedSoftRefresh(String? token) {
    final appProvider = Provider.of<ApplicationProvider>(context, listen: false);
    final companyProvider = Provider.of<CompanyProvider>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    appProvider.loadApplications(token: token, userId: auth.user?.id, force: false);
    companyProvider.loadCompanies(token: token, userId: auth.user?.id);
  }

  Future<void> _pickApplicationDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _applicationDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_applicationDate),
    );
    if (!mounted) return;
    final time = t ?? TimeOfDay.fromDateTime(_applicationDate);
    setState(() {
      _applicationDate = DateTime(d.year, d.month, d.day, time.hour, time.minute);
    });
  }

  Future<void> _pickStatus() async {
    final picked = await showApplicationStatusPicker(
      context,
      current: _status,
      manualOnly: false,
    );
    if (picked != null && mounted) setState(() => _status = picked);
  }

  Widget _positionField() {
    return Semantics(
      label: 'Poste',
      textField: true,
      child: TextFormField(
        controller: _position,
        decoration: const InputDecoration(labelText: 'Poste *', border: OutlineInputBorder()),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Requis' : null,
        textInputAction: TextInputAction.next,
      ),
    );
  }

  Widget _applicationDateTile() {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.calendar_today),
        title: Text(formatUserLocalDateTime(
          _applicationDate.toUtc().toIso8601String(),
          pattern: 'd MMM y HH:mm',
        )),
        subtitle: const Text('Date et heure de candidature'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _pickApplicationDateTime,
      ),
    );
  }

  Widget _statusSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.flag_outlined, color: applicationStatusColor(_status)),
            title: Text(applicationStatusLabel(_status)),
            subtitle: const Text('Statut de la candidature'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickStatus,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mise à jour auto du statut'),
          subtitle: Text(
            _autoStatusUpdate
                ? 'Relances / entretiens mettent à jour le statut'
                : 'Suivi manuel uniquement',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          value: _autoStatusUpdate,
          onChanged: (v) => setState(() => _autoStatusUpdate = v),
        ),
      ],
    );
  }

  List<Widget> _buildFormFields({bool modalCreate = false}) {
    final company = CompanyPickerField(
      companies: _companies,
      selectedCompanyId: _companyId,
      companyName: _companyName,
      validator: (v) => (v == null || v.trim().isEmpty) ? 'Choisir ou saisir une entreprise' : null,
      onChanged: (sel) => setState(() {
        _companyId = sel.companyId;
        _companyName = sel.name;
      }),
    );

    final optionalFields = <Widget>[
      if (_interimMode) ...[
        AgencyPickerField(
          agencies: _agencies,
          selectedAgencyId: _agencyId,
          onChanged: (id) => setState(() => _agencyId = id),
          onAgencyCreated: _loadAgencies,
        ),
        const SizedBox(height: 12),
      ],
      PlatformPickerField(
        selectedPlatformId: _platformId,
        platforms: _platforms,
        onChanged: (id) => setState(() => _platformId = id),
        onPlatformsChanged: _loadPlatforms,
      ),
      const SizedBox(height: 12),
      if (!modalCreate) ...[
        _positionField(),
        const SizedBox(height: 12),
      ],
      TextFormField(
        controller: _description,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _jobUrl,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'URL de l\'offre', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      LocationAutocompleteField(controller: _location),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: _contractType,
        decoration: const InputDecoration(labelText: 'Type de contrat', border: OutlineInputBorder()),
        items: _contractTypes.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (v) => setState(() => _contractType = v ?? 'CDI'),
      ),
      const SizedBox(height: 12),
      _workModeDropdown(),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: _applicationType,
        decoration: const InputDecoration(labelText: 'Type candidature', border: OutlineInputBorder()),
        items: _applicationTypes
            .map((s) => DropdownMenuItem(value: s, child: Text(applicationTypeLabel(s))))
            .toList(),
        onChanged: (v) => setState(() => _applicationType = v ?? 'OFFRE'),
      ),
      const SizedBox(height: 12),
      _statusSection(),
      if (!modalCreate) ...[
        const SizedBox(height: 12),
        _applicationDateTile(),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _salaryMin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Salaire min (€/an)', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _salaryMax,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Salaire max (€/an)', border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Salaire négociable'),
        value: _salaryNegotiable,
        onChanged: (v) => setState(() => _salaryNegotiable = v ?? false),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _notes,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
      ),
    ];

    return [
      company,
      const SizedBox(height: 12),
      ...optionalFields,
      const SizedBox(height: 24),
      ElevatedButton(
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(widget.application == null ? 'Créer' : 'Enregistrer'),
      ),
    ];
  }

  Widget _workModeDropdown() {
    return DropdownButtonFormField<String>(
      value: _workMode ?? '',
      decoration: const InputDecoration(
        labelText: 'Mode de travail',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('Non précisé')),
        ...kWorkModeCodes.map(
          (s) => DropdownMenuItem(value: s, child: Text(workModeLabel(s))),
        ),
      ],
      onChanged: (v) => setState(() => _workMode = (v == null || v.isEmpty) ? null : v),
    );
  }

  List<Widget> _buildModalCreateFields() {
    final company = CompanyPickerField(
      companies: _companies,
      selectedCompanyId: _companyId,
      companyName: _companyName,
      validator: (v) => (v == null || v.trim().isEmpty) ? 'Choisir ou saisir une entreprise' : null,
      onChanged: (sel) => setState(() {
        _companyId = sel.companyId;
        _companyName = sel.name;
      }),
    );

    return [
      company,
      const SizedBox(height: 12),
      _positionField(),
      const SizedBox(height: 12),
      _applicationDateTile(),
      const SizedBox(height: 12),
      _statusSection(),
      const SizedBox(height: 16),
      Text(
        'Options (optionnel)',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.grey.shade700),
      ),
      const SizedBox(height: 8),
      if (_interimMode) ...[
        AgencyPickerField(
          agencies: _agencies,
          selectedAgencyId: _agencyId,
          onChanged: (id) => setState(() => _agencyId = id),
          onAgencyCreated: _loadAgencies,
        ),
        const SizedBox(height: 12),
      ],
      PlatformPickerField(
        selectedPlatformId: _platformId,
        platforms: _platforms,
        onChanged: (id) => setState(() => _platformId = id),
        onPlatformsChanged: _loadPlatforms,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _description,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _jobUrl,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'URL de l\'offre', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      LocationAutocompleteField(controller: _location),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: _contractType,
        decoration: const InputDecoration(labelText: 'Type de contrat', border: OutlineInputBorder()),
        items: _contractTypes.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (v) => setState(() => _contractType = v ?? 'CDI'),
      ),
      const SizedBox(height: 12),
      _workModeDropdown(),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: _applicationType,
        decoration: const InputDecoration(labelText: 'Type candidature', border: OutlineInputBorder()),
        items: _applicationTypes
            .map((s) => DropdownMenuItem(value: s, child: Text(applicationTypeLabel(s))))
            .toList(),
        onChanged: (v) => setState(() => _applicationType = v ?? 'OFFRE'),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _salaryMin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Salaire min (€/an)', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _salaryMax,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Salaire max (€/an)', border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Salaire négociable'),
        value: _salaryNegotiable,
        onChanged: (v) => setState(() => _salaryNegotiable = v ?? false),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _notes,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.check),
        label: Text(
          _saving
              ? 'Enregistrement…'
              : (widget.application == null ? 'Créer la candidature' : 'Enregistrer'),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.application != null;
    final fields = _buildModalCreateFields();
    if (widget.modalMode) {
      return Form(
        key: _formKey,
        child: ListView(
          controller: widget.scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: scrollSafePadding(context, top: 8, extraBottom: 32),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isEdit ? 'Modifier la candidature' : 'Nouvelle candidature',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Entreprise, poste, date et statut en haut — le reste se fait défiler.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            ...fields,
          ],
        ),
      );
    }

    final bottomPad = scrollSafePadding(context, top: 0, extraBottom: 32);
    final form = Form(
      key: _formKey,
      child: ListView(
        controller: widget.scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: bottomPad,
        children: fields,
      ),
    );

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppDrawer(),
      appBar: AppBar(
        leading: const AppDrawerLeadingButton(),
        automaticallyImplyLeading: false,
        title: Text(isEdit ? 'Modifier la candidature' : 'Nouvelle candidature'),
        centerTitle: true,
      ),
      body: DrawerBackScope(
        scaffoldKey: _scaffoldKey,
        child: form,
      ),
    );
  }
}
