import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jobbingtrack_mobile/models/application.dart';
import 'package:jobbingtrack_mobile/models/company.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';

class ApplicationProvider with ChangeNotifier {
  List<Application> _applications = [];
  bool _isLoading = false;
  String? _lastError;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<Application> get applications => _applications;
  bool get isLoading => _isLoading;
  String? get lastError => _lastError;
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

  Future<void> loadApplications({
    String? token,
    String? userId,
    Future<String?> Function()? renewToken,
    bool force = false,
  }) async {
    // Même compte vide : ne pas re-fetcher en boucle (Nothing / Samsung / Blackview).
    if (!force &&
        _lastLoadedAt != null &&
        DateTime.now().difference(_lastLoadedAt!) < _staleAfter) {
      return;
    }
    if (_inFlight != null) return _inFlight!;

    // Spinner uniquement au premier chargement (jamais de données encore).
    final showSpinner = _applications.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      _lastError = null;
      _notifySafely();
    } else {
      _lastError = null;
    }

    _inFlight = () async {
      final known = _applications.map((a) => a.id).toSet();
      try {
        final result = await OfflineListLoader.load<Application>(
          userId: userId,
          cacheKey: OfflineEntityKeys.applications,
          fetch: () => ApiService.getApplications(token: token),
          fromJson: Application.fromJson,
          toJson: (app) => app.toJson(),
        );
        _applications = _keepLocalAdds(known, result.items);
        _isOfflineData = result.fromCache;
        _isLoading = false;
        _lastLoadedAt = DateTime.now();
        _lastError = result.fromCache ? 'Données en cache (hors ligne)' : null;
        _notifySafely();
      } catch (e) {
        final msg = e.toString().replaceAll('Exception: ', '');
        final isAuth = msg.contains('Session expirée') || msg.contains('401') || msg.contains('403');
        if (isAuth && renewToken != null) {
          final fresh = await renewToken();
          if (fresh != null && fresh.isNotEmpty) {
            try {
              final result = await OfflineListLoader.load<Application>(
                userId: userId,
                cacheKey: OfflineEntityKeys.applications,
                fetch: () => ApiService.getApplications(token: fresh),
                fromJson: Application.fromJson,
                toJson: (app) => app.toJson(),
              );
              _applications = _keepLocalAdds(known, result.items);
              _isOfflineData = result.fromCache;
              _isLoading = false;
              _lastLoadedAt = DateTime.now();
              _lastError = result.fromCache ? 'Données en cache (hors ligne)' : null;
              _notifySafely();
              return;
            } catch (retryErr) {
              _lastError = retryErr.toString().replaceAll('Exception: ', '');
              _isLoading = false;
              if (_applications.isEmpty) _isOfflineData = false;
              _notifySafely();
              return;
            }
          }
        }
        _lastError = msg;
        if (_applications.isEmpty) _isOfflineData = false;
        _isLoading = false;
        _notifySafely();
      } finally {
        _inFlight = null;
      }
    }();

    return _inFlight!;
  }

  List<Application> _keepLocalAdds(Set<String> known, List<Application> fresh) {
    final freshIds = fresh.map((a) => a.id).toSet();
    final added = _applications.where(
      (a) => a.id.isNotEmpty && !known.contains(a.id) && !freshIds.contains(a.id),
    );
    return [...added, ...fresh];
  }

  /// Insère / remplace localement sans attendre un rechargement réseau.
  void upsertLocal(Application application) {
    _applications.removeWhere((a) => a.id == application.id);
    _applications.insert(0, application);
    _lastLoadedAt = DateTime.now();
    _notifySafely();
  }

  /// Complète le nom d'entreprise quand la liste API ne renvoie que companyId.
  void enrichCompanies(Map<String, String> companyNamesById) {
    if (companyNamesById.isEmpty) return;
    var changed = false;
    _applications = _applications.map((app) {
      if (app.company.name.isNotEmpty) return app;
      final id = app.company.id;
      if (id.isEmpty) return app;
      final name = companyNamesById[id];
      if (name == null || name.isEmpty) return app;
      changed = true;
      return Application(
        id: app.id,
        position: app.position,
        description: app.description,
        company: Company(
          id: app.company.id,
          name: name,
          website: app.company.website,
          industry: app.company.industry,
          size: app.company.size,
          location: app.company.location,
          description: app.company.description,
          logo: app.company.logo,
          companyType: app.company.companyType,
          isActive: app.company.isActive,
          isDeleted: app.company.isDeleted,
          createdBy: app.company.createdBy,
          createdAt: app.company.createdAt,
          updatedAt: app.company.updatedAt,
        ),
        status: app.status,
        priority: app.priority,
        appliedDate: app.appliedDate,
        interviewDate: app.interviewDate,
        location: app.location,
        salary: app.salary,
        notes: app.notes,
        tags: app.tags,
        createdBy: app.createdBy,
        createdAt: app.createdAt,
        updatedAt: app.updatedAt,
        agencyId: app.agencyId,
        agencyName: app.agencyName,
        platformId: app.platformId,
        platformName: app.platformName,
        jobUrl: app.jobUrl,
        contractType: app.contractType,
        workMode: app.workMode,
        applicationType: app.applicationType,
        salaryMin: app.salaryMin,
        salaryMax: app.salaryMax,
        salaryNegotiable: app.salaryNegotiable,
        statusEngineOptOut: app.statusEngineOptOut,
      );
    }).toList();
    if (changed) _notifySafely();
  }

  Future<void> createApplication(Application application, {String? token}) async {
    try {
      final newApplication =
          await ApiService.createApplication(application, token: token);
      _applications.add(newApplication);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> updateApplication(
    String id,
    Application application, {
    String? token,
  }) async {
    try {
      final updatedApplication =
          await ApiService.updateApplication(id, application, token: token);
      final index = _applications.indexWhere((app) => app.id == id);
      if (index != -1) {
        _applications[index] = updatedApplication;
        notifyListeners();
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteApplication(String id, {String? token}) async {
    try {
      await ApiService.deleteApplication(id, token: token);
      _applications.removeWhere((app) => app.id == id);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> archiveApplication(String id, {String? token, String? reason}) async {
    try {
      await ApiService.archiveApplication(id, token: token, reason: reason);
      _applications.removeWhere((app) => app.id == id);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  void clearUserCache() {
    _applications = [];
    _isLoading = false;
    _lastError = null;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    _notifySafely();
  }
}
