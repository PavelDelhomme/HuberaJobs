import 'package:flutter/material.dart';
import 'package:jobbingtrack_mobile/services/mobile_update_controller.dart';
import 'package:jobbingtrack_mobile/widgets/mobile_update_dialog.dart';

/// Bandeau « Mise à jour disponible » — visible dans le shell tant qu’une MAJ attend.
class MobileUpdateBanner extends StatelessWidget {
  const MobileUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MobileUpdateController.instance,
      builder: (context, _) {
        final ctrl = MobileUpdateController.instance;
        final release = ctrl.pendingRelease;
        if (release == null) return const SizedBox.shrink();
        return _BannerInSafeArea(
          child: Material(
            color: Colors.blue.shade50,
            child: InkWell(
              onTap: () async {
                await showMobileUpdateDialog(
                  context,
                  release: release,
                  currentVersion: ctrl.currentVersion ?? '?',
                  forceUpdate: ctrl.forceUpdate,
                  buildsBehind: ctrl.buildsBehind,
                );
                await ctrl.refresh(silent: true);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.system_update, size: 18, color: Colors.blue.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mise à jour ${release.displayVersion} disponible — appuyer pour installer',
                          style: TextStyle(fontSize: 13, color: Colors.blue.shade900),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Colors.blue.shade700),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pousse tout le bandeau (zone de clic comprise) sous l’encoche.
class _BannerInSafeArea extends StatefulWidget {
  const _BannerInSafeArea({required this.child});

  final Widget child;

  @override
  State<_BannerInSafeArea> createState() => _BannerInSafeAreaState();
}

class _BannerInSafeAreaState extends State<_BannerInSafeArea> {
  final _key = GlobalKey();
  double _extra = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  void _place() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final inset = MediaQuery.viewPaddingOf(context).top;
    final next = (_extra + (inset - top)).clamp(0.0, inset);
    if ((next - _extra).abs() <= 0.5) return;
    setState(() => _extra = next);
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: _extra),
      child: KeyedSubtree(key: _key, child: widget.child),
    );
  }
}
