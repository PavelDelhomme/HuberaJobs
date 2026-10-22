import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';

class CompanyProvider with ChangeNotifier {
  List<Company> _companies = [];
  bool _isLoading = false;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<Company> get companies => _companies;
  bool get isLoading => _isLoading;
  bool get isOfflineData => _isOfflineData;

  static const _staleAfter = Duration(seconds: 45);

  void _notifySafely() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (hasListeners) notifyListeners();
    });
  }

  Future<void> loadCompanies({
    String? token,
    String? userId,
    bool force = false,
  }) async {
    if (!force &&
        _lastLoadedAt != null &&
        DateTime.now().difference(_lastLoadedAt!) < _staleAfter) {
      return;
    }
    if (_inFlight != null) return _inFlight!;

    final showSpinner = _companies.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      _notifySafely();
    }

    _inFlight = () async {
      final known = _companies.map((c) => c.id).toSet();
      try {
        final result = await OfflineListLoader.load<Company>(
          userId: userId,
          cacheKey: OfflineEntityKeys.companies,
          fetch: () => ApiService.getCompanies(token: token),
          fromJson: Company.fromJson,
          toJson: (c) => c.toJson(),
        );
        final freshIds = result.items.map((c) => c.id).toSet();
        final added = _companies.where(
          (c) => c.id.isNotEmpty && !known.contains(c.id) && !freshIds.contains(c.id),
        );
        _companies = [...added, ...result.items];
        _isOfflineData = result.fromCache;
        _lastLoadedAt = DateTime.now();
      } catch (e) {
        if (_companies.isEmpty) {
          _isOfflineData = false;
          rethrow;
        }
        _isOfflineData = true;
      } finally {
        _isLoading = false;
        _inFlight = null;
        _notifySafely();
      }
    }();

    return _inFlight!;
  }

  Future<Company> createCompany({
    required String name,
    String? website,
    String? industry,
    String? location,
    String? description,
    String companyType = 'EMPLOYER',
    String? token,
  }) async {
    final created = await ApiService.createCompany(
      name: name,
      website: website,
      industry: industry,
      location: location,
      description: description,
      companyType: companyType,
      token: token,
    );
    _companies.insert(0, created);
    _lastLoadedAt = DateTime.now();
    notifyListeners();
    return created;
  }

  void upsertLocal(Company company) {
    if (company.id.isEmpty) return;
    _companies.removeWhere((c) => c.id == company.id);
    _companies.insert(0, company);
    _lastLoadedAt = DateTime.now();
    notifyListeners();
  }

  void clearUserCache() {
    _companies = [];
    _isLoading = false;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    _notifySafely();
  }
}
