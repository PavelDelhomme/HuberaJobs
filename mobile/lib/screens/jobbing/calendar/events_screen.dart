import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/models/followup.dart';
import 'package:jobbingtrack_mobile/models/interview.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/followup_provider.dart';
import 'package:jobbingtrack_mobile/providers/interview_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/followups/followup_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/interviews/interview_detail_screen.dart';
import 'package:jobbingtrack_mobile/services/api_config_store.dart';
import 'package:jobbingtrack_mobile/services/api_service.dart';
import 'package:jobbingtrack_mobile/services/offline_entity_cache.dart';
import 'package:jobbingtrack_mobile/services/offline_list_loader.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/utils/shell_layout.dart';
import 'package:jobbingtrack_mobile/widgets/calendar_drawer.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer_leading.dart';
import 'package:jobbingtrack_mobile/widgets/drawer_back_scope.dart';
import 'package:jobbingtrack_mobile/navigation/shell_list_refresh_mixin.dart';
import 'package:jobbingtrack_mobile/widgets/shell_app_bar_menu.dart';
import 'package:jobbingtrack_mobile/widgets/followup_create_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/interview_create_sheet.dart';

/// Calendrier — vue Planning (défaut) ou liste événements.
class EventsScreen extends StatefulWidget {
  final bool isShellVisible;

