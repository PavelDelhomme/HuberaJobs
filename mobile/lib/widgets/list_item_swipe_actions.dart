import 'package:flutter/material.dart';

/// Action affichée derrière une ligne de liste (swipe).
class SwipeListAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const SwipeListAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });
}

/// Ligne de liste avec swipe : gauche→droite = actions de début (ex. archiver),
/// droite→gauche = actions de fin (ex. modifier + corbeille).
class ListItemSwipeActions extends StatefulWidget {
  final Key itemKey;
  final Widget child;
  final List<SwipeListAction> startActions;
  final List<SwipeListAction> endActions;
  final double actionWidth;

  const ListItemSwipeActions({
    required this.itemKey,
    required this.child,
    this.startActions = const [],
    this.endActions = const [],
    this.actionWidth = 76,
    super.key,
  });

  @override
  State<ListItemSwipeActions> createState() => _ListItemSwipeActionsState();
}

class _ListItemSwipeActionsState extends State<ListItemSwipeActions> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _dragExtent = 0;
  static const double _openThreshold = 36;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _maxStart => widget.startActions.length * widget.actionWidth;
  double get _maxEnd => widget.endActions.length * widget.actionWidth;

  void _close() {
    _controller.stop();
    setState(() => _dragExtent = 0);
  }

  void _snapAfterDrag() {
    if (_dragExtent > _openThreshold && widget.startActions.isNotEmpty) {
      setState(() => _dragExtent = _maxStart);
    } else if (_dragExtent < -_openThreshold && widget.endActions.isNotEmpty) {
      setState(() => _dragExtent = -_maxEnd);
    } else {
      _close();
    }
  }

  Widget _actionButton(SwipeListAction action) {
    return Material(
      color: action.color,
      child: InkWell(
        onTap: () {
          _close();
          action.onPressed();
        },
        child: SizedBox(
          width: widget.actionWidth,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, color: Colors.white, size: 22),
              const SizedBox(height: 4),
              Text(
                action.label,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dragExtent = (_dragExtent + details.delta.dx).clamp(-_maxEnd, _maxStart);
          });
        },
        onHorizontalDragEnd: (_) => _snapAfterDrag(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Row(
                children: [
                  if (widget.startActions.isNotEmpty)
                    Row(children: widget.startActions.map(_actionButton).toList()),
                  const Spacer(),
                  if (widget.endActions.isNotEmpty)
                    Row(children: widget.endActions.map(_actionButton).toList()),
                ],
              ),
            ),
            Transform.translate(
              offset: Offset(_dragExtent, 0),
              child: Builder(
                builder: (context) {
                  final isDark = Theme.of(context).brightness == Brightness.dark;
                  final bg = isDark ? const Color(0xFF342652) : const Color(0xFFF3E8FF);
                  final fg = isDark ? const Color(0xFFF5F3FF) : const Color(0xFF1E1B4B);
                  final sub = isDark ? const Color(0xFFDDD6FE) : const Color(0xFF5B21B6);
                  final theme = Theme.of(context);
                  return Material(
                    key: widget.itemKey,
                    color: bg,
                    child: Theme(
                      data: theme.copyWith(
                        colorScheme: theme.colorScheme.copyWith(
                          onSurface: fg,
                          onSurfaceVariant: sub,
                        ),
                        listTileTheme: ListTileThemeData(
                          textColor: fg,
                          iconColor: fg,
                        ),
                        iconTheme: IconThemeData(color: fg),
                      ),
                      child: widget.child,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
