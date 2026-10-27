import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_detector.dart';
import '../data/settings.dart';
import '../domain/letterbox.dart';
import '../domain/shot_logic.dart';

/// Nominal frame rate the live tracker converts wall-clock time with.
///
/// Live frames do not arrive at a constant rate - the worker drops whatever it is busy with -
/// so the frame index is derived from the clock instead of counted. Every window in
/// [ShotTracker] is seconds converted by this number, so as long as the index and the fps use
/// the same value the thresholds stay the per-second thresholds the Python logic used.
const double _nominalFps = 30.0;

/// Rear-camera live mode: count shots and makes while filming, and paint what the detector
/// sees over the preview.
class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> with WidgetsBindingObserver {
  CameraController? _camera;
  LiveDetector? _detector;
  ShotTracker? _tracker;
  StreamSubscription<LiveFrame>? _results;

  String? _blocked;
  int? _rotationOverride;
  bool _overlay = true;

  // Latest detector output, in upright-frame pixels.
  Size _frameSize = Size.zero;
  List<Detection> _balls = const [];
  List<Detection> _hoops = const [];
  List<Tracked> _trail = const [];
  String _verdict = '';
  bool _lastMake = false;

  int _dropped = 0;
  int _prepUs = 0, _inferUs = 0, _postUs = 0;
  final Stopwatch _clock = Stopwatch();
  final List<DateTime> _recentResults = [];

  @override
  void initState() {
    super.initState();
    // Landscape only, because the shot logic's geometry assumes a wide frame with the rim above
    // the ball's arc - which is also what the model saw in training. The capture orientation is
    // deliberately *not* locked; see [_autoRotation].
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // The display rotation is the reference the streamed buffer is turned against, and the
    // phone can change it without sending this page a single camera event.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _results?.cancel();
    _detector?.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The plugin releases the camera while the app is backgrounded. Re-initialise the same
    // controller - building a second one would leak the first and start a second stream.
    final camera = _camera;
    if (state != AppLifecycleState.resumed || camera == null) return;
    _resume(camera);
  }

