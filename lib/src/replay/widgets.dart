import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../client.dart';
import '../configuration.dart';
import '../internal/diagnostics.dart';
import '../models.dart';
import '../singleton.dart';
import 'capture.dart';

const int _maximumPngBytes = 5 * 1024 * 1024;
const int _snapshotImageNodeId = 6;

/// Root instrumentation widget for replay and automatic Flutter interactions.
///
/// Place this directly above `MaterialApp`, `CupertinoApp`, or the root Router.
/// Replay remains disabled unless sampled or explicitly started on the client.
final class RumApp extends StatelessWidget {
  const RumApp({
    required this.child,
    this.client,
    this.behavior = HitTestBehavior.translucent,
    super.key,
  });

  final Widget child;
  final MoleSignalRumClient? client;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) =>
      RumSessionReplay(client: client, behavior: behavior, child: child);
}

/// Captures privacy-processed Flutter frames into rrweb-compatible events.
///
/// [RumApp] is the preferred public wrapper; use this class directly when only
/// the replay boundary is desired.
final class RumSessionReplay extends StatefulWidget {
  const RumSessionReplay({
    required this.child,
    this.client,
    this.behavior = HitTestBehavior.translucent,
    super.key,
  });

  final Widget child;
  final MoleSignalRumClient? client;
  final HitTestBehavior behavior;

  @override
  State<RumSessionReplay> createState() => _RumSessionReplayState();
}

