import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/providers/application_provider.dart';
import 'package:jobbingtrack_mobile/providers/interview_provider.dart';
import 'package:jobbingtrack_mobile/providers/followup_provider.dart';
import 'package:jobbingtrack_mobile/providers/notification_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/followups/followup_detail_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/interviews/interview_detail_screen.dart';
import 'package:jobbingtrack_mobile/utils/application_labels.dart';
import 'package:jobbingtrack_mobile/utils/datetime_display.dart';
import 'package:jobbingtrack_mobile/utils/upcoming_timeline.dart';
import 'package:jobbingtrack_mobile/utils/scroll_padding.dart';
import 'package:jobbingtrack_mobile/widgets/shell_app_bar_menu.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer.dart';
import 'package:jobbingtrack_mobile/widgets/app_drawer_leading.dart';
import 'package:jobbingtrack_mobile/widgets/drawer_back_scope.dart';
import 'package:jobbingtrack_mobile/widgets/home_quick_create.dart';
import 'package:jobbingtrack_mobile/utils/shell_layout.dart';
import 'package:jobbingtrack_mobile/widgets/offline_mode_banner.dart';
import 'package:jobbingtrack_mobile/theme/theme_extensions.dart';

/// Contenu onglet Accueil (sans barre de navigation bas — gérée par [MainShellScreen]).
class HomeDashboardTab extends StatefulWidget {
  final bool isShellVisible;
  final void Function({required int applicationsTabIndex, String? statusFilter})? onOpenApplications;

  const HomeDashboardTab({
    super.key,
    this.isShellVisible = true,
    this.onOpenApplications,
  });

  @override
  State<HomeDashboardTab> createState() => _HomeDashboardTabState();
}