  const EventsScreen({super.key, this.isShellVisible = true});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> with RouteAware, ShellListRefreshMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  bool _fromCache = false;
  String? _error;
  CalendarViewMode _viewMode = CalendarViewMode.planner;
  CalendarFilters _filters = const CalendarFilters();
  DateTime _selectedDay = DateTime.now();
  DateTime _weekAnchor = DateTime.now();
  DateTime? _lastLoadedAt;
  static const _staleAfter = Duration(seconds: 45);

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isShellVisible) _load();
    });
  }

  @override
  void didUpdateWidget(covariant EventsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isShellVisible && widget.isShellVisible) {
      _load();
    }
  }

  @override
  void onShellListVisibleAgain() {
    _load();
  }

  Future<void> _loadPrefs() async {
    final mode = await ApiConfigStore.loadCalendarViewMode();
    final f = await ApiConfigStore.loadCalendarFilters();
    if (!mounted) return;
    setState(() {
      _viewMode = mode == 'list' ? CalendarViewMode.list : CalendarViewMode.planner;
      _filters = CalendarFilters(
        showInterviews: f.interviews,
        showFollowups: f.followups,
        showEvents: f.events,
        showInterim: f.interim,
      );
    });
  }

  Future<void> _load({bool force = false}) async {
    if (!force &&
        _lastLoadedAt != null &&
        DateTime.now().difference(_lastLoadedAt!) < _staleAfter) {
      return;
    }
    final showSpinner = _events.isEmpty && _lastLoadedAt == null;
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _error = null);
    }
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final result = await OfflineListLoader.loadMaps(
        userId: auth.user?.id,
        cacheKey: OfflineEntityKeys.events,
        fetch: () => ApiService.getCalendarEvents(token: auth.token, limit: 200),
      );
      if (mounted) {
        setState(() {
          _events = result.items;
          _fromCache = result.fromCache;
          _lastLoadedAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _fromCache = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openEvent(Map<String, dynamic> e) async {
    final interviewId = e['interviewId']?.toString();
    final followUpId = e['followUpId']?.toString();
    if (interviewId != null && interviewId.isNotEmpty) {
      final interviews = Provider.of<InterviewProvider>(context, listen: false).interviews;
      Interview? found;
      for (final i in interviews) {
        if (i.id == interviewId) {
          found = i;
          break;
        }
      }
      found ??= Interview(
        id: interviewId,
        applicationId: e['applicationId']?.toString() ?? '',
        interviewDate: _parseStart(e),
        location: e['location']?.toString(),
        notes: e['description']?.toString(),
        applicationPosition: e['title']?.toString(),
        companyName: e['companyName']?.toString(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => InterviewDetailScreen(interview: found!)),
      );
      return;
    }
    if (followUpId != null && followUpId.isNotEmpty) {
      final followUps = Provider.of<FollowUpProvider>(context, listen: false).followUps;
      FollowUp? found;
      for (final f in followUps) {
        if (f.id == followUpId) {
          found = f;
          break;
        }
      }
      if (found != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => FollowupDetailScreen(followUp: found!)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relance introuvable localement — tirez pour rafraîchir')),
        );
      }
    }
  }

  Future<void> _showCreateMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.event_outlined),
              title: const Text('Planifier un entretien'),
              onTap: () => Navigator.pop(ctx, 'entretien'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_outlined),
              title: const Text('Planifier une relance'),
              onTap: () => Navigator.pop(ctx, 'relance'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'entretien') {
      final ok = await showCreateInterviewSheet(context);
      if (ok && mounted) await _load(force: true);
    } else if (choice == 'relance') {
      final created = await showCreateFollowUpSheet(context);
      if (created != null && mounted) await _load(force: true);
    }
  }

  List<Map<String, dynamic>> get _filteredEvents {
    return _events.where(_matchesFilters).toList();
  }

  bool _matchesFilters(Map<String, dynamic> e) {
    final colorHex = e['color']?.toString().toUpperCase() ?? '';
    final isInterim = colorHex.contains('F59E0B') || colorHex.contains('F59') ||
        e['application']?['agencyId'] != null;
    if (isInterim && !_filters.showInterim) return false;
    if (e['interviewId'] != null && !_filters.showInterviews) return false;
    if (e['followUpId'] != null && !_filters.showFollowups) return false;
    if (e['interviewId'] == null && e['followUpId'] == null && !isInterim && !_filters.showEvents) {
      return false;
    }
    return true;
  }

  DateTime _parseStart(Map<String, dynamic> e) {
    final raw = e['startDate']?.toString();
    if (raw == null || raw.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(raw).toLocal();
    } catch (_) {
      return DateTime.now();
    }
  }

  DateTime _startOfWeek(DateTime d) {
    final local = d.toLocal();
    final weekday = local.weekday;
    return DateTime(local.year, local.month, local.day).subtract(Duration(days: weekday - 1));
  }

  List<DateTime> get _weekDays {
    final start = _startOfWeek(_weekAnchor);
    return List.generate(7, (i) => start.add(Duration(days: i)));
  }

  List<Map<String, dynamic>> _eventsForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return _filteredEvents.where((e) {
      final dt = _parseStart(e);
      return !dt.isBefore(start) && dt.isBefore(end);
    }).toList()
      ..sort((a, b) => _parseStart(a).compareTo(_parseStart(b)));
  }

  void _shiftWeek(int delta) {
    setState(() {
      _weekAnchor = _weekAnchor.add(Duration(days: 7 * delta));
      _selectedDay = _startOfWeek(_weekAnchor).add(Duration(days: _selectedDay.weekday - 1));
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewLabel = _viewMode == CalendarViewMode.planner ? 'Planning' : 'Liste';

    return Scaffold(
      key: _scaffoldKey,
      drawer: CalendarDrawer(
        viewMode: _viewMode,
        filters: _filters,
        onViewModeChanged: (m) => setState(() => _viewMode = m),
        onFiltersChanged: (f) => setState(() => _filters = f),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'fab_calendar_plan',
        tooltip: 'Planifier',
        onPressed: _showCreateMenu,
        child: const Icon(Icons.add),
      ),
      appBar: AppBar(
        leading: const AppDrawerLeadingButton(),
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Calendrier'),
            Text(
              _fromCache ? '$viewLabel · hors ligne' : viewLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.normal,
                  ),
            ),
          ],
        ),
        actions: [
          ShellAppBarActions(
            leadingActions: [
              IconButton(
                tooltip: 'Affichage',
                icon: const Icon(Icons.tune),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
            ],
          ),
        ],
      ),
      body: DrawerBackScope(
        scaffoldKey: _scaffoldKey,
        active: widget.isShellVisible,
        child: shellUpdateBannerBody(
          child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                      FilledButton(onPressed: () => _load(force: true), child: const Text('Réessayer')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(force: true),
                  child: _viewMode == CalendarViewMode.planner ? _buildPlanner() : _buildList(),
                ),
        ),
      ),
    );
  }

  Widget _buildPlanner() {
    final dayEvents = _eventsForDay(_selectedDay);
    final weekLabel = DateFormat('MMMM yyyy', 'fr_FR').format(_weekAnchor);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: scrollSafePadding(context, top: 0),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shiftWeek(-1)),
              Expanded(
                child: Text(
                  weekLabel[0].toUpperCase() + weekLabel.substring(1),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shiftWeek(1)),
            ],
          ),
        ),
        SizedBox(
          height: 72,
          child: Row(
            children: _weekDays.map((d) {
              final isSelected = d.year == _selectedDay.year &&
                  d.month == _selectedDay.month &&
                  d.day == _selectedDay.day;
              final isToday = _isSameDay(d, DateTime.now());
              final count = _eventsForDay(d).length;
              return Expanded(
                child: InkWell(
                  onTap: () => setState(() => _selectedDay = d),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.blue.shade600 : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: isToday && !isSelected
                          ? Border.all(color: Colors.blue.shade300)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          DateFormat('EEE', 'fr_FR').format(d).replaceAll('.', ''),
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected ? Colors.white : Colors.grey.shade600,
                          ),
                        ),
                        Text(
                          '${d.day}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : Colors.black87,
                          ),
                        ),
                        if (count > 0)
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : Colors.blue.shade400,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            formatSmartEventDate(_selectedDay),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        if (dayEvents.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(Icons.event_available, size: 48, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(
                  'Rien de prévu ce jour',
                  style: TextStyle(color: Colors.grey.shade600),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ...dayEvents.map(_plannerEventTile),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _plannerEventTile(Map<String, dynamic> e) {
    final start = _parseStart(e);
    final title = e['title']?.toString() ?? 'Événement';
    final colorHex = e['color']?.toString();
    final isInterim = colorHex != null &&
        (colorHex.toUpperCase().contains('F59E0B') || colorHex.toUpperCase().contains('F59'));
    final accent = isInterim ? Colors.amber.shade700 : Colors.blue.shade700;
    final canOpen = e['interviewId'] != null || e['followUpId'] != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 52,
              child: Text(
                DateFormat('HH:mm', 'fr_FR').format(start),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              width: 3,
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  onTap: canOpen ? () => _openEvent(e) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (e['description']?.toString().isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              e['description'].toString(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final items = [..._filteredEvents]
      ..sort((a, b) => _parseStart(a).compareTo(_parseStart(b)));

    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.event_note, size: 64, color: Colors.blue.shade300),
          const SizedBox(height: 16),
          const Center(child: Text('Aucun événement à venir')),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Les entretiens et relances planifiés apparaîtront ici.',
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: scrollSafePadding(context),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final e = items[i];
        final title = e['title']?.toString() ?? 'Événement';
        final start = e['startDate']?.toString();
        final colorHex = e['color']?.toString();
        final isInterim = colorHex != null &&
            (colorHex.toUpperCase().contains('F59E0B') || colorHex.toUpperCase().contains('F59'));
        final iconColor = isInterim ? Colors.amber.shade700 : Colors.blue.shade700;
        final canOpen = e['interviewId'] != null || e['followUpId'] != null;
        return Card(
          child: ListTile(
            leading: Icon(Icons.event, color: iconColor),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: start != null ? Text(formatUserLocalDateTime(start)) : null,
            trailing: canOpen ? const Icon(Icons.chevron_right) : null,
            onTap: canOpen ? () => _openEvent(e) : null,
          ),
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
