import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jobbingtrack_mobile/navigation/shell_navigation.dart';
import 'package:jobbingtrack_mobile/navigation/app_navigator.dart';
import 'package:jobbingtrack_mobile/utils/shell_layout.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/applications/applications_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/calendar/events_screen.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/dashboard/home_dashboard_tab.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/users/profile_screen.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_update_banner.dart';
import 'package:jobbingtrack_mobile/widgets/shell_connectivity_banner.dart';

/// Shell principal : 4 onglets (Accueil, Candidatures, Calendrier, Profil).
/// La recherche globale reste dans la barre du haut — pas dans la navigation basse.
class MainShellScreen extends StatefulWidget {
  final int initialTab;
  final int applicationsTabIndex;
  final String? applicationStatusFilter;
  final int? returnTabOnBack;

  const MainShellScreen({
    super.key,
    this.initialTab = 0,
    this.applicationsTabIndex = 0,
    this.applicationStatusFilter,
    this.returnTabOnBack,
  });

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  late int _selectedIndex;
  late int _applicationsTabIndex;
  String? _applicationStatusFilter;
  int? _pendingReturnTab;
  final List<int> _bottomNavBackStack = [];
  int _applicationsResetEpoch = 0;
  DateTime? _lastBackToBackgroundPrompt;
  bool _handlingSystemBack = false;
  late final Set<int> _mountedTabs;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialTab.clamp(0, 3);
    _applicationsTabIndex = widget.applicationsTabIndex;
    _applicationStatusFilter = widget.applicationStatusFilter;
    _pendingReturnTab = widget.returnTabOnBack;
    _mountedTabs = {_selectedIndex};
    _syncShellRegistry();
    ShellBackRegistry.registerSystemBackHandler(_handleSystemBack);
    ShellNavigationRegistry.registerApplyHandler(_applyShellNavigation);
  }

  @override
  void dispose() {
    ShellBackRegistry.registerSystemBackHandler(null);
    ShellNavigationRegistry.registerApplyHandler(null);
    super.dispose();
  }

  void _applyShellNavigation(MainShellArgs args) {
    ShellDrawerRegistry.closeAllDrawers();
    setState(() {
      _selectedIndex = args.initialTab.clamp(0, 3);
      _mountedTabs.add(_selectedIndex);
      if (_applicationsTabIndex != args.applicationsTabIndex ||
          _applicationStatusFilter != args.applicationStatusFilter) {
        _applicationsTabIndex = args.applicationsTabIndex;
        _applicationStatusFilter = args.applicationStatusFilter;
        _applicationsResetEpoch++;
      }
      _pendingReturnTab = args.returnTabOnBack;
      if (args.returnTabOnBack != null) {
        _bottomNavBackStack.clear();
      }
      _syncShellRegistry();
    });
  }

  void _syncShellRegistry() {
    ShellTabRegistry.setCurrentTab(
      _selectedIndex,
      applicationsSubTab: _applicationsTabIndex,
    );
  }

  void _selectTab(int index) {
    if (index == _selectedIndex) return;
    ShellDrawerRegistry.closeAllDrawers();
    setState(() {
      _selectedIndex = index;
      _mountedTabs.add(index);
      _pendingReturnTab = null;
      _syncShellRegistry();
    });
  }

  void _openApplications({required int tabIndex, String? statusFilter}) {
    ShellDrawerRegistry.closeAllDrawers();
    setState(() {
      _selectedIndex = 1;
      _mountedTabs.add(1);
      _applicationsTabIndex = tabIndex;
      _applicationStatusFilter = statusFilter;
      _pendingReturnTab = null;
      _syncShellRegistry();
    });
  }

  void _handleSystemBack() {
    if (_handlingSystemBack) return;
    _handlingSystemBack = true;
    try {
      _handleSystemBackImpl();
    } finally {
      _handlingSystemBack = false;
    }
  }

  /// Hiérarchie retour shell — voir docs/mobile/NAVIGATION_RETOUR_MOBILE.md
  void _handleSystemBackImpl() {
    // 0. Drawer ouvert sur l'onglet actif
    if (ShellDrawerRegistry.closeAnyOpenDrawer()) {
      return;
    }
    // 0b. Écran empilé (détail candidature, paramètres profil, …)
    final nav = appNavigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    // 1. Retour drawer cross-tab (ex. Accueil → drawer Entreprises → retour Accueil)
    if (_pendingReturnTab != null && _pendingReturnTab != _selectedIndex) {
      setState(() {
        _selectedIndex = _pendingReturnTab!.clamp(0, 3);
        _pendingReturnTab = null;
        _bottomNavBackStack.clear();
        _syncShellRegistry();
      });
      return;
    }
    // 2. Sous-onglet Candidatures > 0 → liste principale
    if (_selectedIndex == 1 && _applicationsTabIndex > 0) {
      setState(() {
        _applicationsTabIndex = 0;
        _applicationsResetEpoch++;
        _syncShellRegistry();
      });
      return;
    }
    // 2b. Liste candidatures (sous-onglet 0) → Accueil
    if (_selectedIndex == 1 && _applicationsTabIndex == 0) {
      setState(() {
        _selectedIndex = 0;
        _bottomNavBackStack.clear();
        _pendingReturnTab = null;
        _syncShellRegistry();
      });
      return;
    }
    // 3. Retour barre basse (ex. Calendrier → Profil → retour Calendrier)
    if (_bottomNavBackStack.isNotEmpty) {
      final previous = _bottomNavBackStack.removeLast();
      if (previous != _selectedIndex) {
        setState(() {
          _selectedIndex = previous.clamp(0, 3);
          _syncShellRegistry();
        });
        return;
      }
    }
    if (_selectedIndex != 0) {
      setState(() {
        _selectedIndex = 0;
        _syncShellRegistry();
      });
      return;
    }
    _promptBackgroundOnDoubleBack();
  }

  Future<void> _promptBackgroundOnDoubleBack() async {
    final now = DateTime.now();
    if (_lastBackToBackgroundPrompt == null ||
        now.difference(_lastBackToBackgroundPrompt!) > const Duration(seconds: 2)) {
      _lastBackToBackgroundPrompt = now;
      final bottom = mounted ? shellBottomExtra(context) + 8 : kShellBottomNavHeight + 8;
      rootScaffoldMessengerKey.currentState?.clearSnackBars();
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text(
            'Appuyez à nouveau pour mettre l\'application en arrière-plan (pas de fermeture forcée)',
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottom),
          dismissDirection: DismissDirection.down,
        ),
      );
      return;
    }
    const channel = MethodChannel('hubera_id_sso');
    try {
      await channel.invokeMethod<void>('moveToBackground');
    } catch (_) {
      // Pas de finish() de l’activité racine.
    }
  }

  void _reselectApplicationsTab() {
    ShellDrawerRegistry.closeAllDrawers();
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _applicationsTabIndex = 0;
      _applicationStatusFilter = null;
      _applicationsResetEpoch++;
      _syncShellRegistry();
    });
  }

  void _onBottomNavTap(int index) {
    if (index == 1 && _selectedIndex == 1) {
      _reselectApplicationsTab();
      return;
    }
    if (index != _selectedIndex) {
      _bottomNavBackStack.add(_selectedIndex);
      _pendingReturnTab = null;
    }
    _selectTab(index);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Scaffold(
        body: Column(
          children: [
            const MobileUpdateBanner(),
            const ShellConnectivityBanner(),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _mountedTabs.contains(0)
                      ? HomeDashboardTab(
                          isShellVisible: _selectedIndex == 0,
                          onOpenApplications: ({required applicationsTabIndex, statusFilter}) {
                            _openApplications(tabIndex: applicationsTabIndex, statusFilter: statusFilter);
                          },
                        )
                      : const SizedBox.shrink(),
                  _mountedTabs.contains(1)
                      ? ApplicationsScreen(
                          key: ValueKey(
                            'apps-$_applicationsResetEpoch-$_applicationsTabIndex-${_applicationStatusFilter ?? ''}',
                          ),
                          initialTabIndex: _applicationsTabIndex,
                          statusFilter: _applicationStatusFilter,
                          isShellVisible: _selectedIndex == 1,
                          onSubTabIndexChanged: (index) {
                            if (_applicationsTabIndex != index) {
                              setState(() {
                                _applicationsTabIndex = index;
                                _syncShellRegistry();
                              });
                            }
                          },
                        )
                      : const SizedBox.shrink(),
                  _mountedTabs.contains(2)
                      ? EventsScreen(isShellVisible: _selectedIndex == 2)
                      : const SizedBox.shrink(),
                  _mountedTabs.contains(3)
                      ? ProfileScreen(isShellVisible: _selectedIndex == 3)
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: _selectedIndex,
            onTap: _onBottomNavTap,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Accueil'),
              BottomNavigationBarItem(icon: Icon(Icons.assignment), label: 'Candidatures'),
              BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'Calendrier'),
              BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profil'),
            ],
          ),
        ),
      ),
    );
  }
}