  Future<void> _resume(CameraController camera) async {
    try {
      await camera.initialize();
      await camera.startImageStream(_onImage);
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      _fail('相机恢复失败：${e.description ?? e.code}');
    }
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        // 16:9, because that is the only geometry the model and the goldens were ever validated
        // on: video_test_5.mp4 is 960x540, which ultralytics letterboxes to 640x384 at imgsz 640.
        // The 4:3 `medium` preset letterboxes to 640x480 instead - more pixels to sample through
        // for a frame shape the graph has never seen.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      await controller.startImageStream(_onImage);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _blocked = null;
      });
    } on CameraException catch (e) {
      _fail('相机不可用：${e.description ?? e.code}（请在系统设置里允许访问摄像头）');
    } catch (e) {
      _fail('$e');
    }
    await _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      final detector = await LiveDetector.load();
      final results = detector.frames.listen(_onResult);
      if (!mounted) {
        await detector.dispose();
        return;
      }
      setState(() {
        _detector = detector;
        _results = results;
        _tracker = _newTracker();
        _clock
          ..reset()
          ..start();
      });
    } catch (e) {
      // best.onnx is not in git: this is the message that tells a fresh checkout to export it.
      _fail('$e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _blocked = message);
  }

  ShotTracker _newTracker() => ShotTracker(
    fps: _nominalFps,
    ballConf: widget.settings.ballConf,
    ballConfNearHoop: widget.settings.ballConfNearHoop,
    hoopConf: widget.settings.hoopConf,
    explain: true,
  );

  /// Degrees the streamed buffer must be turned clockwise to be upright.
  ///
  /// The Android preview widget turns the picture by `sensorOrientation - displayRotation` and
  /// then subtracts the turn `CameraPreview` is about to add, which it reads from
  /// [CameraValue.deviceOrientation]. Nothing else in Flutter can see the display rotation -
  /// `dart:ui` has no such getter - so this is the only reference the boxes can share with the
  /// pixels, and the reason the two agree as long as nothing locks the capture orientation:
  /// a lock changes only `CameraPreview`'s half of that subtraction, and the leftover is exactly
  /// the difference between the lock and the grip - 180 degrees when the phone is held in the
  /// other landscape.
  int _autoRotation(CameraController camera) {
    const screenDegrees = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeRight: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeLeft: 270,
    };
    return (camera.description.sensorOrientation -
            screenDegrees[camera.value.deviceOrientation]! +
            360) %
        360;
  }

  /// The rotation actually in use: the manual chips win over the computed one.
  int _rotation(CameraController camera) =>
      _rotationOverride ?? _autoRotation(camera);

  /// Quarter turns the whole preview box takes on top of the automatic ones, so a manual
  /// rotation turns the pixels the same way it turns the frame the boxes are measured in.
  int _previewTurns(CameraController camera) {
    final override = _rotationOverride;
    if (override == null) return 0;
    return (((override - _autoRotation(camera)) % 360) + 360) % 360 ~/ 90;
  }

  void _onImage(CameraImage image) {
    final camera = _camera, detector = _detector;
    if (camera == null || detector == null) return;
    // The pixel layout assumes the packed single-plane NV21 that `ImageFormatGroup.nv21` asks
    // for. A platform that ignores the request would otherwise feed the graph scrambled bytes
    // and every box would look merely "a bit wrong".
    if (image.format.group != ImageFormatGroup.nv21 ||
        image.planes.length != 1) {
      _badFormat();
      return;
    }
    detector.feed(
      // One packed plane: androidx's `planesToNV21` already dropped any row stride.
      Nv21Frame(
        bytes: image.planes.first.bytes,
        width: image.width,
        height: image.height,
        rotation: _rotation(camera),
      ),
    );
  }

  void _badFormat() {
    if (_blocked != null || !mounted) return;
    setState(
      () => _blocked =
          '这台设备没有把相机输出成 NV21，实时链路只按 NV21 校验过字节布局，'
          '所以这里停止推理，只显示预览',
    );
  }

  void _onResult(LiveFrame frame) {
    final tracker = _tracker, detector = _detector;
    if (tracker == null || detector == null) return;
    final index = (_clock.elapsedMicroseconds * _nominalFps / 1000000).round();
    final events = tracker.addFrame(index, frame.detections);

    _recentResults.add(DateTime.now());
    while (_recentResults.length > 30) {
      _recentResults.removeAt(0);
    }
    _prepUs = frame.prepUs;
    _inferUs = frame.inferUs;
    _postUs = frame.postUs;
    _dropped = detector.dropped;

    setState(() {
      _frameSize = Size(frame.frameW.toDouble(), frame.frameH.toDouble());
      _balls = frame.balls;
      _hoops = frame.hoops;
      _trail = List.of(tracker.ballPos);
      if (events.isNotEmpty) {
        // `reasons` only grows while `explain` is on, and then it appends once per attempt, so
        // its tail explains the newest verdict.
        _lastMake = events.last.isMake;
        _verdict =
            '${_lastMake ? '命中' : '未中'} · ${tracker.reasons.isEmpty ? '' : tracker.reasons.last}';
      }
    });
  }

  /// Detection throughput over the last ~30 results, which is what the overlay lags by.
  double get _rate {
    if (_recentResults.length < 2) return 0;
    final span = _recentResults.last
        .difference(_recentResults.first)
        .inMicroseconds;
    return span == 0 ? 0 : (_recentResults.length - 1) * 1000000 / span;
  }

  void _applySensitivity(DetectionSensitivity s) {
    widget.settings
      ..applyPreset(s)
      ..save();
    // The gates are constructor state of the tracker, so changing them restarts the count.
    setState(_clearCount);
  }

  void _clearCount() {
    _tracker = _newTracker();
    _verdict = '';
    _lastMake = false;
    _trail = const [];
    _balls = const [];
    _hoops = const [];
    _dropped = 0;
    _recentResults.clear();
    _clock
      ..reset()
      ..start();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (camera != null && camera.value.isInitialized)
            // `CameraPreview`'s own AspectRatio cannot assert a ratio under the Stack's tight
            // constraints, so the box is given the frame's ratio here and the preview fills it
            // undistorted - which is also what keeps the overlay's uniform scale honest.
            Center(
              child: AspectRatio(
                aspectRatio: _uprightAspect(camera),
                child: RotatedBox(
                  quarterTurns: _previewTurns(camera),
                  child: CameraPreview(
                    camera,
                    child: _overlay && _detector != null
                        ? IgnorePointer(
                            child: CustomPaint(
                              painter: _BoxPainter(
                                _balls,
                                _hoops,
                                _trail,
                                _frameSize,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          SafeArea(
            child: Column(
              children: [
                _scram(_header()),
                if (_blocked != null) _banner(_blocked!),
                const Spacer(),
                _scram(_controls(), flip: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The preview box's ratio: the streamed size, turned the same way the analysis frame is.
  double _uprightAspect(CameraController camera) {
    final size = camera.value.previewSize!;
    final rotation = _rotation(camera);
    return rotation == 90 || rotation == 270
        ? size.height / size.width
        : size.width / size.height;
  }

  /// What the pipeline is actually seeing, because every one of these numbers is a guess until a
  /// phone answers it: the plugin is free to hand `ImageAnalysis` a different size than the
  /// `previewSize` the preview surface is drawn at, and the boxes are painted into the preview's
  /// box from the analysis frame's coordinates - so if the two aspects disagree the overlay is
  /// stretched, which looks exactly like tracking that cannot hold a hoop.
  /// What the pipeline is actually seeing, in two lines of numbers that cannot be worked out
  /// away from a phone.
  ///
  /// The first is `best conf / the gate the tracker applies` per class - the boxes come back in
  /// score order, so the head of the list is what survives or fails. A hoop below its gate means
  /// no hoop point ever reaches [ShotTracker], and the state machine returns before it looks at
  /// the ball, so no amount of shooting will move the counters. The second is the frame the model
  /// reads against the frame the preview draws: `ImageAnalysis` and the preview surface are
  /// separate CameraX use cases, and if their aspects disagree the boxes are stretched over the
  /// picture - which looks exactly like tracking that cannot hold a hoop.
  List<String> _diag(CameraController? camera) {
    if (camera == null || !camera.value.isInitialized || _frameSize.isEmpty) {
      return const [];
    }
    String gate(List<Detection> boxes, double threshold) => boxes.isEmpty
        ? '无/${threshold.toStringAsFixed(2)}'
        : '${boxes.first.conf.toStringAsFixed(2)}/${threshold.toStringAsFixed(2)}';
    final preview = camera.value.previewSize!;
    final rotation = _rotation(camera);
    final turned = rotation == 90 || rotation == 270
        ? preview.height / preview.width
        : preview.width / preview.height;
    final skew = _frameSize.width / _frameSize.height / turned - 1;
    return [
      '球${_balls.length} ${gate(_balls, widget.settings.ballConf)} · '
          '筐${_hoops.length} ${gate(_hoops, widget.settings.hoopConf)}',
      '分析${_frameSize.width.round()}x${_frameSize.height.round()} 预览'
          '${preview.width.round()}x${preview.height.round()} 转$rotation°'
          '${skew.abs() > 0.02 ? ' 比例差${(skew * 100).round()}%!' : ''}',
    ];
  }

  /// The counters sit over whatever the camera is pointed at, and a bright court swallows
  /// white text, so both bars carry their own gradient.
  Widget _scram(Widget child, {bool flip = false}) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: flip ? Alignment.bottomCenter : Alignment.topCenter,
        end: flip ? Alignment.topCenter : Alignment.bottomCenter,
        colors: const [Color(0xB3000000), Color(0x00000000)],
      ),
    ),
    child: child,
  );

  Widget _header() {
    final tracker = _tracker;
    final preset = widget.settings.preset;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '出手 ${tracker?.attempts ?? 0} · 命中 ${tracker?.makes ?? 0}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  _verdict.isEmpty ? '把篮筐和篮球都框进画面，判定会自动累计' : _verdict,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: _verdict.isEmpty
                        ? Colors.white38
                        : _lastMake
                        ? const Color(0xFF81C784)
                        : const Color(0xFFFFB74D),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${_rate.toStringAsFixed(1)} fps · 丢帧 $_dropped',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
              Text(
                '预处理 ${_ms(_prepUs)} / 推理 ${_ms(_inferUs)} / 解码 ${_ms(_postUs)}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              for (final line in _diag(_camera))
                Text(
                  line,
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
            ],
          ),
          IconButton(
            tooltip: '重新开始计数',
            icon: const Icon(Icons.restart_alt),
            onPressed: () => setState(_clearCount),
          ),
          if (preset != null) _sensitivityMenu(preset),
        ],
      ),
    );
  }

  Widget _sensitivityMenu(
    DetectionSensitivity preset,
  ) => PopupMenuButton<DetectionSensitivity>(
    tooltip: '灵敏度：越高越少框，漏判越多（改完重新计数）',
    icon: Text(
      '灵敏度\n${preset.label}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 11, height: 1.1),
    ),
    onSelected: _applySensitivity,
    itemBuilder: (context) => [
      for (final s in DetectionSensitivity.values)
        PopupMenuItem(
          value: s,
          child: Text(
            '${s.label} 篮球 ${s.ballConf} / 近筐 ${s.ballConfNearHoop} / 篮筐 ${s.hoopConf}',
          ),
        ),
    ],
  );

  Widget _banner(String message) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    child: Container(
      padding: const EdgeInsets.all(10),
      color: const Color(0xCC3B1F1F),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF8A80), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        ],
      ),
    ),
  );

  Widget _controls() {
    final camera = _camera;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          FilterChip(
            selected: _overlay,
            label: const Text('标注'),
            onSelected: (v) => setState(() => _overlay = v),
          ),
          const SizedBox(width: 12),
          const Text(
            '旋转',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            label: Text(
              '自动 ${camera == null ? '' : '${_autoRotation(camera)}°'}',
            ),
            visualDensity: VisualDensity.compact,
            selected: _rotationOverride == null,
            onSelected: (_) => setState(() => _rotationOverride = null),
          ),
          for (final deg in const [0, 90, 180, 270])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                label: Text('$deg°'),
                visualDensity: VisualDensity.compact,
                selected: _rotationOverride == deg,
                onSelected: (_) => setState(() => _rotationOverride = deg),
              ),
            ),
          const Spacer(),
          Text(
            _overlay ? '黄框=篮筐 · 蓝圈=篮球 · 蓝线=轨迹' : '标注已关闭',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

String _ms(int us) => '${(us / 1000).toStringAsFixed(1)}ms';

/// Hoop boxes, the rim segment they imply, the ball circles and the recent ball path - all
/// scaled from frame pixels to the preview box, which is the same rectangle because this
/// painter is `CameraPreview`'s child.
class _BoxPainter extends CustomPainter {
  _BoxPainter(this.balls, this.hoops, this.trail, this.frameSize);

  final List<Detection> balls;
  final List<Detection> hoops;
  final List<Tracked> trail;
  final Size frameSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameSize.isEmpty || size.isEmpty) return;
    final sx = size.width / frameSize.width,
        sy = size.height / frameSize.height;
    Rect box(Detection d) => Rect.fromCenter(
      center: Offset(d.cx * sx, d.cy * sy),
      width: d.w * sx,
      height: d.h * sy,
    );

    for (final hoop in hoops) {
      final r = box(hoop);
      canvas.drawRect(r, _stroke(const Color(0xFFFFD54F)));
      // The rim is the box's top edge, half its width - drawing it separately is what makes a
      // make/miss call checkable on the spot instead of arguable from a still.
      final rim = 0.5 * hoop.w * sx;
      canvas.drawLine(
        Offset(r.center.dx - rim, r.top),
        Offset(r.center.dx + rim, r.top),
        _stroke(const Color(0xFFFF7043), 3),
      );
    }

    if (trail.length > 1) {
      final path = Path()..moveTo(trail.first.x * sx, trail.first.y * sy);
      for (final p in trail.skip(1)) {
        path.lineTo(p.x * sx, p.y * sy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x994FC3F7)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    for (final ball in balls) {
      final r = box(ball);
      canvas.drawCircle(
        r.center,
        r.shortestSide / 2,
        _stroke(const Color(0xFF4FC3F7)),
      );
    }
  }

  Paint _stroke(Color color, [double width = 2]) => Paint()
    ..color = color
    ..strokeWidth = width
    ..style = PaintingStyle.stroke;

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.balls != balls ||
      old.hoops != hoops ||
      old.trail != trail ||
      old.frameSize != frameSize;
}
