import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/services/admin_api_service.dart';
import 'package:jobbingtrack_mobile/utils/admin_metrics_parser.dart';
import 'package:jobbingtrack_mobile/utils/admin_time_range.dart';
import 'package:jobbingtrack_mobile/utils/mobile_perf_aggregator.dart';
import 'package:jobbingtrack_mobile/utils/user_friendly_error.dart';
import 'package:jobbingtrack_mobile/widgets/admin/admin_kpi_tile.dart';
import 'package:jobbingtrack_mobile/widgets/admin/admin_hub_leading.dart';
import 'package:jobbingtrack_mobile/widgets/admin/admin_record_detail_sheet.dart';
import 'package:jobbingtrack_mobile/widgets/admin/admin_scroll.dart';
import 'package:jobbingtrack_mobile/widgets/admin/admin_time_range_bar.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_notification_center.dart';

/// Performances : hôte/stack Docker + appareils mobile (télémétrie app).
class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  AdminTimeRange _mobileRange = AdminTimeRange.d7;
  bool _loadingHost = true;
  bool _loadingMobile = true;
  String? _hostError;
  String? _mobileError;
  SystemSnapshot? _system;
  List<ContainerSnapshot> _containers = [];
  List<ServiceSnapshot> _services = [];
  int _runningServices = 0;
  List<Map<String, dynamic>> _mobilePerfRaw = [];
  List<MobileDevicePerfSummary> _mobileDevices = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadHost();
    _loadMobile();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadHost() async {
    setState(() {
      _loadingHost = true;
      _hostError = null;
    });
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final results = await Future.wait([
        AdminApiService.fetchSystemMetrics(token: token),
        AdminApiService.fetchServicesStatus(token: token),
      ]);
      final metrics = Map<String, dynamic>.from(results[0] as Map);
      final servicesData = Map<String, dynamic>.from(results[1] as Map);
      if (mounted) {
        setState(() {
          _system = AdminMetricsParser.parseSystem(metrics);
          _containers = AdminMetricsParser.parseContainers(metrics);
          _services = AdminMetricsParser.parseServices(servicesData);
          _runningServices = _services.where((s) => s.status == 'running' || s.status == 'online').length;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _hostError = userFriendlyError(e, adminContext: true));
    } finally {
      if (mounted) setState(() => _loadingHost = false);
    }
  }

  Future<void> _loadMobile() async {
    setState(() {
      _loadingMobile = true;
      _mobileError = null;
    });
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final rows = await AdminApiService.fetchApplicationPerformance(
        token: token,
        range: _mobileRange,
        limit: 200,
      );
      if (mounted) {
        setState(() {
          _mobilePerfRaw = rows;
          _mobileDevices = MobilePerfAggregator.summarize(rows);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _mobileError = userFriendlyError(e, adminContext: true));
    } finally {
      if (mounted) setState(() => _loadingMobile = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadHost(), _loadMobile()]);
  }

  String _availabilityLabel() {
    final sys = _system;
    if (sys?.availabilityPercent != null) {
      return AdminMetricsParser.fmtPct(sys!.availabilityPercent);
    }
    if (_services.isEmpty) return '—';
    final healthy = _services.where((s) => s.health.toLowerCase() == 'healthy').length;
    final pct = (healthy / _services.length) * 100;
    return '${pct.toStringAsFixed(0)} %';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performances'),
        centerTitle: true,
        leading: const AdminHubLeading(),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Hôte & stack'),
            Tab(text: 'Appareils mobile'),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshAll),
          const MobileNotificationCenter(),
        ],
      ),
      body: AdminSafeBody(
        child: TabBarView(
          controller: _tabs,
          children: [
            _buildHostTab(),
            _buildMobileTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildHostTab() {
    if (_loadingHost && _system == null) return const Center(child: CircularProgressIndicator());
    if (_hostError != null && _system == null) {
      return _errorPanel(_hostError!, onRetry: _loadHost);
    }

    final sys = _system;
    final ts = sys?.timestamp != null
        ? DateTime.tryParse(sys!.timestamp!)?.toLocal().toString().substring(0, 19)
        : null;

    return RefreshIndicator(
      onRefresh: _loadHost,
      child: ListView(
        padding: adminScrollPadding(context, base: const EdgeInsets.only(bottom: 8)),
        children: [
          if (ts != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Dernière collecte hôte : $ts', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ),
          const AdminSectionTitle(
            title: 'Ordinateur hôte',
            subtitle: 'Machine qui exécute Docker (API, backoffice, métriques)',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AdminKpiTile(
                  label: 'CPU hôte',
                  value: AdminMetricsParser.fmtPct(sys?.cpuPercent),
                  icon: Icons.computer,
                  color: Colors.blue,
                  subtitle: sys?.cpuCores != null ? '${sys!.cpuCores} cœurs' : null,
                ),
                AdminKpiTile(
                  label: 'RAM hôte',
                  value: AdminMetricsParser.fmtPct(sys?.memPercent),
                  icon: Icons.memory,
                  color: Colors.purple,
                  subtitle: sys?.memUsedMb != null && sys?.memTotalMb != null
                      ? '${AdminMetricsParser.fmtMb(sys!.memUsedMb)} / ${AdminMetricsParser.fmtMb(sys.memTotalMb)}'
                      : null,
                ),
                AdminKpiTile(
                  label: 'Charge (1 min)',
                  value: sys?.load1?.toStringAsFixed(2) ?? '—',
                  icon: Icons.speed,
                  color: Colors.orange,
                  subtitle: sys?.load5 != null ? '5 min : ${sys!.load5!.toStringAsFixed(2)}' : null,
                ),
                AdminKpiTile(
                  label: 'Santé stack',
                  value: _availabilityLabel(),
                  icon: Icons.check_circle_outline,
                  color: Colors.green,
                  subtitle: '$_runningServices / ${_services.length} services UP',
                ),
              ],
            ),
          ),
          const AdminSectionTitle(
            title: 'Conteneurs Hubera Jobs',
            subtitle: 'CPU/RAM moyens du projet sur l\'hôte',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AdminKpiTile(
                  label: 'CPU projet',
                  value: AdminMetricsParser.fmtPct(sys?.projectCpuAvg),
                  icon: Icons.hub,
                  color: Colors.teal,
                ),
                AdminKpiTile(
                  label: 'RAM projet',
                  value: AdminMetricsParser.fmtPct(sys?.projectMemPercent),
                  icon: Icons.dns,
                  color: Colors.indigo,
                ),
                AdminKpiTile(
                  label: 'Latence HTTP',
                  value: AdminMetricsParser.fmtMs(sys?.avgResponseMs),
                  icon: Icons.timer_outlined,
                  color: Colors.blueGrey,
                ),
              ],
            ),
          ),
          const AdminSectionTitle(title: 'Conteneurs (top CPU)', subtitle: 'jobbingtrack-*'),
          if (_containers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Aucune métrique conteneur — metrics-aggregator indisponible.'),
            )
          else
            ..._containers.take(12).map((c) => Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  child: ListTile(
                    dense: true,
                    title: Text(c.shortName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'RAM ${AdminMetricsParser.fmtPct(c.memPercent)} · ${AdminMetricsParser.fmtMb(c.memMb)}',
                    ),
                    trailing: Text(
                      AdminMetricsParser.fmtPct(c.cpuPercent),
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                    ),
                    onTap: () => showAdminRecordDetailSheet(
                      context,
                      title: 'Conteneur ${c.shortName}',
                      data: {
                        'metricName': c.shortName,
                        'cpuUsage': c.cpuPercent,
                        'memoryUsage': c.memMb,
                        'timestamp': sys?.timestamp,
                      },
                    ),
                  ),
                )),
          const AdminSectionTitle(title: 'Services web/API', subtitle: 'État instantané'),
          if (_services.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Liste services vide.'))
          else
            ..._services.map((s) {
              final running = s.status == 'running' || s.status == 'online';
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    running ? Icons.circle : Icons.circle_outlined,
                    color: running ? Colors.green : Colors.grey,
                    size: 14,
                  ),
                  title: Text(s.name),
                  subtitle: Text('${s.status} · santé ${s.health}'),
                  trailing: Text(AdminMetricsParser.fmtPct(s.cpuPercent)),
                  onTap: () => showAdminRecordDetailSheet(
                    context,
                    title: 'Service ${s.name}',
                    data: {
                      'metricName': s.name,
                      'severity': s.health,
                      'cpuUsage': s.cpuPercent,
                      'memoryUsage': s.memUsage ?? s.memPercent,
                    },
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildMobileTab() {
    return Column(
      children: [
        AdminTimeRangeBar(
          value: _mobileRange,
          onChanged: (r) {
            setState(() => _mobileRange = r);
            _loadMobile();
          },
        ),
        if (_loadingMobile)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_mobileError != null && _mobileDevices.isEmpty)
          Expanded(child: _errorPanel(_mobileError!, onRetry: _loadMobile))
        else
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadMobile,
              child: ListView(
                padding: adminScrollPadding(context),
                children: [
                  const AdminSectionTitle(
                    title: 'Appareils utilisateurs',
                    subtitle: 'Latence API, charge app — télémétrie mobile (pas l\'hôte PC)',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AdminKpiTile(
                          label: 'Échantillons',
                          value: '${_mobilePerfRaw.length}',
                          icon: Icons.analytics_outlined,
                          color: Colors.deepPurple,
                          subtitle: 'Période ${_mobileRange.label}',
                        ),
                        AdminKpiTile(
                          label: 'Appareils',
                          value: '${_mobileDevices.length}',
                          icon: Icons.phone_android,
                          color: Colors.teal,
                        ),
                      ],
                    ),
                  ),
                  if (_mobileDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucune métrique mobile sur la période. Vérifiez que la télémétrie est ON sur l\'app utilisateur.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    ..._mobileDevices.map((d) {
                      final label = d.deviceModel ?? 'Appareil ${d.deviceKey.substring(0, d.deviceKey.length.clamp(0, 8))}';
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: const Icon(Icons.smartphone),
                          title: Text(label),
                          subtitle: Text(
                            '${d.sampleCount} mesures · v${d.appVersion ?? '?'} · ${d.osVersion ?? ''}\n'
                            'Latence moy. ${d.avgLatencyMs?.toStringAsFixed(0) ?? '—'} ms',
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            final samples = _mobilePerfRaw
                                .where((r) =>
                                    (r['deviceId'] ?? r['sessionId'] ?? r['userId'] ?? 'inconnu').toString() ==
                                    d.deviceKey)
                                .toList();
                            showAdminRecordDetailSheet(
                              context,
                              title: label,
                              data: {
                                'deviceModel': d.deviceModel,
                                'appVersion': d.appVersion,
                                'osVersion': d.osVersion,
                                'duration': d.avgLatencyMs?.round(),
                                'cpuUsage': d.avgCpu,
                                'memoryUsage': d.avgMemory,
                                'timestamp': d.lastSeen?.toIso8601String(),
                                'properties': {'samples': d.sampleCount, 'maxLatencyMs': d.maxLatencyMs},
                              },
                              actions: [
                                Text('Dernières mesures (${samples.length.clamp(0, 5)})',
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                ...samples.take(5).map(
                                      (s) => ListTile(
                                        dense: true,
                                        title: Text(s['metricName']?.toString() ?? 'mesure'),
                                        subtitle: Text('${s['duration'] ?? s['networkLatency'] ?? '?'} ms'),
                                        onTap: () => showAdminRecordDetailSheet(
                                          context,
                                          title: 'Mesure',
                                          data: s,
                                        ),
                                      ),
                                    ),
                              ],
                            );
                          },
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _errorPanel(String message, {required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.orange),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}