/// Masks an entire subtree in captured replay frames.
final class RumReplayMask extends StatelessWidget {
  const RumReplayMask({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Replaces an entire sensitive subtree with an opaque block in replay.
///
/// Screenshot replay cannot distinguish DOM-style masking from blocking, so
/// both wrappers intentionally produce the same privacy result.
final class RumReplayBlock extends StatelessWidget {
  const RumReplayBlock({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

final class _RumSessionReplayState extends State<RumSessionReplay>
    implements RumReplayCapture {
  final GlobalKey _boundaryKey = GlobalKey();
  final Map<int, _PointerSample> _pointers = <int, _PointerSample>{};
  final List<_TapSample> _tapSamples = <_TapSample>[];
  final Set<Timer> _deadTapTimers = <Timer>{};

  MoleSignalRumClient? _client;
  String? _sessionId;
  RumReplayEmit? _emit;
  void Function()? _onVisualChange;
  Timer? _captureTimer;
  bool _captureScheduled = false;
  bool _capturing = false;
  bool _captureAgain = false;
  bool _hasSnapshot = false;
  bool _disposed = false;
  int? _lastReplayHash;
  int? _lastFingerprint;
  int? _lastWidth;
  int? _lastHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachClient());
  }

  @override
  void didUpdateWidget(RumSessionReplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _attachClient());
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget boundary = RepaintBoundary(
      key: _boundaryKey,
      child: widget.child,
    );
    if (_client?.userInteractionTrackingEnabled != true) return boundary;
    return Listener(
      behavior: widget.behavior,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: boundary,
    );
  }

  void _attachClient() {
    if (!mounted || _disposed) return;
    final MoleSignalRumClient? next = widget.client ?? getRum();
    if (identical(next, _client)) return;
    _client?.detachReplayCapture(this);
    _client = next;
    next?.attachReplayCapture(this);
    if (next?.frustrationTrackingEnabled == true) {
      unawaited(visualFingerprint(refresh: true));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.detachReplayCapture(this);
    stop();
    for (final Timer timer in _deadTapTimers) {
      timer.cancel();
    }
    _deadTapTimers.clear();
    super.dispose();
  }

  @override
  void start(
    String sessionId,
    RumReplayEmit emit,
    void Function() onVisualChange,
  ) {
    if (_disposed) return;
    final bool changedSession = _sessionId != sessionId;
    _sessionId = sessionId;
    _emit = emit;
    _onVisualChange = onVisualChange;
    if (changedSession) {
      _hasSnapshot = false;
      _lastReplayHash = null;
      _lastWidth = null;
      _lastHeight = null;
    }
    _captureTimer ??= Timer.periodic(_replayConfig.captureInterval, (_) {
      requestCapture();
    });
    requestCapture();
  }

  @override
  void stop() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _sessionId = null;
    _emit = null;
    _onVisualChange = null;
    _captureScheduled = false;
    _captureAgain = false;
    _hasSnapshot = false;
    _lastReplayHash = null;
    _lastWidth = null;
    _lastHeight = null;
  }

  @override
  void requestCapture() {
    if (_sessionId == null || _captureScheduled || _disposed) return;
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      if (!_disposed) unawaited(_captureReplayFrame());
    });
  }

  @override
  void recordPointer(ui.Offset position, {int? timestampMilliseconds}) {
    final String? sessionId = _sessionId;
    final RumReplayEmit? emit = _emit;
    if (!_hasSnapshot || sessionId == null || emit == null) return;
    final RenderRepaintBoundary? boundary = _boundary;
    final Offset local = boundary?.globalToLocal(position) ?? position;
    emit(sessionId, <String, Object?>{
      'type': 3,
      'timestamp':
          timestampMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
      'data': <String, Object?>{
        'source': 2,
        'type': 2,
        'id': _snapshotImageNodeId,
        'x': local.dx.round(),
        'y': local.dy.round(),
        'pointerType': 2,
      },
    });
  }

  @override
  Future<int?> visualFingerprint({bool refresh = false}) async {
    if (!refresh && _lastFingerprint != null) {
      return _lastFingerprint;
    }
    if (_capturing) return _lastFingerprint;
    final RenderRepaintBoundary? boundary = _boundary;
    if (boundary == null || boundary.debugNeedsPaint) return null;
    try {
      final _RawFrame frame = await _captureRaw(boundary, 0.08);
      _lastFingerprint = frame.hash;
      return frame.hash;
    } on Object {
      return null;
    }
  }

  Future<void> _captureReplayFrame() async {
    if (_capturing) {
      _captureAgain = true;
      return;
    }
    final String? sessionId = _sessionId;
    final RumReplayEmit? emit = _emit;
    final RenderRepaintBoundary? boundary = _boundary;
    if (sessionId == null || emit == null || boundary == null) return;
    if (boundary.debugNeedsPaint) {
      requestCapture();
      return;
    }
    _capturing = true;
    try {
      final _EncodedFrame frame = await _captureEncoded(boundary, _pixelRatio);
      if (_sessionId != sessionId || _emit != emit) return;
      if (_lastReplayHash == frame.hash) return;
      if (_lastReplayHash != null) _onVisualChange?.call();
      _lastReplayHash = frame.hash;
      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      final int viewportWidth = boundary.size.width.round();
      final int viewportHeight = boundary.size.height.round();
      final String dataUrl = 'data:image/png;base64,${base64Encode(frame.png)}';

      if (!_hasSnapshot) {
        emit(sessionId, _metaEvent(timestamp, viewportWidth, viewportHeight));
        emit(sessionId, _fullSnapshotEvent(timestamp + 1, dataUrl));
        _hasSnapshot = true;
      } else {
        if (_lastWidth != viewportWidth || _lastHeight != viewportHeight) {
          emit(sessionId, <String, Object?>{
            'type': 3,
            'timestamp': timestamp,
            'data': <String, Object?>{
              'source': 4,
              'width': viewportWidth,
              'height': viewportHeight,
            },
          });
        }
        emit(sessionId, _imageMutationEvent(timestamp + 1, dataUrl));
      }
      _lastWidth = viewportWidth;
      _lastHeight = viewportHeight;
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _client?.diagnosticHandler,
        'RUM replay frame capture failed',
        error,
        stackTrace,
      );
    } finally {
      _capturing = false;
      if (_captureAgain) {
        _captureAgain = false;
        requestCapture();
      }
    }
  }

