import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../data/database.dart';
import '../data/analysis.dart';
import '../data/settings.dart';
import '../domain/models.dart';
import 'timeline.dart';

/// One clip, its markers, and the cut list they imply.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.video,
    required this.db,
    required this.settings,
    required this.analysis,
  });

  final Video video;
  final AppDatabase db;
  final AppSettings settings;
  final AnalysisBackend analysis;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

enum _Drag { none, pan, pin, before, after, delete }

class _EditorPageState extends State<EditorPage> {
  late VideoPlayerController _controller;
  List<Shot> _shots = const [];
  int? _selectedId;
  TimelineView _view = const TimelineView(durationUs: 0, viewStartUs: 0, viewUs: 1, width: 1);
  _Drag _drag = _Drag.none;
  int _dragAnchorUs = 0;
  Shot? _dragStart;
  Offset _dragPx = Offset.zero;
  bool _dragOffStrip = false;
  int _panStartUs = 0;
  int _positionUs = 0;
  String? _error;
  bool _busy = false;
  bool _full = false;

  @override
  void initState() {
    super.initState();
    _open();
    _load();
  }

  Future<void> _open() async {
    try {
      _controller = VideoPlayerController.file(File(widget.video.uri));
      await _controller.initialize();
      _controller.addListener(_onTick);
      final size = _controller.value.size;
      final meta = widget.video.withMeta(
        durationUs: _controller.value.duration.inMicroseconds,
        width: size.width.round(),
        height: size.height.round(),
      );
      if (!mounted) return;
      setState(() => _view = TimelineView(
          durationUs: meta.durationUs,
          viewStartUs: 0,
          viewUs: meta.durationUs,
          width: 1));
      await widget.db.updateVideoMeta(meta);
    } catch (e) {
      // A photo-picker uri can point at a file the provider no longer serves; the editor
      // shows why instead of dying.
      if (!mounted) return;
      setState(() => _error = '打不开这个视频：$e');
    }
  }

  Future<void> _load() async {
    final shots = await widget.db.shots(widget.video.id);
    if (mounted) setState(() => _shots = shots);
  }

  void _onTick() {
    final us = _controller.value.position.inMicroseconds;
    setState(() {
      _positionUs = us;
      // Only re-layout when the playhead has left the window, so a zoomed-in view does not
      // slide on every frame. The listener also carries the play/pause icon change.
      if (_controller.value.isPlaying &&
          (us < _view.viewStartUs || us > _view.viewStartUs + _view.viewUs)) {
        _view = _view.following(us);
      }
    });
  }

