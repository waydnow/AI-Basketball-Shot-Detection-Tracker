import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/analysis.dart';
import '../data/database.dart';
import '../data/settings.dart';
import '../domain/models.dart';
import 'editor_page.dart';
import 'settings_page.dart';

typedef LibraryEntry = ({Video video, int shots, int makes});

/// The clip library: pick videos in, tap one to mark it up.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.db,
    required this.settings,
    required this.analysis,
  });

  final AppDatabase db;
  final AppSettings settings;
  final AnalysisBackend analysis;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<LibraryEntry> _items = const [];
  bool _loading = true;

  static const _videoExtensions = {'.mp4', '.mov', '.mkv', '.avi', '.3gp', '.webm', '.m4v'};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await widget.db.videoSummaries();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty) return;
    var added = 0, skipped = 0;
    for (final file in picked) {
      final path = file.path.toLowerCase();
      final ext = path.contains('.') ? '.${path.split('.').last}' : '';
      if (!_videoExtensions.contains(ext)) {
        skipped++;
        continue;
      }
      // The picker copies the clip into the app cache, and that path is stable enough to be
      // the row id - which is what keeps re-picking the same clip from duplicating markers.
      await widget.db.upsertVideo(Video(id: file.path, uri: file.path, durationUs: 0));
      added++;
    }
    await _reload();
    if (!mounted || skipped == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$added 个视频已加入，跳过 $skipped 个非视频文件')));
  }

  Future<void> _open(LibraryEntry entry) async {
    await widget.db.upsertVideo(entry.video);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => EditorPage(
        video: entry.video,
        db: widget.db,
        settings: widget.settings,
        analysis: widget.analysis,
      ),
    ));
    await _reload();
  }

  Future<void> _confirmDelete(LibraryEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除这个视频？'),
        content: Text('只从列表里删除，${entry.shots} 个标记也会一并清掉，相册里的原片不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await widget.db.deleteVideo(entry.video);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('篮球高光'),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (context) => SettingsPage(
                      settings: widget.settings, analysisLabel: widget.analysis.label)));
              await _reload();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pick,
        icon: const Icon(Icons.video_library_outlined),
        label: const Text('选择视频'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const _EmptyLibrary()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _tile(_items[i]),
                ),
    );
  }

  Widget _tile(LibraryEntry entry) {
    final video = entry.video;
    return ListTile(
      title: Text(clipLabel(video.uri), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${video.width == 0 ? '规格未知' : '${video.width}x${video.height}'} · '
          '${video.durationUs == 0 ? '时长未知' : formatUs(video.durationUs)}'),
      trailing: entry.shots == 0
          ? const Text('未标记', style: TextStyle(fontSize: 12, color: Colors.white54))
          : Chip(
              label: Text('${entry.makes}/${entry.shots}'),
              visualDensity: VisualDensity.compact,
              backgroundColor: const Color(0x3343A047),
            ),
      onTap: () => _open(entry),
      onLongPress: () => _confirmDelete(entry),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text('还没有视频\n点右下角「选择视频」导入投篮片段',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            const Text('调试视频见 README：push 到 /sdcard/Download/ 之后，\n还要让 MediaProvider 扫一次才会在选择器里出现。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
      ),
    );
  }
}
