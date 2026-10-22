import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/company_provider.dart';
import 'package:jobbingtrack_mobile/providers/contact_provider.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/utils/contact_name_utils.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/company_picker_field.dart';

/// Création d'un contact autonome (entreprise existante ou nouvelle).
Future<Map<String, dynamic>?> showCreateContactSheet(BuildContext context) async {
  final companies = Provider.of<CompanyProvider>(context, listen: false).companies;
  if (companies.isEmpty) {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    try {
      await Provider.of<CompanyProvider>(context, listen: false).loadCompanies(token: token);
    } catch (_) {}
  }

  return showModalBottomSheet<Map<String, dynamic>?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ContactCreateSheetBody(
      companies: Provider.of<CompanyProvider>(ctx, listen: false).companies,
    ),
  );
}

class _ContactCreateSheetBody extends StatefulWidget {
  final List<Company> companies;

  const _ContactCreateSheetBody({required this.companies});

  @override
  State<_ContactCreateSheetBody> createState() => _ContactCreateSheetBodyState();
}

class _ContactCreateSheetBodyState extends State<_ContactCreateSheetBody> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  String? _companyId;
  String _companyName = '';
  bool _saving = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<String?> _resolveCompanyId(String? token) async {
    if (_companyId != null && _companyId!.isNotEmpty) return _companyId;
    final name = _companyName.trim();
    if (name.isEmpty) return null;
    final provider = Provider.of<CompanyProvider>(context, listen: false);
    final created = await provider.createCompany(name: name, token: token);
    return created.id;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final fn = _firstName.text.trim();
    final ln = _lastName.text.trim();
    if (fn.isEmpty && ln.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Indiquez au moins un prénom ou un nom')),
      );
      return;
    }
    if (_companyId == null && _companyName.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez ou créez une entreprise')),
      );
      return;
    }

    setState(() => _saving = true);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    try {
      final companyId = await _resolveCompanyId(token);
      if (companyId == null || companyId.isEmpty) {
        throw Exception('Entreprise requise');
      }
      final created = await ApiService.createContact(
        firstName: capitalizePersonName(fn.isNotEmpty ? fn : '.'),
        lastName: capitalizePersonName(ln.isNotEmpty ? ln : '.'),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        companyId: companyId,
        token: token,
      );
      created.putIfAbsent('firstName', () => capitalizePersonName(fn));
      created.putIfAbsent('lastName', () => capitalizePersonName(ln));
      if (mounted) {
        Provider.of<ContactProvider>(context, listen: false).upsertContact(created);
        Navigator.pop(context, created);
      }
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (_, scroll) {
          return Form(
            key: _formKey,
            child: ListView(
              controller: scroll,
              padding: scrollSafePadding(context, top: 0),
              children: [
                Text('Nouveau contact', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Le contact est rattaché à une entreprise (existante ou nouvelle).',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 16),
                CompanyPickerField(
                  companies: widget.companies,
                  selectedCompanyId: _companyId,
                  companyName: _companyName,
                  onChanged: (sel) => setState(() {
                    _companyId = sel.companyId;
                    _companyName = sel.name;
                  }),
                  validator: (name) =>
                      (_companyId != null && _companyId!.isNotEmpty) ||
                              (name?.trim().isNotEmpty ?? false)
                          ? null
                          : 'Entreprise requise',
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: 'Prénom',
                  textField: true,
                  child: TextFormField(
                    controller: _firstName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Prénom',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: 'Nom',
                  textField: true,
                  child: TextFormField(
                    controller: _lastName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nom',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email (optionnel)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Téléphone (optionnel)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 3,
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
                      : const Icon(Icons.person_add_outlined),
                  label: const Text('Créer le contact'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }
}
