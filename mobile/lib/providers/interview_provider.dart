import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:jobbingtrack_mobile/models/interview.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';
import 'package:jobbingtrack_mobile/utils/upcoming_timeline.dart';

class InterviewProvider with ChangeNotifier {
  List<Interview> _interviews = [];
  bool _isLoading = false;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<Interview> get interviews => _interviews;
  List<Interview> get upcomingInterviews => filterUpcomingInterviews(_interviews);
  List<Interview> get pastInterviews => filterPastInterviews(_interviews);
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

  Future<void> loadInterviews({
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

    final showSpinner = _interviews.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      _notifySafely();
    }

    _inFlight = () async {
      final known = _interviews.map((i) => i.id).toSet();
      try {
        final result = await OfflineListLoader.load<Interview>(
          userId: userId,
          cacheKey: OfflineEntityKeys.interviews,
          fetch: () => ApiService.getInterviews(token: token),
          fromJson: Interview.fromJson,
          toJson: (i) => i.toJson(),
        );
        final freshIds = result.items.map((i) => i.id).toSet();
        final added = _interviews.where(
          (i) => i.id.isNotEmpty && !known.contains(i.id) && !freshIds.contains(i.id),
        );
        _interviews = [...added, ...result.items];
        _isOfflineData = result.fromCache;
        _lastLoadedAt = DateTime.now();
      } catch (e) {
        if (_interviews.isEmpty) {
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

  void addInterview(Interview interview) {
    _interviews.removeWhere((i) => i.id == interview.id);
    _interviews.insert(0, interview);
    _lastLoadedAt = DateTime.now();
    _notifySafely();
  }

  void removeLocal(String id) {
    _interviews.removeWhere((i) => i.id == id);
    _notifySafely();
  }

  void clearUserCache() {
    _interviews = [];
    _isLoading = false;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    _notifySafely();
  }
}
