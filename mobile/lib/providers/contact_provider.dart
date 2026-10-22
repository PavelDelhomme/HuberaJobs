import 'package:flutter/foundation.dart';

import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';

class ContactProvider with ChangeNotifier {
  List<dynamic> _contacts = [];
  bool _isLoading = false;
  bool _isOfflineData = false;
  DateTime? _lastLoadedAt;
  Future<void>? _inFlight;

  List<dynamic> get contacts => _contacts;
  bool get isLoading => _isLoading;
  bool get isOfflineData => _isOfflineData;

  static const _staleAfter = Duration(seconds: 45);

  Future<void> loadContacts({
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

    final showSpinner = _contacts.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      _isLoading = true;
      notifyListeners();
    }

    _inFlight = () async {
      final known = _contacts
          .map((c) => c is Map ? c['id']?.toString() : null)
          .whereType<String>()
          .toSet();
      try {
        final result = await OfflineListLoader.loadMaps(
          userId: userId,
          cacheKey: OfflineEntityKeys.contacts,
          fetch: () => ApiService.getContacts(token: token),
        );
        final freshIds = result.items
            .map((c) => c['id']?.toString())
            .whereType<String>()
            .toSet();
        final added = _contacts.where((c) {
          final id = c is Map ? c['id']?.toString() : null;
          return id != null && id.isNotEmpty && !known.contains(id) && !freshIds.contains(id);
        });
        _contacts = [...added, ...result.items];
        _isOfflineData = result.fromCache;
        _lastLoadedAt = DateTime.now();
      } catch (e) {
        if (_contacts.isEmpty) {
          _isOfflineData = false;
          rethrow;
        }
        _isOfflineData = true;
      } finally {
        _isLoading = false;
        _inFlight = null;
        notifyListeners();
      }
    }();

    return _inFlight!;
  }

  void upsertContact(Map<String, dynamic> contact) {
    final id = contact['id']?.toString();
    if (id == null || id.isEmpty) return;
    _contacts = [
      contact,
      ..._contacts.where((c) => (c is Map ? c['id']?.toString() : null) != id),
    ];
    _lastLoadedAt = DateTime.now();
    notifyListeners();
  }

  void clearUserCache() {
    _contacts = [];
    _isLoading = false;
    _isOfflineData = false;
    _lastLoadedAt = null;
    _inFlight = null;
    notifyListeners();
  }
}
