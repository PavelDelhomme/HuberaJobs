import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jobbingtrack_mobile/models/followup.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';
import 'package:jobbingtrack_mobile/utils/upcoming_timeline.dart';

class FollowUpProvider with ChangeNotifier {
  List<FollowUp> _followUps = [];
  bool _isLoading = false;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<FollowUp> get followUps => _followUps;
  bool get isLoading => _isLoading;
  bool get isOfflineData => _isOfflineData;

  List<FollowUp> get pendingFollowUps => filterUpcomingFollowUps(_followUps);

  List<FollowUp> get completedFollowUps => filterPastFollowUps(_followUps);

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

  /// Charge la liste globale. Pour filtrer une candidature, utiliser [forApplication]
  /// (évite d’écraser le cache global).
  Future<void> loadFollowUps({
    String? token,
    String? userId,
    String? applicationId,
    bool force = false,
  }) async {
    // Filtre par candidature : ne remplace pas le cache global.
    if (applicationId != null && applicationId.isNotEmpty) {
      try {
        final scoped = await ApiService.getFollowUps(
          applicationId: applicationId,
          token: token,
        );
        for (final f in scoped) {
          _followUps.removeWhere((x) => x.id == f.id);
          _followUps.insert(0, f);
        }
        _notifySafely();
      } catch (e) {
        if (userId != null && userId.isNotEmpty) {
          final cached = await OfflineEntityCache.instance.loadList(
            userId,
            OfflineEntityKeys.followUps,
          );
          if (cached != null && cached.isNotEmpty) {
            final filtered = cached
                .map(FollowUp.fromJson)
                .where((f) => f.applicationId == applicationId)
                .toList();
            for (final f in filtered) {
              _followUps.removeWhere((x) => x.id == f.id);
              _followUps.insert(0, f);
            }
            _isOfflineData = true;
            _notifySafely();
            return;
          }
        }
        rethrow;
      }
      return;
    }

    if (!force &&
        _lastLoadedAt != null &&
        DateTime.now().difference(_lastLoadedAt!) < _staleAfter) {
      return;
    }
    if (_inFlight != null) return _inFlight!;

    final showSpinner = _followUps.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      _notifySafely();
    }

    _inFlight = () async {
      final known = _followUps.map((f) => f.id).toSet();
      try {
        final result = await OfflineListLoader.load<FollowUp>(
          userId: userId,
          cacheKey: OfflineEntityKeys.followUps,
          fetch: () => ApiService.getFollowUps(token: token),
          fromJson: FollowUp.fromJson,
          toJson: (f) => f.toJson(),
        );
        final freshIds = result.items.map((f) => f.id).toSet();
        final added = _followUps.where(
          (f) => f.id.isNotEmpty && !known.contains(f.id) && !freshIds.contains(f.id),
        );
        _followUps = [...added, ...result.items];
        _isOfflineData = result.fromCache;
        _lastLoadedAt = DateTime.now();
      } catch (e) {
        if (_followUps.isEmpty) {
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

  List<FollowUp> forApplication(String applicationId) {
    return _followUps.where((f) => f.applicationId == applicationId).toList();
  }

  Future<void> addFollowUp(FollowUp followUp) async {
    _followUps.removeWhere((f) => f.id == followUp.id);
    _followUps.insert(0, followUp);
    _lastLoadedAt = DateTime.now();
    _notifySafely();
  }

  Future<FollowUp> createFollowUp({
    required String applicationId,
    required DateTime followUpDate,
    String? notes,
    String? contactId,
    String? token,
  }) async {
    final created = await ApiService.createFollowUp(
      applicationId: applicationId,
      followUpDate: followUpDate,
      notes: notes,
      contactId: contactId,
      token: token,
    );
    await addFollowUp(created);
    return created;
  }

  Future<void> updateFollowUp(String id, FollowUp followUp) async {
    final index = _followUps.indexWhere((f) => f.id == id);
    if (index != -1) {
      _followUps[index] = followUp;
      _notifySafely();
    }
  }

  Future<void> markAsCompleted(String id, String response, {String? token}) async {
    final updated = await ApiService.completeFollowUp(id, response, token: token);
    final index = _followUps.indexWhere((f) => f.id == id);
    if (index != -1) {
      _followUps[index] = updated;
    } else {
      _followUps.insert(0, updated);
    }
    _notifySafely();
  }

  Future<void> deleteFollowUp(String id, {String? token}) async {
    await ApiService.deleteFollowUp(id, token: token);
    _followUps.removeWhere((f) => f.id == id);
    _notifySafely();
  }

  void clearUserCache() {
    _followUps = [];
    _isLoading = false;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    _notifySafely();
  }
}