  @override
  void dispose() {
    if (_full) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  /// Full screen is the only way to watch a clip big enough to judge a marker, because the
  /// video slot shares the column with the strip and the shot list.
  void _setFull(bool on) {
    setState(() => _full = on);
    SystemChrome.setEnabledSystemUIMode(
        on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  Future<void> _analyze() async {
    setState(() => _busy = true);
    try {
      final detected = await widget.analysis.analyze(widget.video.id, widget.settings);
      final stored = await widget.db.saveAnalysis(widget.video, detected);
      setState(() {
        _shots = stored;
        _selectedId = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPin(int us) async {
    final id = await widget.db.insertShot(Shot(
      videoId: widget.video.id,
      tUs: us,
      isMake: true,
      origin: ShotOrigin.manual,
      windowBeforeUs: widget.settings.windowBeforeUs,
      windowAfterUs: widget.settings.windowAfterUs,
    ));
    await _load();
    if (!mounted) return;
    setState(() {
      _selectedId = id;
      _view = _view.following(us);
    });
    _controller.seekTo(Duration(microseconds: us));
  }

  Future<void> _delete(Shot shot) async {
    await widget.db.deleteShot(shot);
    await _load();
    if (mounted && _selectedId == shot.id) setState(() => _selectedId = null);
  }

  Future<void> _restore(Shot shot) async {
    await widget.db.insertShot(shot);
    await _load();
  }

  Shot? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final s in _shots) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _beginDrag(DragAction action, Shot? pin, int us) {
    _dragAnchorUs = us;
    _panStartUs = _view.viewStartUs;
    _dragPx = Offset.zero;
    _dragOffStrip = false;
    // Grabbing an unselected pin moves that pin, not whatever was selected before it.
    if (pin != null && pin.id != _selectedId) setState(() => _selectedId = pin.id);
    _dragStart = pin ?? _selected;
    _drag = switch (action) {
      DragAction.movePin => _Drag.pin,
      DragAction.windowBefore => _Drag.before,
      DragAction.windowAfter => _Drag.after,
      _ => _Drag.pan,
    };
  }

  /// The pin keeps its distance from the point you grabbed it at, so it does not jump
  /// under your finger when the window pans.
  void _updateDrag(DragUpdate update) {
    final us = update.us;
    _dragPx += update.delta;
    final start = _dragStart;
    if (_drag == _Drag.pin && pinDragMode(_dragPx) == PinDrag.delete) {
      // Pulling a pin out of the film. Nothing is written to the shot while it is armed, so
      // dragging back in leaves it exactly where it was.
      setState(() => _drag = _Drag.delete);
      return;
    }
    if (_drag == _Drag.delete) {
      if (update.offStrip != _dragOffStrip) setState(() => _dragOffStrip = update.offStrip);
      return;
    }
    if (_drag == _Drag.pan) {
      setState(() => _view = _view.panned(_panStartUs + (_dragAnchorUs - us)));
      return;
    }
    if (start == null) return;
    final delta = us - _dragAnchorUs;
    final duration = _view.durationUs;
    setState(() {
      _shots = [
        for (final s in _shots)
          if (s.id != start.id)
            s
          else
            switch (_drag) {
              _Drag.pin => start.copyWith(
                  tUs: (start.tUs + delta).clamp(0, duration), origin: ShotOrigin.manual),
              _Drag.before => start.copyWith(
                  windowBeforeUs: (start.tUs - us).clamp(0, start.tUs),
                  origin: ShotOrigin.manual),
              _ => start.copyWith(
                  windowAfterUs: (us - start.tUs).clamp(0, duration - start.tUs),
                  origin: ShotOrigin.manual),
            },
      ];
    });
  }

  Future<void> _endDrag() async {
    final kind = _drag;
    final armed = kind == _Drag.delete && _dragOffStrip;
    final dragged = _dragStart;
    setState(() {
      _drag = _Drag.none;
      _dragPx = Offset.zero;
      _dragOffStrip = false;
    });
    if (armed) {
      if (dragged != null) await _delete(dragged);
      if (!mounted || dragged == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${formatUs(dragged.tUs)} 已删除'),
        action: SnackBarAction(label: '撤销', onPressed: () => _restore(dragged)),
      ));
      return;
    }
    if (kind != _Drag.pin && kind != _Drag.before && kind != _Drag.after) return;
    final edited = _selected;
    if (edited != null) await widget.db.updateShot(edited);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _error == null && _controller.value.isInitialized;
    final shots = _shots;
    // A landscape phone has ~400dp of height to spend on the video, the strip and the list.
    // The two tip rows are the cheapest thing to give up, and you have already read them in
    // portrait.
    final shortScreen = MediaQuery.sizeOf(context).height < 700;
    final showTips = !_full && !shortScreen;
    return PopScope(
      canPop: !_full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setFull(false);
      },
      child: Scaffold(
        appBar: _full
            ? null
            : AppBar(
                title:
                    Text(clipLabel(widget.video.uri), maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: [
                  IconButton(
                    tooltip: '生成高光',
                    icon: const Icon(Icons.movie_creation_outlined),
                    onPressed: ready && shots.isNotEmpty ? _showCutPlan : null,
                  ),
                ],
              ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              )
            else if (!ready)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              // A non-flex child of a Column is measured with an unbounded height, so sizing the
              // video off the screen width alone walked 417px off the bottom in landscape. Both
              // flex slots share what the strip leaves, with the video first: a loose child only
              // claims what its aspect ratio fits into, and hands the rest back.
              Flexible(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                      if (_full)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton(
                            tooltip: '退出全屏',
                            icon: const Icon(Icons.close),
                            onPressed: () => _setFull(false),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (ready) ...[
              Row(
                children: [
                  IconButton(
                      icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: () => _controller.value.isPlaying
                          ? _controller.pause()
                          : _controller.play()),
                  Text(formatUs(_positionUs), style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  if (_busy)
                    const SizedBox.square(
                        dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    TextButton.icon(
                      onPressed: _analyze,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('识别'),
                    ),
                  IconButton(
                    tooltip: '在当前时刻添加标记',
                    icon: const Icon(Icons.add_location_alt_outlined),
                    onPressed: () => _addPin(_positionUs),
                  ),
                  IconButton(
                    tooltip: _full ? '退出全屏' : '全屏看这段',
                    icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen),
                    onPressed: () => _setFull(!_full),
                  ),
                ],
              ),
              TimelineControls(
                view: _view,
                onZoom: (factor) => setState(
                    () => _view = _view.zoom(factor, _view.viewStartUs + _view.viewUs ~/ 2)),
                onFit: () => setState(() => _view = _view.fitted()),
              ),
              TimelineStrip(
                view: _view,
                shots: shots,
                positionUs: _positionUs,
                selectedId: _selectedId,
                deleteArmedId: _drag == _Drag.delete && _dragOffStrip ? _dragStart?.id : null,
                onSeek: _seek,
                onPinTap: (shot) {
                  setState(() => _selectedId = shot.id);
                  _seek(shot.tUs);
                },
                onPinLongPress: _addPin,
                onDragStart: _beginDrag,
                onDragUpdate: _updateDrag,
                onDragEnd: _endDrag,
              ),
              if (!_full) ...[
                if (showTips)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Row(
                      children: [
                        const _Key(Color(0xFF43A047), '自动·进球'),
                        const _Key(Color(0xFF43A047), '自动·未中', hollow: true),
                        const _Key(Color(0xFFFFB300), '手动', hollow: true),
                        const Spacer(),
                        Text('${shots.length} 个标记',
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                if (showTips)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('拖动针改时间 · 拖两侧把手改窗口 · 长按空白新增 · 把针拖出时间轴删除',
                            style: TextStyle(fontSize: 11, color: Colors.white54))),
                  ),
                Expanded(
                  flex: 2,
                  child: shots.isEmpty
                      ? const Center(
                          child: Text('还没有标记\n点「识别」跑检测，或长按时间轴手动打点',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white54)))
                      : ListView.builder(
                          itemCount: shots.length,
                          itemBuilder: (context, i) => _row(shots[i]),
                        ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(Shot shot) {
    final selected = shot.id == _selectedId;
    final color = shot.manual ? const Color(0xFFFFB300) : const Color(0xFF43A047);
    // Deleting lives on the timeline (drag the pin out of the film), not here: a row swipe
    // asked the user to hit a 4px-tall target inside a list that shares the screen with a
    // video, a player bar and the strip itself.
    return ListTile(
      selected: selected,
      dense: true,
      leading: Icon(shot.isMake ? Icons.circle : Icons.circle_outlined, color: color, size: 18),
      title: Text('${formatUs(shot.tUs)}  ${shot.isMake ? '进球' : '未中'}'),
      subtitle: Text('±${(shot.windowBeforeUs / 1000000).toStringAsFixed(1)}s / '
          '+${(shot.windowAfterUs / 1000000).toStringAsFixed(1)}s · '
          '${shot.origin == ShotOrigin.auto ? '自动' : '手动'}'),
      trailing: Checkbox(
        value: shot.enabled,
        onChanged: (on) async {
          final updated = shot.copyWith(enabled: on ?? true);
          setState(() => _shots = [
                for (final s in _shots) s.id == shot.id ? updated : s
              ]);
          await widget.db.updateShot(updated);
        },
      ),
      onTap: () => _seek(shot.tUs),
    );
  }

  void _seek(int us) {
    setState(() {
      _positionUs = us;
      _view = _view.following(us);
    });
    _controller.seekTo(Duration(microseconds: us));
  }

  void _showCutPlan() {
    final segments = planSegments(
        shots: _shots,
        durationUs: _view.durationUs,
        includeMisses: widget.settings.includeMisses);
    final tiles = [
      for (var i = 0; i < segments.length; i++)
        ListTile(
          dense: true,
          leading: Text('${i + 1}'),
          title: Text('${formatUs(segments[i].startUs)} → ${formatUs(segments[i].endUs)}'),
          subtitle: Text('${segments[i].shot.isMake ? '进球' : '未中'} · '
              '${(segments[i].durationUs / 1000000).toStringAsFixed(1)}s'),
          onTap: () => _seek(segments[i].shot.tUs),
        ),
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: Text('${segments.length} 段 · 共 '
                  '${formatUs(segments.fold(0, (a, s) => a + s.durationUs))}'),
              subtitle: const Text('裁剪与拼接在阶段 5 接入 FFmpeg，这里先确认截取范围'),
            ),
            const Divider(height: 1),
            Flexible(child: ListView(shrinkWrap: true, children: tiles)),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.color, this.text, {this.hollow = false});

  final Color color;
  final String text;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          Icon(hollow ? Icons.circle_outlined : Icons.circle, size: 12, color: color),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