class _HomeDashboardTabState extends State<HomeDashboardTab> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isShellVisible) _loadData();
    });
  }

  @override
  void didUpdateWidget(covariant HomeDashboardTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isShellVisible && widget.isShellVisible) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    final userId = auth.user?.id;
    final appProvider = Provider.of<ApplicationProvider>(context, listen: false);
    final interviewProvider = Provider.of<InterviewProvider>(context, listen: false);
    final followUpProvider = Provider.of<FollowUpProvider>(context, listen: false);
    final notifProvider = Provider.of<NotificationProvider>(context, listen: false);
    await Future.wait([
      appProvider.loadApplications(token: token, userId: userId),
      interviewProvider.loadInterviews(token: token, userId: userId),
      followUpProvider.loadFollowUps(token: token, userId: userId),
      notifProvider.loadNotifications(token: token, auth: auth).catchError((_) {}),
    ]);
  }

  void _openApps({int tab = 0, String? status}) {
    if (widget.onOpenApplications != null) {
      widget.onOpenApplications!(applicationsTabIndex: tab, statusFilter: status);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final appProvider = Provider.of<ApplicationProvider>(context);
    final interviewProvider = Provider.of<InterviewProvider>(context);
    final followUpProvider = Provider.of<FollowUpProvider>(context);
    final user = authProvider.user;
    final applications = appProvider.applications;
    final interviews = interviewProvider.interviews;
    final followUps = followUpProvider.followUps;
    final upcoming = buildUpcomingTimeline(interviews: interviews, followUps: followUps);
    // Afficher le dashboard tout de suite ; barre fine si 1er chargement à froid.
    final coldLoading = (appProvider.isLoading && applications.isEmpty) ||
        (interviewProvider.isLoading && interviews.isEmpty) ||
        (followUpProvider.isLoading && followUps.isEmpty);
    final offline = appProvider.isOfflineData ||
        interviewProvider.isOfflineData ||
        followUpProvider.isOfflineData;

    return Scaffold(
      key: _scaffoldKey,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: const AppDrawerLeadingButton(),
        automaticallyImplyLeading: false,
        title: Text('Bonjour ${user?.firstName ?? ''}'),
        centerTitle: true,
        actions: const [
          ShellAppBarActions(),
        ],
      ),
      body: DrawerBackScope(
        scaffoldKey: _scaffoldKey,
        active: widget.isShellVisible,
        child: shellUpdateBannerBody(
          child: SafeArea(
          top: false,
          child: RefreshIndicator(
                  onRefresh: _loadData,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: scrollSafePadding(context, top: 0, extraBottom: shellBottomExtra(context) + 72),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (coldLoading)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: LinearProgressIndicator(minHeight: 2),
                            ),
                          if (offline)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: OfflineModeBanner(),
                            ),
                          Text(
                            'Gérez vos candidatures en un coup d\'œil',
                            style: context.captionMuted,
                          ),
                          const SizedBox(height: 16),
                          _buildMainStats(applications, interviews, followUpProvider.pendingFollowUps),
                          const SizedBox(height: 24),
                          _buildUpcomingSection(upcoming, interviews, followUps),
                          const SizedBox(height: 24),
                          _buildStatusBreakdown(applications),
                          const SizedBox(height: 24),
                          if (followUpProvider.pendingFollowUps.isNotEmpty) ...[
                            _buildUrgentActions(followUpProvider.pendingFollowUps),
                            const SizedBox(height: 24),
                          ],
                          Text(
                            'Actions rapides',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: context.cs.onSurface),
                          ),
                          const SizedBox(height: 16),
                          GridView.count(
                            crossAxisCount: 2,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 16,
                            children: [
                              _buildActionCard('Candidatures', Icons.assignment, Colors.blue[600]!, () => _openApps(tab: 0)),
                              _buildActionCard('Entreprises', Icons.business, Colors.purple[600]!, () => _openApps(tab: 1)),
                              _buildActionCard('Contacts', Icons.person, Colors.green[600]!, () => _openApps(tab: 2)),
                              _buildActionCard('Entretiens', Icons.event, Colors.orange[600]!, () => _openApps(tab: 3)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ),
        ),
      ),
      floatingActionButton: widget.isShellVisible
          ? shellFabPadding(
              context,
              child: FloatingActionButton(
                heroTag: 'fab_home_dashboard',
                tooltip: 'Ajouter',
                onPressed: () async {
                  final changed = await handleHomeQuickCreate(context);
                  if (changed) _loadData();
                },
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.add),
              ),
            )
          : null,
    );
  }

  Widget _buildMainStats(List applications, List interviews, List followUps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Vue d\'ensemble', style: context.sectionTitleStyle),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildStatCard('${applications.length}', 'Candidatures', Colors.blue, Icons.assignment, () => _openApps(tab: 0))),
            const SizedBox(width: 12),
            Expanded(child: _buildStatCard('${interviews.length}', 'Entretiens', Colors.green, Icons.event_available, () => _openApps(tab: 3))),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildStatCard('${followUps.length}', 'Relances', Colors.orange, Icons.schedule_send, () => _openApps(tab: 4))),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                '${applications.where((app) => app.status == 'ACCEPTED').length}',
                'Acceptées',
                Colors.green,
                Icons.check_circle,
                () => _openApps(tab: 0, status: 'ACCEPTED'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(String value, String label, Color color, IconData icon, VoidCallback onTap) {
    final cs = context.cs;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingSection(
    List<UpcomingTimelineItem> upcoming,
    List interviews,
    List followUps,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('À venir', style: context.sectionTitleStyle),
        const SizedBox(height: 12),
        if (upcoming.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Rien de prévu prochainement',
              style: context.captionMuted,
            ),
          )
        else
          ...upcoming.take(5).map((e) {
            final cs = context.cs;
            return Card(
              child: ListTile(
                leading: Icon(
                  e.kind == UpcomingKind.interview ? Icons.event : Icons.schedule_send,
                  color: cs.primary,
                ),
                title: Text(e.title),
                subtitle: Text('${e.subtitle}\n${formatSmartEventDate(e.when)}'),
                isThreeLine: e.subtitle.isNotEmpty,
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  if (e.kind == UpcomingKind.interview) {
                    final match = interviews.cast<dynamic>().where((i) => i.id == e.id).toList();
                    if (match.isNotEmpty) {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => InterviewDetailScreen(interview: match.first),
                        ),
                      );
                      if (mounted) _loadData();
                      return;
                    }
                    _openApps(tab: 3);
                  } else {
                    final match = followUps.cast<dynamic>().where((f) => f.id == e.id).toList();
                    if (match.isNotEmpty) {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FollowupDetailScreen(followUp: match.first),
                        ),
                      );
                      if (mounted) _loadData();
                      return;
                    }
                    _openApps(tab: 4);
                  }
                },
              ),
            );
          }),
      ],
    );
  }

  Widget _buildStatusBreakdown(List applications) {
    final statusCounts = <String, int>{};
    for (final app in applications) {
      statusCounts[app.status] = (statusCounts[app.status] ?? 0) + 1;
    }
    if (statusCounts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Par statut', style: context.sectionTitleStyle),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: statusCounts.entries.map((e) {
            return ActionChip(
              label: Text(
                '${applicationStatusLabel(e.key)} (${e.value})',
                style: TextStyle(color: context.cs.onSurface),
              ),
              onPressed: () => _openApps(tab: 0, status: e.key),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildUrgentActions(List followUps) {
    final cs = context.cs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Relances à faire',
          style: context.sectionTitleStyle?.copyWith(color: cs.error),
        ),
        const SizedBox(height: 8),
        ...followUps.take(3).map((f) => ListTile(
              dense: true,
              leading: Icon(Icons.schedule_send, color: cs.tertiary),
              title: Text(formatSmartEventDate(f.scheduledDate)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => FollowupDetailScreen(followUp: f)),
                );
                if (mounted) _loadData();
              },
            )),
      ],
    );
  }

  Widget _buildActionCard(String title, IconData icon, Color color, VoidCallback onTap) {
    final cs = context.cs;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 28, color: color),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
