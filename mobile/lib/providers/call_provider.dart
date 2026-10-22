import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jobbingtrack_mobile/models/call.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';

class CallProvider with ChangeNotifier {
  List<Call> _calls = [];
  bool _isLoading = false;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<Call> get calls => _calls;
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

  Future<void> loadCalls({
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

    final showSpinner = _calls.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      _notifySafely();
    }

    _inFlight = () async {
      final known = _calls.map((c) => c.id).toSet();
      try {
        final result = await OfflineListLoader.load<Call>(
          userId: userId,
          cacheKey: OfflineEntityKeys.calls,
          fetch: () => ApiService.getCalls(token: token),
          fromJson: Call.fromJson,
          toJson: (c) => c.toJson(),
        );
        final freshIds = result.items.map((c) => c.id).toSet();
        final added = _calls.where(
          (c) => c.id.isNotEmpty && !known.contains(c.id) && !freshIds.contains(c.id),
        );
        _calls = [...added, ...result.items];
        _isOfflineData = result.fromCache;
        _lastLoadedAt = DateTime.now();
      } catch (e) {
        if (_calls.isEmpty) {
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

  void upsertLocal(Call call) {
    _calls.removeWhere((c) => c.id == call.id);
    _calls.insert(0, call);
    _lastLoadedAt = DateTime.now();
    _notifySafely();
  }

  void removeLocal(String id) {
    _calls.removeWhere((c) => c.id == id);
    _notifySafely();
  }

  List<Call> forApplication(String applicationId) {
    return _calls.where((c) => c.applicationId == applicationId).toList();
  }

  List<Call> forContact(String contactId) {
    return _calls.where((c) => c.contactId == contactId).toList();
  }

  void clearUserCache() {
    _calls = [];
    _isLoading = false;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    _notifySafely();
  }
}
