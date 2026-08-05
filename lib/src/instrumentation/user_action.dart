import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../client.dart';
import '../models.dart';
import '../singleton.dart';

/// Non-intrusively records a short, low-movement pointer gesture as a RUM tap.
///
/// The widget uses pointer listeners, so it does not compete in Flutter's
/// gesture arena with controls inside [child].
final class RumUserAction extends StatefulWidget {
  const RumUserAction({
    required this.name,
    required this.child,
    this.client,
    this.context = const <String, Object?>{},
    this.behavior = HitTestBehavior.deferToChild,
    this.maximumMovement = 18,
    this.maximumDuration = const Duration(seconds: 1),
    super.key,
  });

  final String name;
  final Widget child;
  final RumClient? client;
  final RumContext context;
  final HitTestBehavior behavior;
  final double maximumMovement;
  final Duration maximumDuration;

  @override
  State<RumUserAction> createState() => _RumUserActionState();
}

final class _RumUserActionState extends State<RumUserAction> {
  int? _pointer;
  Offset? _position;
  DateTime? _startedAt;
  PointerDeviceKind? _kind;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: widget.behavior,
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    onPointerCancel: _onCancel,
    child: widget.child,
  );

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _position = event.position;
    _startedAt = DateTime.now();
    _kind = event.kind;
  }

  void _onUp(PointerUpEvent event) {
    if (_pointer != event.pointer || _position == null || _startedAt == null) {
      return;
    }
    final Duration elapsed = DateTime.now().difference(_startedAt!);
    final double movement = (event.position - _position!).distance;
    if (elapsed <= widget.maximumDuration &&
        movement <= widget.maximumMovement) {
      (widget.client ?? getRum())?.addInteraction(
        widget.name,
        context: <String, Object?>{
          ...widget.context,
          'pointer_kind': _kind?.name,
          'x': event.position.dx.round(),
          'y': event.position.dy.round(),
          'selector': 'flutter:${widget.name}',
        },
      );
    }
    _clear();
  }

  void _onCancel(PointerCancelEvent event) {
    if (_pointer == event.pointer) _clear();
  }

  void _clear() {
    _pointer = null;
    _position = null;
    _startedAt = null;
    _kind = null;
  }
}