  Future<_EncodedFrame> _captureEncoded(
    RenderRepaintBoundary boundary,
    double ratio,
  ) async {
    final _RawFrame raw = await _captureRaw(boundary, ratio);
    final Uint8List png = await _encodePng(raw);
    if (png.length > _maximumPngBytes && ratio > 0.15) {
      return _captureEncoded(boundary, ratio / 2);
    }
    return _EncodedFrame(raw.width, raw.height, raw.hash, png);
  }

  Future<_RawFrame> _captureRaw(
    RenderRepaintBoundary boundary,
    double ratio,
  ) async {
    final List<Rect> masks = _collectMaskRects(boundary);
    final ui.Image image = await boundary.toImage(pixelRatio: ratio);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) throw StateError('Flutter returned no replay pixels');
      final Uint8List pixels = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _paintMasks(pixels, image.width, image.height, masks, ratio);
      return _RawFrame(
        image.width,
        image.height,
        pixels,
        _hashPixels(pixels, image.width, image.height),
      );
    } finally {
      image.dispose();
    }
  }

  Future<Uint8List> _encodePng(_RawFrame frame) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      frame.pixels,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      rowBytes: frame.width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    try {
      final ui.FrameInfo info = await codec.getNextFrame();
      try {
        final ByteData? encoded = await info.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (encoded == null) {
          throw StateError('Flutter failed to encode replay');
        }
        return Uint8List.fromList(
          encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          ),
        );
      } finally {
        info.image.dispose();
      }
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  List<Rect> _collectMaskRects(RenderRepaintBoundary boundary) {
    final BuildContext? context = _boundaryKey.currentContext;
    if (context is! Element) return const <Rect>[];
    final List<Rect> result = <Rect>[];

    void visit(Element element) {
      final Widget child = element.widget;
      final bool explicit = child is RumReplayMask || child is RumReplayBlock;
      final bool editable = child is EditableText;
      final bool text = child is Text || child is RichText || editable;
      final bool shouldMask =
          explicit ||
          editable ||
          (_client?.privacyLevel == RumPrivacyLevel.mask && text);
      if (shouldMask) {
        final RenderObject? renderObject = element.findRenderObject();
        if (renderObject is RenderBox &&
            renderObject.attached &&
            renderObject.hasSize) {
          try {
            final Matrix4 transform = renderObject.getTransformTo(boundary);
            final Rect rect = MatrixUtils.transformRect(
              transform,
              Offset.zero & renderObject.size,
            );
            if (rect.isFinite && !rect.isEmpty) result.add(rect);
          } on Object {
            // A detached transition subtree can disappear between traversal
            // and capture. The next frame will retry with the current tree.
          }
        }
        if (explicit || text) return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return result;
  }

  void _paintMasks(
    Uint8List pixels,
    int width,
    int height,
    List<Rect> masks,
    double ratio,
  ) {
    final int color = _replayConfig.maskColorValue;
    final int red = (color >> 16) & 0xff;
    final int green = (color >> 8) & 0xff;
    final int blue = color & 0xff;
    for (final Rect logical in masks) {
      final int left = (logical.left * ratio).floor().clamp(0, width);
      final int top = (logical.top * ratio).floor().clamp(0, height);
      final int right = (logical.right * ratio).ceil().clamp(0, width);
      final int bottom = (logical.bottom * ratio).ceil().clamp(0, height);
      for (int y = top; y < bottom; y += 1) {
        int offset = (y * width + left) * 4;
        for (int x = left; x < right; x += 1) {
          pixels[offset] = red;
          pixels[offset + 1] = green;
          pixels[offset + 2] = blue;
          pixels[offset + 3] = 0xff;
          offset += 4;
        }
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    final MoleSignalRumClient? client = _client;
    if (client == null || !client.userInteractionTrackingEnabled) return;
    final _InteractionTarget target = _interactionTarget(event.position);
    if (!target.interactive) return;
    _pointers[event.pointer] = _PointerSample(
      position: event.position,
      startedAt: DateTime.now(),
      kind: event.kind,
      deadTapEligible: target.deadTapEligible,
      changeId: client.visualChangeId,
      fingerprint: client.frustrationTrackingEnabled
          ? visualFingerprint()
          : Future<int?>.value(),
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    final _PointerSample? sample = _pointers.remove(event.pointer);
    final MoleSignalRumClient? client = _client;
    if (sample == null || client == null) return;
    final Duration elapsed = DateTime.now().difference(sample.startedAt);
    if (elapsed > const Duration(seconds: 1) ||
        (event.position - sample.position).distance > 18) {
      return;
    }

    client.recordAutomaticInteraction(
      'Tap',
      position: event.position,
      context: <String, Object?>{'pointer_kind': sample.kind.name},
    );
    if (!client.frustrationTrackingEnabled) return;
    _detectRageTap(client, event.position);
    if (sample.deadTapEligible) {
      _scheduleDeadTap(client, sample, event.position);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
  }

  void _detectRageTap(MoleSignalRumClient client, Offset position) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _tapSamples.removeWhere((_TapSample sample) => sample.time < now - 1000);
    _tapSamples.add(_TapSample(now, position));
    final int nearby = _tapSamples
        .where(
          (_TapSample sample) => (sample.position - position).distance <= 50,
        )
        .length;
    if (nearby < 3) return;
    client.recordFrustration(
      'rage_click',
      'Repeated Flutter tap',
      context: <String, Object?>{
        'click_count': nearby,
        'window_ms': 1000,
        'x': position.dx.round(),
        'y': position.dy.round(),
      },
    );
    _tapSamples.clear();
  }

  void _scheduleDeadTap(
    MoleSignalRumClient client,
    _PointerSample sample,
    Offset position,
  ) {
    late final Timer timer;
    timer = Timer(const Duration(seconds: 1), () {
      _deadTapTimers.remove(timer);
      unawaited(_checkDeadTap(client, sample, position));
    });
    _deadTapTimers.add(timer);
  }

  Future<void> _checkDeadTap(
    MoleSignalRumClient client,
    _PointerSample sample,
    Offset position,
  ) async {
    final int? before = await sample.fingerprint;
    final int? after = await visualFingerprint(refresh: true);
    if (_disposed ||
        before == null ||
        after == null ||
        before != after ||
        client.visualChangeId != sample.changeId) {
      return;
    }
    client.recordFrustration(
      'dead_click',
      'No response after Flutter tap',
      context: <String, Object?>{
        'wait_ms': 1000,
        'x': position.dx.round(),
        'y': position.dy.round(),
      },
    );
  }

  _InteractionTarget _interactionTarget(Offset globalPosition) {
    final RenderRepaintBoundary? boundary = _boundary;
    if (boundary == null) return const _InteractionTarget(false, false);
    final BoxHitTestResult result = BoxHitTestResult();
    final bool hit = boundary.hitTest(
      result,
      position: boundary.globalToLocal(globalPosition),
    );
    if (!hit) return const _InteractionTarget(false, false);
    bool interactive = false;
    bool editable = false;
    for (final HitTestEntry<HitTestTarget> entry in result.path) {
      final HitTestTarget target = entry.target;
      if (target is RenderEditable) editable = true;
      if (target is RenderSemanticsGestureHandler && target.onTap != null) {
        interactive = true;
      }
      if (target is RenderPointerListener &&
          (target.onPointerDown != null || target.onPointerUp != null)) {
        interactive = true;
      }
    }
    return _InteractionTarget(interactive, interactive && !editable);
  }

  RenderRepaintBoundary? get _boundary {
    final RenderObject? renderObject = _boundaryKey.currentContext
        ?.findRenderObject();
    return renderObject is RenderRepaintBoundary ? renderObject : null;
  }

  RumSessionReplayConfiguration get _replayConfig =>
      _client?.replayConfiguration ?? const RumSessionReplayConfiguration();

  double get _pixelRatio {
    final RenderRepaintBoundary? boundary = _boundary;
    if (boundary == null || !boundary.hasSize) return _replayConfig.pixelRatio;
    final double longest = math.max(boundary.size.width, boundary.size.height);
    if (longest <= 0) return _replayConfig.pixelRatio;
    return math.min(
      _replayConfig.pixelRatio,
      _replayConfig.maximumImageDimension / longest,
    );
  }

  RumContext _metaEvent(int timestamp, int width, int height) =>
      <String, Object?>{
        'type': 4,
        'timestamp': timestamp,
        'data': <String, Object?>{
          'href': _client?.replayPage ?? 'molesignal://flutter/',
          'width': width,
          'height': height,
        },
      };
}

RumContext _fullSnapshotEvent(int timestamp, String dataUrl) =>
    <String, Object?>{
      'type': 2,
      'timestamp': timestamp,
      'data': <String, Object?>{
        'node': <String, Object?>{
          'type': 0,
          'id': 1,
          'childNodes': <Object?>[
            <String, Object?>{
              'type': 1,
              'name': 'html',
              'publicId': '',
              'systemId': '',
              'id': 2,
            },
            <String, Object?>{
              'type': 2,
              'tagName': 'html',
              'attributes': <String, Object?>{
                'style': 'width:100%;height:100%;overflow:hidden;',
              },
              'id': 3,
              'childNodes': <Object?>[
                <String, Object?>{
                  'type': 2,
                  'tagName': 'head',
                  'attributes': <String, Object?>{},
                  'id': 4,
                  'childNodes': <Object?>[],
                },
                <String, Object?>{
                  'type': 2,
                  'tagName': 'body',
                  'attributes': <String, Object?>{
                    'style':
                        'margin:0;width:100vw;height:100vh;overflow:hidden;'
                        'background:#111827;',
                  },
                  'id': 5,
                  'childNodes': <Object?>[
                    <String, Object?>{
                      'type': 2,
                      'tagName': 'img',
                      'attributes': <String, Object?>{
                        'src': dataUrl,
                        'alt': '',
                        'draggable': 'false',
                        'style':
                            'display:block;width:100%;height:100%;'
                            'object-fit:fill;user-select:none;',
                      },
                      'id': _snapshotImageNodeId,
                      'childNodes': <Object?>[],
                    },
                  ],
                },
              ],
            },
          ],
        },
        'initialOffset': <String, Object?>{'left': 0, 'top': 0},
      },
    };

RumContext _imageMutationEvent(int timestamp, String dataUrl) =>
    <String, Object?>{
      'type': 3,
      'timestamp': timestamp,
      'data': <String, Object?>{
        'source': 0,
        'texts': <Object?>[],
        'attributes': <Object?>[
          <String, Object?>{
            'id': _snapshotImageNodeId,
            'attributes': <String, Object?>{'src': dataUrl},
          },
        ],
        'removes': <Object?>[],
        'adds': <Object?>[],
      },
    };

int _hashPixels(Uint8List pixels, int width, int height) {
  int hash = 0x811c9dc5;
  for (int index = 0; index < pixels.length; index += 16) {
    hash ^= pixels[index];
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  hash ^= width;
  hash = (hash * 0x01000193) & 0xffffffff;
  hash ^= height;
  return (hash * 0x01000193) & 0xffffffff;
}

final class _RawFrame {
  const _RawFrame(this.width, this.height, this.pixels, this.hash);

  final int width;
  final int height;
  final Uint8List pixels;
  final int hash;
}

final class _EncodedFrame {
  const _EncodedFrame(this.width, this.height, this.hash, this.png);

  final int width;
  final int height;
  final int hash;
  final Uint8List png;
}

final class _PointerSample {
  const _PointerSample({
    required this.position,
    required this.startedAt,
    required this.kind,
    required this.deadTapEligible,
    required this.changeId,
    required this.fingerprint,
  });

  final Offset position;
  final DateTime startedAt;
  final PointerDeviceKind kind;
  final bool deadTapEligible;
  final int changeId;
  final Future<int?> fingerprint;
}

final class _TapSample {
  const _TapSample(this.time, this.position);

  final int time;
  final Offset position;
}

final class _InteractionTarget {
  const _InteractionTarget(this.interactive, this.deadTapEligible);

  final bool interactive;
  final bool deadTapEligible;
}
